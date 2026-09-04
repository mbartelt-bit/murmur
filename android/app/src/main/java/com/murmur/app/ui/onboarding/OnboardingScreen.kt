package com.murmur.app.ui.onboarding

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.murmur.app.KeyboardStatus
import com.murmur.app.R
import com.murmur.app.data.SttEngine
import com.murmur.app.ui.components.MurmurCard
import com.murmur.app.ui.settings.EngineSettingsViewModel
import com.murmur.app.ui.settings.ProviderKeySection
import com.murmur.app.ui.settings.SttPicker
import com.murmur.app.ui.theme.MurmurIndigo
import com.murmur.app.ui.theme.MurmurOk
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * First run. One step per screen, one primary button per step: the microphone, the engine, the
 * keyboard, and one real dictation.
 *
 * Everything that decides *whether* a step is done lives in [OnboardingViewModel]; this file
 * only decides what it looks like — and owns the two things a view model cannot hold: the
 * permission launcher and the focus requester.
 */
@Composable
fun OnboardingScreen(
    viewModel: OnboardingViewModel,
    engine: EngineSettingsViewModel,
    onFinished: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val micLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        viewModel.onMicResult(granted)
        if (granted) viewModel.advance()
    }

    LaunchedEffect(Unit) {
        viewModel.refresh()
        engine.load()
    }

    // The cloud gate is the key block's answer, not a second opinion about it.
    val verifyState = engine.verifyState
    LaunchedEffect(verifyState, viewModel.stt) {
        viewModel.cloudVerified = viewModel.stt.provider
            ?.let { engine.state(it) == EngineSettingsViewModel.VerifyState.Connected } == true
    }

    // The keyboard step is the one the user leaves mid-way, so it watches for the answer
    // instead of waiting to be told. Cancelled by Compose on the way out of the step.
    LaunchedEffect(viewModel.step) {
        if (viewModel.step != OnboardingViewModel.Step.KEYBOARD) return@LaunchedEffect
        while (true) {
            viewModel.refreshKeyboardStatus()
            delay(1_000)
        }
    }

    Column(modifier = modifier.fillMaxSize()) {
        ProgressBars(step = viewModel.step)
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Header(viewModel.step)
            when (viewModel.step) {
                OnboardingViewModel.Step.MIC -> MicStep(viewModel)
                OnboardingViewModel.Step.ENGINE -> EngineStep(viewModel, engine)
                OnboardingViewModel.Step.KEYBOARD -> KeyboardStep(viewModel)
                OnboardingViewModel.Step.TEST -> TestStep()
            }
        }

        Column(modifier = Modifier.padding(20.dp)) {
            Button(
                onClick = {
                    when (viewModel.step) {
                        OnboardingViewModel.Step.MIC ->
                            if (viewModel.mic) viewModel.advance()
                            else micLauncher.launch(Manifest.permission.RECORD_AUDIO)

                        OnboardingViewModel.Step.KEYBOARD ->
                            if (viewModel.keyboardOn) viewModel.advance()
                            else KeyboardStatus.openImeSettings(context)

                        OnboardingViewModel.Step.ENGINE -> viewModel.advance()

                        OnboardingViewModel.Step.TEST -> scope.launch {
                            viewModel.finish()
                            onFinished()
                        }
                    }
                },
                // A step whose one action is the way to do the job is never dead: only the
                // engine step can be genuinely not-ready-yet.
                enabled = when (viewModel.step) {
                    OnboardingViewModel.Step.ENGINE -> viewModel.canAdvance
                    else -> true
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
            ) {
                Text(primaryLabel(viewModel), style = MaterialTheme.typography.titleSmall)
            }
        }
    }
}

@Composable
private fun primaryLabel(viewModel: OnboardingViewModel): String = when (viewModel.step) {
    OnboardingViewModel.Step.MIC ->
        if (viewModel.mic) stringResource(R.string.continue_label) else stringResource(R.string.mic_allow)

    OnboardingViewModel.Step.ENGINE -> stringResource(R.string.continue_label)

    OnboardingViewModel.Step.KEYBOARD ->
        if (viewModel.keyboardOn) stringResource(R.string.continue_label)
        else stringResource(R.string.keyboard_open_settings)

    OnboardingViewModel.Step.TEST -> stringResource(R.string.finish)
}

