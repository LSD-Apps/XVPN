# 本机构建并打包 Windows / Android 发布产物，写入 dist/ 并生成 SHA256SUMS.txt。
#
#   pwsh scripts/build-release.ps1            # 只构建 Windows
#   pwsh scripts/build-release.ps1 -Android   # Windows + Android APK
#
# 这是「本机能跑的那一半」的便捷脚本；正式的发布由
# .github/workflows/release.yml 在 GitHub runner 上完成（Windows/Linux/Android
# 三端）。两者的版本约定与附件命名必须一致，见 docs/RELEASE.md。
#
# 为什么不在这里构建 Linux：Linux 桌面端只能在 Linux 上编译（需要 clang/GTK），
# 本机是 Windows，无法产出 Linux 二进制。Linux 一律交给 CI。
#
# 版本规则（与 CI、in-app 更新器的契约）：
#   * 版本取自 app/pubspec.yaml 的 version，去掉 +build 后缀；
#   * 所有构建都必须带 --dart-define=XVPN_VERSION=<ver>，否则界面显示回落值
#     （见 app/lib/version.dart 顶部注释）。
#
# 附件命名（exact，改动必须同步 CI 与更新器）：
#   XVPN-<ver>-windows-x64.zip
#   XVPN-<ver>-android-arm64.apk
#   XVPN-<ver>-android-arm64.zip
#   SHA256SUMS.txt

[CmdletBinding()]
param(
    # 仓库根目录。留空时自动取本脚本所在目录的上一级。
    #
    # 刻意不写成 param 默认值里的 (Split-Path -Parent $PSScriptRoot)：
    # Windows PowerShell 5.1 在 param 默认值求值阶段还拿不到 $PSScriptRoot，
    # 会得到空串并直接报错。放到脚本体里求值则 -File 与点源两种调用都成立。
    [string]$RepoRoot = '',

    # 期望的版本号（可带前导 v）。留空时取 app/pubspec.yaml。
    # 显式传入且与 pubspec 不一致时**直接报错**——发布版本与安装包版本
    # 不一致是曾经真实踩过的坑，这里用失败把它挡住。
    [string]$Version = '',

    # 同时构建 Android arm64 APK。
    [switch]$Android
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
$pubspec = Join-Path $appDir 'pubspec.yaml'
$coreBinary = Join-Path $appDir 'assets/bin/sing-box.exe'
$distDir = Join-Path $RepoRoot 'dist'

if (-not (Test-Path -LiteralPath $pubspec)) {
    throw "未找到 pubspec.yaml：$pubspec"
}

# ---------------------------------------------------------------- 版本解析

$versionLine = Get-Content -LiteralPath $pubspec |
    Where-Object { $_ -match '^\s*version:\s*\S' } |
    Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($versionLine)) {
    throw "无法从 $pubspec 解析 version 行"
}
# 去掉 "version:" 前缀与 "+build" 后缀，只保留 主.次.修订。
$pubspecVersion = ($versionLine -replace '^\s*version:\s*', '').Trim()
$pubspecVersion = ($pubspecVersion -split '\+')[0].Trim()

if ($pubspecVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "pubspec 的 version 不是 主.次.修订 形式：$pubspecVersion"
}

$requested = $Version.Trim()
if (-not [string]::IsNullOrWhiteSpace($requested)) {
    $requested = $requested.TrimStart('v', 'V')
    if ($requested -ne $pubspecVersion) {
        throw "传入的版本 $requested 与 pubspec 的 $pubspecVersion 不一致；请先修改 pubspec.yaml"
    }
}
$ver = $pubspecVersion
$coreVersion = (Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts/sing-box-version.txt') -Raw).Trim()

# ---------------------------------------------------------------- 前置检查

if (-not (Test-Path -LiteralPath $coreBinary)) {
    throw "缺少内核文件：$coreBinary`n桌面端把 sing-box 作为子进程运行，没有它构建出来的包无法连接。`n可从官方 release 下载并放到该路径（版本见 scripts/sing-box-version.txt：$coreVersion）。"
}

Write-Host "版本：$ver    内核：$coreVersion" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# 打一个「解压即就地覆盖」的 zip：bundle 目录的**内容**位于压缩包根，
# 不要在外面再套一层目录名——这是更新器的解压约定。
function New-BundleZip {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$OutputZip
    )
    if (Test-Path -LiteralPath $OutputZip) { Remove-Item -LiteralPath $OutputZip -Force }
    Compress-Archive -Path (Join-Path $SourceDir '*') -DestinationPath $OutputZip -CompressionLevel Optimal
}

