#requires -Version 5.1
# 测量 geosite-cn-extra 的**运行时**开销。
#
# 为什么必须单独测：此前只量过 `sing-box check` 的耗时（55 KB → 75ms、
# 522 KB → 84ms），那是**配置校验**，不是运行时。真正的成本出现在内核启动时
# 把规则集编译成索引，以及每条连接上做域名匹配。两者都不是 check 能反映的。
#
# 方法：用随包内核在本地跑两种配置（带 / 不带 geosite-cn-extra），
# vpn 出站换成一个必然连不上的本地 socks 端口——因此请求会走到
# 「sniff → 规则匹配 → 落 final=vpn → 立刻失败」这条路径，
# 测到的就是纯粹的路由处理耗时，不含任何真实网络往返。
param(
    [int]$Requests = 300,
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$singBox = Join-Path $RepoRoot 'app/assets/bin/sing-box.exe'
$ruleDir = Join-Path $RepoRoot 'app/assets/rulesets'
$work = Join-Path ([System.IO.Path]::GetTempPath()) 'xvpn-perf'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null

$mixedPort = 12090
$apiPort = 12091

function New-Config {
    param([string[]]$RuleSetNames)
    $sets = @()
    $refs = @()
    foreach ($n in $RuleSetNames) {
        $sets += [ordered]@{
            type   = 'local'
            tag    = $n
            format = 'binary'
            path   = (Join-Path $ruleDir "$n.srs") -replace '\\', '/'
        }
        $refs += $n
    }
    $cfg = [ordered]@{
        log = [ordered]@{ level = 'warn'; timestamp = $false }
        inbounds = @([ordered]@{
            type = 'mixed'; tag = 'mixed-in'; listen = '127.0.0.1'; listen_port = $mixedPort
        })
        outbounds = @(
            # 必连不上的本地出站：让「被判走隧道」的请求立刻失败，不产生外部流量。
            [ordered]@{ type = 'socks'; tag = 'vpn'; server = '127.0.0.1'; server_port = 1 },
            [ordered]@{ type = 'direct'; tag = 'direct' }
        )
        route = [ordered]@{
            rules = @(
                [ordered]@{ action = 'sniff' },
                [ordered]@{ protocol = 'dns'; action = 'hijack-dns' },
                [ordered]@{ ip_is_private = $true; outbound = 'direct' },
                [ordered]@{ rule_set = $refs; outbound = 'direct' }
            )
            rule_set = $sets
            final = 'vpn'
            auto_detect_interface = $true
        }
        experimental = [ordered]@{
            clash_api = [ordered]@{ external_controller = "127.0.0.1:$apiPort" }
        }
    }
    return $cfg
}

function Measure-Variant {
    param([string]$Label, [string[]]$RuleSetNames)

    $cfgPath = Join-Path $work "$Label.json"
    # 无 BOM：带 BOM 时内核报 invalid character 'ï'。
    [System.IO.File]::WriteAllText(
        $cfgPath,
        ((New-Config -RuleSetNames $RuleSetNames) | ConvertTo-Json -Depth 20),
        (New-Object System.Text.UTF8Encoding($false)))

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $singBox -ArgumentList @('run', '-c', $cfgPath, '-D', $work) `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work "$Label.out") `
        -RedirectStandardError (Join-Path $work "$Label.err")

    # 就绪 = Clash API 能应答。它在内核完成初始化（含规则集加载）后才起来。
    $readyMs = $null
    while ($sw.ElapsedMilliseconds -lt 30000) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$apiPort/version" -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
            if ($r.StatusCode -eq 200) { $readyMs = $sw.ElapsedMilliseconds; break }
        } catch { Start-Sleep -Milliseconds 50 }
    }
    if ($null -eq $readyMs) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        throw "$Label 未能就绪；stderr：$(Get-Content (Join-Path $work "$Label.err") -Raw)"
    }

    # 预热若干次，把首次连接的抖动排除。
    for ($i = 0; $i -lt 20; $i++) {
        $null = curl.exe -s --noproxy '*' --proxy "http://127.0.0.1:$mixedPort" `
            -o NUL --max-time 5 'http://no-such-rule.example/' 2>&1
    }

    $samples = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $Requests; $i++) {
        $ms = curl.exe -s --noproxy '*' --proxy "http://127.0.0.1:$mixedPort" -o NUL `
            --max-time 5 -w '%{time_total}' 'http://no-such-rule.example/' 2>&1
        $text = ($ms | Select-Object -Last 1).ToString()
        $val = 0.0
        if ([double]::TryParse($text, [ref]$val)) { $samples.Add($val * 1000.0) }
    }

    $proc = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    $rssMb = if ($proc) { [math]::Round($proc.WorkingSet64 / 1MB, 1) } else { 0 }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400

    $sorted = $samples | Sort-Object
    $median = if ($sorted.Count -gt 0) { $sorted[[int]($sorted.Count / 2)] } else { 0 }
    $p90 = if ($sorted.Count -gt 0) { $sorted[[int]($sorted.Count * 0.9)] } else { 0 }

    return [pscustomobject]@{
        Label    = $Label
        就绪ms   = $readyMs
        内存MB   = $rssMb
        样本数   = $sorted.Count
        中位ms   = [math]::Round($median, 2)
        p90ms    = [math]::Round($p90, 2)
    }
}

