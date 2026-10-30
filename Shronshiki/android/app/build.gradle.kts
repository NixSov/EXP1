plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "ru.shronshiki.shronshiki"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "ru.shronshiki.shronshiki"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Ключ выпусков на GitHub: CI кладёт его во временный файл и передаёт путь в
    // SHRONSHIKI_KEYSTORE. Локальные сборки подписываются debug-ключом.
    val releaseStore = System.getenv("SHRONSHIKI_KEYSTORE")
    signingConfigs {
        if (!releaseStore.isNullOrEmpty()) {
            create("shronshiki") {
                storeFile = file(releaseStore)
                storePassword = System.getenv("SHRONSHIKI_STORE_PASSWORD") ?: "android"
                keyAlias = System.getenv("SHRONSHIKI_KEY_ALIAS") ?: "androiddebugkey"
                keyPassword = System.getenv("SHRONSHIKI_STORE_PASSWORD") ?: "android"
            }
        }
    }

    buildTypes {
        release {
            // APK ставится напрямую на телефон, а не через магазин.
            signingConfig = signingConfigs.findByName("shronshiki") ?: signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
