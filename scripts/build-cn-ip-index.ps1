# 从随包的 geoip-cn.srs 重新生成中国 IP 前缀索引（assets/rulesets/cn-ip.bin）。
#
#   pwsh scripts/build-cn-ip-index.ps1
#
# 何时需要跑：更新了 geoip-cn.srs 之后。「检查更新」只会替换 .srs，
# 不会顺带更新 cn-ip.bin，两者不同步会让 DNS 交叉校验的地理判定
# 与实际分流依据不一致。
#
# 为什么需要这个文件：geoip-cn.srs 是 zlib 压缩的私有二进制格式，而 Dart
# 标准库没有 inflate，无法在运行时解压。Dart 侧只需要「一个地址是否属于该规则集」
# 这一个布尔判断，因此在构建期把它摊平成一张可直接二分查找的紧凑表。
# 详见 docs/RULES.md 的「geoip-cn 前缀索引」一节。
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
$ruleSet = Join-Path $appDir 'assets/rulesets/geoip-cn.srs'
$output = Join-Path $appDir 'assets/rulesets/cn-ip.bin'

foreach ($required in @($singBox, $ruleSet)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "缺少必需文件：$required"
    }
}

$tempJson = Join-Path ([System.IO.Path]::GetTempPath()) 'xvpn-geoip-cn.json'

Write-Host "反编译规则集：$ruleSet"
& $singBox rule-set decompile $ruleSet -o $tempJson
if ($LASTEXITCODE -ne 0) {
    throw "sing-box rule-set decompile 失败（退出码 $LASTEXITCODE）"
}

try {
    Write-Host "生成前缀索引：$output"
    Push-Location $appDir
    try {
        & dart run tool/build_cn_ip_index.dart $tempJson $output
        if ($LASTEXITCODE -ne 0) {
            throw "build_cn_ip_index 失败（退出码 $LASTEXITCODE）"
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if (Test-Path -LiteralPath $tempJson) {
        Remove-Item -LiteralPath $tempJson -Force
    }
}

$size = (Get-Item -LiteralPath $output).Length
Write-Host ''
Write-Host "完成：$output（$size 字节）"
Write-Host '提醒：与 geoip-cn.srs 一起提交，两者必须同源。'
