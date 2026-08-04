pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            val reader = java.io.InputStreamReader(
                file("local.properties").inputStream(),
                java.nio.charset.StandardCharsets.UTF_8,
            )
            reader.use { properties.load(it) }
            val sdkPath = properties.getProperty("flutter.sdk")
            require(sdkPath != null) { "flutter.sdk not set in local.properties" }
            sdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