# GPL-3.0 §4/§6（以及 BSD-3-Clause / Apache-2.0 的二进制再分发条款）要求接收
# 二进制的人同时拿到许可证与第三方声明。仓库根的 LICENSE / NOTICE.md /
# THIRD-PARTY-NOTICES.md 是唯一来源，打包前复制进 bundle，缺一个就拒绝打包
# ——与 CI 的 release.yml 保持一致。
$legalFiles = @('LICENSE', 'NOTICE.md', 'THIRD-PARTY-NOTICES.md')
function Copy-LegalFiles {
    param([Parameter(Mandatory = $true)][string]$DestDir)
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    foreach ($legal in $legalFiles) {
        $src = Join-Path $RepoRoot $legal
        if (-not (Test-Path -LiteralPath $src)) {
            throw "缺少 $legal，拒绝打包：分发物必须附带许可与第三方声明"
        }
        Copy-Item -LiteralPath $src -Destination (Join-Path $DestDir $legal) -Force
    }
}

# 把 docs/LEGAL.md 同步进 Flutter assets 目录（app/assets/legal/LEGAL.md）。
#
# 为什么需要：Flutter 的 asset 只能声明在包目录内，应用内「法律与使用声明」读到的
# 就是这份副本。副本随代码提交，并由 test/legal_assets_test.dart 逐字节断言与源
# 文件一致；打包前再同步一次，保证即使有人改了 docs/LEGAL.md 却忘了更新副本，
# 发布的 bundle 里也一定是最新文本。同步会改写工作区文件，内容确有变化时给出警告。
#
# 许可与第三方声明（LICENSE / NOTICE.md / THIRD-PARTY-NOTICES.md）**不**在这里同步：
# 它们不再作为 Flutter asset 随应用分发，应用内也没有界面读它们（设置页「开源
# 许可」只跳转到项目主页），只在打包时放进压缩包根与 APK 的 assets/licenses/
# ——那是 [Copy-LegalFiles] 的职责。
function Sync-LegalNotice {
    param([Parameter(Mandatory = $true)][string]$DestDir)
    $src = Join-Path $RepoRoot 'docs\LEGAL.md'
    if (-not (Test-Path -LiteralPath $src)) {
        throw '缺少 docs/LEGAL.md，拒绝构建：应用内法律声明必须能读到它'
    }
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $dst = Join-Path $DestDir 'LEGAL.md'
    $changed = $true
    if (Test-Path -LiteralPath $dst) {
        $changed = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    if ($changed) {
        Write-Warning "app/assets/legal/LEGAL.md 与 docs/LEGAL.md 不一致，已重新同步；请提交更新后的副本（test/legal_assets_test.dart 会断言一致）。"
    }
}

# 打开 zip/apk 断言其中含指定条目——让「复制进 bundle」不会静默失效。
function Assert-ZipContains {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string[]]$Entries
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ZipPath).Path)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        foreach ($entry in $Entries) {
            if ($names -notcontains $entry) { throw "$ZipPath 缺少 $entry" }
        }
    }
    finally { $zip.Dispose() }
}

