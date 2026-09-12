<#
.SYNOPSIS
  跨境链路体检：按目的地给出 TCP 握手丢包率与 RTT 分位，并（可选）采样隧道内时延。

.DESCRIPTION
  为什么量 TCP 握手而不是 ping：
    * ICMP 在相当多的网络里被限速、被丢或被屏蔽，ping 不通不等于链路不通；
    * TCP SYN -> SYN/ACK 走真实业务路径，且 Windows 首个 SYN 重传的 RTO 恰好
      是 1 秒。因此「样本落在 0.5s ~ 1.6s 之间」可以直接当作一次丢包事件来
      计数，无需额外工具（Windows 没有 mtr，pathping 又太慢）。

  丢包率比平均时延重要得多：一条 50ms、丢包 5% 的链路，单个 TCP 连接的吞吐
  上限约 1 Mbps（Mathis 公式），表现就是「网页能打开但很卡、视频转圈」——
  这与服务器 CPU、内存、流量包都无关。

  隧道内时延采样需要 XVPN 处于连接状态（内核 Clash API 监听 127.0.0.1:2081），
  它量的是「客户端 -> 服务器 -> 目标站」整条链路，可用于区分「链路丢包」与
  「隧道自身开销」。

.PARAMETER Targets
  逗号分隔的 host:port 列表。建议同时给一个国内对照与一个国际对照。

.PARAMETER Samples
  每个目的地的采样次数。丢包率的分辨率约为 1/Samples，默认 60 够用。

.EXAMPLE
  # 早高峰跑一次、晚高峰再跑一次，两次之差就是线路拥塞的证据
  .\scripts\diag-crossborder.ps1 -Targets "你的服务器IP:22,223.5.5.5:443,1.1.1.1:80"
#>
param(
  [string]$Targets = '223.5.5.5:443,1.1.1.1:80',
  [int]$Samples = 60,
  [int]$TimeoutMs = 1600
)

$ErrorActionPreference = 'Continue'

function Get-TcpSample {
  param([string]$HostName, [int]$Port, [int]$TimeoutMs)
  $client = New-Object System.Net.Sockets.TcpClient
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $iar = $client.BeginConnect($HostName, $Port, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
      $client.EndConnect($iar)
      $sw.Stop()
      return [double]$sw.Elapsed.TotalMilliseconds
    }
    return 99999.0   # 超时：连 SYN 重传都没回来
  } catch {
    return 88888.0   # 拒绝/不可达：端口被过滤或目标不存在
  } finally {
    $client.Close()
  }
}

function Measure-Target {
  param([string]$Target, [int]$Count, [int]$TimeoutMs)
  $parts = $Target.Trim().Split(':')
  $hostName = $parts[0]
  $port = if ($parts.Count -gt 1 -and $parts[1]) { [int]$parts[1] } else { 443 }

  # 注意：PowerShell 变量名大小写不敏感，累加器不能叫 $Samples（会撞参数）。
  $values = New-Object 'System.Collections.Generic.List[double]'
  for ($i = 0; $i -lt $Count; $i++) {
    $values.Add((Get-TcpSample -HostName $hostName -Port $port -TimeoutMs $TimeoutMs))
  }

  $answered = @($values | Where-Object { $_ -lt 5000 })
  $lost = @($values | Where-Object { $_ -ge 500 -and $_ -lt 5000 })
  $dead = @($values | Where-Object { $_ -ge 5000 })

  $row = [ordered]@{
    Target = "{0}:{1}" -f $hostName, $port
    Count = $Count
    Loss = if ($answered.Count) { [math]::Round($lost.Count / $Count * 100, 1) } else { $null }
    Rto = $lost.Count
    Unreachable = $dead.Count
    Min = $null; P50 = $null; P90 = $null; Max = $null
  }
  if ($answered.Count) {
    $sorted = $answered | Sort-Object
    $row.Min = [math]::Round($sorted[0], 0)
    $row.P50 = [math]::Round($sorted[[int]($sorted.Count * 0.5)], 0)
    $row.P90 = [math]::Round($sorted[[int][math]::Min($sorted.Count - 1, [math]::Floor($sorted.Count * 0.9))], 0)
    $row.Max = [math]::Round($sorted[-1], 0)
  }
  return [pscustomobject]$row
}

function Get-TunnelDelay {
  # 隧道内的真实请求由内核自己发出，因此这个数不受本机其它软件的缓存/代理干扰。
  try {
    $probe = curl.exe -s --noproxy '*' --max-time 15 `
      'http://127.0.0.1:2081/proxies/vpn/delay?timeout=9000&url=http%3A%2F%2F1.1.1.1%2F' 2>$null
    $probe = ($probe -join '')
    if ($probe -match '"delay":(\d+)') { return [int]$Matches[1] }
    if ($probe -match 'Timeout') { return 'TIMEOUT' }
    return $null
  } catch { return $null }
}

$lines = New-Object 'System.Collections.Generic.List[string]'
$lines.Add("时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

$egress = curl.exe -s --noproxy '*' --max-time 10 'http://ip-api.com/json/?fields=country,regionName,isp,as' 2>$null
if ($egress) { $lines.Add("本机出口: $($egress -join '')") }

$lines.Add('')
$lines.Add('目的地                         采样   丢包率  RTO次数  最小  P50   P90   最大')
$lines.Add('-' * 82)
foreach ($raw in ($Targets -split ',')) {
  if (-not $raw.Trim()) { continue }
  $r = Measure-Target -Target $raw -Count $Samples -TimeoutMs $TimeoutMs
  $loss = if ($null -eq $r.Loss) { ' 全部超时' } else { ('{0,5:N1}%' -f $r.Loss) }
  $lines.Add(('{0,-28} {1,5}  {2}  {3,7}  {4,5} {5,5} {6,5} {7,6}' -f `
    $r.Target, $r.Count, $loss, $r.Rto, $r.Min, $r.P50, $r.P90, $r.Max))
}

$lines.Add('')
$delays = @()
for ($i = 0; $i -lt 8; $i++) {
  $d = Get-TunnelDelay
  if ($null -ne $d) { $delays += $d }
}
if ($delays.Count) {
  $num = @($delays | Where-Object { $_ -is [int] })
  $to = @($delays | Where-Object { $_ -eq 'TIMEOUT' }).Count
  if ($num.Count) {
    $sorted = $num | Sort-Object
    $lines.Add("隧道内时延(经 XVPN): n=$($num.Count) 超时=$to 最小=$($sorted[0])ms 中位=$($sorted[[int]($sorted.Count / 2)])ms 最大=$($sorted[-1])ms")
  } else {
    $lines.Add("隧道内时延(经 XVPN): 全部超时 ($to/8)")
  }
  $lines.Add('  判读: 一次 HTTP 往返的理论下限约为 2x TCP 握手 RTT；')
  $lines.Add('        实测远高于此，多出来的部分就是丢包重传与隧道封装的代价。')
} else {
  $lines.Add('隧道内时延: 跳过（127.0.0.1:2081 无响应，即 XVPN 当前未连接）')
}

$lines | ForEach-Object { Write-Host $_ }
