package net.lusida.xvpnclient

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.Os
import android.util.Log
import androidx.annotation.RequiresApi
import libbox.CommandServer
import libbox.CommandServerHandler
import libbox.ConnectionOwner
import libbox.InterfaceUpdateListener
import libbox.Libbox
import libbox.LocalDNSTransport
import libbox.NetworkInterface
import libbox.NetworkInterfaceIterator
import libbox.Notification as LibboxNotification
import libbox.OverrideOptions
import libbox.PlatformInterface
import libbox.PlatformUser
import libbox.RoutePrefix
import libbox.SetupOptions
import libbox.ShellSession
import libbox.StringIterator
import libbox.SystemProxyStatus
import libbox.TunOptions
import libbox.WIFIState
import libbox.BridgeOptions
import libbox.BridgeSession
import libbox.NeighborUpdateListener
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress

/**
 * 安卓端的隧道服务。
 *
 * 与 Windows 端的根本差别：安卓上内核不能作为独立进程运行（Android 10 起禁止
 * 执行应用数据目录下的可执行文件），而且 VpnService 的 TUN 文件描述符只能在
 * 应用进程内创建。因此这里把 sing-box 以内核库（libbox）的形式嵌进本进程，
 * 由本服务建立 TUN 并交给内核。
 *
 * 分工：
 *   * 本类负责 VpnService 生命周期、TUN 建立、以及 libbox 需要的平台能力；
 *   * 分流规则、DNS 策略、配置生成完全复用 Dart 侧的 SingBoxConfigBuilder
 *     （配置文件由 Dart 生成后经 MethodChannel 传进来），两端行为一致；
 *   * 连接观测走内核的 Clash API（127.0.0.1:2081），与 Windows 端同一套 Dart 代码。
 */
class XvpnVpnService : VpnService(), PlatformInterface {

    companion object {
        private const val TAG = "XvpnVpnService"
        private const val CHANNEL_ID = "xvpn_vpn"
        private const val NOTIFICATION_ID = 1

        /// 落盘诊断日志的容量上限。超过就清空重来，避免无限增长。
        private const val DIAG_MAX_BYTES = 256 * 1024L

        const val ACTION_CONNECT = "com.xvpn.xvpn.CONNECT"
        const val ACTION_DISCONNECT = "com.xvpn.xvpn.DISCONNECT"
        const val EXTRA_CONFIG = "config"

        // 与 Go 的 net.Flags 对齐，供 getInterfaces() 填 NetworkInterface.flags。
        private const val FLAG_UP = 1
        private const val FLAG_RUNNING = 2
        private const val FLAG_LOOPBACK = 4
        private const val FLAG_POINT_TO_POINT = 8
        private const val FLAG_MULTICAST = 16

        /** 供 Dart 侧查询连接状态。 */
        @Volatile
        var isRunning: Boolean = false
            private set

        /** 最近一次错误，供界面展示原因而不是只显示「连接失败」。 */
        @Volatile
        var lastError: String? = null
            private set

        /**
         * 由界面侧上报错误（例如读取分享进来的配置失败）。
         * 错误信息统一放在这里，界面读取时只需看一个地方。
         */
        fun reportError(message: String) {
            lastError = message
        }

        /**
         * 内核日志的转发出口。
         *
         * 安卓上内核跑在同一进程里，日志经 libbox 回调出来，不像 Windows 那样
         * 能读子进程的 stderr。Dart 侧的失败归因依赖这些日志，因此由 MainActivity
         * 注册一个转发回调。
         */
        @Volatile
        var onLog: ((String) -> Unit)? = null
    }

    private var commandServer: CommandServer? = null
    private var libboxReady = false
    private var tunFd: ParcelFileDescriptor? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var defaultNetworkCallback: ConnectivityManager.NetworkCallback? = null

    /// 上一条上报给内核的默认网卡名。
    ///
    /// 两个用处：一是网卡没变时不重复记诊断（回调很密集）；二是 WiFi 与蜂窝同时
    /// 在线时优先沿用同一条，别让内核每次改判都重建直连出站。
    private var lastDefaultInterface: String? = null

    /// 网卡枚举受限这件事只诊断一次，避免内核反复取网卡时刷满 diag.log。
    private var interfaceDiagDone = false

    /// 平台网卡回调的调用序次。
    ///
    /// 内核「什么时候要网卡、要了几次、我们给了什么」是这类故障唯一的事实，
    /// 而它在界面上一个字都不显示。只记最前面几次：这不是运行日志，是启动剖面。
    private var platformDiagCount = 0

