package net.lusida.xvpnclient

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
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
                // 自动更新：Dart 侧已下载并校验过 SHA-256，这里只负责把它
                // 交给系统安装器。真正的安装动作由系统界面完成，应用无法静默安装。
                "installApk" -> installApk(call.argument<String>("path").orEmpty(), result)
                // 账号密码的密钥：见 [CredentialKeyStore]。只做「取回 / 生成」
                // 这一件事，加解密在 Dart 侧同步完成（那里解释了为什么）。
                "generateCredentialKey" -> result.success(CredentialKeyStore.generate())
                "unwrapCredentialKey" -> {
                    val wrapped = call.argument<String>("wrapped").orEmpty()
                    if (wrapped.isEmpty()) {
                        result.error("bad_argument", "缺少要解开的凭据密钥", null)
                    } else {
                        result.success(CredentialKeyStore.unwrap(wrapped))
                    }
                }
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

    /**
     * 把已下载并校验过的 APK 交给系统安装器。
     *
     * Dart 侧不直接把文件路径丢进 Intent：从 Android 7 (N) 起，跨进程传递
     * `file://` URI 会抛 FileUriExposedException，必须经 FileProvider 换成
     * `content://` 并显式授予一次读取权限（见 AndroidManifest 里的 provider
     * 与 res/xml/file_paths.xml）。
     *
     * 返回的 status：
     *   * `launched`            —— 已拉起系统安装界面（用户仍需在那里确认）；
     *   * `permission_required` —— 本应用还没有「安装未知应用」的权限，已把
     *                              用户送到系统设置页，授权后返回重试即可。
     */
    private fun installApk(path: String, result: MethodChannel.Result) {
        if (path.isBlank()) {
            result.error("bad_argument", "缺少 APK 路径", null)
            return
        }
        // Android 8.0 起「安装未知应用」是按应用授予的，checkSelfPermission
        // 那套对特殊权限不适用，必须用 canRequestPackageInstalls() 判断。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                result.success(mapOf("status" to "permission_required"))
            } catch (e: Throwable) {
                // 有些精简系统没有这个设置页：如实报错，让 Dart 侧提示手动安装，
                // 而不是让用户对着一个点了没反应的按钮。
                Log.e(TAG, "打开「安装未知应用」设置页失败", e)
                result.error("settings_unavailable", e.message, null)
            }
            return
        }

        val file = File(path)
        if (!file.isFile) {
            result.error("missing_apk", "APK 不存在：$path", null)
            return
        }
        try {
            // authority 必须与 AndroidManifest 里的 ${applicationId}.fileprovider
            // 一致；packageName 在 debug 构建里带 .dev 后缀，两边同样成立。
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(mapOf("status" to "launched"))
        } catch (e: Throwable) {
            Log.e(TAG, "启动系统安装器失败：$path", e)
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
