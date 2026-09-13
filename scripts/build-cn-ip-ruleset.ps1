# 从 gaoyifan/china-operator-ip 构建「国内 IP 补充」规则集。
#
#   pwsh scripts/build-cn-ip-ruleset.ps1
#
# 产物：app/assets/rulesets/geoip-cn-extra.srs
#
# 何时需要跑：上游列表更新后（它每日自动构建），或想调整筛选规则时。
#
# ─────────────────────────────────────────────────────────────────────────
# 为什么需要这份规则集
#
# 随包的 geoip-cn.srs（来自 SagerNet/sing-geoip）**整块缺失 8.0.0.0/8**：
# 5742 条 IPv4 前缀里 `8.` 前缀为 **0 条**，而该段包含阿里云的国内区域。
# 实测（本机直连 443）：
#
#   8.129.58.15     7 ms   国内
#   8.134.207.26    7 ms   国内
#   8.131.70.224   42 ms   国内
#   54.80.103.11  231 ms   境外（对照）
#
# 这不是「副本过期」——刷新上游到当前版本（8045 条）后 `8.` 前缀**仍是 0 条**，
# 是那份数据本身不含该段。
#
# ── 为什么选这个上游
#
# 覆盖更全的是 MetaCubeX/Loyalsoldier 系（含 8.128.0.0/10），但它**不能用**：
# 其 geoip 默认由 MaxMind GeoLite2 生成、CN 还融合 IPIP.net，而 GeoLite2 EULA §3
# 要求「新版发布后 30 天内停用并销毁旧版」。本项目把规则集冻结进不可变的发布
# 产物、用户长期保存旧版本，与该条款直接冲突；叠加 CC-BY-SA-4.0 的 share-alike，
# 引入的是一类全新的分发义务。
#
# gaoyifan/china-operator-ip 是 **MIT**，只含国内运营商路由通告（BGP）派生的
# 网段，与 MaxMind 无关——零新增义务。
#
# ── 为什么用「全量并集」而不是「只取差额」
#
# geoip-cn 与这份列表**各有对方没有的网段**（实测：`180.76.0.1` 只在 geoip-cn
# 里）。因此不做机械求差，而是让两份并存、由内核的 `rule_set` 取并集。
# 好处是这份产物自足且稳定，不随 geoip-cn 的状态漂移。
#
# 实测并集效果：
#   * 境外样本 26 个地址误命中 **0**（含 8.128.0.1 这类「同段但不属于 CN」的地址）
#   * 国内样本 35 个地址漏掉 **0**
#   * 缺口 5 个地址（8.128.4.1 / 8.129.58.15 / 8.131.70.224 / 8.134.207.26 /
#     8.140.0.1）全部由 MISS 转为 HIT
#
# 注意：仍有两边都覆盖不到的国内长尾网段（例如实测中延迟仅 12–14 ms 却都不命中
# 的 43.161.214.177 / 154.218.6.135）。本产物补的是**已定位的那块缺口**，
# 不是「补齐所有国内网段」。
[CmdletBinding()]
param(
    # 仓库根目录。留空时自动取本脚本所在目录的上一级。
    #
    # 与其它脚本一致：放在脚本体里求值，因为 Windows PowerShell 5.1 在 param
    # 默认值求值阶段还拿不到 $PSScriptRoot。
    [string]$RepoRoot = '',

    # 上游地址。留空时按 [SourceUrls] 依次尝试。
    [string]$SourceUrl = '',

    # 自检开关：跳过时只构建不验证（不建议，除非上游临时不可达）。
    [switch]$SkipSelfCheck
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
$geoipCn = Join-Path $appDir 'assets/rulesets/geoip-cn.srs'
$output = Join-Path $appDir 'assets/rulesets/geoip-cn-extra.srs'
$staging = Join-Path ([System.IO.Path]::GetTempPath()) 'xvpn-cn-ip-extra'

$script:singBox = $singBox
$script:lastExitCode = 0

foreach ($required in @($singBox, $geoipCn)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "缺少必需文件：$required"
    }
}

