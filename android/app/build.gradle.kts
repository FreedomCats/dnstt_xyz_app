import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key: android/key.properties for local builds, or environment variables in CI.
// Without a key, release builds are signed with the debug key and cannot update an installed release.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) FileInputStream(file).use { load(it) }
}

fun signingValue(property: String, environment: String): String? =
    keystoreProperties.getProperty(property) ?: System.getenv(environment)?.takeIf { it.isNotEmpty() }

val releaseStoreFile = signingValue("storeFile", "ANDROID_KEYSTORE_FILE")

// hev-socks5-tunnel (tun2socks engine for VPN mode) is a git submodule
val hevDir = rootProject.file("../vendor/hev-socks5-tunnel")

repositories {
    flatDir {
        dirs("libs")
    }
}

android {
    namespace = "xyz.dnstt.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "xyz.dnstt.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            ndkBuild {
                // Only the JNI library; the module also defines a standalone executable
                targets += "hev-socks5-tunnel"
                // JNI_OnLoad registers the natives on xyz.dnstt.app.TProxyService. The prefix
                // map keeps the checkout path out of the library.
                cFlags += listOf(
                    "-DPKGNAME=xyz/dnstt/app",
                    "-DCLSNAME=TProxyService",
                    "-O3",
                    "-ffile-prefix-map=${rootProject.projectDir.parentFile.absolutePath}=."
                )
            }
        }
    }

    externalNativeBuild {
        // The Flutter plugin points cmake at an empty project so that AGP installs the NDK;
        // AGP allows one native build, and this one needs the NDK anyway.
        cmake {
            path = null
        }
        ndkBuild {
            path = hevDir.resolve("Android.mk")
        }
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Keep VCS metadata (repository and commit) out of the APK
            vcsInfo.include = false
            signingConfig = if (releaseStoreFile != null) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("No release signing key configured, signing the release build with the debug key")
                signingConfigs.getByName("debug")
            }
        }
    }

    testOptions {
        // Socks5AuthRelay logs through android.util.Log, which is a stub in JVM unit tests
        unitTests.isReturnDefaultValues = true
    }

    packaging {
        resources {
            excludes += listOf(
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/license.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/notice.txt"
            )
        }
    }
}

flutter {
    source = "../.."
}

// dnstt.aar is built from go_src/ by scripts/build_aar.sh and is not in git
val dnsttAar = file("libs/dnstt.aar")
tasks.named("preBuild") {
    doFirst {
        if (!dnsttAar.exists()) {
            throw GradleException("android/app/libs/dnstt.aar is missing: run scripts/build_aar.sh")
        }
        if (!hevDir.resolve("third-part/lwip/Android.mk").exists()) {
            throw GradleException(
                "vendor/hev-socks5-tunnel is missing: run git submodule update --init --recursive vendor/hev-socks5-tunnel"
            )
        }
    }
}

dependencies {
    implementation(files("libs/dnstt.aar"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // JSch for SSH tunneling (dynamic port forwarding through DNSTT)
    implementation("com.github.mwiede:jsch:0.2.18")

    testImplementation("junit:junit:4.13.2")
}
