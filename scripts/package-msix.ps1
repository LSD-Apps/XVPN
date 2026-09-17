# 把一个已构建好的 Windows bundle 打成 MSIX 安装包（可选签名）。
#
#   pwsh scripts/package-msix.ps1 -BundleDir <Release 目录> -Version 1.3.0 -OutFile dist\XVPN-1.3.0-windows-x64.msix
#
# 需要 Windows SDK 的 makeappx.exe（找不到时用 -MakeAppx 显式指定）。
#
# 为什么走 makeappx 而不是 MSIX Packaging Tool：后者是交互式工具，只能在
# 有桌面的机器上手工操作，无法进 CI，也无法在「同一次构建里产出 zip 与 msix」
# 这条流水线上复用同一个 bundle。
#
# 签名说明（很重要，直接决定用户装不装得上）：
#   * MSIX 的 Identity/Publisher 必须与签名证书的 Subject **逐字相同**，
#     否则 Add-AppxPackage 会以 0x800B0109 / 0x80073CF0 之类拒绝安装。
#     因此 Publisher 由本脚本统一决定（-Publisher），并据此配证书。
#   * -CertificateThumbprint 给正式发布用（CI 里从 secret 还原 PFX 后取指纹）。
#   * 不指定指纹时本地生成一张自签名证书：**只适合自测**。用户机器上没有这张
#     证书时必须先导入它（脚本会一并导出 .cer），否则装不上。
#   * 完全不签名（-SkipSign）产出的包只能用于检查内容（makeappx unpack / 看
#     清单），装不上。
#
# 桌面快捷方式**不由本脚本创建**：MSIX 没有「安装后运行脚本」的标准钩子，
# 而打包进程写 %USERPROFILE%\Desktop 会被文件系统虚拟化到包私有目录，写不到
# 真实桌面。快捷方式由 scripts/install-msix.ps1 在安装后创建（那是普通
# PowerShell 进程，写的是真实桌面），目标指向本包声明的执行别名 xvpn.exe。

