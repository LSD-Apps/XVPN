# 从 felixonmars/dnsmasq-china-list 构建「国内域名补充」规则集。
#
#   pwsh scripts/build-cn-domain-ruleset.ps1
#
# 产物：app/assets/rulesets/geosite-cn-extra.srs
#
# 何时需要跑：上游列表更新后（它是每天构建的），或想调整筛选规则时。
#
# ─────────────────────────────────────────────────────────────────────────
# 为什么需要这份规则集
#
# 本程序是白名单式直连，而 geoip-cn **不参与域名目标的判定**（实测见
# docs/RULES.md 第二节）：不在 geosite-cn 内的域名必然进隧道，没有任何兜底。
# geosite-cn 是人工维护的列表，覆盖不全——实测 55 个国内站点漏掉 4 个。
# 这份规则集就是用来补这个缺口的。
#
# ── 为什么选这个上游，而不是覆盖率更高的 ChinaMax 系
#
# 覆盖率最好的是 MetaCubeX/meta-rules-dat 的 cn.srs（111022 条，实测零回退、
# 四个漏网站点全部命中）。但它的 geosite:cn 来源是 blackmatrix7/ios_rule_script
# 的 ChinaMax，而那个仓库的许可是 **GPL-2.0（非 or-later）**——GPL-2.0-only
# 不能单向升级到 GPL-3.0，把它再分发进一个 GPL-3.0 项目存在合规灰区。
#
# felixonmars/dnsmasq-china-list 是 **WTFPL v2**：字面意义上的零条件，
# 不存在任何兼容性问题。代价是覆盖窄一些（27355 条，且不含 gaoding/jianyu360/
# gelonghui 那三个），但那三个已由 AppPresets 里实测确认的少量清单覆盖。
# 两条腿一起用：规则集管广度，预置清单管实测缺口。
#
# 想用覆盖率更高的那份时，**不要**把它内置——走「规则集」页新增自定义规则集
# 的入口由用户自己启用（我们只提供链接，不再分发数据）。
#
# ─────────────────────────────────────────────────────────────────────────
# 为什么筛选而不是照单全收
#
# 上游的收录标准是「用国内 DNS 解析更快/更准」，与我们的决策（该不该直连）
# 高度一致但不完全等价。因此这里剔除明显不是域名的行（注释、格式异常、
# 含通配符的条目），避免把垃圾带进路由表。
#
# ── 单标签条目必须保留（否则产物会系统性缺失整个 .cn）
#
# 上游**故意不列举** .cn 等域名，而是靠 dnsmasq 的顶级规则：
#
#     server=/cn/114.114.114.114
#     server=/top/114.114.114.114
#     ...
#
# 它自己的 README 写明了这一点（「不要为已收录的顶级域添加子域，这包括所有
# .cn —— 它们已被 `/cn/` 规则匹配」）。实测：110460 个条目里含 `.cn` 的**为 0**。
#
# 因此这里**必须**把单标签条目当成顶级域后缀收进去，否则产物会缺掉整批域名。
# 这个坑是实测发现的：40 个国内站点里漏掉的 6 个**全是 `.cn`**，
# 而补上之后召回率从 85% 变成 100%。
#
# 语义完全等价，已用随包内核实测过标签边界：
#   dnsmasq `server=/cn/` ≡ sing-box `domain_suffix: ["cn"]`
#     → `cn` / `example.cn` / `deep.sub.example.cn` 命中
#     → `notcn` / `foocn` / `cn.example` / `cnn` 不命中
[CmdletBinding()]
param(
    # 仓库根目录。留空时自动取本脚本所在目录的上一级。
    #
    # 与 build-cn-ip-index.ps1 同样的理由放在脚本体里求值：Windows PowerShell 5.1
    # 在 param 默认值阶段还拿不到 $PSScriptRoot。
    [string]$RepoRoot = '',

    # 上游列表地址。留空时按 [SourceUrls] 的顺序依次尝试。
    #
    # 做成**多源**是必需的，不是锦上添花：raw.githubusercontent.com 在国内时通时断
    # （本项目的内置规则库因此改用 jsDelivr，见 docs/RULES.md）。单源会让这个脚本
    # 在部分网络下直接不可用，而它会失败在一个看起来像「列表格式变了」的地方。
    [string]$SourceUrl = ''
)

$ErrorActionPreference = 'Stop'

