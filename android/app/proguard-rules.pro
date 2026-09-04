# R8 rules for the release build.
#
# Almost nothing here is about size — it is about the two places R8 cannot see: JNA's
# reflection into the Rust core, and the components Android instantiates by name.

# ── The Rust core, through JNA ────────────────────────────────────────────────
# UniFFI's generated Kotlin binding declares JNA Structure/Callback subclasses whose fields
# are read reflectively by name and whose interface methods are called from native code, so
# R8 sees them as unused and would rename or delete them.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.Library { *; }
-keep class * extends com.sun.jna.Structure { *; }
-keep class * implements com.sun.jna.Callback { *; }
-keepclassmembers class * extends com.sun.jna.Structure {
    public <fields>;
}
# JNA ships an AWT-aware path for desktop JVMs that Android does not have.
-dontwarn java.awt.*
-dontwarn java.awt.**

# The generated binding itself (transcribeCloud, cleanText, verifyProvider, keyPageUrl and the
# structures they pass). `scripts/build-core-mobile.sh` regenerates this package, so it is not
# in git and cannot be annotated — keep the lot.
-keep class app.murmur.core.** { *; }

# ── Room ─────────────────────────────────────────────────────────────────────
# Entities are mapped column-by-column by generated code that reflects on the constructor;
# the DAO and database implementations are generated classes looked up by name.
-keep class com.murmur.app.data.history.** { *; }
-keep class * extends androidx.room.RoomDatabase { *; }
-dontwarn androidx.room.paging.**

# ── Android components instantiated by name ──────────────────────────────────
# The manifest keeps the service, but the system also resolves it from res/xml/method.xml and
# from the user's enabled-input-method list, which R8 does not parse.
-keep class com.murmur.app.ime.MurmurInputMethodService { *; }

# ── Noise from optional dependencies ─────────────────────────────────────────
# DataStore and security-crypto reference javax.annotation / error-prone bits that are not on
# the Android classpath and are never executed.
-dontwarn javax.annotation.**
-dontwarn com.google.errorprone.annotations.**