[CmdletBinding()]
param(
    # 已构建好的 Windows bundle（flutter build windows 的 Release 目录）。
    [Parameter(Mandatory = $true)][string]$BundleDir,

    # 版本号，三段（1.3.0）。MSIX 的 Version 是四段，这里补一个 0。
    [Parameter(Mandatory = $true)][string]$Version,

    # 产物路径。
    [Parameter(Mandatory = $true)][string]$OutFile,

    # 包标识名与发布者。发布者必须与签名证书 Subject 一致。
    [string]$IdentityName = 'LUSIDA.XVPN',
    [string]$Publisher = 'CN=LUSIDA',

    # 用户可见的名字与描述。
    [string]$DisplayName = '幽门',
    [string]$Description = '自备配置的智能分流 VPN 客户端',

    # 主程序在包内的相对路径。
    [string]$Executable = 'xvpn.exe',

    # 用于签名的证书指纹（正式发布）。留空时走自签名。
    [string]$CertificateThumbprint = '',

    # 自签名证书导出的公钥路径（供用户手动导入）。留空则不导出。
    [string]$CertificateOut = '',

    # 只打包不签名。用于检查内容。
    [switch]$SkipSign,

    # 跳过时间戳。**只用于本地迭代**：时间戳服务器偶发不可达时，不签时间戳
    # 的包照样能装（只是签名没有可信时间，长期有效性无法证明），因此不该让它
    # 阻塞开发。正式发布不要带这个开关。
    [switch]$SkipTimestamp,

    # makeappx.exe 的路径。留空时自动在 Windows Kits 下找。
    [string]$MakeAppx = '',

    # 临时工作目录。留空时用系统临时目录。
    [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 前置检查

$bundle = (Resolve-Path -LiteralPath $BundleDir).Path
$exe = Join-Path $bundle $Executable
if (-not (Test-Path -LiteralPath $exe)) {
    throw "bundle 里没有 $Executable：$bundle"
}
if (-not (Test-Path -LiteralPath (Join-Path $bundle 'data\flutter_assets'))) {
    throw "bundle 里没有 data\flutter_assets——这不是一个完整的 Flutter Windows 产物：$bundle"
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "版本号必须是三段（如 1.3.0），收到：$Version"
}
# MSIX 的 Version 是四段，且每段必须是 0..65535 的无符号整数。
$msixVersion = "$Version.0"
foreach ($part in $msixVersion.Split('.')) {
    if ([int]$part -gt 65535) { throw "版本段 $part 超出 MSIX 允许的 0..65535" }
}

# 在 Windows Kits 的 bin 下找某个工具。
#
# **只认版本号目录**（10.0.xxxxx.y）。bin 下同时存在 x64 / x86 / arm64 三个
# 架构目录，不加这一层过滤就会先选中它们——那些目录里没有 makeappx / signtool，
# 于是「找到了」变成空值，报出来的却是「找不到」。
function Find-SdkTool {
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($root in @("${env:ProgramFiles(x86)}\Windows Kits\10\bin",
                        "$env:ProgramFiles\Windows Kits\10\bin",
                        'D:\Windows Kits\10\bin')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $found = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^10\.\d+' } |
            Sort-Object { [version]$_.Name } -Descending |
            ForEach-Object { Join-Path $_.FullName "x64\$Name" } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($found) { return $found }
    }
    return $null
}

function Find-MakeAppx {
    if (-not [string]::IsNullOrWhiteSpace($script:MakeAppx)) {
        if (-not (Test-Path -LiteralPath $script:MakeAppx)) {
            throw "指定的 makeappx.exe 不存在：$script:MakeAppx"
        }
        return (Resolve-Path -LiteralPath $script:MakeAppx).Path
    }
    $found = Find-SdkTool -Name 'makeappx.exe'
    if (-not $found) {
        throw '找不到 makeappx.exe。请安装 Windows SDK，或用 -MakeAppx 指定路径。'
    }
    return $found
}

$makeappxPath = Find-MakeAppx
Write-Host "makeappx：$makeappxPath"

# ---------------------------------------------------------------- 图标

# 从 app_icon.ico 里按尺寸抽出 PNG 帧写出去。
#
# 用 .NET 的 Icon 类直接抽帧有两个坑，都在下面绕开了：
#   * 首选尺寸不等于「最接近」的尺寸——Icon 会挑一个不小于请求值的帧，要 310
#     的时候它可能只给 128，于是在 4K 屏上糊成一片。因此显式遍历所有帧，
#     取**不小于目标且最小**的那一帧，没有更大的才退回最大的那帧。
#   * 中转过 Icon 对象会丢掉 alpha：`[System.Drawing.Icon]::FromHandle` 之后
#     再 ToBitmap 得到的图是黑的。所以这里直接读 .ico 里的 PNG 帧字节，
#     app_icon.ico 的每一帧都是 PNG（构建期已确认），不需要解 BMP 帧。
function Export-IconPng {
    param(
        [Parameter(Mandatory = $true)][string]$IcoPath,
        [Parameter(Mandatory = $true)][int[]]$Sizes,
        [Parameter(Mandatory = $true)][string]$DestDir
    )

    $bytes = [System.IO.File]::ReadAllBytes($IcoPath)
    if ($bytes.Length -lt 6) { throw "图标文件太小，不是 .ico：$IcoPath" }
    $imageCount = [BitConverter]::ToUInt16($bytes, 4)

    $frames = @()
    for ($i = 0; $i -lt $imageCount; $i++) {
        $entry = 6 + $i * 16
        if ($entry + 16 -gt $bytes.Length) { break }
        $width = [int]$bytes[$entry]
        $height = [int]$bytes[$entry + 1]
        # .ico 里 0 表示 256。
        if ($width -eq 0) { $width = 256 }
        if ($height -eq 0) { $height = 256 }
        $length = [BitConverter]::ToUInt32($bytes, $entry + 8)
        $offset = [BitConverter]::ToUInt32($bytes, $entry + 12)
        if ($offset + $length -gt $bytes.Length) { continue }
        # 只接受 PNG 帧：MSIX 的资源图必须是 PNG，而 .ico 里的 BMP 帧
        # 直接改名成 .png 是无效文件。
        $isPng = $bytes[$offset] -eq 0x89 -and $bytes[$offset + 1] -eq 0x50 -and
                 $bytes[$offset + 2] -eq 0x4E -and $bytes[$offset + 3] -eq 0x47
        if (-not $isPng) { continue }
        $frames += [pscustomobject]@{ Width = $width; Height = $height; Offset = $offset; Length = $length }
    }
    if ($frames.Count -eq 0) {
        throw "$IcoPath 里没有 PNG 帧。MSIX 的图标必须是 PNG，请改用含 PNG 帧的 .ico。"
    }

    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    foreach ($size in $Sizes) {
        $pick = $frames |
            Where-Object { $_.Width -ge $size } |
            Sort-Object Width |
            Select-Object -First 1
        if (-not $pick) {
            # 没有这么大的帧：用最大的那帧。MSIX 会缩放，总比没有图标强。
            $pick = $frames | Sort-Object Width -Descending | Select-Object -First 1
            Write-Warning "$IcoPath 里没有 ${size}x${size} 的帧，用 $($pick.Width)x$($pick.Height) 代替。"
        }
        $dest = Join-Path $DestDir "icon-$size.png"
        $frame = New-Object byte[] $pick.Length
        [Array]::Copy($bytes, $pick.Offset, $frame, 0, $pick.Length)
        [System.IO.File]::WriteAllBytes($dest, $frame)
    }
}

# ---------------------------------------------------------------- 资源图

# MSIX 的每个资源图都有**固定的像素尺寸**，名称也必须逐字符合约定：
#
#   Square44x44Logo.png    44 x 44
#   Square150x150Logo.png 150 x 150
#   Wide310x150Logo.png   310 x 150
#   SplashScreen.png      620 x 300
#   StoreLogo.png          50 x 50
#
# app_icon.ico 里最大只有 256 的**方**帧，因此宽磁贴与启动画面必须自己合成：
# 把方图按短边居中贴到目标画布上，其余位置留透明。此前直接把 310 的方图当宽
# 磁贴用——尺寸不对的图不会让 makeappx 报错，只会在开始菜单里被拉成变形的
# 一块，属于「能装上但难看」的那类问题。
function Resize-Png {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][string]$DestPath
    )

    Add-Type -AssemblyName System.Drawing
    $source = [System.Drawing.Image]::FromFile($SourcePath)
    try {
        $bitmap = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                # 画布保持透明（PNG 的 alpha 就是它），不做填充。
                if ($Width -eq $Height) {
                    # 方图：整块铺满。
                    $graphics.DrawImage($source, (New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)))
                }
                else {
                    # 非方图：把图标缩到短边高度、水平居中，与系统对宽磁贴的
                    # 常规呈现一致。
                    $side = $Height
                    $left = [int](($Width - $side) / 2)
                    $graphics.DrawImage($source, (New-Object System.Drawing.Rectangle($left, 0, $side, $side)))
                }
            }
            finally { $graphics.Dispose() }
            $bitmap.Save($DestPath, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally { $bitmap.Dispose() }
    }
    finally { $source.Dispose() }
}

