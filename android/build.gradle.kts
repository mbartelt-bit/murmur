// Root build script: declare the plugin versions once, apply them in :app.
plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.0" apply false
    // Room's annotation processor runs through KSP; the version tracks Kotlin 2.1.0.
    id("com.google.devtools.ksp") version "2.1.0-1.0.29" apply false
}
