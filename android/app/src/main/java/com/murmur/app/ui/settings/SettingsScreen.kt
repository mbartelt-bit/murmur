package com.murmur.app.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.murmur.app.BuildConfig
import com.murmur.app.R
import com.murmur.app.data.CleanupEngine
import com.murmur.app.data.Settings
import com.murmur.app.data.SettingsStore
import com.murmur.app.data.SttEngine
import com.murmur.app.ui.components.MurmurCard
import com.murmur.app.ui.components.SectionLabel
import kotlinx.coroutines.launch

/**
 * Engines, keys, the four behaviour toggles and the version.
 *
 * Everything saves the instant it is touched — there is no Save button, because the keyboard
 * reads the same DataStore directly and a half-applied setting would mean the keyboard and the
 * app disagreeing about which engine is running.
 */
@Composable
fun SettingsScreen(
    engine: EngineSettingsViewModel,
    settingsStore: SettingsStore,
    settings: Settings,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) { engine.load() }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Text(
            text = stringResource(R.string.tab_settings),
            style = MaterialTheme.typography.headlineMedium,
        )

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionLabel(stringResource(R.string.transcription_section))
            SttPicker(selected = engine.stt, onSelect = { scope.launch { engine.setStt(it) } })
            Text(
                text = stringResource(R.string.engine_step_body),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionLabel(stringResource(R.string.cleanup_section))
            CleanupPicker(selected = engine.cleanup, onSelect = { scope.launch { engine.setCleanup(it) } })
        }

        // One block per provider actually in use — Local speech with OpenAI cleanup still
        // needs the OpenAI key, which is the rule the desktop learned the hard way.
        engine.providersInUse.forEach { provider ->
            ProviderKeySection(provider = provider, engine = engine)
        }

        MurmurCard(padding = 8) {
            // Every switch is drawn from the store's own flow, so nothing is mirrored here:
            // the recomposition that follows the write is what moves the thumb — and it is the
            // same write the keyboard is watching.
            SettingToggle(
                label = stringResource(R.string.auto_listen_toggle),
                checked = settings.autoListen,
                onChange = { value -> scope.launch { settingsStore.update { it.copy(autoListen = value) } } },
            )
            SettingToggle(
                label = stringResource(R.string.return_keyboard_toggle),
                checked = settings.returnToPreviousKeyboard,
                onChange = { value ->
                    scope.launch { settingsStore.update { it.copy(returnToPreviousKeyboard = value) } }
                },
            )
            SettingToggle(
                label = stringResource(R.string.auto_stop_toggle),
                checked = settings.autoStopOnSilence,
                onChange = { value -> scope.launch { settingsStore.update { it.copy(autoStopOnSilence = value) } } },
            )
            SettingToggle(
                label = stringResource(R.string.clipboard_toggle),
                checked = settings.copyToClipboard,
                onChange = { value -> scope.launch { settingsStore.update { it.copy(copyToClipboard = value) } } },
            )
            Text(
                text = stringResource(R.string.clipboard_footer),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionLabel(stringResource(R.string.about_section))
            MurmurCard {
                Row(modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = stringResource(R.string.version_row),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        text = BuildConfig.VERSION_NAME,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun SettingToggle(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.weight(1f),
        )
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

/** The three transcription engines, in the desktop's words. */
@Composable
fun SttPicker(selected: SttEngine, onSelect: (SttEngine) -> Unit, modifier: Modifier = Modifier) {
    val labels = listOf(
        SttEngine.LOCAL to R.string.stt_local,
        SttEngine.GROQ to R.string.stt_groq,
        SttEngine.OPENAI to R.string.stt_openai,
    )
    Segmented(labels, selected, onSelect, modifier)
}

/** The three cleanup engines. `Rules` is the core's offline pass and cannot fail. */
@Composable
fun CleanupPicker(
    selected: CleanupEngine,
    onSelect: (CleanupEngine) -> Unit,
    modifier: Modifier = Modifier,
) {
    val labels = listOf(
        CleanupEngine.RULE to R.string.cleanup_rule,
        CleanupEngine.GROQ to R.string.cleanup_groq,
        CleanupEngine.OPENAI to R.string.cleanup_openai,
    )
    Segmented(labels, selected, onSelect, modifier)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> Segmented(
    options: List<Pair<T, Int>>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    SingleChoiceSegmentedButtonRow(modifier = modifier.fillMaxWidth()) {
        options.forEachIndexed { index, (value, label) ->
            SegmentedButton(
                selected = value == selected,
                onClick = { onSelect(value) },
                shape = SegmentedButtonDefaults.itemShape(index = index, count = options.size),
            ) {
                Text(
                    text = stringResource(label),
                    style = MaterialTheme.typography.labelMedium,
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                )
            }
        }
    }
}
