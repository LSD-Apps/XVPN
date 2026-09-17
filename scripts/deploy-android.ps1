#Requires -Version 5.1
<#
.SYNOPSIS
    把当前工作区构建成 APK，装到已连接的安卓真机上，全程不需要碰手机。

.DESCRIPTION
    这个脚本存在的唯一理由是：**vivo / iQOO 的 ROM 会在每次 USB 安装时弹一个
    拦截页**（`com.android.packageinstaller.PackageInterceptActivity`），
    要点「已了解应用的风险检测结果」再点「继续安装」才继续。它让
    `adb install` 永远不返回——不是慢，是卡住——于是「跑一条命令部署」
    这件事在真机上直接不成立。

    脚本做两件事：

      1. `-Relax`（默认开启）把设备侧的安装校验与动画关掉：包校验、ADB 安装
         校验、vivo 的「智能安装」、三档动画时长，以及插着电时保持唤醒。
         这些都是 `adb shell settings put`，可重复执行，幂等。
      2. 安装时**轮询并代点**那个拦截页：找到复选框就勾上，再点「继续安装」。
         坐标不写死——拦截页在不同 ROM / 不同版本上会换布局（实测同一台机器
         勾选框从 y=1893 挪到 y=2031），因此每次都重新 dump UI 再按控件找。

    为什么不用 `adb install -g -t` 就完事：这两个开关只影响**权限**与
    **测试包**标记，管不了厂商的拦截页。`-i com.bbk.appstore` 伪装成自家商店
    的安装器也试过，同样会被拦。

    真正能一次性关掉拦截页的是 vivo 设置里那一项，而它**没有对应的 shell
    设置键**，只能点：
      设置 → 应用安装 → 应用安全验证 → 关
    拦截页右上角那个齿轮就是它的入口。脚本会检测这项是否还开着，并在需要时
    把路径打出来——第一次仍然要用手点一次，之后所有安装都不再需要。

.PARAMETER Mode
    `debug`（默认）或 `release`。debug 变体的包名带 `.dev` 后缀，与正式版并存。
    release 需要 `app/android/key.properties`，缺了会由 Gradle 守卫直接失败。

.PARAMETER Device
    指定设备序列号。只连了一台时可以省略。

.PARAMETER NoBuild
    跳过构建，直接装 `-Apk` 指定的（或上次构建出的）APK。改一行 Dart 想快速
    看效果时用。

.PARAMETER Apk
    要安装的 APK 路径。省略时按 `Mode` 取 `app/build/app/outputs/flutter-apk/` 下
    的产物。

.PARAMETER SkipRelax
    不碰设备设置，只安装。设备已经调好、或不想让脚本改系统设置时用。

.PARAMETER RelaxAnimations
    额外把三档动画时长设为 0。**默认不做**——它改的是用户日常就能感觉到的系统
    行为，而部署脚本的职责只是把包装上。要在真机上空跑 UI 断言（反复截图与
    dump）时再显式打开；收工后记得手工把三项改回 1。

.PARAMETER Launch
    装完顺带把应用拉起来。

.PARAMETER Uninstall
    先卸载再安装。**会连配置、账号密码、学到的分流规则一起删掉**，只在签名
    不一致（换过包名、换过密钥）导致覆盖安装失败时用。

.PARAMETER Evidence
    装完打印一份真机取证：解包出来的规则集、diag.log 里的默认网卡与 TUN fd。
    排查「装上了但连不通」时先看这个。

.EXAMPLE
    powershell -File scripts/deploy-android.ps1 -Launch -Evidence
    构建 debug 包、调设备、安装、拉起来、并打印取证。

.EXAMPLE
    powershell -File scripts/deploy-android.ps1 -NoBuild -Launch
    不重新构建，装上次的产物并直接拉起来。

.NOTES
    *.ps1 必须带 UTF-8 BOM：本机只有 Windows PowerShell 5.1，它按 ANSI 解码
    脚本，中文注释会变成乱码并导致语法错误。
