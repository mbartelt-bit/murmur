package com.murmur.app.ui.recorder

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.murmur.app.R
import com.murmur.app.ime.ImePhase
import com.murmur.app.ui.theme.MurmurIndigo

/**
 * The in-app dictation: the keyboard's screen, without the keyboard.
 *
 * Everything on it is driven by the very same [com.murmur.app.ime.ImeController] the input
 * method uses, so what a user sees here is what they will see over their messaging app.
 */
@Composable
fun RecorderScreen(
    viewModel: RecorderViewModel,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val phase by viewModel.controller.phase.collectAsState()

    DisposableEffect(Unit) {
        viewModel.onShown()
        onDispose { viewModel.onHidden() }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Text(
            text = stringResource(R.string.recorder_title),
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.fillMaxWidth(),
        )

        // Read-only: this field is where the sink's committed text lands, not somewhere to
        // type. Editing it would put the screen and the controller's idea of the text out of
        // step for no gain.
        OutlinedTextField(
            value = viewModel.text,
            onValueChange = {},
            readOnly = true,
            modifier = Modifier
                .fillMaxWidth()
                .height(160.dp),
            placeholder = { Text(stringResource(R.string.recorder_placeholder)) },
        )

        Text(
            text = statusText(phase),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )

        if (phase is ImePhase.Failed && (phase as ImePhase.Failed).canRetryOnDevice) {
            TextButton(onClick = viewModel.controller::retryOnDevice) {
                Text(stringResource(R.string.ime_try_on_device))
            }
        }

        Spacer(Modifier.weight(1f))

        MicButton(phase = phase, onTap = viewModel.controller::tapMic)

        Spacer(Modifier.weight(1f))

        Button(onClick = onDone, modifier = Modifier.fillMaxWidth().height(52.dp)) {
            Text(stringResource(R.string.recorder_done))
        }
    }
}

@Composable
private fun statusText(phase: ImePhase): String = when (phase) {
    ImePhase.Idle -> stringResource(R.string.ime_idle)
    ImePhase.NeedsPermission -> stringResource(R.string.ime_needs_permission)
    is ImePhase.Listening -> stringResource(R.string.ime_listening)
    is ImePhase.Transcribing -> phase.partial.ifBlank { stringResource(R.string.ime_transcribing) }
    is ImePhase.Done -> phase.clean
    is ImePhase.Failed -> phase.message
}

/** The same button the keyboard draws: the level meter and the stop control are one object. */
@Composable
private fun MicButton(phase: ImePhase, onTap: () -> Unit) {
    val listening = phase as? ImePhase.Listening
    val target = if (listening != null) 1f + 0.3f * listening.level.coerceIn(0f, 1f) else 1f
    val scale by animateFloatAsState(targetValue = target, label = "micLevel")
    val enabled = phase !is ImePhase.Transcribing
    val description = stringResource(
        if (listening != null) R.string.ime_mic_stop else R.string.ime_mic_start,
    )

    Box(
        modifier = Modifier
            .size(112.dp)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .clip(CircleShape)
            .background(if (enabled) MurmurIndigo else MurmurIndigo.copy(alpha = 0.4f))
            .clickable(enabled = enabled, onClick = onTap),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Default.Mic,
            contentDescription = description,
            tint = Color.White,
            modifier = Modifier.size(48.dp),
        )
    }
}
