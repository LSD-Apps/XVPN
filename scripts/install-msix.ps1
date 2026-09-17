# 在**当前用户**范围内安装 XVPN 的 MSIX 包，并在桌面上创建快捷方式。
#
#   pwsh scripts/install-msix.ps1 -Package dist\XVPN-1.3.0-windows-x64.msix
#   pwsh scripts/install-msix.ps1 -Package ... -Certificate dist\XVPN-msix.cer
#   pwsh scripts/install-msix.ps1 -Uninstall
#
# 为什么需要这个脚本，而不是「双击 .msix 就完事」：
#
#   1. **桌面快捷方式**。MSIX 没有「安装完成后运行脚本」的标准钩子，而打包进程
#      写 %USERPROFILE%\Desktop 会被文件系统虚拟化到包私有目录——写不到真实
#      桌面。因此快捷方式只能由一个**未打包**的进程来建，也就是本脚本。这是
#      「安装后自动有桌面图标」这条要求唯一站得住的实现路径。
#   2. **自签名证书**。未在 Microsoft Store 上架的包必须签名，而自签名证书在
#      用户机器上默认不被信任。这里在安装前把公钥放进当前用户的
#      TrustedPeople，并把这一步**明确告诉用户**（-Certificate 是显式的）。
#
# 快捷方式的目标是执行别名 %LOCALAPPDATA%\Microsoft\WindowsApps\xvpn.exe
# （清单里的 windows.appExecutionAlias）。**不要**改成
# %ProgramFiles%\WindowsApps\XVPN_<版本>_x64__<哈希>\xvpn.exe：那个路径每次
# 升级都会变，升级之后快捷方式就成了死链接。

[CmdletBinding()]
param(
    # 要安装的 .msix 路径。
    [string]$Package = '',

    # 自签名证书公钥（.cer/.crt）。给了就先把它导入当前用户的证书库。
    #
    # **两个存储都会写**（Root 与 TrustedPeople），原因见下面安装段：自签名证书
    # 自己就是链的根，只放进 TrustedPeople 会被 AppX 部署以 0x800B0109 拒绝。
    #
    # 刻意不默认去旁边找同名 .cer：静默安装一张证书比装一个应用影响大得多，
    # 必须由调用者显式要求。
    [string]$Certificate = '',

    # 快捷方式的名字（不含 .lnk）。
    [string]$ShortcutName = '幽门',

    # 应用图标（.ico）。留空时依次尝试：
    #   1. 与 .msix 同目录、同名的 .ico（发布包里与 .cer 并排的那份）；
    #   2. 包内 Assets\ 的多尺寸 PNG 磁贴，现场合成一份 .ico；
    #   3. 从包内 exe 抽单帧（32x32，高 DPI 下偏虚）。
    # **不能省**：快捷方式的目标是执行别名（0 字节重解析点），自身没有图标资源，
    # 不给图标文件桌面就是一块白板——实测踩过。
    [string]$IconFile = '',

    # 不创建桌面快捷方式。
    [switch]$NoShortcut,

    # 卸载（按包名找当前用户已安装的包并移除，同时清掉快捷方式与发布者证书）。
    [switch]$Uninstall,

    # 包标识名，用于 -Uninstall 查找。
    [string]$IdentityName = 'LUSIDA.XVPN',

    # 发布者 DN。**必须与包的清单 Publisher 以及证书 Subject 逐字一致**。
    #
    # 它只在 -Uninstall 里用到：卸载时按它去两个证书库里精确匹配并移除本脚本
    # 导入的那一张。默认值与 package-msix.ps1 的 -Publisher 默认值一致。
    [string]$Publisher = 'CN=LUSIDA'
)

$ErrorActionPreference = 'Stop'

function Get-DesktopDir {
    # 用 shell 的已知文件夹而不是拼 "$env:USERPROFILE\Desktop"：桌面被重定向到
    # OneDrive 的机器上，后者指向的目录是空的，快捷方式会「建了但看不见」。
    $dir = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($dir)) {
        throw '拿不到桌面目录（GetFolderPath 返回空）。'
    }
    return $dir
}

function Get-AliasPath {
    $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    return (Join-Path $windowsApps 'xvpn.exe')
}