Push-Location $appDir
try {
    Write-Host '=== flutter pub get ===' -ForegroundColor Cyan
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 失败' }

    # 应用内「法律与使用声明」读的是 Flutter assets（app/assets/legal/LEGAL.md），
    # 打包前从 docs/ 同步一次，保证副本不过期。
    Sync-LegalNotice -DestDir (Join-Path $appDir 'assets/legal')

    # ------------------------------------------------------------ Windows
    Write-Host '=== 构建 Windows Release ===' -ForegroundColor Cyan
    flutter build windows --release "--dart-define=XVPN_VERSION=$ver"
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows 失败' }

    $winBundle = Join-Path $appDir 'build/windows/x64/runner/Release'
    if (-not (Test-Path -LiteralPath (Join-Path $winBundle 'xvpn.exe'))) {
        throw "未找到 Windows 产物：$winBundle\xvpn.exe"
    }
    # CMake 会把 sing-box.exe 作为安装项放到可执行文件旁；缺了就说明内核没被装进 bundle。
    if (-not (Test-Path -LiteralPath (Join-Path $winBundle 'sing-box.exe'))) {
        throw "bundle 中缺少 sing-box.exe（app/windows/CMakeLists.txt 未安装内核？）"
    }
    # 许可与第三方声明随包分发；zip 根多了这两个文件，但附件命名不变。
    Copy-LegalFiles -DestDir $winBundle
    $winZip = Join-Path $distDir "XVPN-$ver-windows-x64.zip"
    New-BundleZip -SourceDir $winBundle -OutputZip $winZip
    Assert-ZipContains -ZipPath $winZip -Entries @('LICENSE', 'NOTICE.md', 'THIRD-PARTY-NOTICES.md')
    Write-Host "已生成：$winZip（含 LICENSE、NOTICE.md 与 THIRD-PARTY-NOTICES.md）" -ForegroundColor Green

    # ------------------------------------------------------------ Android
    if ($Android) {
        # 许可与第三方声明必须先于构建放进 AGP 默认合并的 native assets 源集
        # （src/main/assets），否则不会被打进 APK。APK 内路径为
        # assets/licenses/<文件名>。构建后在 finally 里清理，
        # 避免工作区留下未跟踪文件（该目录已在 .gitignore 中）。
        $androidLegalDir = Join-Path $appDir 'android/app/src/main/assets/licenses'
        Copy-LegalFiles -DestDir $androidLegalDir
        try {
            Write-Host '=== 构建 Android arm64 Release ===' -ForegroundColor Cyan
            flutter build apk --release --target-platform android-arm64 "--dart-define=XVPN_VERSION=$ver"
            if ($LASTEXITCODE -ne 0) { throw 'flutter build apk 失败' }

            $apk = Join-Path $appDir 'build/app/outputs/flutter-apk/app-release.apk'
            if (-not (Test-Path -LiteralPath $apk)) { throw "未找到 APK：$apk" }

            # 更新器需要裸 APK 才能调用系统安装；再附带一份 zip，让三端都有 zip。
            $apkOut = Join-Path $distDir "XVPN-$ver-android-arm64.apk"
            Copy-Item -LiteralPath $apk -Destination $apkOut -Force
            Assert-ZipContains -ZipPath $apkOut -Entries @('assets/licenses/LICENSE', 'assets/licenses/NOTICE.md', 'assets/licenses/THIRD-PARTY-NOTICES.md')
            Write-Host "已生成：$apkOut（含 assets/licenses/ 下的 LICENSE、NOTICE.md 与 THIRD-PARTY-NOTICES.md）" -ForegroundColor Green

            $apkZip = Join-Path $distDir "XVPN-$ver-android-arm64.zip"
            if (Test-Path -LiteralPath $apkZip) { Remove-Item -LiteralPath $apkZip -Force }
            Compress-Archive -LiteralPath $apkOut -DestinationPath $apkZip -CompressionLevel Optimal
            Write-Host "已生成：$apkZip" -ForegroundColor Green
        }
        finally {
            if (Test-Path -LiteralPath $androidLegalDir) {
                Remove-Item -LiteralPath $androidLegalDir -Recurse -Force
            }
        }
    }
    else {
        Write-Host '（未传 -Android，跳过 APK 构建）' -ForegroundColor Yellow
    }
}
finally {
    Pop-Location
}

# ---------------------------------------------------------------- 校验和

# SHA256SUMS.txt 采用 sha256sum 的格式（小写十六进制 + 两个空格 + 文件名），
# 这样 Linux 端可直接 `sha256sum -c SHA256SUMS.txt`。
$assets = Get-ChildItem -LiteralPath $distDir -File |
    Where-Object { $_.Name -ne 'SHA256SUMS.txt' } |
    Sort-Object Name
$sumLines = foreach ($asset in $assets) {
    $hash = (Get-FileHash -LiteralPath $asset.FullName -Algorithm SHA256).Hash.ToLower()
    "$hash  $($asset.Name)"
}
$sumFile = Join-Path $distDir 'SHA256SUMS.txt'
[System.IO.File]::WriteAllLines($sumFile, $sumLines, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "完成。产物目录：$distDir" -ForegroundColor Cyan
$assets | ForEach-Object { Write-Host ("  {0}  ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
Write-Host "  SHA256SUMS.txt"
Write-Host ''
Write-Host '提醒：Linux 产物只能在 Linux 上构建，本地无法产出；正式发布请用 GitHub Actions。' -ForegroundColor Yellow