    private fun diagPlatform(message: String) {
        if (platformDiagCount >= 8) return
        platformDiagCount++
        diag(message)
    }

    /**
     * 连接过程的落盘诊断。
     *
     * 存在的理由很具体：这台设备上 logcat 过滤掉了本应用的日志，一旦内核在
     * 原生层出问题，用户能提供的只有「连不上」三个字。这里只记**连接生命周期
     * 的关键节点**（几步、TUN 是否建立、内核是否启动、异常），不记内核的逐行
     * 日志——那些走 [Handler.writeDebugMessage] 进 Dart 的日志缓冲，界面里能看。
     *
     * 用 `run-as <包名> cat .../diag.log` 读取；超过 [DIAG_MAX_BYTES] 就重来，
     * 避免无限增长。
     */
    private fun diag(message: String) {
        try {
            val f = File(filesDir, "diag.log")
            if (f.exists() && f.length() > DIAG_MAX_BYTES) f.delete()
            f.appendText("${System.currentTimeMillis()} $message\n")
        } catch (_: Throwable) {
            // 诊断日志失败绝不能影响主流程。
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CONNECT -> {
                val config = intent.getStringExtra(EXTRA_CONFIG).orEmpty()
                if (config.isBlank()) {
                    fail("配置为空，无法建立隧道")
                } else {
                    Thread { startBox(config) }.start()
                }
            }
            ACTION_DISCONNECT -> Thread { stopBox() }.start()
            else -> {
                // 系统在进程被回收后按 START_STICKY 重新拉起服务时会传 null intent
                // （或一个我们不认识的动作）。此时进程是全新的：libbox 的全局状态、
                // TUN 的 fd、commandServer 都已随旧进程消失，服务手里**没有任何**
                // 可恢复的东西。原实现对此什么都不做，于是服务空转、`isRunning`
                // 却为 false——系统和界面各说各话。
                //
                // 这里选择「干净地拆掉」而不是「从持久化状态重建」：配置原文与
                // 用户的连接意图由 Dart 侧持久化（见 AppState.restoreConnection），
                // 界面起来后会自己重新拨号；在原生侧再存一份配置只会制造第二个
                // 真相来源，迟早与 Dart 侧不一致。
                diag("onStartCommand 收到空/未知 intent，拆掉空服务")
                Thread { stopBox() }.start()
            }
        }
        return START_STICKY
    }

    override fun onRevoke() {
        // 用户在其他应用里撤销了 VPN 授权，必须立刻断开，
        // 否则会留下一个内核还在跑、但流量已经不通的状态。
        Thread { stopBox() }.start()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopBox()
        super.onDestroy()
    }

    // ------------------------------------------------------------ 内核生命周期

    private fun startBox(configJson: String) {
        if (commandServer != null) {
            Log.i(TAG, "内核已在运行，忽略重复的启动请求")
            return
        }
        try {
            diag("startBox enter, configLen=${configJson.length}")
            setupLibbox()
            diag("setupLibbox ok")
            startForeground(NOTIFICATION_ID, buildNotification())
            diag("startForeground ok")

            val server = Libbox.newCommandServer(Handler(), this)
            diag("newCommandServer ok")
            server.start()
            diag("commandServer.start ok")
            // 先登记再启动：内核启动失败时 stopBox() 才能把这个 server 收掉。
            commandServer = server
            // 这里必须传一个真实对象。sing-box 1.14 的 StartOrReloadService 会
            // 无条件读取 options.AutoRedirect，传 null 会在原生层直接段错误崩溃
            // （不是抛异常，是整个进程消失）。
            // autoRedirect 只在「无 VpnService 的 root 重定向」场景用，走 TUN 时保持 false。
            val overrides = OverrideOptions()
            overrides.autoRedirect = false
            diag("startOrReloadService ...")
            server.startOrReloadService(configJson, overrides)
            isRunning = true
            lastError = null
            diag("startOrReloadService ok, 内核已启动")
            Log.i(TAG, "内核已启动")
        } catch (e: Throwable) {
            diag("startBox 抛异常: ${e::class.java.name}: ${e.message}")
            Log.e(TAG, "启动失败", e)
            // 启动中途失败可能已经把 server 登记上了，这里统一收尾，
            // 否则 TUN 与内核会残留在半启动状态。
            stopBox()
            fail(e.message ?: e.toString())
        }
    }

