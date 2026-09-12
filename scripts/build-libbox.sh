#!/usr/bin/env bash
# 构建 Android 端的 sing-box 内核库（libbox.aar）——Linux/macOS 版。
#
# 用法：
#   bash scripts/build-libbox.sh
#
# 这是 scripts/build-libbox.ps1 的逐步骤移植，供 GitHub Actions 的 Linux runner
# 使用（Windows 本机仍走 PowerShell 版，两者不要互相调用）。
#
# 背景与理由（与 ps1 版一致）：
#   * 安卓端需要 sing-box 以「库」的形式嵌入（libbox），配合 VpnService 建立
#     TUN，而不是像 Windows 那样拉起独立进程——安卓不允许执行应用数据目录下的
#     可执行文件，而且 VpnService 的 TUN 必须在应用进程内创建。
#   * libbox 由 gomobile 把 Go 源码编译成 AAR，因此需要 Go 与 Android NDK。
#   * sing-box 1.14.0 要求 Go >= 1.25.5；gomobile 要求的版本更高。基座 Go 版本
#     不满足时由 GOTOOLCHAIN=auto 从模块代理自动拉取，无需手工安装。
#
# 依赖的环境变量（CI 已就绪，本机需自行设置）：
#   * ANDROID_SDK_ROOT / ANDROID_HOME：Android SDK 根目录；
#   * GOPROXY（可选）：默认 https://proxy.golang.org,direct，网络受限时可设 goproxy.cn；
#   * ANDROID_NDK_VERSION（可选）：默认 28.2.13676358（与 Flutter 的
#     flutter.ndkVersion 相同，见 FlutterExtension.kt）。
#
# 产物：app/android/app/libs/libbox.aar（Android 模块的 libs 目录，Gradle 在此查找）
#   随后在 android/app/build.gradle.kts 里以 fileTree 引入即可。

set -euo pipefail

# ---------------------------------------------------------------- 路径与版本

# BASH_SOURCE 在 `bash script.sh` 与 `. script.sh` 两种调用下都成立；
# 先取绝对路径再退到上一层，避免从任意 cwd 调用时相对路径失真。
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$script_dir/.." && pwd)"

# sing-box 版本**单一来源**：scripts/sing-box-version.txt。
# Windows 端的 sing-box.exe、Linux 端的 sing-box、以及这里编译的 libbox
# 必须来自同一版本，否则三端的协议能力会不一致。改版本只改这一个文件。
version_file="$script_dir/sing-box-version.txt"
if [ ! -f "$version_file" ]; then
  echo "缺少 sing-box 版本文件：$version_file" >&2
  exit 1
fi
# Windows 上编辑该文件可能写入 CRLF，这里一并去掉，避免 URL/模块路径里混进 \r。
version="$(tr -d ' \t\r\n' < "$version_file")"
if [ -z "$version" ]; then
  echo "sing-box 版本文件为空：$version_file" >&2
  exit 1
fi
version_num="${version#v}"

build_root="$repo/.build"
src_dir="$build_root/sing-box-$version"
out_aar="$repo/app/android/app/libs/libbox.aar"

# ---------------------------------------------------------------- 工具链环境

# 走模块代理：CI 上直连 proxy.golang.org 通常没问题；保留可覆盖能力，
# 网络受限时设为 https://goproxy.cn,direct 即可。
# 不要设 GOSUMDB=off——它会让工具链下载无法校验而直接失败。
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
# GOTOOLCHAIN=auto：sing-box 与 gomobile 各自要求不同的最低 Go 版本，
# 让每条命令各自拉取所需工具链，避免把版本钉死。
export GOTOOLCHAIN=auto
export CGO_ENABLED=1

android_sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [ -z "$android_sdk_root" ]; then
  echo "未设置 ANDROID_SDK_ROOT / ANDROID_HOME，无法定位 NDK" >&2
  exit 1
fi
ndk_version="${ANDROID_NDK_VERSION:-28.2.13676358}"
ndk="$android_sdk_root/ndk/$ndk_version"
if [ ! -d "$ndk" ]; then
  echo "未找到 Android NDK：$ndk" >&2
  echo "请用 sdkmanager 安装：sdkmanager --install 'ndk;$ndk_version'" >&2
  exit 1
fi
export ANDROID_NDK_HOME="$ndk"
export ANDROID_HOME="$android_sdk_root"

mkdir -p "$build_root"
mkdir -p "$(dirname "$out_aar")"

# ---------------------------------------------------------------- 1/6 gomobile

echo '=== 1/6 安装 gomobile ==='
gopath="$(go env GOPATH)"
gomobile="$gopath/bin/gomobile"
if [ ! -x "$gomobile" ]; then
  go install golang.org/x/mobile/cmd/gomobile@latest
  go install golang.org/x/mobile/cmd/gobind@latest
fi
"$gomobile" version

# ---------------------------------------------------------------- 2/6 拉取源码

echo '=== 2/6 拉取 sing-box 源码 ==='
if [ ! -d "$src_dir" ]; then
  stage="$build_root/fetch"
  mkdir -p "$stage"
  (
    cd "$stage"
    # gomobile bind 要求当前模块有上下文；先建一个临时模块再 go get。
    [ -f go.mod ] || go mod init xvpn-libbox-fetch >/dev/null
    go get "github.com/sagernet/sing-box@$version"
  )
  mod_cache="$(go env GOMODCACHE)"
  cached="$mod_cache/github.com/sagernet/sing-box@$version"
  if [ ! -d "$cached" ]; then
    echo "模块缓存中未找到源码：$cached" >&2
    exit 1
  fi
  # 模块缓存是只读的，编译需要可写目录，因此复制一份。
  cp -R "$cached" "$src_dir"
  chmod -R u+w "$src_dir"
fi
echo "源码目录：$src_dir"

# ---------------------------------------------------------------- 3~6 编译

cd "$src_dir"

echo '=== 3/6 gomobile init ==='
"$gomobile" init

echo '=== 4/6 注入 gomobile 依赖 ==='
# gomobile bind 要求 x/mobile 出现在当前模块的依赖图里，否则会直接拒绝执行：
#   "requires golang.org/x/mobile in the current module"
# 用 -tool 写入 go.mod 的 tool 指令，后续 go mod tidy 也不会把它清掉。
go get -tool golang.org/x/mobile/cmd/gobind

echo '=== 5/6 编译 libbox（耗时较长）==='
# 与官方 SFA 一致的构建标签：安卓端需要 gvisor 协议栈与 Quic。
# linkname 校验用下面的 -checklinkname=0 关闭，badlinkname 标签在新版 Go 已不够。
tags='with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_openvpn,with_dhcp,with_naive_outbound,badlinkname'
start_ts="$(date +%s)"
"$gomobile" bind \
  -target=android/arm64 \
  -androidapi 21 \
  -trimpath \
  -tags "$tags" \
  -ldflags '-s -w -buildid= -checklinkname=0' \
  -o "$out_aar" \
  ./experimental/libbox
echo "编译耗时 $(( $(date +%s) - start_ts )) 秒"

echo '=== 6/6 校验产物 ==='
if [ ! -f "$out_aar" ]; then
  echo "未生成 AAR：$out_aar" >&2
  exit 1
fi
size_mb=$(( $(wc -c < "$out_aar") / 1024 / 1024 ))
echo "libbox.aar 已生成：$out_aar  (${size_mb} MB)"
