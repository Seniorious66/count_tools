import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}
val signingPath = System.getenv("COUNT_TOOLS_SIGNING_PROPERTIES")
val signing = Properties()
if (signingPath != null) file(signingPath).inputStream().use { signing.load(it) }
android {
    namespace = "com.seniorious66.counttools"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "com.seniorious66.counttools"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    signingConfigs {
        if (signingPath != null) create("personal") {
            storeFile = file(requireNotNull(signing.getProperty("storeFile")))
            storePassword = requireNotNull(signing.getProperty("storePassword"))
            keyAlias = requireNotNull(signing.getProperty("keyAlias"))
            keyPassword = requireNotNull(signing.getProperty("keyPassword"))
        }
    }
    buildTypes { release { if (signingPath != null) signingConfig = signingConfigs.getByName("personal") } }
}
gradle.taskGraph.whenReady {
    if (allTasks.any { it.name.contains("Release") } && signingPath == null) {
        throw GradleException("Personal release requires external signing configuration")
    }
}
kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
flutter { source = "../.." }
