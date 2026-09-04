package com.murmur.app.data

/** Which engine turns speech into text. */
enum class SttEngine(val id: String) {
    LOCAL("local"),
    GROQ("groq"),
    OPENAI("openai"),
    ;

    /** The cloud provider behind this choice, or `null` for the on-device recognizer. */
    val provider: ProviderId?
        get() = when (this) {
            LOCAL -> null
            GROQ -> ProviderId.GROQ
            OPENAI -> ProviderId.OPENAI
        }

    companion object {
        /** Unknown ids (an older or newer build) fall back to the default rather than throwing. */
        fun fromId(id: String?): SttEngine = entries.firstOrNull { it.id == id } ?: LOCAL
    }
}

/** Which engine cleans the transcript up. `RULE` is the core's offline rules pass. */
enum class CleanupEngine(val id: String) {
    RULE("rule"),
    GROQ("groq"),
    OPENAI("openai"),
    ;

    /** The cloud provider behind this choice, or `null` for the core's offline rules. */
    val provider: ProviderId?
        get() = when (this) {
            RULE -> null
            GROQ -> ProviderId.GROQ
            OPENAI -> ProviderId.OPENAI
        }

    companion object {
        fun fromId(id: String?): CleanupEngine = entries.firstOrNull { it.id == id } ?: RULE
    }
}

/**
 * The two cloud providers, and everything the UI needs to talk about one.
 *
 * The copy here is lifted verbatim from the desktop's `src/components/EngineSettings.tsx`
 * `PROVIDER_INFO`, and mirrors iOS's `ProviderId`, so all three say exactly the same things.
 *
 * The key page URL is deliberately *not* a property here: it comes from the core
 * (`app.murmur.core.keyPageUrl(provider.core)`) at the call site, so this file stays loadable
 * in a plain JVM unit test where `libmurmur_core.so` does not exist.
 */
enum class ProviderId(
    val id: String,
    /** Secret-store account name — the desktop's, so a future sync sees the same items. */
    val keychainAccount: String,
    val core: app.murmur.core.Provider,
    val displayName: String,
    val costLabel: String,
    val signupSteps: List<String>,
) {
    GROQ(
        id = "groq",
        keychainAccount = "groq_api_key",
        core = app.murmur.core.Provider.GROQ,
        displayName = "Groq",
        costLabel = "Free tier · no card",
        signupSteps = listOf(
            "Sign in with Google or GitHub",
            "Click \"Create API Key\"",
            "Copy it and paste below",
        ),
    ),
    OPENAI(
        id = "openai",
        keychainAccount = "openai_api_key",
        core = app.murmur.core.Provider.OPEN_AI,
        displayName = "OpenAI",
        costLabel = "Pay-as-you-go · card required",
        signupSteps = listOf(
            "Add ~\$5 credit + a card",
            "Click \"Create new secret key\"",
            "Copy it and paste below",
        ),
    ),
    ;

    companion object {
        fun fromId(id: String?): ProviderId? = entries.firstOrNull { it.id == id }
    }
}

/**
 * Everything the app remembers that is not a secret. Stored in DataStore, which the input
 * method reads directly because it runs in the same process.
 *
 * `copyToClipboard` defaults to **off** on Android, unlike iOS: `commitText` puts the words
 * straight into the focused field, so the clipboard is not the safety net here — it would only
 * be a copy of the user's speech sitting where every app can read it.
 */
data class Settings(
    val stt: SttEngine = SttEngine.LOCAL,
    val cleanup: CleanupEngine = CleanupEngine.RULE,
    val autoStopOnSilence: Boolean = true,
    val copyToClipboard: Boolean = false,
    val autoListen: Boolean = true,
    val returnToPreviousKeyboard: Boolean = true,
    val onboardingComplete: Boolean = false,
)