#>
[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug',

    [string]$Device,

    [string]$Apk,

    [switch]$NoBuild,

    [switch]$SkipRelax,

    [switch]$RelaxAnimations,

    [switch]$Launch,

    [switch]$Uninstall,

    [switch]$Evidence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 常量

$DebugPackageId = 'net.lusida.xvpnclient.dev'
$ReleasePackageId = 'net.lusida.xvpnclient'

# Activity 的**类名**用的是 namespace（net.lusida.xvpnclient），不是
# applicationId。debug 变体只给 applicationId 加了 .dev 后缀，类名不受影响，
# 因此 am start 的组件名要写成「带后缀的包 / 不带后缀的类」。
$ActivityClass = 'net.lusida.xvpnclient.MainActivity'

# 安装校验相关的设备设置。[Name] 是 `settings` 的命名空间，空字符串表示
# 这个键在部分 ROM 上不存在——写不进去不算失败，只是那台机器没有这个概念。
$InstallPolicySettings = @(
    @{ Scope = 'global'; Key = 'package_verifier_enable';              Value = '0'; Why = '包校验器：安装时联网送检，慢且会拦' }
    @{ Scope = 'global'; Key = 'verifier_verify_adb_installs';         Value = '0'; Why = 'ADB 安装送检（默认已是 0）' }
    @{ Scope = 'global'; Key = 'verifier_timeout';                     Value = '0'; Why = '校验等待上限' }
    @{ Scope = 'secure'; Key = 'install_non_market_apps';              Value = '1'; Why = '允许非市场来源' }
    @{ Scope = 'global'; Key = 'vivo_update_intelligent_installation'; Value = '0'; Why = 'vivo 的「智能安装」' }
    @{ Scope = 'global'; Key = 'wait_for_debugger';                    Value = '0'; Why = '被打开过会让应用启动即挂起' }
)

# 关掉动画是**可选项**，默认不动。
#
# 它省掉的是「脚本自己反复截图与 dump UI 时，每一帧都晚到」。但它改的是用户日常
# 就能感觉到的系统行为（整个手机的动画都会没掉），而部署脚本的职责只是把包装上：
# 为了自己方便就去动用户的手机，是这一整套工具里最不该有的顺手动作。
# 需要无人值守跑 UI 断言时再显式打开。
$AnimationSettings = @(
    @{ Scope = 'global'; Key = 'window_animation_scale';     Value = '0' }
    @{ Scope = 'global'; Key = 'transition_animation_scale'; Value = '0' }
    @{ Scope = 'global'; Key = 'animator_duration_scale';    Value = '0' }
)

$script:Adb = $null
$script:Serial = $null

# ---------------------------------------------------------------- 输出

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Warn2 { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }
function Write-Bad { param([string]$Message) Write-Host "    $Message" -ForegroundColor Red }

# ---------------------------------------------------------------- adb

function Resolve-Adb {
    <#
      按可靠程度依次找 adb：环境变量 → 仓库的 local.properties → 各平台默认位置。
      直接从 PATH 找是不可靠的——Android Studio 装的 SDK 默认不进 PATH，
      而 `flutter doctor` 照样能跑（它自己知道 SDK 在哪）。
    #>
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($root in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)) {
        if ($root) { $candidates.Add((Join-Path $root 'platform-tools\adb.exe')) }
    }

    # app/android/local.properties 里的 sdk.dir 就是本机真正在用的那个 SDK。
    $localProperties = Join-Path $PSScriptRoot '..\app\android\local.properties'
    if (Test-Path $localProperties) {
        foreach ($line in Get-Content $localProperties) {
            if ($line -match '^\s*sdk\.dir\s*=\s*(.+)$') {
                # Java properties 把反斜杠写成 \\，这里还原成一个。
                $dir = $Matches[1].Trim() -replace '\\\\', '\'
                $candidates.Add((Join-Path $dir 'platform-tools\adb.exe'))
            }
        }
    }

    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'))
    $candidates.Add('C:\Android\Sdk\platform-tools\adb.exe')

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return (Resolve-Path $candidate).Path }
    }

    $onPath = Get-Command adb -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    throw "找不到 adb。设 ANDROID_SDK_ROOT，或让 app/android/local.properties 里的 sdk.dir 指向 SDK。"
}