    private fun stopBox() {
        try {
            commandServer?.let { server ->
                server.closeService()
                server.close()
            }
        } catch (e: Throwable) {
            Log.w(TAG, "关闭内核时出错", e)
        }
        commandServer = null

        // TUN 必须显式关闭，否则下一次连接会拿不到 fd。
        try {
            tunFd?.close()
        } catch (e: Throwable) {
            Log.w(TAG, "关闭 TUN 时出错", e)
        }
        tunFd = null

        stopDefaultInterfaceMonitor()
        isRunning = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun fail(message: String) {
        lastError = message
        isRunning = false
        stopSelf()
    }

    /**
     * 全局初始化：告诉内核把数据放在哪里。
     *
     * 内核约定 setup 每个进程只做一次，重复调用会重置全局状态；而用户反复
     * 「断开→连接」时会再次走到这里，因此用一个进程级的标记挡掉后续调用。
     */
    private fun setupLibbox() {
        if (libboxReady) return
        val options = SetupOptions()
        options.basePath = filesDir.absolutePath
        options.workingPath = filesDir.absolutePath
        options.tempPath = cacheDir.absolutePath
        // 安卓上必须开启：修正 netstack 与系统协议栈的差异。
        options.fixAndroidStack = true
        options.logMaxLines = 300
        // 打开平台侧 DEBUG 日志。
        //
        // 这曾经是**开不得**的：DEBUG 日志会经 `writeDebugMessage` 转发给 Dart，
        // 而那一层直接在原生线程里调 Flutter 的 MethodChannel，触发 JNI 校验
        // 失败并 abort 整个进程。根因已修（见 [Handler.writeDebugMessage] 的
        // 注释），现在打开是安全的。
        //
        // 注意它只是平台侧的开关，「会不会产生 DEBUG 行」由配置里的
        // `log.level` 决定——WireGuard 的握手行是 DEBUG 级，配置侧已按协议
        // 下发 debug（见 Dart 侧的 `ParsedProfile.wantsDebugLogs`）。两者都打开，
        // 界面上的「隧道握手」一行才有数据。
        options.debug = true
        diag("setupLibbox: 即将调用 Libbox.setup")
        Libbox.setup(options)
        diag("setupLibbox: Libbox.setup 返回")
        libboxReady = true
    }

    // ------------------------------------------------------------ TUN

    /**
     * 建立 TUN。
     *
     * 参数由内核根据配置里的 tun 入站推导出来，这里只负责翻译成
     * VpnService.Builder 的调用——包括地址、路由、DNS 与分包名过滤。
     */
    override fun openTun(options: TunOptions): Int {
        diag("openTun enter, mtu=${options.mtu}")
        val builder = Builder()
        // 会话名。系统「VPN 已连接」通知与设置里的 VPN 条目都显示它，
        // 因此这里是用户可见的应用名，跟随中文名。
        builder.setSession("幽门")
        builder.setMtu(options.mtu)

        var hasAddress = false
        val v4 = options.inet4Address
        while (v4.hasNext()) {
            val prefix = v4.next()
            builder.addAddress(prefix.address(), prefix.prefix())
            hasAddress = true
        }
        val v6 = options.inet6Address
        while (v6.hasNext()) {
            val prefix = v6.next()
            builder.addAddress(prefix.address(), prefix.prefix())
            hasAddress = true
        }
        if (!hasAddress) {
            throw IllegalStateException("配置里没有为 TUN 指定地址")
        }

        addRoutes(builder::addRoute, options.inet4RouteAddress)
        addRoutes(builder::addRoute, options.inet6RouteAddress)
        addRoutes(builder::addRoute, options.inet4RouteRange)
        addRoutes(builder::addRoute, options.inet6RouteRange)

        // Android 13+ 支持直接排除路由，比「用 allowFamily + 自行计算补集」可靠。
        // 注意 excludeRoute 接受的是 IpPrefix 对象，不是 (地址, 掩码)。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            addExcludeRoutes(builder, options.inet4RouteExcludeAddress)
            addExcludeRoutes(builder, options.inet6RouteExcludeAddress)
        }

        val dns = options.dnsServerAddress
        while (dns.hasNext()) {
            builder.addDnsServer(dns.next())
        }

        if (options.autoRoute) {
            // 应用自身的流量不进隧道：否则内核去连服务器时会被自己再抓一次，
            // 形成回环，表现是「连接成功但完全上不了网」。
            try {
                builder.addDisallowedApplication(packageName)
            } catch (e: Throwable) {
                Log.w(TAG, "排除自身应用失败", e)
            }
        }

        val fd = builder.establish() ?: throw IllegalStateException("建立 TUN 失败，请检查 VPN 授权")
        tunFd = fd
        diag("openTun ok, fd=${fd.fd}")
        return fd.fd
    }

