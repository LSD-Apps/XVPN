# 构建 Android 端的 sing-box 内核库（libbox.aar）
#
# 用法：pwsh -File scripts/build-libbox.ps1
#
# 背景与理由：
#   * 安卓端需要 sing-box 以「库」的形式嵌入（libbox），配合 VpnService 建立
#     TUN，而不是像 Windows 那样拉起独立进程——安卓不允许执行应用数据目录下的
#     可执行文件，而且 VpnService 的 TUN 必须在应用进程内创建。
#   * libbox 由 gomobile 把 Go 源码编译成 AAR，因此需要 Go 与 Android NDK。
#   * sing-box 1.14.0 要求 Go >= 1.25.5；本机 Go 是 1.23.5，但 Go 1.21+ 能从
#     模块代理自动拉取所需工具链（GOTOOLCHAIN=auto），无需手工安装。
#
# 产物：app/android/app/libs/libbox.aar（Android 模块的 libs 目录，Gradle 在此查找）
#   随后在 android/app/build.gradle.kts 里以 fileTree 引入即可。

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot

# sing-box 版本**单一来源**：scripts/sing-box-version.txt。
# Windows 端的 sing-box.exe、Linux 端的 sing-box、以及这里编译的 libbox
# 必须来自同一版本，否则三端的协议能力会不一致（例如某个构建标签只在
# 某个版本才有）。改版本时只改这一个文件，三个平台自动保持一致。
$versionFile = Join-Path $PSScriptRoot 'sing-box-version.txt'
if (-not (Test-Path -LiteralPath $versionFile)) {
  throw "缺少 sing-box 版本文件：$versionFile"
}
$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($version)) {
  throw "sing-box 版本文件为空：$versionFile"
}

$buildRoot = Join-Path $repo '.build'
$srcDir = Join-Path $buildRoot "sing-box-$version"
$outAar = Join-Path $repo 'app\android\app\libs\libbox.aar'

# 走国内代理：直连 GitHub 时通时断，模块代理稳定得多。
# 不要设 GOSUMDB=off——它会让工具链下载无法校验而直接失败。
$env:GOPROXY = 'https://goproxy.cn,direct'
$env:GOTOOLCHAIN = 'auto'
$env:CGO_ENABLED = '1'

$ndk = Join-Path $env:ANDROID_SDK_ROOT 'ndk\28.2.13676358'
if (-not (Test-Path $ndk)) {
  throw "未找到 Android NDK：$ndk"
}
$env:ANDROID_NDK_HOME = $ndk
$env:ANDROID_HOME = $env:ANDROID_SDK_ROOT

New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outAar) | Out-Null

Write-Host '=== 1/5 安装 gomobile ===' -ForegroundColor Cyan
# GOTOOLCHAIN=auto：sing-box 要求 >= 1.25.5，而 gomobile 要求 >= 1.26.0，
# 让每条命令各自拉取所需工具链，避免把版本钉死。
$gobin = (go env GOPATH | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($gobin)) {
  $gobin = Join-Path $env:USERPROFILE 'go'
  Write-Host "go env GOPATH 无输出，回退到 $gobin"
}
$gomobile = Join-Path $gobin 'bin\gomobile.exe'
if (-not (Test-Path $gomobile)) {
  go install golang.org/x/mobile/cmd/gomobile@latest
  if ($LASTEXITCODE -ne 0) { throw 'gomobile 安装失败' }
  go install golang.org/x/mobile/cmd/gobind@latest
  if ($LASTEXITCODE -ne 0) { throw 'gobind 安装失败' }
}
& $gomobile version
if ($LASTEXITCODE -ne 0) { throw 'gomobile 不可用' }

Write-Host '=== 2/5 拉取 sing-box 源码 ===' -ForegroundColor Cyan
if (-not (Test-Path $srcDir)) {
  $stage = Join-Path $buildRoot 'fetch'
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Push-Location $stage
  try {
    if (-not (Test-Path 'go.mod')) { go mod init xvpn-libbox-fetch | Out-Null }
    go get "github.com/sagernet/sing-box@$version"
    if ($LASTEXITCODE -ne 0) { throw '拉取 sing-box 源码失败' }
  } finally {
    Pop-Location
  }
  $modCache = (go env GOMODCACHE | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($modCache)) { throw 'go env GOMODCACHE 无输出' }
  $cached = Join-Path $modCache "github.com\sagernet\sing-box@$version"
  if (-not (Test-Path $cached)) { throw "模块缓存中未找到源码：$cached" }
  # 模块缓存是只读的，编译需要可写目录，因此复制一份。
  Copy-Item $cached $srcDir -Recurse -Force
  # 只读属性会阻止 Go 写缓存文件，统一去掉。
  Get-ChildItem $srcDir -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
}
Write-Host "源码目录：$srcDir"

Write-Host '=== 3/5 gomobile init ===' -ForegroundColor Cyan
Push-Location $srcDir
try {
  & $gomobile init
  if ($LASTEXITCODE -ne 0) { throw 'gomobile init 失败' }

  Write-Host '=== 4/6 注入 gomobile 依赖 ===' -ForegroundColor Cyan
  # gomobile bind 要求 x/mobile 出现在当前模块的依赖图里，否则会直接拒绝执行：
  #   "requires golang.org/x/mobile in the current module"
  # 用 -tool 写入 go.mod 的 tool 指令，后续 go mod tidy 也不会把它清掉。
  go get -tool golang.org/x/mobile/cmd/gobind
  if ($LASTEXITCODE -ne 0) { throw '注入 gomobile 依赖失败' }

  Write-Host '=== 5/6 编译 libbox（耗时较长）===' -ForegroundColor Cyan
  # 与官方 SFA 一致的构建标签：安卓端需要 gvisor 协议栈与 Quic。
  # 注意：反引号续行的命令中间不能插注释——注释会直接终止续行。
  # linkname 校验用下面的 -checklinkname=0 关闭，badlinkname 标签在新版 Go 已不够。
  $tags = 'with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_openvpn,with_dhcp,with_naive_outbound,badlinkname'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & $gomobile bind `
    -target=android/arm64 `
    -androidapi 21 `
    -trimpath `
    -tags $tags `
    -ldflags '-s -w -buildid= -checklinkname=0' `
    -o $outAar `
    ./experimental/libbox
  if ($LASTEXITCODE -ne 0) { throw 'gomobile bind 失败' }
  Write-Host ("编译耗时 {0} 秒" -f [int]$sw.Elapsed.TotalSeconds)

  Write-Host '=== 6/6 校验产物 ===' -ForegroundColor Cyan
  if (-not (Test-Path $outAar)) { throw "未生成 AAR：$outAar" }
  $size = (Get-Item $outAar).Length / 1MB
  Write-Host ("libbox.aar 已生成：{0}  ({1:N1} MB)" -f $outAar, $size) -ForegroundColor Green
} finally {
  Pop-Location
}
