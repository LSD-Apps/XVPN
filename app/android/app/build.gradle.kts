import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------- 发行签名
//
// 发行包必须用**固定**的密钥签名，否则自动更新装不上：
// debug 密钥是在每台构建机上现生成的，不同机器（包括不同 CI runner）产出的
// APK 签名不同，Android 只允许「签名一致」的包覆盖安装。签名不一致时用户
// 必须卸载旧版，而卸载会连配置、账号密码、学到的分流规则一起删掉。
//
// 密钥不在仓库里，两处来源任取其一（CI 与本机各用其一）：
//   * CI：GitHub Secrets → 四个环境变量
//       ANDROID_KEYSTORE_FILE / ANDROID_KEYSTORE_PASSWORD /
//       ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD
//     （见 .github/workflows/release.yml 的「还原 Android 发行签名密钥」）
//   * 本机：app/android/key.properties（已 gitignore，Flutter 官方约定），
//     键名 storeFile / storePassword / keyAlias / keyPassword，
//     storeFile 相对 app/android/ 解析。
//
// **release 绝不回退到 debug 密钥**：缺签名材料时由文件末尾的 taskGraph 检查
// 让 release 构建**直接失败**并打印中文指引。debug 构建不受影响（`flutter run` 照常）。
// 原因：用 debug 密钥签出的「正式版」无法覆盖安装由发行密钥签名的版本，
// 用户必须卸载重装，而卸载会清掉配置与凭据——比构建失败严重得多。
val releaseKeystoreProperties = Properties()
val releaseKeystorePropertiesFile = rootProject.file("key.properties")
if (releaseKeystorePropertiesFile.isFile) {
    releaseKeystorePropertiesFile.inputStream().use { releaseKeystoreProperties.load(it) }
}

fun releaseSigningValue(envName: String, propertyName: String): String? =
    System.getenv(envName)?.takeIf { it.isNotBlank() }
        ?: releaseKeystoreProperties.getProperty(propertyName)?.takeIf { it.isNotBlank() }

val releaseStoreFilePath: String? = releaseSigningValue("ANDROID_KEYSTORE_FILE", "storeFile")
val releaseStoreFile: java.io.File? =
    releaseStoreFilePath?.let { path -> rootProject.file(path).takeIf { it.isFile } }
val releaseKeystorePassword: String? =
    releaseSigningValue("ANDROID_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias: String? = releaseSigningValue("ANDROID_KEY_ALIAS", "keyAlias")
val releaseKeyPassword: String? = releaseSigningValue("ANDROID_KEY_PASSWORD", "keyPassword")

val hasReleaseSigning: Boolean =
    releaseStoreFile != null &&
        !releaseKeystorePassword.isNullOrBlank() &&
        !releaseKeyAlias.isNullOrBlank() &&
        !releaseKeyPassword.isNullOrBlank()

android {
    namespace = "net.lusida.xvpnclient"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 公开身份（包名）：net.lusida.xvpnclient。debug 构建追加 .dev 后缀，
        // 使开发版与正式版**并存**（见下方 debug 块的说明）。
        //
        // 包名一旦在应用商店上架就不可更改（Play Console 接受首个安装包后锁死），
        // 因此它与 namespace 必须一致地改，避免出现「代码在一个包、对外是另一个包」
        // 的长期错位。
        applicationId = "net.lusida.xvpnclient"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // 只有四个值齐全且密钥文件确实存在时才创建发行签名配置。
        if (hasReleaseSigning) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // 配了发行密钥就用它。缺材料时不设签名配置，由文件末尾的
            // taskGraph 检查让 release 构建**直接失败**——不回退 debug。
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        debug {
            // 开发版换个包名，**与正式安装并存**。
            //
            // 不这样做的话，装一个开发版就会覆盖用户手机上已经装好的正式版：
            // 两者签名不同（正式版用发行者的密钥，开发版用本机 debug 密钥），
            // Android 只允许「先卸载再安装」，而卸载会连配置、账号密码、
            // 学到分流规则一起删掉——这些数据在 Android 11+ 上也没法完整备份。
            //
            // 加个后缀之后，`flutter run` / `flutter install` 装的是另一个应用，
            // 手机上的正式版与它的数据都不受影响。
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // sing-box 内核（libbox）。由 scripts/build-libbox.ps1 用 gomobile 把
    // sing-box 源码编译成 AAR 产出。
    //
    // 为什么安卓端不能像 Windows 那样直接跑 sing-box.exe：
    //   * Android 10 起不允许执行应用数据目录下的可执行文件；
    //   * VpnService 的 TUN 必须在应用进程内创建，外部进程拿不到那个 fd。
    // 因此安卓端把内核作为库嵌入，由 VpnService 提供 TUN。
    implementation(files("libs/libbox.aar"))
}

// ---------------------------------------------------------------- 发行签名守卫
//
// 缺签名材料时让 release 构建**直接失败**，而不是悄悄用 debug 密钥签名。
// 用 debug 密钥签出的「正式版」无法覆盖安装由发行密钥签名的版本，用户必须
// 卸载重装，而卸载会清掉配置与凭据——比构建失败严重得多。
//
// 检查必须放在 task graph 回调里，不能写进 buildTypes：Gradle 配置阶段会读取
// 所有 buildType，写在那里会让 debug 构建也一起失败。这里只在本次真的要执行
// 本模块的 Release 任务时才拦截。
val xvpnAppProject = project
gradle.taskGraph.whenReady {
    val buildingRelease = allTasks.any { task ->
        task.project == xvpnAppProject && task.name.contains("Release", ignoreCase = true)
    }
    if (buildingRelease && !hasReleaseSigning) {
        throw GradleException(
            """
            发行(Release)构建缺少签名配置，已中止——release 不再回退到 debug 密钥。

            本机构建：创建 app/android/key.properties（已 gitignore），内容为
              storeFile=keystore/xvpn-release.jks
              storePassword=<密码>
              keyAlias=<别名>
              keyPassword=<密码>

            CI 构建：配置四个 GitHub Secrets，工作流会导出为环境变量
              ANDROID_KEYSTORE_FILE / ANDROID_KEYSTORE_PASSWORD /
              ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD

            生成密钥库的命令见 docs/RELEASE.md。
            """.trimIndent(),
        )
    }
}