# 把若干张 PNG 的原字节打包成 .ico。
#
# 为什么自己拼字节而不是用 [System.Drawing.Icon]::Save：后者只能写单帧，而且
# 会把 PNG 帧解码后重编码成 BMP。Windows 与资源管理器都支持 PNG 压缩的 ico 帧，
# 直接搬运原字节既不丢质量也不用处理 alpha 合成。
function Write-IcoFromPngs {
    param(
        [Parameter(Mandatory = $true)][string[]]$PngPaths,
        [Parameter(Mandatory = $true)][string]$DestPath
    )
    Add-Type -AssemblyName System.Drawing
    $frames = @()
    foreach ($p in $PngPaths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $img = [System.Drawing.Image]::FromFile($p)
        try { $w = $img.Width; $h = $img.Height } finally { $img.Dispose() }
        $frames += [pscustomobject]@{ W = $w; H = $h; Bytes = [System.IO.File]::ReadAllBytes($p) }
    }
    if ($frames.Count -eq 0) { throw '没有任何可用的 PNG 帧' }
    # .ico 要求按尺寸升序，且宽/高为 0 表示 256
    $frames = $frames | Sort-Object W

    $fs = [System.IO.File]::Create($DestPath)
    try {
        $bw = New-Object System.IO.BinaryWriter($fs)
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)
        $dataOffset = 6 + 16 * $frames.Count
        foreach ($f in $frames) {
            $bw.Write([byte]$(if ($f.W -ge 256) { 0 } else { $f.W }))
            $bw.Write([byte]$(if ($f.H -ge 256) { 0 } else { $f.H }))
            $bw.Write([byte]0); $bw.Write([byte]0)
            $bw.Write([uint16]1); $bw.Write([uint16]32)
            $bw.Write([uint32]$f.Bytes.Length); $bw.Write([uint32]$dataOffset)
            $dataOffset += $f.Bytes.Length
        }
        foreach ($f in $frames) { $bw.Write($f.Bytes) }
        $bw.Flush()
    }
    finally { $fs.Dispose() }
    return $DestPath
}

function Get-IconPath {
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'XVPN') 'app.ico')
}

# 取一份 .ico 放到稳定位置，供桌面快捷方式引用。返回图标路径；实在取不到时 $null。
function Install-AppIcon {
    param(
        [string]$PreferredSource,
        [Parameter(Mandatory = $true)]$Package
    )

    $dest = Get-IconPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null

    # 1) 显式给的源 .ico（发布包里与 .msix 并排的那份）——最好，多尺寸且是原始资源
    if (-not [string]::IsNullOrWhiteSpace($PreferredSource) -and
        (Test-Path -LiteralPath $PreferredSource) -and
        [System.IO.Path]::GetExtension($PreferredSource) -ieq '.ico') {
        Copy-Item -LiteralPath $PreferredSource -Destination $dest -Force
        Write-Host "已放置应用图标（源 .ico）：$dest" -ForegroundColor Green
        return $dest
    }

    # 2) 包内的 Assets PNG——**这条路对任何安装形态都成立**：那些图是清单声明的
    #    一部分，随包永久存在，且 `Assets` 目录不带版本号，不依赖 InstallLocation
    #    里的版本段。优先用 256 那张大图，小尺寸从它缩小比从 44 放大清楚得多。
    #    （exe 内嵌的多尺寸图标资源在 Win32 下没有干净的读取途径——要自己解
    #     RT_GROUP_ICON，容易出微妙的错，因此不走那条路。）
    $assets = Join-Path $Package.InstallLocation 'Assets'
    if (Test-Path -LiteralPath $assets) {
        $pngs = @('Icon-256.png', 'Square150x150Logo.png', 'Square44x44Logo.png') |
            ForEach-Object { Join-Path $assets $_ } |
            Where-Object { Test-Path -LiteralPath $_ }
        if ($pngs.Count -gt 0) {
            Write-IcoFromPngs -PngPaths $pngs -DestPath $dest | Out-Null
            Write-Host "已放置应用图标（取自包内 Assets 的 $($pngs.Count) 帧）：$dest" -ForegroundColor Green
            return $dest
        }
    }

    # 3) 最后兜底：从 exe 抽单帧。ExtractAssociatedIcon 只给 32x32，高 DPI 下偏虚，
    #    但总好过一个白板图标。
    $exe = Join-Path $Package.InstallLocation 'xvpn.exe'
    if (Test-Path -LiteralPath $exe) {
        try {
            Add-Type -AssemblyName System.Drawing
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
            if ($icon) {
                $fs = [System.IO.File]::Create($dest)
                try { $icon.Save($fs) } finally { $fs.Dispose() }
                $icon.Dispose()
                Write-Warning "只取到单尺寸图标（32x32），高 DPI 下可能偏虚：$dest"
                return $dest
            }
        } catch { }
    }

    Write-Warning '没能取得应用图标，桌面快捷方式会显示为白板。'
    return $null
}

