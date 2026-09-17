# 只做**语法/编译检查**：用 MSVC 把 windows/runner 下的原生源码编译到 .obj 为止，
# 不链接、不跑 Flutter 构建。
#
#   pwsh scripts/check-windows-native.ps1
#
# 为什么需要它：完整的 `flutter build windows` 要几分钟，而**原生代码的问题里
# 绝大多数是编译期就能发现的**（拼错的符号、vtable 顺序、缺头文件、/WX 下的
# 警告）。改一行 C++ 就等一次完整构建，代价高到会让人懒得改。这个脚本把那一层
# 单独拎出来，几秒钟就能给出结论。
#
# 它**不能替代**完整构建：链接错误（缺导入库）、资源编译（Runner.rc）与
# Dart 侧的问题都要靠 `flutter build windows`。因此两者是互补的，不是替代关系。
#
# 编译选项刻意与 windows/CMakeLists.txt 的 APPLY_STANDARD_SETTINGS 保持一致
# （/W4 /WX /EHsc /utf-8 /std:c++17 与 _HAS_EXCEPTIONS=0）：选项不一致的话，
# 这个脚本会「通过」而真实构建失败，那比没有它更糟。

[CmdletBinding()]
param(
    # 仓库根目录。留空时取本脚本所在目录的上一级。
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        (Get-Location).Path
    }
    else {
        Split-Path -Parent $PSScriptRoot
    }
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$runnerDir = Join-Path $RepoRoot 'app\windows\runner'
if (-not (Test-Path -LiteralPath $runnerDir)) {
    throw "找不到 windows runner 目录：$runnerDir"
}

# ---------------------------------------------------------------- 找 MSVC

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "找不到 vswhere.exe：$vswhere`n请安装 Visual Studio（含 C++ 桌面开发工作负载）。"
}
$vsPath = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ([string]::IsNullOrWhiteSpace($vsPath)) {
    throw 'vswhere 没有找到带 MSVC x64 工具的 Visual Studio 安装。'
}
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) {
    throw "找不到 vcvars64.bat：$vcvars"
}

# ---------------------------------------------------------------- 头文件路径

# Flutter 的引擎头（flutter/*.h、flutter_windows.h）在 build 时才被下载到
# windows/flutter/ephemeral 下。没有它们就先跑一次 `flutter build windows`——
# 与其在这里猜一个路径，不如把真实原因说出来。
$ephemeral = Join-Path $RepoRoot 'app\windows\flutter\ephemeral'
if (-not (Test-Path -LiteralPath (Join-Path $ephemeral 'flutter_windows.h'))) {
    throw @"
找不到 Flutter 引擎头（$ephemeral\flutter_windows.h）。
这些头文件由 Flutter 在构建时下载。请先跑一次：
    cd app; flutter build windows
之后再运行本脚本。
"@
}

$includes = New-Object System.Collections.Generic.List[string]
$includes.Add((Join-Path $RepoRoot 'app\windows'))
$includes.Add($ephemeral)
$includes.Add((Join-Path $ephemeral 'cpp_client_wrapper\include'))
# 插件的头目录（generated_plugin_registrant.h 会引用它们）随依赖变化，因此
# 遍历一遍而不是写死——写死了加一个插件就会在这里莫名其妙地失败。
Get-ChildItem -LiteralPath $ephemeral -Recurse -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'include' } |
    ForEach-Object { $includes.Add($_.FullName) }
# 去重（同一个目录可能被上面多条规则命中），并去掉不存在的。
$includeArgs = $includes |
    Sort-Object -Unique |
    Where-Object { Test-Path -LiteralPath $_ } |
    ForEach-Object { "/I`"$_`"" }

# ---------------------------------------------------------------- 编译

$sources = @('auto_start.cc', 'flutter_window.cpp', 'main.cpp', 'utils.cpp', 'win32_window.cpp')
$existing = $sources | Where-Object { Test-Path -LiteralPath (Join-Path $runnerDir $_) }
if ($existing.Count -eq 0) {
    throw "在 $runnerDir 下没有找到任何待检查的源文件"
}

# FLUTTER_VERSION 系列是 CMake 注入的宏，Runner.rc 与 win32_window 会用到；
# 这里给一组固定值，仅为让编译通过——它不影响任何**语法**检查。
$defines = @(
    '/DUNICODE', '/D_UNICODE', '/DWIN32', '/D_WINDOWS', '/DNOMINMAX',
    '/D_HAS_EXCEPTIONS=0',
    '/DFLUTTER_VERSION=\"1.0.0\"',
    '/DFLUTTER_VERSION_MAJOR=1', '/DFLUTTER_VERSION_MINOR=0',
    '/DFLUTTER_VERSION_PATCH=0', '/DFLUTTER_VERSION_BUILD=0'
)

$objDir = Join-Path ([System.IO.Path]::GetTempPath()) ("xvpn-native-check-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $objDir | Out-Null

try {
    $failures = @()
    foreach ($source in $existing) {
        Write-Host "检查 $source …" -ForegroundColor Cyan
        $obj = Join-Path $objDir ($source -replace '\.cc$|\.cpp$', '.obj')
        $command = 'call "{0}" >nul && cl /nologo /c /W4 /WX /wd4100 /EHsc /utf-8 /std:c++17 {1} {2} /Fo:"{3}" "{4}"' -f `
            $vcvars, ($defines -join ' '), ($includeArgs -join ' '), $obj, (Join-Path $runnerDir $source)
        & "$env:SystemRoot\System32\cmd.exe" /c $command
        if ($LASTEXITCODE -ne 0) {
            $failures += $source
        }
    }

    if ($failures.Count -gt 0) {
        throw ("原生代码编译失败：" + ($failures -join '、'))
    }
    Write-Host ''
    Write-Host "原生代码编译检查通过（$($existing.Count) 个文件）。" -ForegroundColor Green
    Write-Host '提醒：这只覆盖编译期。链接错误、资源与 Dart 侧的问题请跑 flutter build windows。' -ForegroundColor Yellow
}
finally {
    if (Test-Path -LiteralPath $objDir) {
        Remove-Item -LiteralPath $objDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