    private fun addRoutes(add: (String, Int) -> Unit, iterator: libbox.RoutePrefixIterator?) {
        if (iterator == null) return
        while (iterator.hasNext()) {
            val prefix = iterator.next()
            add(prefix.address(), prefix.prefix())
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun addExcludeRoutes(builder: Builder, iterator: libbox.RoutePrefixIterator?) {
        if (iterator == null) return
        while (iterator.hasNext()) {
            val prefix = iterator.next()
            builder.excludeRoute(IpPrefix(InetAddress.getByName(prefix.address()), prefix.prefix()))
        }
    }

    /** 内核发起直连连接前会调用这里，让 socket 绕过隧道。 */
    override fun autoDetectInterfaceControl(fd: Int) {
        if (!protect(fd)) {
            throw IllegalStateException("protect($fd) 失败")
        }
    }

    // ------------------------------------------------------------ 网络接口

    /**
     * 默认网络变化监听。
     *
     * 内核靠它决定直连走哪张网卡。不实现的话 `auto_detect_interface` 拿不到
     * 默认接口，直连部分会失败——表现是「直连站点打不开、其余正常」。
     *
     * **必须排除 VPN 网络本身**，理由见 [pickDefaultNetwork]。
     */
    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        diagPlatform("内核请求默认接口监听")
        stopDefaultInterfaceMonitor()
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = reportDefaultInterface(manager, listener)
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                reportDefaultInterface(manager, listener)

            override fun onLost(network: Network) = reportDefaultInterface(manager, listener)
        }
        defaultNetworkCallback = callback
        // 用 LISTEN 模式（registerNetworkCallback）而不是 registerDefaultNetworkCallback：
        // 后者在 Android 9 起把**我们自己的 VPN** 当成默认网络返回，正好是我们最不
        // 想要的那一张。LISTEN 模式配上 NOT_VPN 要求，拿到的是「所有物理网络」，
        // 由 [pickDefaultNetwork] 挑一张最合适的。
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        try {
            manager.registerNetworkCallback(request, callback)
        } catch (e: Throwable) {
            Log.w(TAG, "注册网络回调失败", e)
        }
        // 注册回调不会立刻触发一次，这里主动报一次。
        //
        // 这一步是**关键路径**：内核此刻正同步等这张网卡（见 [reportDefaultInterface]
        // 的说明），而回调是异步的，赶不上。
        reportDefaultInterface(manager, listener, retries = 10)
    }