@Composable
private fun ProgressBars(step: OnboardingViewModel.Step) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        OnboardingViewModel.Step.entries.forEach { entry ->
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(
                        if (entry.ordinal <= step.ordinal) MurmurIndigo
                        else MaterialTheme.colorScheme.outlineVariant,
                    ),
            )
        }
    }
}

@Composable
private fun Header(step: OnboardingViewModel.Step) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (step == OnboardingViewModel.Step.MIC) {
            Text(
                text = stringResource(R.string.welcome_title),
                style = MaterialTheme.typography.headlineLarge,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = stringResource(R.string.welcome_subtitle),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 8.dp),
            )
        }
        Text(
            text = stringResource(
                when (step) {
                    OnboardingViewModel.Step.MIC -> R.string.mic_step_title
                    OnboardingViewModel.Step.ENGINE -> R.string.engine_step_title
                    OnboardingViewModel.Step.KEYBOARD -> R.string.keyboard_step_title
                    OnboardingViewModel.Step.TEST -> R.string.test_step_title
                },
            ),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            text = stringResource(
                when (step) {
                    OnboardingViewModel.Step.MIC -> R.string.mic_step_body
                    OnboardingViewModel.Step.ENGINE -> R.string.engine_step_body
                    OnboardingViewModel.Step.KEYBOARD -> R.string.keyboard_step_body
                    OnboardingViewModel.Step.TEST -> R.string.test_step_body
                },
            ),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun MicStep(viewModel: OnboardingViewModel) {
    MurmurCard {
        StatusLine(
            ok = viewModel.mic,
            text = when {
                viewModel.mic -> stringResource(R.string.mic_granted)
                viewModel.micAsked -> stringResource(R.string.mic_denied)
                else -> stringResource(R.string.permission_pending)
            },
        )
    }
}

@Composable
private fun EngineStep(viewModel: OnboardingViewModel, engine: EngineSettingsViewModel) {
    val scope = rememberCoroutineScope()
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        SttPicker(
            selected = viewModel.stt,
            onSelect = { choice ->
                scope.launch {
                    viewModel.choose(choice)
                    engine.setStt(choice)
                }
            },
        )
        val provider = viewModel.stt.provider
        if (provider == null) {
            MurmurCard {
                StatusLine(
                    ok = viewModel.localReady,
                    text = stringResource(
                        if (viewModel.localReady) R.string.local_ready else R.string.local_unavailable,
                    ),
                )
            }
        } else {
            ProviderKeySection(provider = provider, engine = engine)
        }
    }
}

/**
 * Two rows, because Android needs both: the keyboard has to be *enabled* in system settings,
 * and then *picked* once from the switcher for the field in front of the user.
 */
@Composable
private fun KeyboardStep(viewModel: OnboardingViewModel) {
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        MurmurCard {
            Text(
                text = stringResource(R.string.keyboard_step_path),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(12.dp))
            StatusLine(
                ok = viewModel.keyboardOn,
                text = stringResource(
                    if (viewModel.keyboardOn) R.string.keyboard_step_done
                    else R.string.keyboard_step_waiting,
                ),
            )
        }
        MurmurCard {
            Text(
                text = stringResource(R.string.keyboard_picker_line),
                style = MaterialTheme.typography.bodyMedium,
            )
            Spacer(Modifier.height(10.dp))
            OutlinedButton(
                onClick = { KeyboardStatus.showImePicker(context) },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(stringResource(R.string.keyboard_show_picker))
            }
        }
    }
}

/**
 * A field and the switcher. "Try it" opens the keyboard picker and puts the cursor in the
 * field, so the very first Murmur dictation lands somewhere the user can see it.
 */
@Composable
private fun TestStep() {
    val context = LocalContext.current
    val focus = remember { FocusRequester() }
    var typed by remember { mutableStateOf("") }

    MurmurCard {
        OutlinedTextField(
            value = typed,
            onValueChange = { typed = it },
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(focus),
            placeholder = { Text(stringResource(R.string.test_step_placeholder)) },
        )
        Spacer(Modifier.height(12.dp))
        OutlinedButton(
            onClick = {
                KeyboardStatus.showImePicker(context)
                runCatching { focus.requestFocus() }
            },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(stringResource(R.string.test_it))
        }
    }
}

@Composable
private fun StatusLine(ok: Boolean, text: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            imageVector = if (ok) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (ok) MurmurOk else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(20.dp),
        )
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
