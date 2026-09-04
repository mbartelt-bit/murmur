package com.murmur.app.ui.home

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.text.format.DateUtils
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.collectAsState
import com.murmur.app.KeyboardStatus
import com.murmur.app.Permissions
import com.murmur.app.R
import com.murmur.app.data.SttEngine
import com.murmur.app.data.history.TranscriptEntity
import com.murmur.app.data.history.TranscriptSource
import com.murmur.app.ui.components.MurmurCard
import com.murmur.app.ui.components.SectionLabel
import com.murmur.app.ui.components.StatusChip
import com.murmur.app.ui.theme.MurmurIndigo
import com.murmur.app.ui.theme.MurmurOk
import kotlinx.coroutines.delay

/**
 * The screen Murmur opens on: one big button, the readiness chips, the last three dictations.
 *
 * The button is deliberately the largest thing on the phone — the whole product is "press this
 * and talk" — and the chips sit under it rather than above, so a healthy app reads as a button
 * with a receipt rather than as a checklist.
 */
@Composable
fun HomeScreen(
    viewModel: HomeViewModel,
    onTryDictation: () -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier,
    /** The IME sent the user here to grant the microphone: say which chip it meant. */
    highlightMic: Boolean = false,
) {
    val context = LocalContext.current
    val recent by viewModel.recent.collectAsState(initial = emptyList())
    val micLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val hadAsked = viewModel.micAsked
        viewModel.onMicResult(granted)
        // A denial that the system never showed a dialog for is a permanent one; the only way
        // back is Murmur's own page in system settings.
        if (!granted && hadAsked) Permissions.openAppSettings(context)
    }

    /** The mic chip's fix: the runtime dialog, then system settings if it never appeared. */
    val fixMic = { micLauncher.launch(Manifest.permission.RECORD_AUDIO) }

    LaunchedEffect(Unit) { viewModel.refresh() }

    // The check on a copied row clears itself; nothing to remember once it is gone.
    LaunchedEffect(viewModel.copiedId) {
        if (viewModel.copiedId == null) return@LaunchedEffect
        delay(1_500)
        viewModel.copiedId = null
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        Text(
            text = stringResource(R.string.app_name),
            style = MaterialTheme.typography.headlineMedium,
        )

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(MurmurIndigo)
                .clickable(onClick = onTryDictation)
                .padding(vertical = 34.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                imageVector = Icons.Default.Mic,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(34.dp),
            )
            Text(
                text = stringResource(R.string.try_dictation),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
            )
        }

        MurmurCard(padding = 14) {
            StatusChip(
                title = stringResource(R.string.chip_mic),
                detail = stringResource(
                    if (viewModel.mic) R.string.chip_allowed else R.string.chip_tap_to_allow,
                ),
                ok = viewModel.mic,
                highlighted = highlightMic && !viewModel.mic,
                onClick = if (viewModel.mic) null else fixMic,
            )
            HorizontalDivider()
            StatusChip(
                title = stringResource(R.string.chip_keyboard),
                detail = stringResource(if (viewModel.keyboardOn) R.string.chip_on else R.string.chip_off),
                ok = viewModel.keyboardOn,
                onClick = { KeyboardStatus.openImeSettings(context) },
            )
            HorizontalDivider()
            StatusChip(
                title = stringResource(R.string.chip_engine),
                detail = engineSummary(viewModel.stt, viewModel.engineReady),
                ok = viewModel.engineReady,
                onClick = onOpenSettings,
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SectionLabel(stringResource(R.string.recent_title))
            if (recent.isEmpty()) {
                MurmurCard {
                    Text(
                        text = stringResource(R.string.no_dictations_yet),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                MurmurCard(padding = 0) {
                    recent.forEachIndexed { index, transcript ->
                        TranscriptRow(
                            transcript = transcript,
                            copied = viewModel.copiedId == transcript.id,
                            modifier = Modifier
                                .clickable {
                                    context.copyToClipboard(transcript.cleanText)
                                    viewModel.copiedId = transcript.id
                                }
                                .padding(14.dp),
                        )
                        if (index != recent.lastIndex) HorizontalDivider()
                    }
                }
                Text(
                    text = stringResource(R.string.tap_to_copy),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** The engine chip's second line, e.g. "Local · on device" or "Groq · no key". */
@Composable
private fun engineSummary(stt: SttEngine, keyPresent: Boolean): String = when (stt) {
    SttEngine.LOCAL -> stringResource(R.string.engine_summary_local)
    else -> stringResource(
        if (keyPresent) R.string.engine_summary_connected else R.string.engine_summary_no_key,
        engineName(stt),
    )
}

@Composable
private fun engineName(stt: SttEngine): String = stringResource(
    when (stt) {
        SttEngine.LOCAL -> R.string.engine_name_local
        SttEngine.GROQ -> R.string.engine_name_groq
        SttEngine.OPENAI -> R.string.engine_name_openai
    },
)

/**
 * One saved dictation, as Home and History both draw it: the cleaned line, when it happened,
 * where it came from, and the copy affordance. Tapping copies the *cleaned* text — the raw one
 * is not what the user asked Murmur for.
 */
@Composable
fun TranscriptRow(
    transcript: TranscriptEntity,
    copied: Boolean,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Text(
                text = transcript.cleanText,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = relativeTime(transcript.createdAt),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = sourceLabel(transcript.source),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(horizontal = 6.dp, vertical = 1.dp),
                )
            }
        }
        Icon(
            imageVector = if (copied) Icons.Default.Check else Icons.Default.ContentCopy,
            contentDescription = stringResource(if (copied) R.string.copied else R.string.tap_to_copy),
            tint = if (copied) MurmurOk else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(16.dp),
        )
    }
}

@Composable
private fun sourceLabel(source: String): String = stringResource(
    when (TranscriptSource.fromId(source)) {
        TranscriptSource.KEYBOARD -> R.string.source_keyboard
        TranscriptSource.IN_APP -> R.string.source_in_app
    },
)

/** "4 minutes ago" in the user's own locale, from the platform rather than a format string. */
@Composable
private fun relativeTime(createdAt: Long): String = remember(createdAt) {
    DateUtils.getRelativeTimeSpanString(
        createdAt,
        System.currentTimeMillis(),
        DateUtils.MINUTE_IN_MILLIS,
    ).toString()
}

/**
 * The clipboard, for a row the user tapped. Nothing else in the app writes to it except the
 * "Copy dictations to the clipboard" setting, which the pipeline's callers honour.
 */
internal fun Context.copyToClipboard(text: String) {
    val manager = getSystemService(ClipboardManager::class.java) ?: return
    runCatching { manager.setPrimaryClip(ClipData.newPlainText("Murmur", text)) }
}
