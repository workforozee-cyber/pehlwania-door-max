import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.pehlwania.pehlwania_pos"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        // Registered in Google Cloud (Android OAuth client) together with the signing SHA-1.
        applicationId = "com.pehlwania.doormax"
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
    }

    // Release signing: from environment variables (CI secrets) or android/key.properties
    // (local builds). Neither the keystore nor its password is ever committed.
    val keyProps = Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    val storeFilePath = System.getenv("ANDROID_KEYSTORE_PATH") ?: keyProps.getProperty("storeFile")
    val hasReleaseKey = !storeFilePath.isNullOrBlank() && file(storeFilePath).exists()

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(storeFilePath!!)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: keyProps.getProperty("storePassword")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: keyProps.getProperty("keyAlias") ?: "pehlwania"
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: System.getenv("ANDROID_KEYSTORE_PASSWORD")
                    ?: keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Without the release key the "release" APK is signed with the debug key and
            // must be labelled as a DEBUG-SIGNED test build (CI does this).
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
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
    // Google Identity Services: OAuth authorization for Google Sheets / Drive
    implementation("com.google.android.gms:play-services-auth:21.2.0")
    // FileProvider / ContextCompat (Gallery save + WhatsApp share)
    implementation("androidx.core:core-ktx:1.13.1")
}
