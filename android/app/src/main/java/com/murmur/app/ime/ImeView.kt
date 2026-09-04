package com.murmur.app.ime

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Backspace
import androidx.compose.material.icons.automirrored.filled.KeyboardReturn
import androidx.compose.material.icons.filled.Language
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.murmur.app.R

/** The desktop's `--accent: #6366f1`, on every platform. */
private val Indigo = Color(0xFF6366F1)

/** Fixed light/dark tokens, matching the desktop — dynamic colour is off on purpose. */
private val LightKeyboard = lightColorScheme(
    primary = Indigo,
    onPrimary = Color.White,
    surface = Color(0xFFF5F5F7),
    onSurface = Color(0xFF1C1C1E),
    surfaceVariant = Color(0xFFFFFFFF),
    onSurfaceVariant = Color(0xFF5A5A60),
)

private val DarkKeyboard = darkColorScheme(
    primary = Indigo,
    onPrimary = Color.White,
    surface = Color(0xFF1C1C1E),
    onSurface = Color(0xFFF2F2F5),
    surfaceVariant = Color(0xFF2C2C2E),
    onSurfaceVariant = Color(0xFFA0A0A6),
)

/** The keyboard's height, spec section 7.1. A voice keyboard needs no more. */
private val KeyboardHeight = 220.dp

/**
 * The whole keyboard: a status strip, one big microphone, and four keys.
 *
 * No letters, on purpose (spec section 7.1): Android hands the user straight back to their own
 * keyboard when the dictation lands, so a QWERTY layout here would only be in the way.
 */
@Composable
fun ImeView(controller: ImeController) {
    val phase by controller.phase.collectAsState()
    val showsGlobe by controller.showsGlobe.collectAsState()
    val colors = if (isSystemInDarkTheme()) DarkKeyboard else LightKeyboard

    MaterialTheme(colorScheme = colors) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(colors.surface)
                // The keyboard's own 220 dp sit *above* the gesture bar: the background still
                // runs to the bottom of the screen, the keys do not go under the pill.
                .windowInsetsPadding(WindowInsets.navigationBars)
                .height(KeyboardHeight),
        ) {
            StatusStrip(
                phase = phase,
                onOpenApp = controller::openApp,
                onRetryOnDevice = controller::retryOnDevice,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(58.dp),
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentAlignment = Alignment.Center,
            ) {
                MicButton(phase = phase, onTap = { controller.tapMic() })
            }
            KeyRow(
                showsGlobe = showsGlobe,
                onGlobe = controller::tapGlobe,
                onDelete = controller::tapDelete,
                onSpace = controller::tapSpace,
                onReturn = controller::tapReturn,
            )
        }
    }
}