# ── 调用内核的辅助函数
#
# 必须包一层，理由有两条：
#
#   1. Windows PowerShell 5.1 在 `$ErrorActionPreference = 'Stop'` 下会把
#      **原生命令写到 stderr 的每一行**都当成终止错误（NativeCommandError），
#      哪怕退出码是 0。内核在正常路径上也会写进度信息，于是「本来成功」的调用
#      会把脚本打断。这里临时放开偏好，只用退出码与 stdout 判断结果。
#   2. 参数必须整体传进来，不能靠 ValueFromRemainingArguments 摊开：那样
#      PowerShell 会先把 `-f` / `-o` 当成**本函数**的参数名去解析，报
#      「参数名不明确」。（踩过一次。）
function Invoke-SingBox {
    param([Parameter(Mandatory = $true)][string[]]$CommandArgs)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # 必须合并两个流：`rule-set match` 把命中描述写到 **stderr**（合理——
        # 它的退出码恒为 0，命中与否靠输出表示）。只收 stdout 会得到空串，
        # 于是「明明命中」被判定为未命中。（踩过一次。）
        $merged = & $script:singBox @CommandArgs 2>&1
        $script:lastExitCode = $LASTEXITCODE
        # 合并后混有 ErrorRecord 对象，统一成字符串再做判空。
        return @($merged | ForEach-Object { "$_" })
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

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
$output = Join-Path $appDir 'assets/rulesets/geosite-cn-extra.srs'
$staging = Join-Path ([System.IO.Path]::GetTempPath()) 'xvpn-cn-extra'

foreach ($required in @($singBox)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "缺少必需文件：$required"
    }
}

if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $staging | Out-Null

$confPath = Join-Path $staging 'accelerated-domains.china.conf'
$sourceJson = Join-Path $staging 'geosite-cn-extra.json'

# 依次尝试的下载源。顺序即优先级：CDN 优先（国内可达性明显更好），
# 官方 raw 作为兜底，最后允许本地文件（便于离线复现）。
$sourceUrls = if (-not [string]::IsNullOrWhiteSpace($SourceUrl)) {
    @($SourceUrl)
}
else {
    @(
        'https://cdn.jsdelivr.net/gh/felixonmars/dnsmasq-china-list@master/accelerated-domains.china.conf'
        'https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf'
    )
}

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$downloaded = $false
$attemptErrors = New-Object System.Collections.Generic.List[string]