$rows = @()
# 交替采样，且**交换先后顺序**。
#
# 单次 A/B 配对不足以得出结论：后跑的那一次可能因为 OS 缓存、热态等原因系统性
# 偏快或偏慢（第一次试跑里 B 的就绪时间反而比 A 短，说明顺序效应真实存在）。
# 这是本项目在 docs/PROTOCOLS.md §3.5.8 记录过的教训——对照实验必须消除时间漂移，
# 否则测到的是「当时机器忙不忙」，而不是被测对象。
$schedule = @(
    @{ Label = 'A-两份'; Sets = @('geosite-cn', 'geoip-cn') },
    @{ Label = 'B-加补充'; Sets = @('geosite-cn', 'geoip-cn', 'geosite-cn-extra') },
    @{ Label = 'B-加补充'; Sets = @('geosite-cn', 'geoip-cn', 'geosite-cn-extra') },
    @{ Label = 'A-两份'; Sets = @('geosite-cn', 'geoip-cn') },
    @{ Label = 'A-两份'; Sets = @('geosite-cn', 'geoip-cn') },
    @{ Label = 'B-加补充'; Sets = @('geosite-cn', 'geoip-cn', 'geosite-cn-extra') }
)
for ($i = 0; $i -lt $schedule.Count; $i++) {
    Write-Host ("  第 {0}/{1} 轮：{2}" -f ($i + 1), $schedule.Count, $schedule[$i].Label)
    $rows += Measure-Variant -Label $schedule[$i].Label -RuleSetNames $schedule[$i].Sets
}

$rows | Format-Table -AutoSize

Write-Host "按变体汇总（中位数取各轮中位数的中位数）："
foreach ($label in @('A-两份', 'B-加补充')) {
    $subset = @($rows | Where-Object { $_.Label -eq $label })
    $med = @($subset | ForEach-Object { $_.中位ms } | Sort-Object)
    $p90 = @($subset | ForEach-Object { $_.p90ms } | Sort-Object)
    $ready = @($subset | ForEach-Object { $_.就绪ms } | Sort-Object)
    $rss = @($subset | ForEach-Object { $_.内存MB } | Sort-Object)
    Write-Host ("  {0,-10} 就绪 {1,5}ms   内存 {2,5}MB   中位 {3,6}ms   p90 {4,6}ms" -f `
        $label, $ready[[int]($ready.Count / 2)], $rss[[int]($rss.Count / 2)], `
        $med[[int]($med.Count / 2)], $p90[[int]($p90.Count / 2)])
}

$sizeA = (Get-Item (Join-Path $ruleDir 'geosite-cn.srs')).Length + (Get-Item (Join-Path $ruleDir 'geoip-cn.srs')).Length
$sizeB = $sizeA + (Get-Item (Join-Path $ruleDir 'geosite-cn-extra.srs')).Length
Write-Host ("规则集体积：A {0:N0} 字节 → B {1:N0} 字节（+{2:N0}）" -f $sizeA, $sizeB, ($sizeB - $sizeA))
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
