import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// release 署名の鍵の情報。android/key.properties に置く（Git には入れない）。
// 無いときは release のビルドを止める（X-08）。
// 以前は黙って debug の鍵で署名していたので、鍵の無い PC で作った版を配ってしまうと、
// 鍵が違うため上書きインストールできなかった。
// 試しに release で動かしたいだけなら、環境変数 RAIM_ALLOW_DEBUG_SIGNING=true を付けると
// これまでどおり debug の鍵で作れる（配布には使わないこと）。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val allowDebugSigning =
    (System.getenv("RAIM_ALLOW_DEBUG_SIGNING") ?: "").equals("true", ignoreCase = true)

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

// release を作ろうとしたときだけ確かめる（debug のビルドは今までどおり）
gradle.taskGraph.whenReady {
    val releasing = allTasks.any {
        it.path == ":app:assembleRelease" || it.path == ":app:bundleRelease"
    }
    if (releasing && !keystorePropertiesFile.exists() && !allowDebugSigning) {
        throw GradleException(
            "android/key.properties が無いので release を作れません。" +
                "配布する版は鍵のある PC で作ってください。" +
                "試しに動かすだけなら環境変数 RAIM_ALLOW_DEBUG_SIGNING=true を付けると debug の鍵で作れます。"
        )
    }
}

dependencies {
    implementation(project(":unityLibrary"))
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
