package com.murmur.app

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.emptyPreferences
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.SttEngine
import com.murmur.app.ui.onboarding.OnboardingViewModel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Onboarding's four steps and their gates, with no permission system, no keyboard list and no
 * speech service — every system answer is a closure the test owns.
 */
class OnboardingViewModelTest {

    /** DataStore in memory: the real store's logic, none of its files. */
    private class FakeDataStore : DataStore<Preferences> {
        private val state = MutableStateFlow(emptyPreferences())
        override val data: Flow<Preferences> = state
        override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences =
            transform(state.value).also { state.value = it }
    }

    private var mic = false
    private var keyboard = false
    private var local = true
    private val settings = SettingsStore(FakeDataStore())

    private fun model() = OnboardingViewModel(
        settings = settings,
        micGranted = { mic },
        keyboardEnabled = { keyboard },
        localAvailable = { local },
    )

    // ── The order ────────────────────────────────────────────────────────────

    @Test
    fun `the steps run mic then engine then keyboard then test`() {
        val model = model()

        assertEquals(OnboardingViewModel.Step.MIC, model.step)
        assertEquals(OnboardingViewModel.Step.ENGINE, model.nextStep)
        model.advance()
        assertEquals(OnboardingViewModel.Step.KEYBOARD, model.nextStep)
        model.advance()
        assertEquals(OnboardingViewModel.Step.TEST, model.nextStep)
        model.advance()
        assertEquals(OnboardingViewModel.Step.TEST, model.step)
        assertNull(model.nextStep)
        // The last step goes nowhere; Finish is the only way out.
        model.advance()
        assertEquals(OnboardingViewModel.Step.TEST, model.step)
    }

    // ── The gates ────────────────────────────────────────────────────────────

    @Test
    fun `the mic step waits for the permission dialog`() = runTest {
        val model = model()
        model.refresh()

        assertFalse(model.canAdvance)
        assertFalse(model.micAsked)

        model.onMicResult(granted = false)
        assertTrue(model.micAsked)
        assertFalse(model.canAdvance)

        model.onMicResult(granted = true)
        assertTrue(model.canAdvance)
    }

    @Test
    fun `local needs an on-device recognizer`() = runTest {
        local = false
        val model = model()
        model.refresh()
        model.advance()

        assertEquals(SttEngine.LOCAL, model.stt)
        assertFalse(model.canAdvance)

        local = true
        model.choose(SttEngine.LOCAL)
        assertTrue(model.canAdvance)
    }

    @Test
    fun `a cloud engine needs a key that actually verified`() = runTest {
        val model = model()
        model.refresh()
        model.advance()

        model.choose(SttEngine.GROQ)
        // On-device speech being ready says nothing about Groq's key.
        assertTrue(model.localReady)
        assertFalse(model.canAdvance)

        model.cloudVerified = true
        assertTrue(model.canAdvance)
    }

    @Test
    fun `the keyboard step is a hard gate`() = runTest {
        val model = model()
        model.refresh()
        model.advance()
        model.advance()

        assertEquals(OnboardingViewModel.Step.KEYBOARD, model.step)
        assertFalse(model.canAdvance)

        keyboard = true
        model.refreshKeyboardStatus()
        assertTrue(model.keyboardOn)
        assertTrue(model.canAdvance)
    }

    @Test
    fun `the test step never blocks Finish`() = runTest {
        val model = model()
        model.goTo(OnboardingViewModel.Step.TEST)

        assertTrue(model.canAdvance)
    }

    // ── Persistence ──────────────────────────────────────────────────────────

    @Test
    fun `choosing an engine persists it immediately`() = runTest {
        val model = model()

        model.choose(SttEngine.OPENAI)

        assertEquals(SttEngine.OPENAI, model.stt)
        assertEquals(SttEngine.OPENAI, settings.current().stt)
        // And it survives someone quitting mid-onboarding.
        assertEquals(SttEngine.OPENAI, model().also { it.refresh() }.stt)
    }

    @Test
    fun `finish flips onboardingComplete`() = runTest {
        val model = model()
        assertFalse(settings.current().onboardingComplete)

        model.finish()

        assertTrue(settings.current().onboardingComplete)
    }

    @Test
    fun `refresh re-reads everything the system may have changed`() = runTest {
        val model = model()
        model.refresh()
        assertFalse(model.mic)
        assertFalse(model.keyboardOn)

        mic = true
        keyboard = true
        model.refresh()

        assertTrue(model.mic)
        assertTrue(model.keyboardOn)
    }
}
