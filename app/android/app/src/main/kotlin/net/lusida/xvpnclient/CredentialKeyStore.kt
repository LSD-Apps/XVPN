package net.lusida.xvpnclient

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * `auth-user-pass` 账号密码的落盘保护，用的是系统 Keystore。
 *
 * 只做两件事，且各自只在 Dart 侧启动流程里调用一次：
 *   1. [generate] —— 生成一把随机的数据密钥（DEK），用 Keystore 里的**包装密钥**
 *      加密后交给 Dart 落盘，同时把明文 DEK 交给它；
 *   2. [unwrap] —— 应用下次启动时，用 Keystore 里的同一把包装密钥把 DEK 解回来。
 *
 * 为什么要绕这一层，而不是直接用 Keystore 加密账号密码：
 * AndroidKeyStore 里的密钥**不可导出**，而且只能经 Java 侧调用（通道调用必然是
 * 异步的）。Dart 侧加解密账号密码却必须是同步的——账号密码在 `AppState` 的构造
 * 里就要恢复出来（见 `secret_protector.dart` 里 `AndroidKeystoreSecretProtector`
 * 的说明）。所以真正加密数据的是那把随机的 DEK，它可以被 Dart 留在内存里；而
 * 包装密钥一辈子不出 Keystore，落盘的 DEK 因此**只在这台设备上**解得开。
 *
 * 代价写清楚：`credentials.key`（被包起来的 DEK）与 Keystore 里的包装密钥都
 * 不随云备份 / 换机迁移。从备份恢复出来或拷到另一台设备上时，[unwrap] 会失败，
 * 那批凭据只能作废重填——这与 Windows 上换了账户就解不开 DPAPI 密文是同一类
 * 特性。Dart 侧对此的处理见 `AndroidKeystoreSecretProtector.create`。
 */
object CredentialKeyStore {
    private const val TAG = "XvpnCredentialKey"
    private const val PROVIDER = "AndroidKeyStore"

    /** Keystore 里包装密钥的别名。带包名前缀，避免与同一设备上其它应用撞名。 */
    private const val ALIAS = "xvpn.credentials.wrap"

    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val KEY_SIZE_BITS = 256

    /** GCM 的标准 nonce 长度。 */
    private const val NONCE_BYTES = 12

    /** GCM 认证标签长度（位）。 */
    private const val TAG_BITS = 128

    /** 数据密钥长度：AES-256。Dart 侧会再校验一次，长度不对就当没拿到。 */
    private const val DEK_BYTES = 32

    /**
     * 生成数据密钥并返回 `{wrapped, key}`（都是 base64）。
     *
     * 失败返回 null，由 Dart 侧如实退化成「不加密」——绝不返回一个假的东西让它
     * 以为已经保护好了。
     */
    fun generate(): Map<String, String>? = try {
        val dek = ByteArray(DEK_BYTES).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.ENCRYPT_MODE, wrappingKey())
        }
        // iv 在 init 之后必然有值（GCM 要求随机 iv）；真为 null 的话下面的拼接会
        // 抛 NPE，被这里接住并退化成不加密，不会写出一个半截的密文。
        val blob = cipher.iv + cipher.doFinal(dek)
        mapOf(
            "wrapped" to Base64.encodeToString(blob, Base64.NO_WRAP),
            "key" to Base64.encodeToString(dek, Base64.NO_WRAP),
        )
    } catch (e: Throwable) {
        Log.e(TAG, "生成凭据密钥失败", e)
        null
    }

    /**
     * 用 Keystore 里的包装密钥解开数据密钥，返回 base64 明文；解不开返回 null。
     *
     * 失败**不往上抛**：这是预期内的情况（从备份恢复、换了设备），Dart 侧会按
     * 「需要重新填写账号密码」处理，而不是让应用起不来。
     */
    fun unwrap(wrapped: String): String? = try {
        val blob = Base64.decode(wrapped, Base64.NO_WRAP)
        if (blob.size <= NONCE_BYTES) {
            null
        } else {
            val iv = blob.copyOfRange(0, NONCE_BYTES)
            val sealed = blob.copyOfRange(NONCE_BYTES, blob.size)
            val cipher = Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(TAG_BITS, iv))
            }
            Base64.encodeToString(cipher.doFinal(sealed), Base64.NO_WRAP)
        }
    } catch (e: Throwable) {
        Log.w(TAG, "解开凭据密钥失败（可能来自另一台设备）", e)
        null
    }

    /**
     * 取 Keystore 里的包装密钥，没有就现生成一把。
     *
     * 两条刻意的「不设」：
     *   * 不设 `setUserAuthenticationRequired(true)`：那会要求每次使用都过一遍
     *     指纹 / 锁屏，而解凭据发生在连接流程里，用户不该为了连一次隧道去按指纹；
     *   * 不设 `setUnlockedDeviceRequired(true)`：锁屏状态下后台隧道重建同样要解
     *     凭据，加了它那条路会直接失败。
     *
     * 也就是说：这台设备上的任何进程只要能以本应用身份运行，就能解开这份密钥。
     * 它挡住的是**读到那两份文件**的人（云备份、adb 拉取、误发的日志），不是一台
     * 已经被 root、能注入本应用进程的设备——后者在任何方案下都挡不住。
     */
    private fun wrappingKey(): SecretKey {
        val keyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
        val existing = keyStore.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry
        existing?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(KEY_SIZE_BITS)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }
}
