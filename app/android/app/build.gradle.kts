plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.xvpn.xvpn"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.xvpn.xvpn"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
