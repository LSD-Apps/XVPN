#requires -Version 5.1
# 对 geosite-cn-extra 做**无偏抽样**评测：从清单里随机抽 N 条，逐条解析，
# 用 geoip-cn 判定归属。
#
# 为什么必须随机抽：手挑样本只能证明「我挑的那些没问题」，无法给出清单整体的
# 组成质量。随机抽才能回答「这 11 万条里有多少是活的国内站点、多少是死域名、
# 多少解析到境外」。
#
# 解读要点（避免把结论说过头）：
#   * NXDOMAIN           → 死域名/停放域名。占位但无害（只是让清单变胖）。
#   * 解析到国内网段      → 正确收录。
#   * 解析到境外网段      → **不等于是误命中**：国内站点也可能托管在境外或用
#                          境外 CDN。它只能标记为「需要人工复核」，因为真正
#                          有害的情形是「被墙的境外站点被列进来」，而解析结果
#                          区分不出这一点。
param(
    [int]$SampleSize = 150,
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$singBox = Join-Path $RepoRoot 'app/assets/bin/sing-box.exe'
$ruleDir = Join-Path $RepoRoot 'app/assets/rulesets'
$work = Join-Path ([System.IO.Path]::GetTempPath()) 'xvpn-review'
New-Item -ItemType Directory -Force -Path $work | Out-Null

# 自己反编译，不依赖调用方先做一步：脚本必须能一次跑通，
# 否则「怎么复现这个数字」就散落在命令历史里了。
$extraJson = Join-Path $work 'extra.json'
$geoipJson = Join-Path $work 'geoip.json'
foreach ($pair in @(
        @{ Srs = (Join-Path $ruleDir 'geosite-cn-extra.srs'); Out = $extraJson },
        @{ Srs = (Join-Path $ruleDir 'geoip-cn.srs'); Out = $geoipJson }
    )) {
    if (-not (Test-Path -LiteralPath $pair.Srs)) { throw "缺少规则集：$($pair.Srs)" }
    & $singBox rule-set decompile $pair.Srs -o $pair.Out
    if ($LASTEXITCODE -ne 0) { throw "decompile 失败：$($pair.Srs)" }
}

# ── geoip-cn：解析成 (网络地址, 掩码长度) 并升序排列，供二分查找
$cidrs = @((Get-Content $geoipJson -Raw | ConvertFrom-Json).rules[0].ip_cidr |
    Where-Object { $_ -notmatch ':' })

$nets = New-Object 'System.Collections.Generic.List[object]'
foreach ($c in $cidrs) {
    $parts = $c.Split('/')
    $octets = $parts[0].Split('.')
    $addr = 0
    foreach ($o in $octets) { $addr = ($addr -shl 8) -bor [int]$o }
    $nets.Add([pscustomobject]@{ Addr = $addr; Len = [int]$parts[1] })
}
$sorted = $nets | Sort-Object Addr
$netAddrs = [int[]]($sorted | ForEach-Object { $_.Addr })
$netLens = [int[]]($sorted | ForEach-Object { $_.Len })

function Test-CnIp([string]$ip) {
    if ($ip -match ':') { return $null }   # IPv6 未纳入索引，判定不了
    $octets = $ip.Split('.')
    if ($octets.Count -ne 4) { return $null }
    $addr = 0
    foreach ($o in $octets) {
        $v = 0
        if (-not [int]::TryParse($o, [ref]$v)) { return $null }
        $addr = ($addr -shl 8) -bor $v
    }
    # 二分：找到最后一个 Addr <= 目标
    $lo = 0; $hi = $netAddrs.Count - 1; $cand = -1
    while ($lo -le $hi) {
        $mid = ($lo + $hi) -shr 1
        if ($netAddrs[$mid] -le $addr) { $cand = $mid; $lo = $mid + 1 } else { $hi = $mid - 1 }
    }
    if ($cand -lt 0) { return $false }
    $len = $netLens[$cand]
    if ($len -le 0) { return $true }
    $shift = 32 - $len
    $mask = if ($len -ge 32) { 0xFFFFFFFF } else { ((0xFFFFFFFF -shl $shift) -band 0xFFFFFFFF) }
    return (($addr -band $mask) -eq $netAddrs[$cand])
}

# ── 随机抽样（固定种子 → 评测可复现）
$all = @((Get-Content $extraJson -Raw | ConvertFrom-Json).rules[0].domain_suffix)
$rand = New-Object System.Random 20260913
$sample = New-Object 'System.Collections.Generic.HashSet[string]'
while ($sample.Count -lt [Math]::Min($SampleSize, $all.Count)) {
    [void]$sample.Add($all[$rand.Next(0, $all.Count)])
}

Write-Host ("从 {0} 条中随机抽 {1} 条评测`n" -f $all.Count, $sample.Count)

$dead = 0; $domestic = 0; $foreign = New-Object System.Collections.Generic.List[string]
$mixed = New-Object System.Collections.Generic.List[string]
$done = 0

foreach ($domain in $sample) {
    $done++
    if ($done % 25 -eq 0) { Write-Host ("  ... {0}/{1}" -f $done, $sample.Count) }
    $answers = @()
    try {
        $j = Invoke-RestMethod -Uri "https://dns.alidns.com/resolve?name=$domain&type=A" `
            -TimeoutSec 6 -ErrorAction Stop
        $answers = @($j.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
    }
    catch { $answers = @() }

    if ($answers.Count -eq 0) { $dead++; continue }
    $anyCn = $false; $anyForeign = $false
    foreach ($a in $answers) {
        $r = Test-CnIp $a
        if ($r -eq $true) { $anyCn = $true }
        elseif ($r -eq $false) { $anyForeign = $true }
    }
    if ($anyCn -and -not $anyForeign) { $domestic++ }
    elseif ($anyCn -and $anyForeign) { $mixed.Add("$domain -> $($answers -join ',')") }
    elseif ($anyForeign) { $foreign.Add("$domain -> $($answers -join ',')") }
}

$n = $sample.Count
Write-Host ""
Write-Host "=== 组成质量（随机抽样） ==="
Write-Host ("  解析到国内网段（正确收录） : {0,4}  {1}%" -f $domestic, [math]::Round(100.0*$domestic/$n,1))
Write-Host ("  混合（国内+境外地址）      : {0,4}  {1}%" -f $mixed.Count, [math]::Round(100.0*$mixed.Count/$n,1))
Write-Host ("  仅解析到境外网段           : {0,4}  {1}%" -f $foreign.Count, [math]::Round(100.0*$foreign.Count/$n,1))
Write-Host ("  无解析结果（死域名/停放）  : {0,4}  {1}%" -f $dead, [math]::Round(100.0*$dead/$n,1))
Write-Host ""
if ($mixed.Count -gt 0) { Write-Host '混合样例：'; $mixed | Select-Object -First 8 | ForEach-Object { "   $_" } }
if ($foreign.Count -gt 0) { Write-Host '仅境外样例（需人工复核，不必然是误命中）：'; $foreign | Select-Object -First 12 | ForEach-Object { "   $_" } }
