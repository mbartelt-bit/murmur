import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.devtools.ksp")
}

/**
 * The upload keystore, when this machine has one: `android/keystore.properties` (gitignored,
 * see `keystore.properties.example`).
 *
 * A fresh clone and CI have no keystore and must still be able to build the bundle, so a
 * missing file is not an error — `bundleRelease` just produces an *unsigned* .aab, which is
 * fine for size checks and R8 verification and useless to Play. The warning below says so.
 */
val keystoreProps: Properties? = rootProject.file("keystore.properties")
    .takeIf { it.isFile }
    ?.let { file -> Properties().apply { file.inputStream().use(::load) } }

android {
    namespace = "com.murmur.app"
    compileSdk = 35

    // Lets AGP find llvm-strip, so the 60 MB unstripped release .so shrinks in the APK.
    ndkVersion = "27.2.12479018"

    defaultConfig {
        applicationId = "com.murmur.app"
        minSdk = 28
        targetSdk = 35
        // Every Play upload needs a strictly higher code; scripts/android-play-upload.sh sets
        // this to the current UTC minute (yyMMddHHmm). 1 is only ever a local build.
        versionCode = (System.getenv("MURMUR_VERSION_CODE") ?: "1").toInt()
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            // Only the ABIs scripts/build-core-mobile.sh produces libmurmur_core.so for.
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    signingConfigs {
        create("release") {
            // Left empty when this machine has no keystore.properties; the release build type
            // then signs with nothing rather than failing.
            keystoreProps?.let { props ->
                // Relative paths resolve against `android/`, absolute ones are taken as-is,
                // so the keystore can live outside the repo (it must).
                storeFile = rootProject.file(props.getProperty("storeFile"))
                storePassword = props.getProperty("storePassword")
                keyAlias = props.getProperty("keyAlias")
                keyPassword = props.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystoreProps != null) signingConfigs.getByName("release") else null
            // R8 keeps the UniFFI binding, JNA, Room and the input method — see proguard-rules.pro.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
        // The About row reads BuildConfig.VERSION_NAME, and the debug-only screenshot
        // launcher reads BuildConfig.DEBUG.
        buildConfig = true
    }

    testOptions {
        // Robolectric needs the merged resources/manifest to boot an Android runtime
        // for the DataStore, EncryptedSharedPreferences and Room tests.
        unitTests.isIncludeAndroidResources = true
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
    // The keyboard's bottom row draws the globe, backspace and return glyphs every other
    // keyboard uses; words in their place read as buttons for something else.
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    // The input method has no activity, so it installs the three view-tree owners Compose
    // needs by hand (see ime/ComposeInputView.kt) — these two carry the setters.
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7")
    implementation("androidx.savedstate:savedstate-ktx:1.2.1")
    implementation("androidx.navigation:navigation-compose:2.8.5")

    // Settings (never secrets) live in DataStore Preferences.
    implementation("androidx.datastore:datastore-preferences:1.1.1")
    // API keys live here and nowhere else (design spec section 10).
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // History is Room; the IME reads the same database from the same process.
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")

    // UniFFI's generated Kotlin binding talks to libmurmur_core.so through JNA.
    implementation("net.java.dev.jna:jna:5.15.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.test:core:1.6.1")
    testImplementation("androidx.room:room-testing:2.6.1")
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

// Say it out loud rather than handing someone an .aab Play will reject at upload.
if (keystoreProps == null) {
    tasks.matching { it.name == "bundleRelease" || it.name == "assembleRelease" }
        .configureEach {
            doFirst {
                logger.warn(
                    "warning: android/keystore.properties not found — this release build is " +
                        "UNSIGNED and cannot be uploaded to Play. Copy " +
                        "android/keystore.properties.example and fill it in to sign it.",
                )
            }
        }
}