function Invoke-Adb {
    <# 跑一条 adb 命令并返回它合并后的输出行。 #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    # adb 会往 stderr 写**正常进度**（`adb push` 的 "1 file pushed" 就是 stderr），
    # 而 `$ErrorActionPreference = 'Stop'` 配 `2>&1` 会把「stderr 有输出」当成
    # 终止性错误——于是推送刚成功、脚本就抛一句看起来像失败的成功消息。成败一律
    # 只看退出码，因此这里临时把偏好放宽。
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $script:Adb @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "adb $($Arguments -join ' ') 失败（退出码 $code）：`n$($output -join "`n")"
    }
    return @($output | ForEach-Object { "$_" })
}

function Select-Device {
    <#
      选出唯一的目标设备。unauthorized 要单独说清楚——它的现象是
      `adb devices` 里能看到序列号、但每条命令都报 device unauthorized，
      而用户以为手机已经连上了。真正缺的是手机上那一下「允许 USB 调试」。
    #>
    $lines = Invoke-Adb -Arguments @('devices', '-l')
    $devices = @()
    foreach ($line in $lines) {
        if ($line -match '^(\S+)\s+(device|unauthorized|offline)\b') {
            $devices += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2]; Raw = $line }
        }
    }

    if ($Device) {
        $match = $devices | Where-Object { $_.Serial -eq $Device }
        if (-not $match) { throw "指定的设备 $Device 不在 adb 列表里。" }
        if ($match.State -ne 'device') { throw "设备 $Device 状态是 $($match.State)，不是 device。" }
        return $match.Serial
    }

    if ($devices.Count -eq 0) { throw "没有连接任何设备。插上 USB 并确认手机上弹出了调试授权。" }
    if ($devices.Count -gt 1) {
        $list = ($devices | ForEach-Object { "  $($_.Serial)  [$($_.State)]" }) -join "`n"
        throw "连接了多台设备，请用 -Device 指定：`n$list"
    }

    $only = $devices[0]
    if ($only.State -eq 'unauthorized') {
        throw @"
设备 $($only.Serial) 显示 unauthorized —— 手机上还没同意这台电脑的调试授权。

请在那台手机上：开发者选项 → 撤销 USB 调试授权 → 重新插拔 USB，
然后在弹出的「允许 USB 调试吗？」里勾选「一直允许」再点允许。
"@
    }
    if ($only.State -ne 'device') { throw "设备 $($only.Serial) 状态是 $($only.State)。" }

    return $only.Serial
}

function Set-DeviceInstallPolicy {
    <#
      把设备侧的安装校验关掉。每一项单独 try：不同 ROM 上有的键根本不存在，
      写不进去是正常情况，不该让整条部署失败。
    #>
    Write-Step '调整设备安装策略（关掉安装校验）'

    $targets = $InstallPolicySettings
    if ($RelaxAnimations) { $targets = $targets + $AnimationSettings }

    $applied = 0
    foreach ($item in $targets) {
        $before = (Invoke-Adb -Arguments @('shell', 'settings', 'get', $item.Scope, $item.Key) -AllowFailure) -join ''
        $before = $before.Trim()
        if ($before -eq $item.Value) { continue }

        Invoke-Adb -Arguments @('shell', 'settings', 'put', $item.Scope, $item.Key, $item.Value) -AllowFailure | Out-Null
        $after = ((Invoke-Adb -Arguments @('shell', 'settings', 'get', $item.Scope, $item.Key) -AllowFailure) -join '').Trim()

        if ($after -eq $item.Value) {
            $applied++
            $reason = if ($item.ContainsKey('Why')) { "  # $($item.Why)" } else { '' }
            Write-Ok "$($item.Key): $before -> $after$reason"
        }
        elseif (-not $item.ContainsKey('Why')) {
            Write-Note "$($item.Key): 改不动（这台 ROM 上不存在或不让改）"
        }
    }
    if ($applied -eq 0) { Write-Note '已经都是目标值，无需改动。' }

    # 插着电时不锁屏：UI 自动化最怕屏幕熄灭后控件不再刷新。
    Invoke-Adb -Arguments @('shell', 'svc', 'power', 'stayon', 'true') -AllowFailure | Out-Null
    Write-Ok 'svc power stayon true（插电时不休眠）'
}

