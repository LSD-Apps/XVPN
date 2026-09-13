# 从随包的 geoip 规则集重新生成中国 IP 前缀索引（assets/rulesets/cn-ip.bin）。
#
#   pwsh scripts/build-cn-ip-index.ps1
#
# 何时需要跑：更新了 geoip-cn.srs **或 geoip-cn-extra.srs** 之后。
# 「检查更新」只会替换 .srs，不会顺带更新 cn-ip.bin，两者不同步会让 DNS
# 交叉校验的地理判定与实际分流依据不一致。
#
# 为什么需要这个文件：geoip-cn.srs 是 zlib 压缩的私有二进制格式，而 Dart
# 标准库没有 inflate，无法在运行时解压。Dart 侧只需要「一个地址是否属于该规则集」
# 这一个布尔判断，因此在构建期把它摊平成一张可直接二分查找的紧凑表。
# 详见 docs/RULES.md 的「geoip-cn 前缀索引」一节。
#
# ── 必须合并两份来源
#
# geoip-cn-extra.srs 补的是 geoip-cn.srs 整块缺失的 8.0.0.0/8（含阿里云国内段）。
# 路由那边由内核的 `rule_set` 取并集，因此这张索引也必须取并集——否则会出现
# 「路由判为直连、判定却认为那是境外地址」，反方向纠正因此永不触发，
# DNS 交叉校验还会把正常的两套部署报成「答案不一致」。
# 缺了合并这一步，补规则集等于只补了一半。
[CmdletBinding()]
param(
    # 仓库根目录。留空时自动取本脚本所在目录的上一级。
    #
    # 刻意不写成 param 默认值里的 (Split-Path -Parent $PSScriptRoot)：
    # Windows PowerShell 5.1 在 param 默认值求值阶段还拿不到 $PSScriptRoot，
    # 会得到空串并直接报错。放到脚本体里求值则 `-File` 与点源两种调用都成立。
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $RepoRoot = (Get-Location).Path
    }
    else {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
    }
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$appDir = Join-Path $RepoRoot 'app'
$singBox = Join-Path $appDir 'assets/bin/sing-box.exe'
$ruleSetDir = Join-Path $appDir 'assets/rulesets'
# 主源 + 补充源。补充源缺失时**直接报错**而不是只做一半：只合并主源会让
# cn-ip.bin 悄悄退回「缺 8.0.0.0/8」的旧行为，而 .srs 那边已经补上了，
# 于是路由与判定不一致——这正是本脚本要避免的。
$sources = @(
    (Join-Path $ruleSetDir 'geoip-cn.srs'),
    (Join-Path $ruleSetDir 'geoip-cn-extra.srs')
)
$output = Join-Path $ruleSetDir 'cn-ip.bin'

foreach ($required in @($singBox) + $sources) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "缺少必需文件：$required（补充源缺失时请先跑 scripts/build-cn-ip-ruleset.ps1）"
    }
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) 'xvpn-cn-ip-index'
if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$jsonInputs = @()
foreach ($src in $sources) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $json = Join-Path $tempDir "$name.json"
    Write-Host "反编译规则集：$src"
    & $singBox rule-set decompile $src -o $json
    if ($LASTEXITCODE -ne 0) {
        throw "sing-box rule-set decompile 失败：$src（退出码 $LASTEXITCODE）"
    }
    $jsonInputs += $json
}

try {
    Write-Host "生成前缀索引：$output"
    Push-Location $appDir
    try {
        & dart run tool/build_cn_ip_index.dart @jsonInputs $output
        if ($LASTEXITCODE -ne 0) {
            throw "build_cn_ip_index 失败（退出码 $LASTEXITCODE）"
        }
    }
    finally {
        Pop-Location
    }

    # 自检：索引必须真的包含补充源补上的那批网段。
    # 只比对条目数是不够的——条目数对但内容错（例如漏掉 MergeCidr）也会通过。
    Write-Host '校验索引内容…'
    $bytes = [System.IO.File]::ReadAllBytes($output)
    $count = [BitConverter]::ToUInt32($bytes, 4)
    Write-Host ("  索引条目数：{0}" -f $count)
    # 8.129.0.0/16：只可能来自补充源（主源 8.x 前缀为 0 条）。
    $needle = [uint32](8 -shl 24 -bor 129 -shl 16)
    $found = $false
    for ($i = 0; $i -lt $count; $i++) {
        $base = 8 + $i * 8
        if ([BitConverter]::ToUInt32($bytes, $base) -eq $needle -and $bytes[$base + 4] -eq 16) {
            $found = $true
            break
        }
    }
    if (-not $found) {
        throw '索引里没有 8.129.0.0/16 —— 补充源没有合并进来，请检查 build_cn_ip_index.dart 的入参'
    }
    Write-Host '  已确认包含 8.129.0.0/16（来自补充源）'
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}

$size = (Get-Item -LiteralPath $output).Length
Write-Host ''
Write-Host "完成：$output（$size 字节）"
Write-Host '提醒：与 geoip-cn.srs、geoip-cn-extra.srs 一起提交，三者必须同源刷新。'