foreach ($url in $sourceUrls) {
    Write-Host "下载上游列表：$url"
    if ($url -notmatch '^https?://') {
        # 本地路径：直接复制，便于离线复现构建。
        if (Test-Path -LiteralPath $url) {
            Copy-Item -LiteralPath $url -Destination $confPath -Force
            $downloaded = $true
            break
        }
        $attemptErrors.Add("$url -> 本地文件不存在")
        continue
    }

    $client = New-Object System.Net.WebClient
    try {
        # 用字节流下载而不是 Invoke-WebRequest 的文本模式：后者按响应头猜编码，
        # 而列表里含 punycode 域名，猜错会写坏一批条目。
        $client.DownloadFile($url, $confPath)
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

$lines = Get-Content -LiteralPath $confPath
$domains = New-Object 'System.Collections.Generic.HashSet[string]'
$skipped = 0

foreach ($line in $lines) {
    $text = $line.Trim()
    # 跳过注释与空行。上游用 `#server=/.../... # Disabled: ...` 表示被禁用的条目，
    # 那些必须一并跳过——它们是被上游**明确排除**的域名。
    if ($text.Length -eq 0 -or $text.StartsWith('#')) { continue }

    # 期望形态：server=/<domain>/<dns-server>
    if ($text -notmatch '^server=/([^/]+)/') { $skipped++; continue }
    $domain = $matches[1].Trim().ToLowerInvariant()

    # 含通配符或空白的条目不可用（上游没有，但格式变化时要挡住）。
    if ($domain -match '[\s\*/]') { $skipped++; continue }

    # 单标签条目是**顶级域规则**（`server=/cn/`），必须保留——见文件头的说明。
    # `domain_suffix` 对单标签的匹配行为已用内核验证：只命中该顶级域及其子域。
    if (-not $domain.Contains('.')) {
        [void]$domains.Add($domain)
        continue
    }

    # 多标签域名：去掉首尾点，避免 domain_suffix 语义变形。
    $domain = $domain.Trim('.')
    if (-not $domain.Contains('.')) { $skipped++; continue }

    [void]$domains.Add($domain)
}

if ($domains.Count -eq 0) {
    throw "没有从上游解析出任何域名，列表格式可能已变化：$confPath"
}

# 排序保证产物**可复现**：同一份上游内容每次构建得到逐字节相同的 .srs，
# 提交历史里才不会出现莫名其妙的大 diff。
$ordered = $domains | Sort-Object

Write-Host ("解析出 {0} 个域名（跳过 {1} 行）" -f $ordered.Count, $skipped)

# sing-box 的 rule-set 源格式。version 1 是当前接受的版本。
$payload = [ordered]@{
    version = 1
    rules   = @([ordered]@{ domain_suffix = @($ordered) })
}
# 必须无 BOM：内核报 `invalid character 'ï' looking for beginning of value`
# （这个坑在本仓库里踩过两次，见 docs/PROTOCOLS.md 与测试用例的注释）。
$json = $payload | ConvertTo-Json -Depth 6 -Compress
[System.IO.File]::WriteAllText($sourceJson, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "编译规则集：$output"
Invoke-SingBox -CommandArgs @('rule-set', 'compile', $sourceJson, '-o', $output) | Out-Null
if ($script:lastExitCode -ne 0) {
    throw "sing-box rule-set compile 失败（退出码 $($script:lastExitCode)）"
}

# 自检：产物必须能被内核解析，且行为符合预期。
#
# `rule-set match` 用**输出是否为空**表示命中，而不是退出码；而且条目很多时
# 它把列表打印成 `<binary>`。因此这里只看「有没有输出」。
# 注意变量不能叫 $host：它是 PowerShell 的只读自动变量。
function Assert-Hit {
    param([string]$Pattern, [bool]$Expected)
    $result = Invoke-SingBox -CommandArgs @('rule-set', 'match', '-f', 'binary', $output, $Pattern)
    $hit = -not [string]::IsNullOrWhiteSpace(($result -join ''))
    if ($hit -ne $Expected) {
        $want = if ($Expected) { '应当命中' } else { '不该命中' }
        throw "产物自检失败：$Pattern $want"
    }
}

# ① 普通域名及其子域。
$probeDomain = $ordered | Where-Object { $_.Contains('.') } | Select-Object -First 1
Assert-Hit -Pattern $probeDomain -Expected $true
Assert-Hit -Pattern "probe.$probeDomain" -Expected $true

# ② 顶级域规则必须存在且语义正确。
#
# 这一条是**回归防护**：上游不列举 .cn，靠 `server=/cn/` 规则表达；
# 早期版本的构建脚本把单标签条目当垃圾跳过，于是产物系统性缺失整批 .cn 域名，
# 而 40 个国内站点里漏掉的 6 个全是 .cn——不测这一项，这个坑会再犯一次。
foreach ($tld in @('cn', 'top', 'wang')) {
    if (-not $domains.Contains($tld)) {
        throw "上游缺少顶级规则 /$tld/，列表结构可能已变化，请复核构建脚本"
    }
    Assert-Hit -Pattern "example.$tld" -Expected $true
    Assert-Hit -Pattern "deep.sub.example.$tld" -Expected $true
}
# 标签边界：不能把 `notcn` / `cn.example` 这种误判成中文域名。
Assert-Hit -Pattern 'notcn' -Expected $false
Assert-Hit -Pattern 'cn.example' -Expected $false

# ③ 明确应当走隧道的境外站点不能命中（误判成直连会让它们直接打不开）。
foreach ($foreign in @('www.google.com', 'www.youtube.com', 'github.com', 'api2.cursor.sh')) {
    Assert-Hit -Pattern $foreign -Expected $false
}

Remove-Item -LiteralPath $staging -Recurse -Force

$size = (Get-Item -LiteralPath $output).Length
Write-Host ''
Write-Host ("完成：{0}（{1} 字节，{2} 个域名）" -f $output, $size, $ordered.Count)
Write-Host ''
Write-Host '注意：'
Write-Host '  · 上游许可是 WTFPL v2（零条件），但归属仍要保留——'
Write-Host '    提交前确认 NOTICE.md 里的来源与许可见已同步。'
Write-Host '  · 这是出厂副本，需在 app/lib/core/rulesets.dart 的 builtins 里登记'
Write-Host '    （含来源说明，供界面展示）；默认启用与否也在那里逐条声明。'
Write-Host '  · 它**不可通过「检查更新」下载**（上游给的是 dnsmasq 配置，不是 .srs），'
Write-Host '    要刷新就重跑本脚本。'
Write-Host '  · 上面第 ② 组自检是**回归防护**：上游不列举 .cn，靠 server=/cn/ 这类'
Write-Host '    顶级规则表达。早期版本把单标签条目当垃圾跳过，产物缺了整批 .cn，'
Write-Host '    而 40 个国内站点里漏掉的 6 个全是 .cn——很难从现象看出来。'