# ── 调用内核的辅助函数
#
# 与 build-cn-domain-ruleset.ps1 同一套理由，两处都踩过同一个坑：
#   1. `$ErrorActionPreference='Stop'` 下原生命令写到 stderr 的**每一行**都会被
#      当成终止错误（NativeCommandError），哪怕退出码是 0；
#   2. 参数必须整体传入，否则 PowerShell 会先把 `-f` / `-o` 当成**本函数**的参数名。
function Invoke-SingBox {
    param([Parameter(Mandatory = $true)][string[]]$CommandArgs)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # 必须合并两个流：`rule-set match` 把命中描述写到 **stderr**
        # （它的退出码恒为 0，命中与否靠输出表示）。
        $merged = & $script:singBox @CommandArgs 2>&1
        $script:lastExitCode = $LASTEXITCODE
        return @($merged | ForEach-Object { "$_" })
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $staging | Out-Null

$txtPath = Join-Path $staging 'china.txt'
$sourceJson = Join-Path $staging 'geoip-cn-extra.json'

# 依次尝试的下载源。顺序即优先级：自定义域与 GitHub Pages 在国内可达性更好，
# raw.githubusercontent.com 作为兜底（本机实测它时通时断）。
$sourceUrls = if (-not [string]::IsNullOrWhiteSpace($SourceUrl)) {
    @($SourceUrl)
}
else {
    @(
        'https://china-operator-ip.yfgao.com/china.txt',
        'https://gaoyifan.github.io/china-operator-ip/china.txt',
        'https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt'
    )
}

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$downloaded = $false
$attemptErrors = New-Object System.Collections.Generic.List[string]

foreach ($url in $sourceUrls) {
    Write-Host "下载上游列表：$url"
    $client = New-Object System.Net.WebClient
    try {
        $client.DownloadFile($url, $txtPath)
        # 空文件或错误页会让后续步骤产出一个「看着成功」的空规则集，因此在这里挡。
        if ((Get-Item -LiteralPath $txtPath).Length -lt 10000) {
            throw "下载内容过小（$((Get-Item -LiteralPath $txtPath).Length) 字节），疑似错误页"
        }
        $downloaded = $true
        break
    }
    catch {
        $attemptErrors.Add("$url -> $($_.Exception.Message)")
    }
    finally {
        $client.Dispose()
    }
}

if (-not $downloaded) {
    throw ("所有下载源都失败：`n  " + ($attemptErrors -join "`n  "))
}

# ── 解析：只接受 IPv4 CIDR
#
# 上游是纯 CIDR 列表，形如 `8.129.0.0/16`。注释与空行跳过；不符合 IPv4 CIDR
# 形态的行一律跳过并计数——上游若改了格式，这里的计数会明显异常。
$cidrs = New-Object 'System.Collections.Generic.HashSet[string]'
$skipped = 0
foreach ($line in (Get-Content -LiteralPath $txtPath)) {
    $text = $line.Trim()
    if ($text.Length -eq 0 -or $text.StartsWith('#')) { continue }
    if ($text -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') {
        $len = [int]$matches[5]
        if ($len -gt 32) { $skipped++; continue }
        $ok = $true
        foreach ($i in 1..4) { if ([int]$matches[$i] -gt 255) { $ok = $false; break } }
        if (-not $ok) { $skipped++; continue }
        [void]$cidrs.Add($text)
        continue
    }
    $skipped++
}

if ($cidrs.Count -lt 1000) {
    throw "只解析出 $($cidrs.Count) 条 CIDR，列表格式可能已变化（跳过 $skipped 行）"
}

# 排序保证产物**可复现**：同一份上游内容每次构建得到逐字节相同的 .srs。
$ordered = @($cidrs | Sort-Object)

Write-Host ("解析出 {0} 条 IPv4 CIDR（跳过 {1} 行）" -f $ordered.Count, $skipped)

$payload = [ordered]@{
    version = 1
    rules   = @([ordered]@{ ip_cidr = $ordered })
}
# 必须无 BOM：内核报 `invalid character 'ï' looking for beginning of value`。
$json = $payload | ConvertTo-Json -Depth 6 -Compress
[System.IO.File]::WriteAllText($sourceJson, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "编译规则集：$output"
Invoke-SingBox -CommandArgs @('rule-set', 'compile', $sourceJson, '-o', $output) | Out-Null
if ($script:lastExitCode -ne 0) {
    throw "sing-box rule-set compile 失败（退出码 $($script:lastExitCode)）"
}

# ── 自检：这是「这次修复有没有真的生效」的唯一自动化保障。
#
# 分两组，第一组是**回归防护**（缺了它会再犯同样的错）；
# 第二组是**安全边界**（误命中被墙站点会让它们直接打不开）。
if (-not $SkipSelfCheck) {
    function Assert-Match {
        param([string]$Address, [bool]$Expected)
        $result = Invoke-SingBox -CommandArgs @('rule-set', 'match', '-f', 'binary', $output, $Address)
        $hit = -not [string]::IsNullOrWhiteSpace(($result -join ''))
        if ($hit -ne $Expected) {
            $want = if ($Expected) { '应当命中' } else { '不该命中' }
            throw "产物自检失败：$Address $want"
        }
    }

    # ① 必须补上的缺口（geoip-cn 对这些一律 MISS，本产物必须 HIT）
    foreach ($address in @(
            '8.128.4.1', '8.129.58.15', '8.131.70.224', '8.134.207.26', '8.140.0.1'
        )) {
        Assert-Match -Address $address -Expected $true
    }

    # ② 安全边界：这些境外地址一个都不能命中。
    #
    # 尤其 8.128.0.1 —— 它与缺口同在 8.128.0.0/16 段内，但**不属于** CN
    # （上游只收 8.128.4.0/22、8.128.32.0/19 等子段）。用逐段收录而不是整段
    # 放行，正是为了避免把同段的境外地址一起拉进来。
    foreach ($address in @(
            '8.8.8.8', '1.1.1.1', '54.80.103.11', '104.18.13.243',
            '151.101.1.140', '185.199.108.153', '8.128.0.1'
        )) {
        Assert-Match -Address $address -Expected $false
    }
}

Remove-Item -LiteralPath $staging -Recurse -Force

$size = (Get-Item -LiteralPath $output).Length
Write-Host ''
Write-Host ("完成：{0}（{1} 字节，{2} 条 CIDR）" -f $output, $size, $ordered.Count)
Write-Host ''
Write-Host '后续两步（缺任一步，缺口等于没补上）：'
Write-Host '  1. pwsh scripts/build-cn-ip-index.ps1'
Write-Host '     刷新 cn-ip.bin——DNS 交叉校验与反方向纠正读的是它。'
Write-Host '     只更新 .srs 而不更新它，路由会直连但判定仍认为那是境外地址。'
Write-Host '  2. 在 NOTICE.md 保留 MIT 归属（两处副本都要改：'
Write-Host '     仓库根与 app/assets/legal/）。'