# ---------------------------------------------------------------- UI 自动化

function Get-UiXml {
    <# dump 当前界面。uiautomator 偶尔返回空，重试一次。 #>
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $xml = (Invoke-Adb -Arguments @('exec-out', 'uiautomator', 'dump', '/dev/tty') -AllowFailure) -join "`n"
        if ($xml -match '<hierarchy') { return $xml }
        Start-Sleep -Milliseconds 700
    }
    return $null
}

function Get-NodeCenter {
    <#
      在 dump 出来的 XML 里按谓词找控件，返回它的中心坐标。找不到返回 $null。

      这里刻意用正则扫 <node ...> 而不是解析成 XML 文档：uiautomator 的输出
      里 text 属性可能带未转义的字符，走 XML 解析会直接抛异常，而正则不会。
    #>
    param(
        [Parameter(Mandatory)][string]$Xml,
        [Parameter(Mandatory)][scriptblock]$Match
    )
    foreach ($m in [regex]::Matches($Xml, '<node[^>]*?/?>')) {
        $node = $m.Value
        $text = [regex]::Match($node, 'text="([^"]*)"').Groups[1].Value
        $desc = [regex]::Match($node, 'content-desc="([^"]*)"').Groups[1].Value
        $class = [regex]::Match($node, 'class="([^"]*)"').Groups[1].Value
        $id = [regex]::Match($node, 'resource-id="([^"]*)"').Groups[1].Value
        $checked = [regex]::Match($node, 'checked="([^"]*)"').Groups[1].Value
        $bounds = [regex]::Match($node, 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')

        if (-not $bounds.Success) { continue }

        $candidate = [pscustomobject]@{
            Text    = $text
            Desc    = $desc
            Class   = $class
            Id      = $id
            Checked = $checked
            X       = [int](([int]$bounds.Groups[1].Value + [int]$bounds.Groups[3].Value) / 2)
            Y       = [int](([int]$bounds.Groups[2].Value + [int]$bounds.Groups[4].Value) / 2)
        }

        if (& $Match $candidate) { return $candidate }
    }
    return $null
}

function Tap-At {
    param([int]$X, [int]$Y)
    Invoke-Adb -Arguments @('shell', 'input', 'tap', "$X", "$Y") -AllowFailure | Out-Null
}

function Get-InterceptState {
    <#
      判断当前界面是不是厂商的安装拦截页，返回 'intercept' / 'need-manual' / 'absent'。

      **不要用 Activity 名去认它**。拦截页的 Activity 是
      `PackageInterceptActivity`，但那个名字只出现在 `dumpsys window` 的输出里，
      而 `uiautomator dump` 给出的 XML 只带 `package="com.android.packageinstaller"`
      和各个控件的文本。按名字认会导致「界面明明停在拦截页，脚本却一直以为
      没有拦截页」——症状是安装卡到超时。

      因此按**内容**认：包名 + 那句只有拦截页才有的文案。

      拦截页有两副面孔，取决于「应用安全验证」是否开着：
        * 开着：页面上写着「继续安装第三方应用需身份验证」——点下去还要按指纹，
          脚本没有手指，只能如实认输；
        * 关着：只剩「已了解应用的风险检测结果」复选框 + 「继续安装」。
    #>
    param([string]$Xml)

    if ($Xml -notmatch 'com\.android\.packageinstaller') { return 'absent' }
    if ($Xml -match '需身份验证|指纹验证|锁屏密码验证|账号密码验证') { return 'need-manual' }
    if ($Xml -match '继续安装|已了解应用的风险检测结果') { return 'intercept' }
    return 'absent'
}

function Resolve-VivoIntercept {
    <#
      代点拦截页：勾上风险确认，再点「继续安装」。返回是否已经点过。
      坐标不写死——同一个 ROM 的不同版本会把控件挪位置（实测勾选框从
      y=1893 挪到 y=2031），所以每次都重新 dump、按控件找中心点。
    #>
    param([string]$Xml)

    $checkBox = Get-NodeCenter -Xml $Xml -Match {
        param($n) $n.Class -match 'CheckBox' -or $n.Text -match '已了解应用的风险'
    }
    if ($checkBox -and $checkBox.Checked -ne 'true') {
        Tap-At -X $checkBox.X -Y $checkBox.Y
        Start-Sleep -Milliseconds 700
    }

    $confirm = Get-NodeCenter -Xml $Xml -Match {
        param($n) $n.Text -eq '继续安装' -or $n.Id -eq 'android:id/button1'
    }
    if (-not $confirm) { return $false }

    Tap-At -X $confirm.X -Y $confirm.Y
    return $true
}

function Show-ManualInterceptHelp {
    Write-Bad '这台 vivo/iQOO 的「应用安全验证」还开着，安装会停下来要指纹或密码。'
    Write-Note '手机上一次点掉即可，之后所有安装都不再需要：'
    Write-Note '  设置 → 应用安装 → 应用安全验证 → 关'
    Write-Note '（拦截页右上角那个齿轮就是这一页的入口。）'
    Write-Note '脚本已经可以代点「继续安装」，但指纹这一步点不了。'
}

# ---------------------------------------------------------------- 安装

function Get-PackageStamp {
    <#
      已安装版本的 `lastUpdateTime`；没装过就返回 $null。

      这是判断「装完了没有」的**唯一可靠依据**（原因见 [Install-Apk]）。
    #>
    param([Parameter(Mandatory)][string]$PackageId)

    $dump = (Invoke-Adb -Arguments @('shell', 'dumpsys', 'package', $PackageId) -AllowFailure) -join "`n"
    if ($dump -notmatch "Package \[$([regex]::Escape($PackageId))\]") { return $null }
    $match = [regex]::Match($dump, 'lastUpdateTime=([^\r\n]+)')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.Trim()
}

function Get-PackageVersion {
    param([Parameter(Mandatory)][string]$PackageId)
    $dump = (Invoke-Adb -Arguments @('shell', 'dumpsys', 'package', $PackageId) -AllowFailure) -join "`n"
    $match = [regex]::Match($dump, 'versionName=([^\r\n]+)')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

function Install-Apk {
    <#
      先把 APK 推到 /data/local/tmp 再 `pm install`，而不是用 `adb install` 的
      流式安装。理由：流式安装在拦截页卡住时，整个会话会随 adb 进程一起被掐掉，
      重试要从头再传一遍 155 MB。先 push 之后，重试只是在手机上原地重装。

      另外 `pm install` 比 `adb install` 多给一条关键信息：成功时打印 Success，
      失败时打印 Failure [原因]，而流式安装失败常常只是一句笼统的 error。
    #>
    param(
        [Parameter(Mandatory)][string]$ApkPath,
        [Parameter(Mandatory)][string]$PackageId
    )

    $remotePath = '/data/local/tmp/xvpn-deploy.apk'
    $size = (Get-Item $ApkPath).Length
    Write-Step "推送 APK（$([math]::Round($size / 1MB, 1)) MB）"

    Invoke-Adb -Arguments @('push', $ApkPath, $remotePath) | Out-Null
    Write-Ok "已推到 $remotePath"

    Write-Step '安装（拦截页由脚本代点）'

    # 判断「装完了没有」**不能只看 pm install 的退出**。
    #
    # vivo 的安装器提交完会话之后并不关掉它（安装完成页还留在前台），于是
    # `pm install` 这个客户端会一直等：实测包在 19:01:17 已经装好、启动器图标
    # 都出来了，命令却还阻塞着。以它为准的话每次安装都会等到超时，再被误报成
    # 失败——比慢更糟的是**把成功说成失败**。
    #
    # 因此以设备上的事实为准：lastUpdateTime 变了（覆盖安装）或包从无到有
    # （首次安装），就算装完了。pm install 的输出只在失败时用来取原因。
    $before = Get-PackageStamp -PackageId $PackageId

    $stdout = Join-Path $env:TEMP "xvpn-pm-install-$PID.out"
    $stderr = Join-Path $env:TEMP "xvpn-pm-install-$PID.err"
    Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

    $pmArgs = @('-s', $script:Serial, 'shell', 'pm', 'install', '-r', '-g', '-t', '--user', '0', $remotePath)
    if ($Uninstall) { $pmArgs = @('-s', $script:Serial, 'shell', 'pm', 'install', '-g', '-t', '--user', '0', $remotePath) }

    $proc = Start-Process -FilePath $script:Adb -ArgumentList $pmArgs -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    $deadline = (Get-Date).AddMinutes(5)
    $sawIntercept = $false
    $installed = $false
    $tick = 0

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $tick++

        # 客户端自己退了：正常路径（重装同一版本、没有拦截页时就是这样）。
        if ($proc.HasExited) { break }

        $xml = Get-UiXml
        if ($xml) {
            switch (Get-InterceptState -Xml $xml) {
                'need-manual' {
                    Show-ManualInterceptHelp
                    $proc.Kill()
                    throw '安装需要人工身份验证，脚本无法继续。'
                }
                'intercept' {
                    if (-not $sawIntercept) {
                        $sawIntercept = $true
                        Write-Note '检测到厂商安装拦截页，正在代点…'
                    }
                    if (Resolve-VivoIntercept -Xml $xml) {
                        Write-Ok '已勾选风险确认并点「继续安装」'
                    }
                }
            }
        }

        # 每 3 轮（约 6 秒）量一次设备侧事实：问得太密会和安装本身抢 PackageManager。
        if ($tick % 3 -eq 0) {
            $stamp = Get-PackageStamp -PackageId $PackageId
            if ($stamp -and $stamp -ne $before) { $installed = $true; break }
        }
    }

    $clientReturned = $proc.HasExited
    if (-not $clientReturned) { $proc.Kill() }

    $out = if (Test-Path $stdout) { (Get-Content $stdout -Raw) } else { '' }
    $err = if (Test-Path $stderr) { (Get-Content $stderr -Raw) } else { '' }
    Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue
    Invoke-Adb -Arguments @('shell', 'rm', '-f', $remotePath) -AllowFailure | Out-Null

    $combined = "$out`n$err"
    if ($combined -match 'Success') { $installed = $true }

    if (-not $installed) {
        if ($combined -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match') {
            throw @"
覆盖安装失败：签名不一致。用旧包名或旧密钥装过的版本无法被覆盖，
必须先在手机上卸载（**会连配置、账号密码、学到的分流规则一起删掉**），
再跑一次并加上 -Uninstall。
"@
        }
        if ($combined -match 'INSTALL_FAILED_ABORTED') {
            throw @"
安装被中止（INSTALL_FAILED_ABORTED）：手机上那一页没有被点放行。

最可能的原因是拦截页停在了需要人工确认的位置。请检查：
  * 「应用安全验证」是否还开着（设置 → 应用安装 → 应用安全验证）。开着的话
    点「继续安装」之后还要按指纹，脚本代点不了；
  * 手机是否熄屏或停在锁屏——UI 自动化在锁屏下读不到控件。
"@
        }
        if ($combined.Trim()) { throw "安装失败：`n$($combined.Trim())" }
        throw '安装超时：设备上的 lastUpdateTime 一直没变，且 pm install 没有给出任何结论。'
    }

    $version = Get-PackageVersion -PackageId $PackageId
    $versionNote = if ($version) { "，版本 $version" } else { '' }
    if ($clientReturned) {
        Write-Ok "安装成功$versionNote"
    }
    else {
        Write-Ok "安装成功$versionNote（包已在设备上就绪）"
        Write-Note 'pm install 客户端没有返回：vivo 的安装器提交会话后不关闭它。以设备上的 lastUpdateTime 为准。'
    }
    if (-not $sawIntercept) { Write-Note '这次没有出现拦截页。' }
}

# ---------------------------------------------------------------- 取证

function Show-DeviceEvidence {
    <#
      真机取证。这几项各自对应一个**只有真机才会暴露**的失败：
        * rulesets/ 里少文件 → 内核起手就报 rule-set 不存在，界面只说「连不上」；
        * 默认网卡报成 tun0 → 直连出站绑到自己身上，握手包先进隧道；
        * openTun 没有 fd → VpnService 没建成，后面的现象全是连锁反应。
    #>
    param([Parameter(Mandatory)][string]$PackageId)

    Write-Step "真机取证（$PackageId）"

    $files = (Invoke-Adb -Arguments @('shell', 'run-as', $PackageId, 'ls', 'files/') -AllowFailure) -join "`n"
    if ($files -match 'Package .* is not debuggable|not debuggable|unknown package') {
        Write-Warn2 'release 包不可 run-as，拿不到私有目录。debug 变体才有这份取证。'
        return
    }

    $ruleSets = (Invoke-Adb -Arguments @('shell', 'run-as', $PackageId, 'ls', 'files/rulesets/') -AllowFailure) -join "`n"
    $expected = @('geosite-cn.srs', 'geoip-cn.srs', 'geosite-cn-extra.srs', 'geoip-cn-extra.srs', 'cn-ip.bin')
    $missing = @($expected | Where-Object { $ruleSets -notmatch [regex]::Escape($_) })
    if ($missing.Count -eq 0) {
        Write-Ok "内置规则集齐了：$($expected.Count) 项（含 cn-ip.bin）"
    }
    else {
        Write-Bad "缺内置规则集：$($missing -join ', ')"
        Write-Note '内核会带着不存在的 path 启动，第一次连接必定失败。'
    }

    if ($files -match 'credentials\.key') {
        $blob = ((Invoke-Adb -Arguments @('shell', 'run-as', $PackageId, 'cat', 'files/credentials.key') -AllowFailure) -join '').Trim()
        # 12 字节 IV + 32 字节 DEK + 16 字节 GCM tag = 60 字节 → 恰好 80 个 base64 字符。
        # 长度对得上，说明落盘的是被 Keystore 包起来的密文，而不是明文密钥。
        if ($blob.Length -eq 80) {
            Write-Ok 'credentials.key：80 字符 base64 = 60 字节密文，Keystore 包装生效'
        }
        else {
            Write-Warn2 "credentials.key 长度是 $($blob.Length)，不是预期的 80 —— 检查 Keystore 是否可用"
        }
    }
    else {
        Write-Note '还没有 credentials.key（没填过 auth-user-pass 账号密码）。'
    }

    $diag = (Invoke-Adb -Arguments @('shell', 'run-as', $PackageId, 'cat', 'files/diag.log') -AllowFailure) -join "`n"
    if ($diag -match '上报默认接口') {
        $line = ($diag -split "`n" | Where-Object { $_ -match '上报默认接口' } | Select-Object -Last 1).Trim()
        if ($line -match '上报默认接口\s+(tun\d+)') {
            Write-Bad "默认网卡被报成了 $($Matches[1])（我们自己的隧道）—— 直连会绕回隧道"
        }
        else {
            Write-Ok "默认网卡：$line"
        }
    }
    if ($diag -match 'openTun ok, fd=(\d+)') {
        $fds = [regex]::Matches($diag, 'openTun ok, fd=(\d+)') | ForEach-Object { $_.Groups[1].Value }
        Write-Ok "openTun 成功 $($fds.Count) 次，fd: $($fds -join ', ')"
    }
    if ($diag -match '网卡枚举受限') {
        Write-Bad '网卡枚举受限：内核会报 no available network interface，整个内核起不来'
    }
}

# ---------------------------------------------------------------- 主流程

try {
    $script:Adb = Resolve-Adb
    Write-Step "adb: $script:Adb"

    $script:Serial = Select-Device
    Write-Ok "设备: $script:Serial"

    $packageId = if ($Mode -eq 'debug') { $DebugPackageId } else { $ReleasePackageId }
    Write-Note "包名: $packageId（$Mode）"

    if (-not $SkipRelax) { Set-DeviceInstallPolicy }

    if (-not $NoBuild) {
        Write-Step "构建（flutter build apk --$Mode --target-platform android-arm64）"
        $appDir = Resolve-Path (Join-Path $PSScriptRoot '..\app')
        Push-Location $appDir
        try {
            # 只构建 arm64-v8a，与 release.yml 的理由相同：libbox.aar 只有这一个
            # ABI。不加这个开关，debug 包会把三个 ABI 全塞进去（147 MB → 220 MB
            # 以上），而那多出来的两个 ABI 在运行时根本加载不到内核——推一台
            # 32 位机器上去只会拿到一个「装得上、一开就崩」的应用。
            #
            # **必须临时放宽 $ErrorActionPreference**，与 [Invoke-Adb] 同一个理由：
            # flutter 会把**正常的**提示写到 stderr（「Flutter assets will be
            # downloaded from ...」、插件 KGP 的弃用警告等），而 'Stop' 配 `2>&1`
            # 会把「stderr 有输出」当成终止性错误。后果是：APK 已经构建成功、
            # 脚本却在下面那句 `if ($code -ne 0)` **之前**就抛出去，把一条成功
            # 消息当成失败报出来。实测踩过——脚本以退出码 1 中止，而
            # `build/app/outputs/flutter-apk/app-debug.apk` 是好的。
            # 成败一律只看退出码。
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & flutter build apk "--$Mode" --target-platform android-arm64
                $code = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $previous }
            if ($code -ne 0) { throw "flutter build apk 失败（退出码 $code）。" }
        }
        finally { Pop-Location }
        Write-Ok '构建完成'
    }

    if (-not $Apk) {
        $Apk = Join-Path $PSScriptRoot "..\app\build\app\outputs\flutter-apk\app-$Mode.apk"
    }
    if (-not (Test-Path $Apk)) { throw "找不到 APK：$Apk（先跑一次不带 -NoBuild 的构建）。" }
    $Apk = (Resolve-Path $Apk).Path

    if ($Uninstall) {
        Write-Warn2 "卸载 $packageId —— 配置、账号密码、学到的分流规则都会一起没"
        Invoke-Adb -Arguments @('uninstall', $packageId) -AllowFailure | Out-Null
        Start-Sleep -Seconds 2
    }

    Install-Apk -ApkPath $Apk -PackageId $packageId

    if ($Launch) {
        Write-Step '拉起应用'
        Invoke-Adb -Arguments @('shell', 'monkey', '-p', $packageId, '-c', 'android.intent.category.LAUNCHER', '1') -AllowFailure | Out-Null
        Start-Sleep -Seconds 6
        $pidValue = ((Invoke-Adb -Arguments @('shell', 'pidof', $packageId) -AllowFailure) -join '').Trim()
        if ($pidValue) { Write-Ok "已启动，pid=$pidValue" }
        else { Write-Warn2 '进程没起来，看 adb logcat 里的 FATAL / panic:' }
    }

    if ($Evidence) { Show-DeviceEvidence -PackageId $packageId }

    Write-Step '完成'
}
catch {
    Write-Host ''
    Write-Bad $_.Exception.Message
    exit 1
}