/** Everything the keyboard has to say, in one line — plus the one button that phase needs. */
@Composable
private fun StatusStrip(
    phase: ImePhase,
    onOpenApp: () -> Unit,
    onRetryOnDevice: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = statusText(phase),
            style = MaterialTheme.typography.bodyMedium,
            color = when (phase) {
                is ImePhase.Done -> MaterialTheme.colorScheme.onSurface
                is ImePhase.Failed, is ImePhase.NeedsPermission -> MaterialTheme.colorScheme.onSurface
                else -> MaterialTheme.colorScheme.onSurfaceVariant
            },
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        when {
            phase is ImePhase.NeedsPermission -> TextButton(onClick = onOpenApp) {
                Text(stringResource(R.string.ime_open_app), color = Indigo)
            }

            phase is ImePhase.Failed && phase.canRetryOnDevice -> TextButton(onClick = onRetryOnDevice) {
                Text(stringResource(R.string.ime_try_on_device), color = Indigo)
            }

            phase is ImePhase.Listening -> Text(
                text = elapsedLabel(phase.elapsedMs),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun statusText(phase: ImePhase): String = when (phase) {
    ImePhase.Idle -> stringResource(R.string.ime_idle)
    ImePhase.NeedsPermission -> stringResource(R.string.ime_needs_permission)
    is ImePhase.Listening -> stringResource(R.string.ime_listening)
    is ImePhase.Transcribing ->
        phase.partial.ifBlank { stringResource(R.string.ime_transcribing) }

    is ImePhase.Done -> phase.clean
    is ImePhase.Failed -> phase.message
}

/** `m:ss`, so a long dictation is visibly running towards the two-minute cap. */
internal fun elapsedLabel(elapsedMs: Long): String {
    val seconds = (elapsedMs / 1000).coerceAtLeast(0)
    val padded = (seconds % 60).toString().padStart(2, '0')
    return "${seconds / 60}:$padded"
}

/**
 * The one thing the user is meant to look at. It grows with the microphone level while
 * listening — the level meter and the stop button are the same object.
 */
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
            .size(72.dp)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .clip(CircleShape)
            .background(if (enabled) Indigo else Indigo.copy(alpha = 0.4f))
            .clickable(enabled = enabled, onClick = onTap)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        MicGlyph()
    }
}

/** A microphone, drawn rather than imported: four shapes, no icon dependency. */
@Composable
private fun MicGlyph() {
    Canvas(modifier = Modifier.size(30.dp)) {
        val w = size.width
        val h = size.height
        val capsule = w * 0.40f
        val stroke = w * 0.10f
        drawRoundRect(
            color = Color.White,
            topLeft = Offset((w - capsule) / 2f, h * 0.06f),
            size = Size(capsule, h * 0.50f),
            cornerRadius = CornerRadius(capsule / 2f, capsule / 2f),
        )
        drawArc(
            color = Color.White,
            startAngle = 0f,
            sweepAngle = 180f,
            useCenter = false,
            topLeft = Offset(w * 0.16f, h * 0.34f),
            size = Size(w * 0.68f, h * 0.46f),
            style = Stroke(width = stroke, cap = StrokeCap.Round),
        )
        drawLine(
            color = Color.White,
            start = Offset(w / 2f, h * 0.78f),
            end = Offset(w / 2f, h * 0.94f),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
    }
}

/** The only keys a voice keyboard needs: switch away, fix a word, add a space, send. */
@Composable
private fun KeyRow(
    showsGlobe: Boolean,
    onGlobe: () -> Unit,
    onDelete: () -> Unit,
    onSpace: () -> Unit,
    onReturn: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(54.dp)
            .padding(horizontal = 8.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (showsGlobe) {
            Key(
                description = stringResource(R.string.ime_key_globe),
                onClick = onGlobe,
                modifier = Modifier.width(72.dp),
            ) {
                KeyIcon(Icons.Default.Language)
            }
        }
        Key(
            description = stringResource(R.string.ime_key_delete),
            onClick = onDelete,
            modifier = Modifier.width(72.dp),
        ) {
            KeyIcon(Icons.AutoMirrored.Filled.Backspace)
        }
        // The one key wide enough to say what it is in words, exactly as every other keyboard
        // labels it.
        Key(
            description = stringResource(R.string.ime_key_space),
            onClick = onSpace,
            modifier = Modifier.weight(1f),
        ) {
            Text(
                text = stringResource(R.string.ime_key_space_label),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
        Key(
            description = stringResource(R.string.ime_key_return),
            onClick = onReturn,
            modifier = Modifier.width(84.dp),
        ) {
            KeyIcon(Icons.AutoMirrored.Filled.KeyboardReturn)
        }
    }
}

/**
 * One key. [description] is what TalkBack reads — the glyph itself carries no text, which is
 * exactly why it has to be spelled out here.
 */
@Composable
private fun Key(
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
        content = { content() },
    )
}

@Composable
private fun KeyIcon(icon: ImageVector) {
    Icon(
        imageVector = icon,
        // The key itself carries the label; a second one here would be read out twice.
        contentDescription = null,
        tint = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.size(22.dp),
    )
}
