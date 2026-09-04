package com.murmur.app.ui.onboarding

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.SttEngine

/**
 * First run, one step per screen.
 *
 * The order is the spec's (§5), minus the two steps that only exist on iOS: Android has no
 * separate speech-recognition permission and no Action Button, so it is microphone, engine,
 * the keyboard, and one test dictation. Each step has exactly one thing to do and
 * [canAdvance] says whether it has been done; the screen owns no rules of its own, which is
 * what makes the whole flow testable with fakes.
 *
 * Every system answer arrives through an injected closure rather than a `Context`, so a unit
 * test never touches the permission system, the keyboard list or Google's speech services.
 */
class OnboardingViewModel(
    private val settings: SettingsStore,
    /** `RECORD_AUDIO`, asked again each time the user comes back from system settings. */
    private val micGranted: () -> Boolean,
    /** Murmur is in the enabled keyboard list — `KeyboardStatus.isEnabled`. */
    private val keyboardEnabled: () -> Boolean,
    /** This phone can transcribe offline — `SpeechEngines.isLocalAvailable`. */
    private val localAvailable: () -> Boolean,
) : ViewModel() {

    enum class Step { MIC, ENGINE, KEYBOARD, TEST }

    var step by mutableStateOf(Step.MIC)
        private set

    var mic by mutableStateOf(false)
        private set

    /**
     * The runtime dialog has been shown and answered. Until it has, "Not allowed yet." is the
     * honest line — "Microphone access is off" would be blaming the user for a question
     * nobody has asked them.
     */
    var micAsked by mutableStateOf(false)
        private set

    var keyboardOn by mutableStateOf(false)
        private set

    /** On-device speech can run right now. */
    var localReady by mutableStateOf(false)
        private set

    /** Mirrors `settings.stt`; [choose] is the only thing that writes it. */
    var stt by mutableStateOf(SttEngine.LOCAL)
        private set

    /**
     * Set by the engine step once a cloud key has verified. Onboarding cannot ask the secret
     * store itself — that is `EngineSettingsViewModel`'s job, and this is the one bit of its
     * state the step gate needs.
     */
    var cloudVerified by mutableStateOf(false)

    // MARK: - Gating

    /**
     * Whether the current step's one job is done.
     *
     * The engine step is the only interesting one: `LOCAL` needs an on-device recognizer to be
     * there, a cloud engine needs a key that actually verified — a saved-but-rejected key is
     * not a working engine and must not let anyone through to a dictation that will fail.
     */
    val canAdvance: Boolean
        get() = when (step) {
            Step.MIC -> mic
            Step.ENGINE -> if (stt == SttEngine.LOCAL) localReady else cloudVerified
            // The one hard gate: the keyboard *is* the product.
            Step.KEYBOARD -> keyboardOn
            // Nothing left to require — Finish is always live, because a user who cannot make
            // the keyboard picker work here can still use the in-app recorder.
            Step.TEST -> true
        }

    /** The next step, or `null` on the last one. */
    val nextStep: Step?
        get() = when (step) {
            Step.MIC -> Step.ENGINE
            Step.ENGINE -> Step.KEYBOARD
            Step.KEYBOARD -> Step.TEST
            Step.TEST -> null
        }

    fun advance() {
        step = nextStep ?: return
    }

    /** Straight to one step: the IME's "Open Murmur" lands on [Step.MIC]. */
    fun goTo(step: Step) {
        this.step = step
    }

    // MARK: - The system's answers

    /**
     * The result of the `RECORD_AUDIO` dialog. Only the containing app can show it, which is
     * the whole reason onboarding exists before the keyboard does.
     */
    fun onMicResult(granted: Boolean) {
        micAsked = true
        mic = granted
    }

    /**
     * Re-reads everything the system may have changed behind the app's back — the user can
     * leave for system settings at any step and come back with a different answer.
     */
    suspend fun refresh() {
        mic = micGranted()
        keyboardOn = keyboardEnabled()
        localReady = localAvailable()
        stt = settings.current().stt
    }

    /**
     * Just the keyboard answer. There is no notification for "the user added a keyboard", and
     * the user is expected to leave for Settings and come back mid-step, so the only way for
     * the check to turn green on its own is to look again every second.
     */
    fun refreshKeyboardStatus() {
        keyboardOn = keyboardEnabled()
    }

    // MARK: - Actions

    /**
     * Persists the engine choice immediately — someone who quits during onboarding and comes
     * back should not have to pick again — and re-checks the on-device recognizer for Local.
     */
    suspend fun choose(engine: SttEngine) {
        settings.update { it.copy(stt = engine) }
        stt = engine
        if (engine == SttEngine.LOCAL) localReady = localAvailable()
    }

    /** Onboarding is over: the tabs replace this screen on the next render. */
    suspend fun finish() {
        settings.update { it.copy(onboardingComplete = true) }
    }
}
