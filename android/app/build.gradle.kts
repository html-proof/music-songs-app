import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

tasks.whenTaskAdded {
    if (name.contains("AppLinkSettings")) {
        try {
            val getManifestFileMethod = this.javaClass.getMethod("getManifestFile")
            val manifestFileProperty = getManifestFileMethod.invoke(this) as org.gradle.api.file.RegularFileProperty
            manifestFileProperty.set(file("src/main/AndroidManifest.xml"))
        } catch (e: Exception) {
            // ignore
        }
    }
}

android {
    namespace = "com.musichub.musichubapp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    val keyProperties = Properties()
    val keyPropertiesFile = rootProject.file("key.properties")
    val hasReleaseKeyProperties = keyPropertiesFile.exists()
    if (hasReleaseKeyProperties) {
        keyProperties.load(keyPropertiesFile.inputStream())
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.musichub.musichubapp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeyProperties) {
            create("release") {
                val storeFilePath = keyProperties["storeFile"] as String?
                if (!storeFilePath.isNullOrBlank()) {
                    storeFile = file(storeFilePath)
                }
                storePassword = keyProperties["storePassword"] as String?
                keyAlias = keyProperties["keyAlias"] as String?
                keyPassword = keyProperties["keyPassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            // Use real release signing when key.properties exists.
            // Fallback to debug signing for local install/testing builds.
            signingConfig = if (hasReleaseKeyProperties) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
