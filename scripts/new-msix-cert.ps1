# 生成一张用于签名 MSIX 的代码签名证书，并打印配置 GitHub Secret 需要的内容。
#
#   pwsh scripts/new-msix-cert.ps1
#   pwsh scripts/new-msix-cert.ps1 -Publisher 'CN=LUSIDA' -Years 10
#
# 为什么需要它：Windows **只发 MSIX**，而 MSIX 必须签名、且清单里的
# `Identity/Publisher` 必须与证书 `Subject` 逐字相同。缺证书时 CI 会直接失败
# （见 .github/workflows/release.yml 的签名守卫）——不再回退到「每次构建现造一张
# 自签名证书」：那样每个版本由不同证书签名，已装旧版的用户升级时签名链对不上，
# 只能卸载重装，而卸载会清掉配置。
#
# **证书只能生成一次，然后一直用同一张。** 丢了私钥（或口令）就无法再签出能被
# 已有用户覆盖安装的包，只能让所有用户卸载重装。因此脚本默认拒绝覆盖已存在的
# .pfx，并要求你把 `MSIX_PFX_BASE64` 存进 GitHub Secrets 之后再备份一份离线。
#
# 私钥去哪：写进 -OutDir（默认 <仓库>\.secrets\，已在 .gitignore 里）的 .pfx。
# **绝不要把它提交进仓库**：公开仓库里的发布私钥意味着任何人都能签出一个
# Windows 信任的「XVPN 升级包」。公钥 .cer 没有这个问题，可以入库、也可以随
# Release 一起分发（自签名场景下用户必须先信任它才装得上）。
#
# 自签名 vs 正式证书（这一步决定用户的安装体验）：
#   * 自签名（本脚本产出）：用户必须先手动信任 .cer（要管理员提权一次），
#     否则 Add-AppxPackage 会以 0x800B0109 失败。适合自用与小范围分发。
#   * 正式代码签名证书（CA 签发，或 SignPath / Azure Trusted Signing 这类
#     面向开源项目的签名服务）：用户双击即装，没有信任步骤，也不会被
#     SmartScreen / 企业策略拦。要公开分发，最终应当走这一条。
#   两者的用法完全相同：把 PFX 转成 base64 填进 MSIX_PFX_BASE64 即可。

[CmdletBinding()]
param(
    # 证书 Subject，必须与 app/packaging/AppxManifest.xml 的 Publisher
    # （以及仓库变量 MSIX_PUBLISHER）逐字相同。
    [string]$Publisher = 'CN=LUSIDA',

    # 私钥与公钥的输出目录。默认 <仓库>\.secrets\（已 gitignore）。
    [string]$OutDir = '',

    # 有效期（年）。MSIX 安装包的有效期不能短于这张证书——证书过期后已装用户
    # 无法再覆盖升级。默认 10 年。
    [int]$Years = 10,

    # PFX 口令。留空则随机生成并打印出来（口令与 PFX 一起备份）。
    [string]$Password = '',

    # 覆盖已存在的 .pfx。**默认拒绝**：换证书会让所有已装用户无法覆盖升级。
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        throw '无法推断仓库根目录，请显式传 -OutDir'
    }
    $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) '.secrets'
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

# 文件名带上 Publisher 里的 CN，避免同一台机器上为不同发布者生成的证书互相覆盖。
$cn = ($Publisher -replace '^CN=', '') -replace '[^\w.-]', '_'
$pfxPath = Join-Path $OutDir "xvpn-msix-$cn.pfx"
$cerPath = Join-Path $OutDir "xvpn-msix-$cn.cer"

if ((Test-Path -LiteralPath $pfxPath) -and -not $Force) {
    throw @"
已存在私钥文件：$pfxPath

**不要**随手换掉它：已装旧版的用户只能用同一张证书签出的包覆盖升级，换了证书
他们必须卸载重装（卸载会清掉配置）。要用新证书请显式加 -Force，并确认这是你
想要的结果。
"@
}

if ([string]::IsNullOrWhiteSpace($Password)) {
    # 32 个字符、大小写数字混合：够长，且能直接粘进 GitHub Secret。
    # 用 RandomNumberGenerator.Create().GetBytes() 而不是 .Fill()：后者只在
    # .NET Core 2.1+ 上存在，而本仓库要能在只有 Windows PowerShell 5.1
    # （.NET Framework）的机器上跑——这台机器就是。
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $Password = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

Write-Host "为「$Publisher」生成代码签名证书…" -ForegroundColor Cyan
# EKU 必须是「代码签名」，密钥用途必须含数字签名：否则 signtool 会拒绝用它签，
# MSIX 也装不上（而且报出来的错误与真实原因毫无关系）。
$cert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $Publisher `
    -KeyUsage DigitalSignature `
    -KeySpec Signature `
    -KeyAlgorithm RSA `
    -KeyLength 4096 `
    -HashAlgorithm SHA256 `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -NotAfter (Get-Date).AddYears($Years) `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')

$secure = ConvertTo-SecureString -String $Password -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $secure | Out-Null
Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

$base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pfxPath))

Write-Host ''
Write-Host '已生成：' -ForegroundColor Green
Write-Host "  私钥（**不要入库**）：$pfxPath"
Write-Host "  公钥（可入库/随包分发）：$cerPath"
Write-Host "  证书指纹：$($cert.Thumbprint)"
Write-Host "  有效期至：$($cert.NotAfter.ToString('yyyy-MM-dd'))"
Write-Host ''
Write-Host '接下来（GitHub 仓库 Settings → Secrets and variables → Actions）：' -ForegroundColor Cyan
Write-Host '  1) Secret  MSIX_PFX_BASE64   = 下面这一整行 base64'
Write-Host "  2) Secret  MSIX_PFX_PASSWORD = $Password"
Write-Host "  3) Variable MSIX_PUBLISHER   = $Publisher   （必须与证书 Subject 逐字相同）"
Write-Host ''
Write-Host '把它粘进 MSIX_PFX_BASE64（单行，不要换行、不要引号）：' -ForegroundColor Cyan
Write-Host $base64
Write-Host ''
Write-Host '口令（与 .pfx 一起备份到密码管理器；两样缺一不可）：' -ForegroundColor Yellow
Write-Host "  $Password"
Write-Host ''
Write-Host '本机若要直接用这张证书打包（免去临时自签名证书）：' -ForegroundColor Cyan
Write-Host "  pwsh scripts/package-msix.ps1 -BundleDir app\build\windows\x64\runner\Release ``"
Write-Host "    -Version <版本> -OutFile dist\XVPN-<版本>-windows-x64.msix -CertificateThumbprint $($cert.Thumbprint)"
Write-Host ''
Write-Host '提醒：这张是**自签名**证书，用户安装前必须先信任随包发布的 .cer' -ForegroundColor Yellow
Write-Host '      （见 scripts/install-msix.ps1）。要免掉这一步，需要用正式代码签名证书。' -ForegroundColor Yellow
