import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// release 署名の鍵の情報。android/key.properties に置く（Git には入れない）。
// 無ければ debug の鍵で署名する（チームの誰でもビルドはできるように）。
// debug の鍵は PC ごとに違うので、配布する版は必ず key.properties のある PC で作ること。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.raim_prototype"
    compileSdk = flutter.compileSdkVersion
    // ローカル検証環境に導入済みの NDK に合わせます。
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications（駅アラームの通知）が使う
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // 配布するアプリの ID。一度配ったら変えない（変えると別のアプリ扱いになり、
        // 上書きインストールできなくなる）。
        // namespace（コードのパッケージ名）は MainActivity の場所と合わせるため据え置き。
        applicationId = "com.ando.raim"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 25
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // Unity 側と同じく、Android 実機検証では arm64 のみをパッケージします。
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // key.properties があれば配布用の鍵で署名する。
            // 以前は常に debug の鍵で、PC ごとに鍵が違うため、別の PC で作った版を
            // 上書きインストールできなかった。
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    implementation(project(":unityLibrary"))
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
