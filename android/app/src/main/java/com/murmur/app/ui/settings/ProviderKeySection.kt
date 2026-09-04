package com.murmur.app.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.murmur.app.R
import com.murmur.app.data.ProviderId
import com.murmur.app.ui.components.MurmurCard
import com.murmur.app.ui.theme.MurmurIndigo
import com.murmur.app.ui.theme.MurmurOk
import kotlinx.coroutines.launch

/**
 * The guided "connect a provider" block, shared by Settings and onboarding's engine step — the
 * phone's version of the desktop's `ConnectBlock` and the twin of iOS's `ProviderKeyView`.
 *
 * The typed key lives in exactly one piece of Compose state, cleared the moment
 * [EngineSettingsViewModel.saveKey] has been handed it — before the verify round trip, not
 * after. It is never rendered back, never held by the view model, and never leaves this file.
 */
@Composable
fun ProviderKeySection(
    provider: ProviderId,
    engine: EngineSettingsViewModel,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    var key by remember(provider) { mutableStateOf("") }
    val state = engine.state(provider)

    MurmurCard(modifier = modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = stringResource(R.string.connect_provider, provider.displayName),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.width(8.dp))
            CostBadge(provider.costLabel)
            Spacer(Modifier.weight(1f))
            TextButton(
                onClick = { runCatching { uriHandler.openUri(engine.keyPageUrl(provider)) } },
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 4.dp),
            ) {
                Text(
                    text = stringResource(R.string.get_api_key),
                    style = MaterialTheme.typography.labelMedium,
                    color = MurmurIndigo,
                )
            }
        }

        Column(
            modifier = Modifier.padding(top = 10.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            provider.signupSteps.forEachIndexed { index, step ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "${index + 1}.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        text = step,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        if (engine.hasKey(provider)) {
            SavedKeyRow(
                verifying = state is EngineSettingsViewModel.VerifyState.Verifying,
                onVerify = { scope.launch { engine.verify(provider) } },
                onRemove = { engine.removeKey(provider) },
                modifier = Modifier.padding(top = 12.dp),
            )
        } else {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = key,
                    onValueChange = { key = it },
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                    placeholder = {
                        Text(
                            text = stringResource(R.string.key_field_placeholder, provider.displayName),
                            style = MaterialTheme.typography.bodySmall,
                        )
                    },
                    textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.None,
                        keyboardType = KeyboardType.Password,
                        imeAction = ImeAction.Done,
                    ),
                )
                val saving = engine.saving == provider
                Button(
                    onClick = {
                        val pasted = key
                        // Cleared before the suspend call, not after: the field must not hold
                        // a key for the length of a network round trip.
                        key = ""
                        scope.launch { engine.saveKey(pasted, provider) }
                    },
                    enabled = key.isNotBlank() && !saving,
                ) {
                    Text(stringResource(if (saving) R.string.connecting else R.string.connect))
                }
            }
        }

        StatusLine(state, modifier = Modifier.padding(top = 8.dp))
    }
}

@Composable
private fun CostBadge(label: String) {
    Text(
        text = label,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 7.dp, vertical = 2.dp),
    )
}

@Composable
private fun SavedKeyRow(
    verifying: Boolean,
    onVerify: () -> Unit,
    onRemove: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = stringResource(R.string.key_saved),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onVerify, enabled = !verifying) {
            Text(stringResource(R.string.verify), style = MaterialTheme.typography.labelMedium)
        }
        TextButton(onClick = onRemove) {
            Text(
                text = stringResource(R.string.remove_key),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.error,
            )
        }
    }
}

@Composable
private fun StatusLine(state: EngineSettingsViewModel.VerifyState, modifier: Modifier = Modifier) {
    when (state) {
        EngineSettingsViewModel.VerifyState.Idle -> Unit

        EngineSettingsViewModel.VerifyState.Verifying -> Text(
            text = stringResource(R.string.verifying),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = modifier,
        )

        EngineSettingsViewModel.VerifyState.Connected -> Text(
            text = stringResource(R.string.connected),
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.Medium,
            color = MurmurOk,
            modifier = modifier,
        )

        is EngineSettingsViewModel.VerifyState.Failed -> Text(
            // The core's own sentence. Never a key, never a stack trace.
            text = state.message,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
            modifier = modifier,
        )
    }
}
