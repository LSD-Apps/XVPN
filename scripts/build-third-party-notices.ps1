# 生成 THIRD-PARTY-NOTICES.md：聚合内核（sing-box）静态内嵌的 Go 依赖许可。
#
#   pwsh scripts/build-third-party-notices.ps1
#
# 为什么需要它：Windows / Linux 的 sing-box 可执行文件与 Android 的 libbox.aar
# 都是静态链接的 Go 程序，除 sing-box 自身外还内嵌了它在 go.mod 里声明的整棵
# 依赖树。BSD-3-Clause 与 Apache-2.0 要求二进制再分发时**复现**版权与许可声明；
# 只在 NOTICE.md 里指向上游 go.mod 并不构成「复现」。本脚本把真实依赖集合与
# 各模块的许可文本落到一个文件里，随发布包一起分发。
#
# 关键点：依赖集合不是抄 sing-box 的 go.mod，而是对**三个实际分发目标**
# （windows/amd64 桌面端、linux/amd64 桌面端、android/arm64 的 libbox）分别跑
# `go list -deps` 求出来的真实链接集合，再取并集。这样：
#   * 平台专属模块（例如 Android 的 cronet 库、Windows 的 wintun）不会被漏掉；
#   * go.mod 里声明但实际没有包被链接的模块不会被误列。
#
# 生成结果应当提交进仓库（发布产物直接复制它，不在 CI 里重跑，避免给发布流水线
# 引入 Go 工具链与模块代理依赖）。sing-box 版本变化时重新运行本脚本并提交。
#
# 依赖：Go 工具链（本机或 CI；GOTOOLCHAIN=auto 会按需拉取最新工具链）与
# 模块代理（默认取 go env 的 GOPROXY，本项目常用 https://goproxy.cn,direct）。

[CmdletBinding()]
param(
    # 仓库根目录。留空时自动取本脚本所在目录的上一级。
    [string]$RepoRoot = '',

    # 输出文件。留空时写到仓库根的 THIRD-PARTY-NOTICES.md。
    [string]$OutputFile = ''
)

$ErrorActionPreference = 'Stop'

# 调 Go 工具链。Windows PowerShell 5.1 在 $ErrorActionPreference='Stop' 下会把
# 原生命令写到 stderr 的正常进度信息（如 "go: creating new go.mod"）当成终止
# 错误，因此这里临时把偏好降级为 Continue，只压制 stderr、按退出码/输出判断成败。
function Invoke-Go {
    param([Parameter(Mandatory = $true)][string[]]$GoArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return (& go @GoArgs 2>$null)
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

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path $RepoRoot 'THIRD-PARTY-NOTICES.md'
}

$versionFile = Join-Path $RepoRoot 'scripts/sing-box-version.txt'
if (-not (Test-Path -LiteralPath $versionFile)) {
    throw "缺少 $versionFile；内核版本必须以该文件为唯一来源。"
}
$singBoxVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if ($singBoxVersion -notmatch '^v') { $singBoxVersion = "v$singBoxVersion" }

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw '未找到 go 命令：本脚本需要 Go 工具链来求解真实依赖集合。'
}

# 工作目录放 .build/（已 gitignore），不污染工作区。
$work = Join-Path $RepoRoot '.build/third-party-notices'
New-Item -ItemType Directory -Force -Path $work | Out-Null

# 三个实际分发目标。构建标签与 .github/workflows/release.yml 校验的官方二进制
# 标签一致；Android 的 gomobile 产物对应 experimental/libbox 包。
$targets = @(
    [pscustomobject]@{ Label = 'windows/amd64'; GOOS = 'windows'; GOARCH = 'amd64'; Package = './cmd/sing-box' },
    [pscustomobject]@{ Label = 'linux/amd64'; GOOS = 'linux'; GOARCH = 'amd64'; Package = './cmd/sing-box' },
    [pscustomobject]@{ Label = 'android/arm64'; GOOS = 'android'; GOARCH = 'arm64'; Package = './experimental/libbox' }
)
$buildTags = 'with_gvisor,with_quic,with_openvpn,with_clash_api,with_naive_outbound'

