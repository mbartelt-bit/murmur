plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.murmur.app"
    compileSdk = 35

    // Lets AGP find llvm-strip, so the 60 MB unstripped release .so shrinks in the APK.
    ndkVersion = "27.2.12479018"

    defaultConfig {
        applicationId = "com.murmur.app"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            // Only the ABIs scripts/build-core-mobile.sh produces libmurmur_core.so for.
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")

    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // UniFFI's generated Kotlin binding talks to libmurmur_core.so through JNA.
    implementation("net.java.dev.jna:jna:5.15.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    testImplementation("junit:junit:4.13.2")
}

// Rebuild the Rust core (jniLibs/*.so + the generated Kotlin binding) before every
// Android compile, so `./gradlew` is the only entry point. Requires cargo + cargo-ndk
// on PATH (`. "$HOME/.cargo/env"`).
val buildRustCore by tasks.registering(Exec::class) {
    workingDir = rootDir.parentFile
    commandLine("scripts/build-core-mobile.sh", "android")
}

tasks.named("preBuild") {
    dependsOn(buildRustCore)
}
