plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// `flutter build apk --target-platform` 只决定引擎与 Dart 快照用哪个 ABI，
// **不会**过滤插件 AAR 里的原生库：实测 `--target-platform android-arm` 打出来的
// 包里 arm64-v8a / armeabi-v7a / x86_64 三份 .so 都在（104 MB，几乎是三倍）。
// 这里把同一个 project property 映射成 ABI，真正落到 packaging 的过滤器上。
//
// 没传 target-platform（普通 `flutter build apk`）时映射为空，保持「全都打」。
val requestedAbis: List<String> = (project.findProperty("target-platform") as String?)
    ?.split(",")
    ?.map { it.trim() }
    ?.filter { it.isNotEmpty() }
    ?.mapNotNull {
        when (it) {
            "android-arm" -> "armeabi-v7a"
            "android-arm64" -> "arm64-v8a"
            "android-x64" -> "x86_64"
            "android-x86" -> "x86"
            else -> null
        }
    }
    ?.distinct()
    .orEmpty()

android {
    namespace = "com.lumebox.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.lumebox.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (requestedAbis.isNotEmpty()) {
            ndk {
                abiFilters.clear()
                abiFilters.addAll(requestedAbis)
            }
        }
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
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}