# 许可标识识别。纯文本匹配，规则从「更具体」到「更一般」，避免 Apache 被 MIT
# 之类的宽泛特征抢先命中。匹配前先把空白（含换行）折叠成单空格：不少模块的
# 许可全文按 72 列硬换行，逐行匹配会漏（例如 coder/websocket 的 ISC 文本
# 在 "for any / purpose" 处断行）。
function Get-LicenseId {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '未识别' }
    $t = ($Text -replace '\s+', ' ')
    if ($t -match 'Apache License' -and $t -match 'Version 2\.0') { return 'Apache-2.0' }
    if ($t -match 'Mozilla Public License' -and $t -match '2\.0') { return 'MPL-2.0' }
    if ($t -match 'GNU AFFERO GENERAL PUBLIC LICENSE') { return 'AGPL-3.0' }
    if ($t -match 'GNU LESSER GENERAL PUBLIC LICENSE' -and $t -match 'Version 3') { return 'LGPL-3.0' }
    if ($t -match 'GNU LESSER GENERAL PUBLIC LICENSE') { return 'LGPL-2.1' }
    if ($t -match 'GNU GENERAL PUBLIC LICENSE' -and $t -match 'Version 3') { return 'GPL-3.0' }
    if ($t -match 'GNU GENERAL PUBLIC LICENSE') { return 'GPL-2.0' }
    if ($t -match 'ISC License') { return 'ISC' }
    if ($t -match 'Permission to use, copy, modify, and' -and
        $t -match 'distribute this software for any purpose' -and
        $t -match 'provided that the above copyright notice') { return 'ISC' }
    if ($t -match 'Permission to use, copy, modify, and/or distribute this software for any purpose' -and
        $t -match 'provided that the above copyright notice') { return 'ISC' }
    if ($t -match 'Permission to use, copy, modify, and/or distribute this software for any purpose') { return '0BSD' }
    if ($t -match 'Redistribution and use in source and binary forms' -and
        ($t -match 'Neither the name' -or $t -match 'neither the name')) { return 'BSD-3-Clause' }
    if ($t -match 'Redistribution and use in source and binary forms') { return 'BSD-2-Clause' }
    if ($t -match 'Permission is hereby granted, free of charge') { return 'MIT' }
    if ($t -match 'Boost Software License') { return 'BSL-1.0' }
    if ($t -match 'This is free and unencumbered software released into the public domain') { return 'Unlicense' }
    if ($t -match 'CC0 1\.0 Universal') { return 'CC0-1.0' }
    if ($t -match 'Creative Commons Attribution 4\.0') { return 'CC-BY-4.0' }
    if ($t -match 'Creative Commons Attribution 3\.0') { return 'CC-BY-3.0' }
    if ($t -match 'altered source versions' -and $t -match 'as-is') { return 'Zlib' }
    if ($t -match 'DO WHAT THE F\*CK YOU WANT') { return 'WTFPL' }
    if ($t -match 'Python Software Foundation License') { return 'Python-2.0' }
    if ($t -match 'public domain') { return 'Public-Domain' }
    # 有些模块把「版权声明」单独成文（如 miekg/dns 的 COPYRIGHT），正文里引用
    # 「见 LICENSE」。它本身不是许可全文，但属于必须随二进制保留的声明。
    if ($t -match 'Copyright' -and $t -match '(?i)license') { return '版权声明（许可见 LICENSE）' }
    return '未识别'
}

# 找出模块根目录下的许可/声明文件。
#
# 只在根目录没有许可文件时，才回退去看 `LICENSES/`（REUSE 规范）。原因：
# sagernet/tailscale 这类仓库自带一个 `LICENSES/` 聚合目录，里面既有 `.md` 说明
# 也有 `licenses.go`、`README.md` 等非许可文件；把整个目录当成「模块自身许可」
# 会引入噪声，也会把 `license_test.go` 这种源码文件误当声明。
function Get-LicenseFiles {
    param([string]$Dir)
    $found = @()
    if (-not (Test-Path -LiteralPath $Dir)) { return $found }
    $skipExtensions = @('.go', '.dart', '.py', '.js', '.ts', '.rs', '.c', '.h', '.cc', '.cpp', '.json', '.yml', '.yaml', '.toml')
    $root = Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '(?i)^(licen[cs]e|copying|copyright|notice)([._-].*)?$' -and
            ($skipExtensions -notcontains $_.Extension.ToLowerInvariant())
        }
    if ($root) { $found += $root }
    if ($found.Count -eq 0) {
        foreach ($sub in @('LICENSES', 'licenses')) {
            $licensesDir = Join-Path $Dir $sub
            if (-not (Test-Path -LiteralPath $licensesDir)) { continue }
            $nested = Get-ChildItem -LiteralPath $licensesDir -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -notmatch '(?i)^(readme|index|licenses)\.' -and
                    ($skipExtensions -notcontains $_.Extension.ToLowerInvariant()) -and
                    $_.Extension -match '(?i)^(\.(txt|md|rst))?$'
                }
            if ($nested) { $found += $nested }
        }
    }
    return @($found | Sort-Object FullName -Unique)
}