function New-PackageAssets {
    param(
        [Parameter(Mandatory = $true)][string]$IcoPath,
        [Parameter(Mandatory = $true)][string]$DestDir
    )

    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $rawDir = Join-Path $DestDir 'raw'
    try {
        # 全部从最大的方帧出发，再由 [Resize-Png] 落到各自的目标尺寸：直接从
        # 小帧放大到 620 会糊，而从 256 缩放的质量明显更好。
        Export-IconPng -IcoPath $IcoPath -Sizes @(256) -DestDir $rawDir
        $master = Join-Path $rawDir 'icon-256.png'

        foreach ($spec in @(
            @{ Name = 'Square44x44Logo.png';   W = 44;  H = 44 },
            @{ Name = 'Square150x150Logo.png'; W = 150; H = 150 },
            @{ Name = 'Wide310x150Logo.png';   W = 310; H = 150 },
            @{ Name = 'SplashScreen.png';      W = 620; H = 300 },
            @{ Name = 'StoreLogo.png';         W = 50;  H = 50 },
            # 256 的大图**不被清单引用**，只给安装脚本合成桌面快捷方式图标用。
            # 为什么要放进包里：快捷方式的目标是执行别名（0 字节重解析点，没有
            # 图标资源），因此必须有一份真实图片文件；而包内 Assets 是**不带
            # 版本号**的稳定位置，随包永久存在，适合当那个来源。
            # 小尺寸从它缩小，44 的那张直接放大到 256 会糊。
            @{ Name = 'Icon-256.png';          W = 256; H = 256 }
        )) {
            Resize-Png -SourcePath $master -Width $spec.W -Height $spec.H `
                -DestPath (Join-Path $DestDir $spec.Name)
        }
    }
    finally {
        if (Test-Path -LiteralPath $rawDir) {
            Remove-Item -LiteralPath $rawDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------- 清单渲染

function New-RenderedManifest {
    param([Parameter(Mandatory = $true)][string]$TemplatePath, [Parameter(Mandatory = $true)][string]$DestPath)

    $template = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    $map = [ordered]@{
        '@VERSION@'       = $msixVersion
        '@PUBLISHER@'     = $Publisher
        '@DISPLAY_NAME@'  = $DisplayName
        '@DESCRIPTION@'   = $Description
        '@IDENTITY_NAME@' = $IdentityName
        '@EXECUTABLE@'    = $Executable
    }
    foreach ($key in $map.Keys) {
        $template = $template.Replace($key, $map[$key])
    }
    # 还有没被替换掉的占位符就说明模板里新加了变量而这里忘了给值——
    # 那种包能装上去，但某项是空的，排查起来很远。直接失败。
    $leftover = [regex]::Matches($template, '@[A-Z_]+@')
    if ($leftover.Count -gt 0) {
        $names = ($leftover | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ', '
        throw "清单模板里还有未替换的占位符：$names"
    }
    # 清单必须是 UTF-8 **带 BOM**：makeappx 在中文代码页下会把没有 BOM 的
    # 非 ASCII 内容按 ANSI 读，「幽门」会变成乱码或让清单校验失败。
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($DestPath, $template, $utf8Bom)
}

# ---------------------------------------------------------------- 签名证书

# 自签名 = 签发者就是自己。
#
# 用它而不是「本次是否新建」来决定要不要导出公钥：复用了上一次构建留下的那张
# 自签名证书时，用户**同样**需要那份 .cer，而按「本次是否新建」判断会让 .cer
# 时有时无——发布流程里少一个附件，用户就装不上，而且只在「第二次构建之后」才
# 出现，最难查。
function Test-SelfSigned {
    param([Parameter(Mandatory = $true)]$Certificate)
    return $Certificate.Subject -eq $Certificate.Issuer
}

# 找一张可用的签名证书。
# 返回 @{ Thumbprint = ...; Created = $true/$false; SelfSigned = $true/$false }。
function Resolve-SigningCertificate {
    if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        $normalized = $CertificateThumbprint -replace '\s', ''
        $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $normalized } |
            Select-Object -First 1
        if (-not $cert) {
            throw "找不到指纹为 $CertificateThumbprint 的证书（已查 CurrentUser\My 与 LocalMachine\My）"
        }
        if ($cert.Subject -ne $Publisher) {
            throw "证书 Subject「$($cert.Subject)」与清单 Publisher「$Publisher」不一致；MSIX 要求两者逐字相同。"
        }
        if (-not $cert.HasPrivateKey) {
            throw "证书 $($cert.Thumbprint) 没有私钥，无法签名。"
        }
        return @{
            Thumbprint = $cert.Thumbprint
            Created    = $false
            SelfSigned = (Test-SelfSigned -Certificate $cert)
        }
    }

    # 已有同 Subject 的自签名证书就复用：每次构建都新造一张会让「已经装过前一版
    # 的用户」在升级时遇到签名不一致，只能卸载重装，而卸载会清掉配置。
    $existing = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $Publisher -and $_.HasPrivateKey } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
    if ($existing) {
        Write-Host "复用已有的自签名证书：$($existing.Thumbprint)（$($existing.Subject)）"
        return @{
            Thumbprint = $existing.Thumbprint
            Created    = $false
            SelfSigned = (Test-SelfSigned -Certificate $existing)
        }
    }

    Write-Host "为「$Publisher」新建一张自签名代码签名证书（仅供本机测试）。"
    # 自签名证书的 EKU 必须是「代码签名」，密钥用途必须含数字签名，否则
    # signtool 会以「证书用途不符」拒绝使用它。
    $cert = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $Publisher `
        -KeyUsage DigitalSignature `
        -FriendlyName 'XVPN MSIX self-signed' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    Write-Host "已创建：$($cert.Thumbprint)"
    return @{ Thumbprint = $cert.Thumbprint; Created = $true; SelfSigned = $true }
}

function Find-SignTool {
    $found = Find-SdkTool -Name 'signtool.exe'
    if (-not $found) {
        throw '找不到 signtool.exe。请安装 Windows SDK，或用 -SkipSign 只打包不签名。'
    }
    return $found
}

# ---------------------------------------------------------------- 打包

$repoRoot = Split-Path -Parent $PSScriptRoot
$template = Join-Path $repoRoot 'app\packaging\AppxManifest.xml'
if (-not (Test-Path -LiteralPath $template)) {
    throw "缺少清单模板：$template"
}
$iconSource = Join-Path $repoRoot 'app\windows\runner\resources\app_icon.ico'
if (-not (Test-Path -LiteralPath $iconSource)) {
    throw "缺少应用图标：$iconSource"
}

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("xvpn-msix-" + [guid]::NewGuid().ToString('N'))
}
$stage = Join-Path $WorkDir 'stage'
New-Item -ItemType Directory -Force -Path $stage | Out-Null

try {
    Write-Host '正在准备包内容…'
    # bundle 的**内容**位于包根：清单里 Executable 写的就是相对包根的路径。
    Copy-Item -Path (Join-Path $bundle '*') -Destination $stage -Recurse -Force

    New-PackageAssets -IcoPath $iconSource -DestDir (Join-Path $stage 'Assets')
    New-RenderedManifest -TemplatePath $template -DestPath (Join-Path $stage 'AppxManifest.xml')

    # 许可与第三方声明随包分发：GPL-3.0 §4/§6 要求接收二进制的人同时拿到许可证
    # 与对应源码获取方式。与 zip 包的约定一致，缺一个就拒绝打包。
    foreach ($legal in @('LICENSE', 'NOTICE.md', 'THIRD-PARTY-NOTICES.md')) {
        $src = Join-Path $repoRoot $legal
        if (-not (Test-Path -LiteralPath $src)) {
            throw "缺少 $legal，拒绝打包：分发物必须附带许可与第三方声明"
        }
        Copy-Item -LiteralPath $src -Destination (Join-Path $stage $legal) -Force
    }

    $outFull = [System.IO.Path]::GetFullPath($OutFile)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outFull) | Out-Null
    if (Test-Path -LiteralPath $outFull) { Remove-Item -LiteralPath $outFull -Force }

    Write-Host '正在生成 MSIX…'
    $packArgs = @('pack', '/d', $stage, '/p', $outFull, '/o')
    & $makeappxPath @packArgs
    if ($LASTEXITCODE -ne 0) { throw "makeappx 失败（退出码 $LASTEXITCODE）" }

    if (-not (Test-Path -LiteralPath $outFull)) { throw "makeappx 没有产出 $outFull" }

    # ------------------------------------------------------------ 签名
    if ($SkipSign) {
        Write-Warning '未签名：这个包只能用于检查内容，Add-AppxPackage 装不上。'
    }
    else {
        $signing = Resolve-SigningCertificate
        $signtool = Find-SignTool
        Write-Host "正在签名（证书 $($signing.Thumbprint)）…"
        # /fd SHA256 是 MSIX 的要求；时间戳让证书过期后已签的包仍然有效。
        #
        # 这里用 **http**，不是笔误：实测 signtool（SDK 10.0.26100.0）对
        # `https://timestamp.digicert.com` 直接报
        # `SignTool Error: Invalid Timestamp URL`，而 `http://` 那个能正常盖戳。
        # 不要凭「https 更安全」把它改成 https——改完不会更安全，只会让每一次签名
        # 都掉进下面的无时间戳回退路径，于是包里的签名悄悄失去时间戳。
        # （RFC3161 的响应本身由 CA 签名并随签名一起校验，http 传输不构成信任
        #   问题；它只影响签名长期可验证性，而那由回退路径兜底。）
        $timestampUrl = 'http://timestamp.digicert.com'
        if ($SkipTimestamp) {
            Write-Host '按要求跳过时间戳（仅本地迭代用）。'
            & $signtool sign /fd SHA256 /sha1 $signing.Thumbprint $outFull
            if ($LASTEXITCODE -ne 0) { throw "signtool 签名失败（退出码 $LASTEXITCODE）" }
        }
        else {
            # **临时放宽偏好，只按退出码判成败。**
            #
            # signtool 把「时间戳服务器不可达」写到 **stderr**，而脚本开头设了
            # `$ErrorActionPreference = 'Stop'`——于是这条**本可以被回退路径处理**
            # 的失败会先抛出去，回退逻辑根本执行不到，整个构建白白失败。
            # 实测踩过：DigiCert 时间戳服务偶发不可达时，包其实完全可用。
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $signtool sign /fd SHA256 /sha1 $signing.Thumbprint `
                    /tr $timestampUrl /td SHA256 $outFull
                $stamped = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $previous }

            if ($stamped -ne 0) {
                # 时间戳服务不可达是常见情况（离线构建、内网、服务抖动）。去掉
                # 时间戳再签一次，包仍然可用，只是证书过期后需要重签——比整个
                # 构建失败好。
                Write-Warning '带时间戳的签名失败，改为不带时间戳重试。'
                & $signtool sign /fd SHA256 /sha1 $signing.Thumbprint $outFull
                if ($LASTEXITCODE -ne 0) { throw "signtool 签名失败（退出码 $LASTEXITCODE）" }
            }
        }

        # 只在**自签名**时导出公钥：正式证书本来就该在用户机器上受信任，
        # 把它一并发布出去只会让人以为需要手动导入。
        if ($signing.SelfSigned -and -not [string]::IsNullOrWhiteSpace($CertificateOut)) {
            $certOutFull = [System.IO.Path]::GetFullPath($CertificateOut)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $certOutFull) | Out-Null
            $cert = Get-Item "Cert:\CurrentUser\My\$($signing.Thumbprint)"
            # DER 编码的公钥：用户 `Import-Certificate` 一下就能装。
            [System.IO.File]::WriteAllBytes($certOutFull, $cert.Export('Cert'))
            Write-Host "已导出自签名证书公钥：$certOutFull" -ForegroundColor Yellow
            Write-Host '  用户首次安装前需先信任它（见 scripts/install-msix.ps1）：' -ForegroundColor Yellow
            Write-Host "    Import-Certificate -FilePath '$certOutFull' -CertStoreLocation Cert:\CurrentUser\TrustedPeople" -ForegroundColor Yellow
        }
    }

    $size = (Get-Item -LiteralPath $outFull).Length
    Write-Host ''
    Write-Host ("已生成：{0}  ({1:N1} MB)" -f $outFull, ($size / 1MB)) -ForegroundColor Green
    Write-Host ("  版本：{0}    发布者：{1}" -f $msixVersion, $Publisher)
    Write-Host '  安装与桌面快捷方式：pwsh scripts/install-msix.ps1 -Package <上面的 .msix>'
}
finally {
    if (Test-Path -LiteralPath $WorkDir) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