    /**
     * 从系统的所有网络里挑出**真正该走的物理出口**。
     *
     * 为什么不能直接用 `activeNetwork`：Android 9 起，默认网络对我们这种
     * VPN 应用返回的就是**自己的 tun**（上游 SFA 为此专门用 requestNetwork /
     * registerBestMatchingNetworkCallback 绕开这件事）。把 tun0 报成默认出口，
     * 内核就会把「直连出站」也绑到 tun0 上——那正是 `auto_detect_interface`
     * 要避免的路由回环：对端地址的握手包自己先进了隧道。
     *
     * 症状很容易被误读成「节点坏了」：内核起得来、TUN 也建好了、界面说已连接，
     * 但对端**一次都收不到连接**，而直连（命中规则集的那部分）同样不通。
     *
     * 稳定优先：上一条报过的网卡只要还在候选里就继续用它。内核每次改判都要重建
     * 直连出站，WiFi 与蜂窝之间来回改判没有任何好处。
     */
    private fun pickDefaultNetwork(manager: ConnectivityManager): Network? {
        val candidates = ArrayList<Pair<Network, Int>>()
        for (network in orderedNetworks(manager)) {
            val caps = manager.getNetworkCapabilities(network) ?: continue
            // 排除 VPN 网络（包括我们自己的 tun0）：内核要的是物理出口。
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            var score = 0
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) score += 4
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) score += 2
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) score += 1
            candidates.add(network to score)
        }
        if (candidates.isEmpty()) return null
        val last = lastDefaultInterface
        if (last != null) {
            candidates.firstOrNull { manager.getLinkProperties(it.first)?.interfaceName == last }
                ?.let { return it.first }
        }
        return candidates.maxByOrNull { it.second }?.first
    }

    /// 默认网络排在最前，其余按系统给的顺序。
    private fun orderedNetworks(manager: ConnectivityManager): List<Network> {
        val ordered = ArrayList<Network>()
        manager.activeNetwork?.let { ordered.add(it) }
        manager.allNetworks.forEach { network -> if (!ordered.contains(network)) ordered.add(network) }
        return ordered
    }

    /// 上报默认接口。
    ///
    /// **必须同步调 [InterfaceUpdateListener.updateDefaultInterface]，不要 post 到
    /// 其它线程。** 这不是风格偏好，是实测出来的：
    ///
    ///   * 内核在 `startOrReloadService` 里**同步等**这张网卡——它不返回，内核就
    ///     继续往下走，然后立刻取网卡列表、立刻建直连出站。实测时序：请求监听
    ///     → 5ms 后我们算出结果 → 21ms 后内核取列表 → 再 1ms 就报
    ///     `no available network interface`；
    ///   * 那 21ms 就是全部预算。`mainHandler.post` 要等主线程把手上的活干完
    ///     （点击「连接」之后正是界面最忙的时候），窗口只有一个帧的量级，而内核
    ///     不会为了等一个回调而暂停启动。实测改进之前 **5 次连接 5 次都错过**，
    ///     不是偶发竞态——这也解释了为什么它看起来像「安卓上一连就失败」。
    ///
    /// 上游（SFA 的 `DefaultNetworkMonitor`）同样是在这里直接回调、不切线程；它甚至
    /// 会在拿不到地址时重试若干次，理由一样：这一步必须在内核提问之前完成。
    ///
    /// [retries] 只给启动那条路：内核只等这一次机会，而网络刚切换时
    /// `LinkProperties` 可能还没就绪。回调路径不重试——它有下一次回调兜底。
    private fun reportDefaultInterface(
        manager: ConnectivityManager,
        listener: InterfaceUpdateListener,
        retries: Int = 0,
    ) {
        for (attempt in 0..retries) {
            if (attempt > 0) {
                // 等网络就绪；上限 10×100ms，与上游取同一个量级。
                try {
                    Thread.sleep(100)
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return
                }
            }
            try {
                val network = pickDefaultNetwork(manager)
                if (network == null) {
                    // 系统此刻一张物理网卡都没有（飞行模式等）。如实上报「没有默认
                    // 接口」——空名字 + -1 是内核认的那一种（上游同样这么发）。
                    // 留着上一条已消失的网卡名，只会让内核去绑一张不存在的网卡。
                    if (lastDefaultInterface != null || retries > 0) {
                        diagPlatform("没有可用的物理网卡，上报空默认接口")
                        lastDefaultInterface = null
                        listener.updateDefaultInterface("", -1, false, false)
                    }
                    return
                }
                val linkProperties = manager.getLinkProperties(network) ?: continue
                val name = linkProperties.interfaceName ?: continue
                val index = networkInterfaceIndex(name)
                if (index <= 0) continue
                val caps = manager.getNetworkCapabilities(network)
                val expensive = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
                // constrained 对应「受限网络」（如强制门户），不是「是不是 VPN」。
                val constrained = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED) == false
                if (name == lastDefaultInterface) {
                    // 同一条网卡重复上报没有意义，也没必要记诊断——回调很密集。
                    listener.updateDefaultInterface(name, index, expensive, constrained)
                    return
                }
                diagPlatform("上报默认接口 $name index=$index")
                lastDefaultInterface = name
                listener.updateDefaultInterface(name, index, expensive, constrained)
                return
            } catch (e: Throwable) {
                Log.w(TAG, "上报默认接口失败", e)
                return
            }
        }
    }

    /// 网卡的**内核 ifindex**。
    ///
    /// 两条路都留着，是因为 `java.net` 这条不可靠：Android 11 起收紧了接口枚举，
    /// 部分 ROM 上 `NetworkInterface` 的枚举会返回空（Lantern 等下游项目为此专门
    /// 加过兜底）。而这里的调用方**按 index 过滤网卡**——取不到 index 就等于把
    /// 这张网卡丢掉，于是列表为空，内核起手的每一次直连都报
    /// `Get "http://127.0.0.1:xxxxx/…": no available network interface`。
    ///
    /// 后果不是「直连站点打不开」那么轻：规则集投递（热更新）属于内核启动流程，
    /// 它一失败内核整个起不来，用户看到的是「一连就失败」，而界面上只有那句
    /// 读不懂的原话。
    ///
    /// [Os.if_nametoindex] 是安全的退路：它就是一次 `ioctl(SIOCGIFINDEX)`，不做
    /// 枚举、不受上面那条收紧影响，返回的也是同一个内核 ifindex——两条路的结果
    /// 可以互换。
    private fun networkInterfaceIndex(name: String): Int {
        try {
            val index = java.net.NetworkInterface.getByName(name)?.index ?: -1
            if (index > 0) return index
        } catch (e: Throwable) {
            // 受限 ROM：不在这里放弃，继续走下面那条不依赖枚举的路。
        }
        val index = try {
            Os.if_nametoindex(name)
        } catch (e: Throwable) {
            -1
        }
        if (index <= 0) {
            warnInterfaceEnumeration("拿不到网卡 $name 的 ifindex")
        } else {
            diagPlatform("java.net 给不出 $name 的 ifindex，已用 Os.if_nametoindex 兜底")
        }
        return index
    }

    /// 接口枚举受限的诊断。只记一次。
    ///
    /// 这件事曾经**完全不可见**：内核只报一句 `no available network interface`，
    /// 既没说是哪张网卡、也没说为什么，排查只能靠猜。现在它会落在 diag.log 里。
    private fun warnInterfaceEnumeration(detail: String) {
        if (interfaceDiagDone) return
        interfaceDiagDone = true
        diag(
            "网卡枚举受限（$detail）：java.net 与 Os.if_nametoindex 都没给出结果。" +
                "内核会因此拿不到出口网卡，直连出站报 no available network interface",
        )
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        stopDefaultInterfaceMonitor()
    }

    private fun stopDefaultInterfaceMonitor() {
        lastDefaultInterface = null
        val callback = defaultNetworkCallback ?: return
        defaultNetworkCallback = null
        try {
            (getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)
                ?.unregisterNetworkCallback(callback)
        } catch (e: Throwable) {
            Log.w(TAG, "注销默认网络回调失败", e)
        }
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val list = ArrayList<NetworkInterface>()
        val seen = HashSet<Int>()
        try {
            val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            if (manager != null) {
                // 默认网络排在最前，内核按 index 找默认出口时优先命中。
                val ordered = ArrayList<Network>()
                manager.activeNetwork?.let { ordered.add(it) }
                manager.allNetworks.forEach { network -> if (!ordered.contains(network)) ordered.add(network) }
                for (network in ordered) {
                    val capabilities = manager.getNetworkCapabilities(network)
                    // 跳过 VPN 网络（包括我们自己的 tun0）：内核要的是物理出口。
                    if (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) == false) continue
                    val props = manager.getLinkProperties(network) ?: continue
                    val name = props.interfaceName ?: continue
                    val index = networkInterfaceIndex(name)
                    if (index <= 0 || !seen.add(index)) continue

                    val item = NetworkInterface()
                    item.name = name
                    item.index = index
                    item.mtu = if (props.mtu > 0) props.mtu else 1500
                    item.addresses = stringIterator(formatAddresses(props))
                    item.dnsServer = stringIterator(
                        props.dnsServers.mapNotNull { it.hostAddress?.substringBefore('%') },
                    )
                    item.gateway = stringIterator(
                        props.routes.mapNotNull { route -> route.gateway?.hostAddress?.substringBefore('%') },
                    )
                    item.flags = interfaceFlags(name)
                    item.type = interfaceType(capabilities)
                    item.metered =
                        capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
                    list.add(item)
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "枚举网络接口失败", e)
        }
        // 空列表必然意味着内核的直连出站不可用（见 [networkInterfaceIndex]）。
        // 它是**静默**的：内核只会丢一句 no available network interface，界面上
        // 只剩「连接失败」。在这里记一笔，下一次排查不用再从内核日志倒推。
        diagPlatform("内核请求网卡列表，返回 ${list.size} 张：${list.joinToString(",") { it.name }}")
        if (list.isEmpty()) {
            warnInterfaceEnumeration("网卡列表为空")
        }
        return networkInterfaceIterator(list)
    }

    /**
     * 内核用 netip.MustParsePrefix 解析这里的每一项，非法值会让整个进程段错误崩溃
     * （不是抛异常）。因此必须输出「地址/前缀长度」，并且去掉 IPv6 的 %scope
     * ——前缀语法里不允许 zone。
     */
    private fun formatAddresses(props: LinkProperties): List<String> =
        props.linkAddresses.mapNotNull { link ->
            val host = link.address?.hostAddress?.substringBefore('%')
            if (host.isNullOrEmpty()) return@mapNotNull null
            val prefix = if (link.prefixLength >= 0) link.prefixLength else if (host.contains(':')) 64 else 32
            "$host/$prefix"
        }

    /**
     * 与 Go 的 net.Flags 对齐：up=1 running=2 loopback=4 pointToPoint=8 multicast=16。
     * 内核只保留带 FlagUp 的网卡，少这一位会导致整个网卡列表被清空。
     */
    private fun interfaceFlags(name: String): Int {
        val nif = try {
            java.net.NetworkInterface.getByName(name)
        } catch (e: Throwable) {
            null
        } ?: return FLAG_UP or FLAG_RUNNING
        var flags = 0
        try {
            if (nif.isUp) flags = flags or FLAG_UP or FLAG_RUNNING
            if (nif.isLoopback) flags = flags or FLAG_LOOPBACK
            if (nif.isPointToPoint) flags = flags or FLAG_POINT_TO_POINT
            if (nif.supportsMulticast()) flags = flags or FLAG_MULTICAST
        } catch (e: Throwable) {
            // 权限受限时读不到明细，按「已启用」处理即可。
        }
        return flags
    }

    /** 与 sing-box constant.InterfaceType 对齐：wifi=0 cellular=1 ethernet=2 other=3。 */
    private fun interfaceType(capabilities: NetworkCapabilities?): Int = when {
        capabilities == null -> 3
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 0
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 1
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 2
        else -> 3
    }

    // ------------------------------------------------------------ 其余平台能力

    override fun clearDNSCache() {
        // 安卓的 DNS 缓存由系统管理，内核会自行处理缓存失效。
    }

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun readWIFIState(): WIFIState? = null

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    // ---- 能力开关：告诉内核本平台提供了哪些平台能力 ----

    /** 我们实现了 autoDetectInterfaceControl（用 VpnService.protect）。 */
    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    /** Bridge（把 TUN 流量转给另一个进程）用不到。 */
    override fun usePlatformBridge(): Boolean = false

    /** 不支持 SSH 会话。 */
    override fun usePlatformShell(): Boolean = false

    /** 安卓对 /proc 的访问受限，不依赖它去找连接归属进程。 */
    override fun useProcFS(): Boolean = false

    override fun checkPlatformShell() {
        throw UnsupportedOperationException("本应用不支持 SSH 会话")
    }

    // 同上：内核包装层会直接解引用返回值，查不到时必须抛异常而不是返回 null。
    override fun lookupUser(username: String): PlatformUser =
        throw UnsupportedOperationException("本应用不使用系统账户")

    override fun lookupSFTPServer(): String? = null

    override fun readSystemSSHHostKey(): String? = null

    override fun tailscaleHostname(): String? = null

    /**
     * 解析某条连接属于哪个应用。
     *
     * 两点必须注意：
     *   1. 内核的包装层会无条件解引用本函数的返回值，返回 null 会让整个进程段错误
     *      崩溃；查不到时必须抛异常，内核会把异常当成「查不到」并继续跑。
     *   2. 内核对每一条新连接都会调用本函数（prepareMatchMetadata → searchProcessInfo），
     *      因此这是热路径，失败要尽早返回。
     */
    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        val protocol = when (ipProtocol) {
            6 -> 6 // IPPROTO_TCP
            17 -> 17 // IPPROTO_UDP
            else -> throw IllegalArgumentException("不支持的协议: $ipProtocol")
        }
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: throw IllegalStateException("ConnectivityManager 不可用")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw IllegalStateException("系统版本过低，无法解析连接归属")
        }
        // getConnectionOwnerUid 要求 java.net.InetSocketAddress，且不接受 IPv6 的 %scope。
        val local = InetSocketAddress(InetAddress.getByName(sourceAddress.substringBefore('%')), sourcePort)
        val remote = InetSocketAddress(InetAddress.getByName(destinationAddress.substringBefore('%')), destinationPort)
        val uid = manager.getConnectionOwnerUid(protocol, local, remote)
        if (uid < 0) {
            throw IllegalStateException("无法解析连接归属")
        }

        val owner = ConnectionOwner()
        owner.userId = uid
        val packages = try {
            packageManager.getPackagesForUid(uid)
        } catch (e: Throwable) {
            null
        }
        if (packages.isNullOrEmpty()) {
            owner.userName = uid.toString()
        } else {
            owner.userName = packages[0]
            // 注意：libbox 这里的方法名是 setAndroidPackageNames，不是标准 setter 命名，
            // Kotlin 不会合成属性，必须直接调用方法。
            owner.setAndroidPackageNames(stringIterator(packages.toList()))
        }
        return owner
    }

    override fun createBridge(options: BridgeOptions): BridgeSession? = null

    override fun openShellSession(
        user: PlatformUser?,
        command: String,
        args: StringIterator?,
        env: String?,
        rows: Int,
        cols: Int,
    ): ShellSession? = null

    override fun registerMyInterface(name: String) {
        // 安卓无需把 TUN 接口注册给系统。
    }

    override fun startNeighborMonitor(listener: NeighborUpdateListener) {
        // 邻居表用于局域网设备发现，本应用不需要。
    }

    override fun closeNeighborMonitor(listener: NeighborUpdateListener) {
    }

    override fun sendNotification(notification: LibboxNotification) {
    }

    override fun cancelNotification(name: String, id: Int) {
    }

    // ------------------------------------------------------------ 通知

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "VPN 连接",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持隧道在后台运行"
            setShowBadge(false)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)
            ?.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            // 通知标题。常驻通知是用户在系统里唯一能看到「隧道还开着」的地方，
            // 用产品名而不是仓库名。
            .setContentTitle("幽门运行中")
            .setContentText("智能分流已启用：命中规则集的流量直连，其余走隧道")
            .setSmallIcon(R.drawable.ic_stat_xvpn)
            .setOngoing(true)
            .build()
    }

    // ------------------------------------------------------------ 迭代器适配

    /** libbox 的 StringIterator 接口实现。 */
    private fun stringIterator(values: List<String>): StringIterator {
        val iterator = values.iterator()
        return object : StringIterator {
            override fun hasNext(): Boolean = iterator.hasNext()
            override fun next(): String = iterator.next()
            override fun len(): Int = values.size
        }
    }

    private fun networkInterfaceIterator(values: List<NetworkInterface>): NetworkInterfaceIterator {
        val iterator = values.iterator()
        return object : NetworkInterfaceIterator {
            override fun hasNext(): Boolean = iterator.hasNext()
            override fun next(): NetworkInterface = iterator.next()
        }
    }

    /** 命令服务回调。绝大多数能力本应用用不到，给最小实现即可。 */
    private inner class Handler : CommandServerHandler {
        override fun serviceReload() = Unit

        override fun serviceStop() {
            Thread { stopBox() }.start()
        }

        override fun setSystemProxyEnabled(enabled: Boolean) {
            // 安卓走 TUN，不使用系统代理。
        }

        override fun getSystemProxyStatus(): SystemProxyStatus =
            SystemProxyStatus().apply { available = false }

        override fun connectSSHAgent(): Int = 0

        override fun writeDebugMessage(message: String) {
            Log.d(TAG, message)
            // **必须** post 到主线程再转发给 Dart。
            //
            // 这个方法由内核的 Go 线程调用，而 `onLog` 最终会走到 Flutter 的
            // MethodChannel——Flutter 要求通道调用必须在平台主线程。直接在原生
            // 线程里调它会触发 ART 的 JNI 校验失败并 `abort()`：
            //
            //   JNI called with thread not attached to the JVM
            //     at XvpnVpnService$Handler.writeDebugMessage(...)
            //     at MethodChannel.invokeMethod
            //
            // 后果是整个进程原生崩溃（不是抛异常，没有 Java 栈），而且因为它只在
            // DEBUG 级日志上触发，此前一直藏得很深：**一开内核调试日志应用就崩，
            // 而且因此永远拿不到安卓端的内核日志**——「手机上连不上」查不下去
            // 正是卡在这里。
            val handler = mainHandler
            handler.post { onLog?.invoke(message) }
        }

        override fun triggerNativeCrash() {
            throw RuntimeException("内核请求触发崩溃（用于诊断）")
        }
    }
}