Push-Location $work
try {
    if (-not (Test-Path 'go.mod')) { Invoke-Go @('mod', 'init', 'xvpn-notices') | Out-Null }

    Write-Host "解析 sing-box $singBoxVersion 的模块目录…" -ForegroundColor Cyan
    $raw = (Invoke-Go @('mod', 'download', '-json', "github.com/sagernet/sing-box@$singBoxVersion")) -join "`n"
    $brace = $raw.IndexOf('{')
    if ($brace -lt 0) { throw "无法下载 github.com/sagernet/sing-box@$singBoxVersion（检查网络与 GOPROXY）。输出：$raw" }
    $singBoxInfo = $raw.Substring($brace) | ConvertFrom-Json
    $srcDir = $singBoxInfo.Dir
    if (-not (Test-Path -LiteralPath $srcDir)) { throw "sing-box 模块目录不存在：$srcDir" }

    # 逐目标求解真实依赖模块集合。
    $modules = @{}
    $perTarget = @{}
    Push-Location $srcDir
    try {
        foreach ($t in $targets) {
            $env:GOOS = $t.GOOS
            $env:GOARCH = $t.GOARCH
            $env:CGO_ENABLED = '0'
            $env:GOFLAGS = "-tags=$buildTags"
            Write-Host "go list -deps $($t.Label) $($t.Package) …" -ForegroundColor Cyan
            $listing = Invoke-Go @('list', '-deps', '-e', '-f', '{{if .Module}}{{.Module.Path}} {{.Module.Version}}{{end}}', $t.Package)
            $set = @()
            foreach ($line in $listing) {
                if ($line -match '^(\S+) (v\S+)$') {
                    $path = $matches[1]
                    $version = $matches[2]
                    $modules[$path] = $version
                    $set += "$path $version"
                }
            }
            if ($set.Count -eq 0) {
                # 不能让某个目标静默解析为空：那会产出「看起来完整、其实漏了一端」的声明。
                throw "go list 在 $($t.Label) 上没有解析到任何模块；请检查 Go 工具链与模块代理。"
            }
            $perTarget[$t.Label] = @($set | Sort-Object -Unique)
        }
    }
    finally {
        Pop-Location
    }

    if ($modules.Count -eq 0) { throw 'go list 未解析到任何依赖模块，脚本中止以免产出空声明。' }

    Write-Host "共 $($modules.Count) 个模块，开始读取许可文本…" -ForegroundColor Cyan

    $entries = @()
    $unresolved = @()
    foreach ($path in ($modules.Keys | Sort-Object)) {
        $version = $modules[$path]
        try {
            $rawInfo = (Invoke-Go @('mod', 'download', '-json', "$path@$version")) -join "`n"
            $b = $rawInfo.IndexOf('{')
            if ($b -lt 0) { throw 'go mod download 未返回 JSON' }
            $info = $rawInfo.Substring($b) | ConvertFrom-Json
        }
        catch {
            $unresolved += [pscustomobject]@{ Path = $path; Version = $version; Reason = "模块下载失败：$($_.Exception.Message)" }
            continue
        }

        $files = Get-LicenseFiles -Dir $info.Dir
        if ($files.Count -eq 0) {
            $unresolved += [pscustomobject]@{ Path = $path; Version = $version; Reason = '模块内未找到许可/声明文件' }
            continue
        }

        $licenseBlocks = @()
        $ids = @()
        foreach ($f in $files) {
            $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($null -eq $text) { $text = '' }
            $text = $text -replace "`r`n", "`n"
            $id = Get-LicenseId -Text $text
            $ids += $id
            $licenseBlocks += [pscustomobject]@{ Name = $f.Name; Id = $id; Text = $text.TrimEnd() }
        }
        $entries += [pscustomobject]@{
            Path    = $path
            Version = $version
            Ids     = @($ids | Sort-Object -Unique)
            Files   = $licenseBlocks
        }
    }

    # ------------------------------------------------------------ 输出 Markdown
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# 第三方组件许可声明（内核静态依赖聚合）')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('> 本文件由 `scripts/build-third-party-notices.ps1` **自动生成，请勿手工编辑**。')
    [void]$sb.AppendLine('> 重新生成：`pwsh scripts/build-third-party-notices.ps1`。')
    [void]$sb.AppendLine('>')
    [void]$sb.AppendLine('> 覆盖范围：Windows / Linux 桌面端 `sing-box` 可执行文件与 Android `libbox.aar`')
    [void]$sb.AppendLine('> 中**静态链接**的 Go 模块。依赖集合不是照抄上游 `go.mod`，而是对三个实际分发目标')
    [void]$sb.AppendLine('> 分别执行 `go list -deps` 求出的真实链接集合的并集。')
    [void]$sb.AppendLine('> 构建标签：`' + $buildTags + '`。')
    [void]$sb.AppendLine('>')
    [void]$sb.AppendLine("> 内核版本：sing-box $singBoxVersion（唯一来源 `scripts/sing-box-version.txt`）。")
    [void]$sb.AppendLine("> 生成时间：$([DateTime]::UtcNow.ToString('yyyy-MM-dd'))（UTC）。")
    [void]$sb.AppendLine('>')
    [void]$sb.AppendLine('> **本节不是法律意见**：许可识别由文件文本自动判定，可能存在误判；')
    [void]$sb.AppendLine('> 商用再分发前请自行复核上游条款。')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## 依赖总览')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| 模块 | 版本 | 许可（自动识别） |')
    [void]$sb.AppendLine('| --- | --- | --- |')
    foreach ($e in ($entries | Sort-Object Path)) {
        $idText = if ($e.Ids.Count -gt 0) { $e.Ids -join ' / ' } else { '未识别' }
        [void]$sb.AppendLine("| ``$($e.Path)`` | $($e.Version) | $idText |")
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## 许可与声明全文')
    [void]$sb.AppendLine()
    foreach ($e in ($entries | Sort-Object Path)) {
        [void]$sb.AppendLine("### $($e.Path) $($e.Version)")
        [void]$sb.AppendLine()
        foreach ($block in $e.Files) {
            [void]$sb.AppendLine("**$($block.Name)** — 识别为 ``$($block.Id)``")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('````text')
            [void]$sb.AppendLine($block.Text)
            [void]$sb.AppendLine('````')
            [void]$sb.AppendLine()
        }
    }

    [void]$sb.AppendLine('## 未能解析的模块')
    [void]$sb.AppendLine()
    if ($unresolved.Count -eq 0) {
        [void]$sb.AppendLine('无。所有被 `go list -deps` 解析到的模块都取到了许可/声明文件。')
    }
    else {
        [void]$sb.AppendLine('以下模块被解析进依赖集合，但脚本未能取得其许可文件；**请勿据此认为')
        [void]$sb.AppendLine('这些模块没有许可**，而应人工到对应模块目录核对：')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| 模块 | 版本 | 原因 |')
        [void]$sb.AppendLine('| --- | --- | --- |')
        foreach ($u in ($unresolved | Sort-Object Path)) {
            [void]$sb.AppendLine("| ``$($u.Path)`` | $($u.Version) | $($u.Reason) |")
        }
    }
    [void]$sb.AppendLine()

    $encoded = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($OutputFile, $sb.ToString(), $encoded)

    $size = (Get-Item -LiteralPath $OutputFile).Length
    Write-Host '' 
    Write-Host "已生成：$OutputFile（$size 字节）" -ForegroundColor Green
    Write-Host "模块：$($entries.Count) 个已解析，$($unresolved.Count) 个未解析" -ForegroundColor Green
    foreach ($t in $targets) {
        Write-Host ("  " + $t.Label + " 实际链接模块：" + $perTarget[$t.Label].Count)
    }
}
finally {
    Pop-Location
}
