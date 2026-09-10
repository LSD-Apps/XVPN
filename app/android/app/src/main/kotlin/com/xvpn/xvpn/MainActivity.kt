package com.xvpn.xvpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 界面进程。
 *
 * 隧道本身跑在 [XvpnVpnService] 里（VpnService 必须由独立服务持有），
 * 这里只负责三件 Dart 做不到的事：
 *   1. **申请 VPN 授权**——`VpnService.prepare()` 只能在 Activity 里调用，
 *      而且可能弹系统对话框，必须回到 `onActivityResult` 才能拿到结果；
 *   2. **把可写目录路径告诉 Dart**——安卓的规则集打包在 APK 里，
 *      内核需要真实文件路径，要先解包到 files 目录；
 *   3. **转发内核日志**——失败归因（区分规则判错与节点不通）依赖内核日志，
 *      安卓上日志经 libbox 回调出来，不像 Windows 那样能读子进程 stderr。
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "com.xvpn.xvpn/vpn"
        private const val TAG = "XvpnMainActivity"
        private const val REQUEST_VPN_PERMISSION = 0x5650
    }

    private var channel: MethodChannel? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    /**
     * 从「分享」或「用其他应用打开」进来的配置。
     *
     * 存在这里而不是直接调用 Dart：Dart 侧可能在引擎就绪前还没注册好通道，
     * 也可能此时界面还没起来。由 Dart 主动来取，就不会丢事件。
     */
    private var pendingSharedConfig: Map<String, String>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel

        // 让服务能把内核日志推给 Dart。
        XvpnVpnService.onLog = { line -> channel?.invokeMethod("coreLog", line) }

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "prepareVpn" -> prepareVpn(result)
                "filesDir" -> result.success(filesDir.absolutePath)
                "takeSharedConfig" -> {
                    val shared = pendingSharedConfig
                    pendingSharedConfig = null
                    result.success(shared)
                }
                "connect" -> {
                    val config = call.argument<String>("config").orEmpty()
                    startService(
                        Intent(this, XvpnVpnService::class.java)
                            .setAction(XvpnVpnService.ACTION_CONNECT)
                            .putExtra(XvpnVpnService.EXTRA_CONFIG, config),
                    )
                    result.success(true)
                }
                "disconnect" -> {
                    startService(
                        Intent(this, XvpnVpnService::class.java)
                            .setAction(XvpnVpnService.ACTION_DISCONNECT),
                    )
                    result.success(true)
                }
                "status" -> result.success(
                    mapOf(
                        "running" to XvpnVpnService.isRunning,
                        "error" to XvpnVpnService.lastError,
                    ),
                )
                else -> result.notImplemented()
            }
        }

        // 冷启动时带的 Intent 也要处理，否则「用 XVPN 打开」第一次会无效。
        handleSharedIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleSharedIntent(intent)
    }

    /**
     * 解析「打开」或「分享」进来的配置文件。
     *
     * 安卓上 App 拿不到命令行参数，这是除界面导入外唯一的入口；
     * 界面上「也可以从文件管理器分享到 XVPN」的承诺就落在这里。
     */
    private fun handleSharedIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action != Intent.ACTION_VIEW && action != Intent.ACTION_SEND) return

        val uri = intent.data
            ?: @Suppress("DEPRECATION") intent.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM)
        Log.i(TAG, "收到配置分享/打开：action=$action uri=$uri")
        try {
            val text = when {
                uri != null -> readUri(uri)
                action == Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
                else -> null
            }
            if (text.isNullOrBlank()) {
                // 读到了空内容同样要留下痕迹，否则用户只看到「什么都没发生」。
                Log.w(TAG, "分享进来的配置内容为空：uri=$uri")
                XvpnVpnService.reportError("分享进来的配置是空的，或无法读取该文件")
                return
            }

            val name = uri?.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
                ?: "shared.conf"
            pendingSharedConfig = mapOf("name" to name, "text" to text)
            Log.i(TAG, "已暂存分享的配置：$name（${text.length} 字符）")
            // 通知 Dart：界面已经在运行时也能立刻响应。
            channel?.invokeMethod("sharedConfigAvailable", null)
        } catch (e: Throwable) {
            // 失败必须落日志：界面上的提示会自动消失，出问题时只能靠这里定位。
            Log.e(TAG, "读取分享的配置失败：uri=$uri", e)
            XvpnVpnService.reportError("读取分享的配置失败：${e.message}")
        }
    }

    /**
     * 读取分享进来的 URI。
     *
     * `content://` 走 ContentResolver；`file://` 直接用路径读——
     * 文件管理器与 adb 传进来的多半是后者，而 ContentResolver 对 file:// 的
     * 处理在不同版本上并不一致，直接读反而更可靠。
     */
    private fun readUri(uri: android.net.Uri): String? {
        if (uri.scheme == "file") {
            val path = uri.path ?: return null
            return File(path).takeIf { it.canRead() }?.readText()
        }
        return contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
    }

    /**
     * 申请 VPN 授权。
     *
     * 返回 true 表示已获授权；用户在系统对话框里拒绝则返回 false，
     * 界面要据此给出明确提示，而不是静默失败。
     *
     * 这里用经典的 startActivityForResult 而不是 registerForActivityResult：
     * FlutterActivity 的继承链上并不保证有后者。
     */
    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true) // 已经授权过了
            return
        }
        if (pendingPermissionResult != null) {
            result.error("busy", "上一次授权请求尚未结束", null)
            return
        }
        pendingPermissionResult = result
        try {
            startActivityForResult(intent, REQUEST_VPN_PERMISSION)
        } catch (e: Throwable) {
            pendingPermissionResult = null
            result.error("launch_failed", e.message, null)
        }
    }

    @Deprecated("FlutterActivity 只保证提供旧版结果回调")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_VPN_PERMISSION) {
            val result = pendingPermissionResult
            pendingPermissionResult = null
            result?.success(resultCode == Activity.RESULT_OK)
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }
}