function New-DesktopShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        # 图标文件。**必须给一个真实文件**：目标是执行别名（0 字节重解析点），
        # 自身没有图标资源可提取，不显式指定就一定是白板。
        [string]$IconPath = ''
    )
    $desktop = Get-DesktopDir
    $link = Join-Path $desktop "$Name.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = Split-Path -Parent $TargetPath
    $shortcut.Description = '幽门 · 智能分流 VPN 客户端'
    if (-not [string]::IsNullOrWhiteSpace($IconPath) -and (Test-Path -LiteralPath $IconPath)) {
        $shortcut.IconLocation = "$IconPath,0"
    }
    else {
        Write-Warning '未指定图标文件：桌面快捷方式会是白板图标。'
    }
    $shortcut.Save()
    Write-Host "已创建桌面快捷方式：$link" -ForegroundColor Green
    return $link
}

function Get-InstalledPackage {
    param([Parameter(Mandatory = $true)][string]$Name)
    return Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 卸载

if ($Uninstall) {
    $installed = Get-InstalledPackage -Name $IdentityName
    if (-not $installed) {
        Write-Host "当前用户没有安装 $IdentityName。" -ForegroundColor Yellow
    }
    else {
        Remove-AppxPackage -Package $installed.PackageFullName
        Write-Host "已卸载：$($installed.PackageFullName)" -ForegroundColor Green
    }
    # 删掉快捷方式**以及那个指向已卸载别名的目标**：留着一条指向不存在文件的
    # .lnk 比没有更糟（点下去只会得到「找不到项目」）。
    $link = Join-Path (Get-DesktopDir) "$ShortcutName.lnk"
    if (Test-Path -LiteralPath $link) {
        Remove-Item -LiteralPath $link -Force
        Write-Host "已删除快捷方式：$link" -ForegroundColor Green
    }

    # 清掉安装时导入的发布者证书。**只在包已经卸掉之后做**：留着它等于让一台
    # 机器长期信任一个已经不在的发布者。
    #
    # 两个作用域都扫：以管理员安装时证书落在 LocalMachine，非管理员时落在
    # CurrentUser，而卸载未必是同一个权限级别跑的。
    #
    # 只删 Subject 与 Publisher 完全一致的那些——那是本脚本导入的那一张，
    # 不会误伤用户自己装过的别的证书。
    if (-not [string]::IsNullOrWhiteSpace($Publisher)) {
        $removed = 0
        foreach ($scope in @('CurrentUser', 'LocalMachine')) {
            foreach ($store in @('Root', 'TrustedPeople')) {
                # **先把结果物化成数组再遍历**：直接在管道上 `Remove-Item` 会在
                # 枚举过程中改动被枚举的集合，枚举器随即失效——下一次迭代读到的
                # 是空项，于是报出一句 Thumbprint 为空的「无法移除」。
                # 实测踩过：LocalMachine\Root 明明删成功了，却多打一条空指纹的警告。
                $targets = @(
                    Get-ChildItem "Cert:\$scope\$store" -ErrorAction SilentlyContinue |
                        Where-Object { $_.Subject -eq $Publisher }
                )
                foreach ($cert in $targets) {
                    try {
                        Remove-Item -LiteralPath $cert.PSPath -Force -ErrorAction Stop
                        $removed++
                        Write-Host "已从 $scope\$store 移除证书：$($cert.Thumbprint)"
                    }
                    catch {
                        # 删除证书需要管理员；删不掉时如实说明，不要假装成功。
                        Write-Warning "无法从 $scope\$store 移除 $($cert.Thumbprint)：$($_.Exception.Message)"
                    }
                }
            }
        }
        if ($removed -eq 0) {
            Write-Host '证书库里没有本发布者的证书（可能未导入过，或已被删除）。'
        }
    }

    # 注意：卸载**不会**删除用户数据（%LOCALAPPDATA%\Packages\<包家族>\LocalCache
    # 下的配置与凭据）。这是有意的——重装或升级不该让用户重新导入配置。
    Write-Host '用户配置与凭据保留在包的数据目录中；如需彻底清除请手动删除。'
    return
}

# ---------------------------------------------------------------- 安装

if ([string]::IsNullOrWhiteSpace($Package)) {
    throw '请用 -Package 指定要安装的 .msix（或用 -Uninstall 卸载）。'
}
$msix = (Resolve-Path -LiteralPath $Package).Path

if (-not [string]::IsNullOrWhiteSpace($Certificate)) {
    $cer = (Resolve-Path -LiteralPath $Certificate).Path
    $wanted = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cer)

    # 证书必须放进**机器级**存储，否则安装了也装不上。
    #
    #   自签名证书**同时是叶证书和根证书**（自己给自己签发），因此两件事都要表态：
    #     * `TrustedPeople`——「这个发布者可信」；
    #     * `Root`——「这条链的根可信」。
    #
    #   关键在于作用域：**AppX 部署服务以 SYSTEM 身份运行，不读 CurrentUser 的
    #   证书存储**。把它们放进 CurrentUser 足以让 `signtool verify` 通过
    #   （实测 0 errors），部署服务却仍然以 0x800B0109 拒绝。这条是实测出来的，
    #   而它的表现极具误导性——「验签通过但装不上」。
    #
    #   因此：**能提权就写机器级**（LocalMachine）；没提权就只好退回 CurrentUser，
    #   并明确告诉用户这样装不上、下一步该做什么。
    #
    # Root 必须走 .NET 的 X509Store，**不能用 Import-Certificate**：那个 cmdlet
    # 对 Root 存储会报 "UI is not allowed in this operation"（Windows 不允许它
    # 往可能弹确认框的存储里静默写入）。同一个操作换 X509Store 就是允许的——
    # 它是一次明确的、无 UI 的写入调用。这条差异同样是实测出来的。
    $isAdmin = ([Security.Principal.WindowsPrincipal](
        [Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $scope = if ($isAdmin) { 'LocalMachine' } else { 'CurrentUser' }

    if (-not $isAdmin) {
        Write-Warning @"
当前不是管理员：只能把证书放进 **CurrentUser** 存储。
自签名 MSIX 需要**机器级**信任（AppX 部署服务以 SYSTEM 身份运行），因此下一步
Add-AppxPackage 很可能以 0x800B0109 失败。届时请以管理员身份重跑本脚本。
"@
    }

    $stores = @(
        @{ Name = 'Root'; Label = '受信任的根证书颁发机构' },
        @{ Name = 'TrustedPeople'; Label = '受信任的发布者' }
    )
    foreach ($store in $stores) {
        # 已经导入过就别重复：同一个指纹出现两条只会让人怀疑哪里出了问题。
        $already = Get-ChildItem "Cert:\$scope\$($store.Name)" -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $wanted.Thumbprint } |
            Select-Object -First 1
        if ($already) {
            Write-Host "证书已在「$scope\$($store.Name)」中：$($already.Thumbprint)"
            continue
        }
        $handle = New-Object System.Security.Cryptography.X509Certificates.X509Store(
            $store.Name, $scope)
        try {
            $handle.Open('ReadWrite')
            $handle.Add($wanted)
        }
        finally {
            $handle.Close()
        }
        Write-Host "已导入「$scope\$($store.Name)」（$($store.Label)）：$($wanted.Thumbprint)" -ForegroundColor Green
    }
}

# 先装包再建快捷方式：快捷方式指向执行别名，而别名由包的注册过程创建。
# 顺序反过来会得到一个指向不存在文件的 .lnk。
Write-Host "正在安装 $msix …"
try {
    Add-AppxPackage -Path $msix -ForceUpdateFromAnyVersion -ErrorAction Stop
}
catch {
    # 0x80073CFB = 「同一个标识、内容不同」，Windows 拒绝覆盖。
    #
    # 这条在**开发期必然撞上**：改一行代码重建，版本号没动，包内容却变了。
    # `-ForceUpdateFromAnyVersion` 也救不了它（那个开关管的是版本号高低，不是
    # 内容差异）。唯一出路是先卸掉旧的再装。
    #
    # 自动卸载再装，而不是把这件事丢给用户：卸载本脚本自己做过、是幂等的，
    # 而且**用户配置与凭据不会丢**（它们不在包里）。这与 [Uninstall] 那条路
    # 一样，只清包与快捷方式。卸载前提醒一句，因为配置虽然不丢，
    # 但用户可能正开着应用。
    if ($_.Exception.Message -match '0x80073CFB') {
        Write-Warning '检测到同版本号但内容不同的旧包（开发期重建常见）。先卸载再安装。'
        $stale = Get-InstalledPackage -Name $IdentityName
        if ($stale) {
            Get-Process xvpn -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 2
            Remove-AppxPackage -Package $stale.PackageFullName -ErrorAction Stop
            Write-Host "已卸载旧包：$($stale.PackageFullName)"
        }
        Add-AppxPackage -Path $msix -ForceUpdateFromAnyVersion -ErrorAction Stop
    }
    else {
    # 0x800B0109 = 包签名的根证书不受信任。
    #
    # 这里给出**可执行的下一步**，而不是把 HRESULT 甩给用户。原因是这条错误在
    # 自签名场景下几乎必然出现，而它的真实成因很不直观：
    #
    #   AppX 部署服务以 **SYSTEM** 身份运行，**不读 CurrentUser 的证书存储**。
    #   本脚本把自签名证书放进 CurrentUser\Root + CurrentUser\TrustedPeople，
    #   足以让 signtool 验签通过（实测 Number of errors: 0），却不足以让部署
    #   服务接受它。自签名证书必须落到**机器级**存储，而那需要管理员权限。
    #
    # 换句话说：自签名 MSIX 的安装本身就需要提权一次——提的是「信任证书」这一步，
    # 不是「安装应用」这一步。配了正式代码签名证书时不适用：那类证书的根本来
    # 就在 Windows 受信任根里。
    if ($_.Exception.Message -match '0x800B0109') {
        Write-Warning @"
安装被拒：包签名的根证书不受信任（0x800B0109）。

当前用户的证书存储不够用——AppX 部署服务以 SYSTEM 身份运行，只认机器级证书
存储。请以**管理员**身份执行下面之一，然后重新运行本脚本：

  # 方式一：只信任发布者（推荐，不动根存储）
  Import-Certificate -FilePath "$cer" -CertStoreLocation Cert:\LocalMachine\TrustedPeople

  # 方式二：直接以管理员身份重跑本脚本，它会自己补上机器级存储
  #   （脚本会把证书同时放到 LocalMachine\TrustedPeople）

配了正式代码签名证书（MSIX_PFX_*）时没有这个问题：那类证书的根本来就在
Windows 受信任根里，双击 .msix 即可安装。

要绕过安装做**运行期验证**，还有一条不需要信任证书的路：
以管理员开启「开发人员模式」后，用 Add-AppxPackage -Register 直接注册解包目录，
签名与证书都不参与。
"@
    }
    throw
    }
}
$installed = Get-InstalledPackage -Name $IdentityName
if (-not $installed) {
    throw "Add-AppxPackage 没有报错，但当前用户下找不到包 $IdentityName——安装没有真正生效。"
}
Write-Host "已安装：$($installed.PackageFullName)" -ForegroundColor Green
Write-Host "  版本：$($installed.Version)"

if (-not $NoShortcut) {
    $alias = Get-AliasPath

    # 图标：留空时先看与 .msix 并排的同名 .ico（发布包的约定），再退回包内资源。
    $iconSource = $IconFile
    if ([string]::IsNullOrWhiteSpace($iconSource)) {
        $adjacent = [System.IO.Path]::ChangeExtension($msix, '.ico')
        if (Test-Path -LiteralPath $adjacent) { $iconSource = $adjacent }
    }
    $icon = Install-AppIcon -PreferredSource $iconSource -Package $installed

    New-DesktopShortcut -Name $ShortcutName -TargetPath $alias -IconPath $icon | Out-Null
    if (-not (Test-Path -LiteralPath $alias)) {
        # 别名是桌面快捷方式的目标，它不存在就意味着快捷方式点不开。
        # 不抛异常（包已经装好了），但必须说出来。
        Write-Warning "执行别名 $alias 尚未出现。重启资源管理器或重新登录后它就会生效，届时快捷方式即可使用。"
    }
}

Write-Host ''
Write-Host '安装完成。' -ForegroundColor Cyan
Write-Host '  · 开始菜单里会出现「幽门」'
Write-Host '  · 桌面上有「幽门」快捷方式'
Write-Host '  · 「随系统启动」可在应用设置页或托盘右键菜单里开关'
