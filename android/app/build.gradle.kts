import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("keystore.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

fun releaseProperty(name: String): String? =
    keystoreProperties.getProperty(name) ?: System.getenv(name)

val releaseStoreFile = releaseProperty("RELEASE_STORE_FILE")
val releaseStorePassword = releaseProperty("RELEASE_STORE_PASSWORD")
val releaseKeyAlias = releaseProperty("RELEASE_KEY_ALIAS") ?: "easyread"
val releaseKeyPassword = releaseProperty("RELEASE_KEY_PASSWORD") ?: releaseStorePassword

android {
    namespace = "com.easyread.easy_read"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (releaseStoreFile != null && releaseStorePassword != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.easyread.easy_read"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Release 签名必须通过 keystore.properties 或 RELEASE_* 环境变量提供，
            // 不再回退到 debug key；未配置时生成 unsigned APK。
            if (releaseStoreFile != null && releaseStorePassword != null) {
                signingConfig = signingConfigs.getByName("release")
            }
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
