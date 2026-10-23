import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 修正: 署名設定の不足や読み取り失敗は release の検証タスクで通知し、debug の構成を妨げない。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystorePropertiesResult = runCatching {
    Properties().apply {
        if (keystorePropertiesFile.isFile) {
            FileInputStream(keystorePropertiesFile).use { load(it) }
        }
    }
}
val keystoreProperties = keystorePropertiesResult.getOrDefault(Properties())
val releaseKeystoreFile = keystoreProperties.getProperty("storeFile")
    ?.takeIf { it.isNotBlank() }
    ?.let { file(it) }

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
            // 修正: 未設定値を強制変換せず、必須項目と鍵ファイルは release 実行時だけ検証する。
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = releaseKeystoreFile
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            // 修正: 配布版は必ず release 鍵を使い、debug 鍵への自動切り替えを禁止する。
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// 修正: 同じ署名チェックを、明示的なrelease要求とreleaseタスクの両方で使う。
fun validateReleaseSigningFiles() {
    if (!keystorePropertiesFile.isFile) {
        throw GradleException(
            "release の作成には android/key.properties と配布用 keystore が必要です。" +
                "debug ビルドは鍵なしで実行できます。",
        )
    }
    if (keystorePropertiesResult.isFailure) {
        throw GradleException("android/key.properties を読み取れません。形式と読み取り権限を確認してください。")
    }
    val missing = listOf("keyAlias", "keyPassword", "storeFile", "storePassword")
        .filter { keystoreProperties.getProperty(it).isNullOrBlank() }
    if (missing.isNotEmpty()) {
        throw GradleException("android/key.properties の必須項目が未設定です: ${missing.joinToString(", ")}")
    }
    if (releaseKeystoreFile?.isFile != true) {
        throw GradleException("android/key.properties の storeFile が既存の keystore ファイルを指していません。")
    }
}

// 修正: releaseが明示された場合は構成時にも不足を知らせる。debugや一般タスクには適用しない。
val releaseArtifactRequested = gradle.startParameter.taskNames.any { requestedTask ->
    val taskName = requestedTask.substringAfterLast(':')
    taskName == "preReleaseBuild" || taskName == "validateSigningRelease" ||
        taskName == "validateReleaseSigning" ||
        (taskName.endsWith("Release", ignoreCase = true) &&
            listOf("assemble", "bundle", "package", "install").any {
                taskName.startsWith(it, ignoreCase = true)
            })
}
if (releaseArtifactRequested) {
    validateReleaseSigningFiles()
}

// 修正: 依存関係経由でreleaseが要求された場合も、ビルドと署名の前に同じ検証を行う。
val validateReleaseSigning by tasks.registering {
    group = "verification"
    description = "release 用の署名設定と keystore の存在を確認します。"
    doLast {
        validateReleaseSigningFiles()
    }
}

// 修正: debug タスクには依存を追加せず、release のビルドと署名より先に検証する。
tasks.configureEach {
    if (name == "preReleaseBuild" || name == "validateSigningRelease") {
        dependsOn(validateReleaseSigning)
    }
}

dependencies {
    implementation(project(":unityLibrary"))
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
