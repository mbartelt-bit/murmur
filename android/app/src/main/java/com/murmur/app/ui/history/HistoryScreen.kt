package com.murmur.app.ui.history

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.murmur.app.R
import com.murmur.app.data.history.TranscriptEntity
import com.murmur.app.ui.components.MurmurCard
import com.murmur.app.ui.home.TranscriptRow
import com.murmur.app.ui.home.copyToClipboard
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Every dictation Murmur has made on this phone, newest first.
 *
 * Tap copies — that is the action people actually want from a list of things they said, and it
 * is one gesture rather than a row of icon buttons squeezed onto a phone. Delete is the
 * standard swipe, and the raw transcript is one long-press away for anyone who wants to see
 * what the cleanup pass changed.
 */
@Composable
fun HistoryScreen(viewModel: HistoryViewModel, modifier: Modifier = Modifier) {
    LaunchedEffect(viewModel.query) { viewModel.reload() }

    LaunchedEffect(viewModel.copiedId) {
        if (viewModel.copiedId == null) return@LaunchedEffect
        delay(1_500)
        viewModel.copiedId = null
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = stringResource(R.string.tab_history),
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.padding(top = 16.dp),
        )

        OutlinedTextField(
            value = viewModel.query,
            onValueChange = { viewModel.query = it },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
            placeholder = { Text(stringResource(R.string.search_placeholder)) },
        )

        if (viewModel.items.isEmpty()) {
            MurmurCard {
                Text(
                    text = stringResource(
                        if (viewModel.query.isBlank()) R.string.history_empty
                        else R.string.history_no_matches,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(viewModel.items, key = { it.id }) { transcript ->
                    HistoryRow(transcript, viewModel)
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HistoryRow(transcript: TranscriptEntity, viewModel: HistoryViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var menuOpen by remember { mutableStateOf(false) }

    val dismissState = rememberSwipeToDismissBoxState(
        // Confirming *is* the delete: the row leaves the database before the box finishes
        // animating it away, so there is nothing to bounce back.
        confirmValueChange = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) {
                scope.launch { viewModel.delete(transcript.id) }
                true
            } else {
                false
            }
        },
    )

    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(14.dp))
                    .background(MaterialTheme.colorScheme.error)
                    .padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Icon(
                    imageVector = Icons.Default.Delete,
                    contentDescription = stringResource(R.string.delete),
                    tint = MaterialTheme.colorScheme.onError,
                )
            }
        },
    ) {
        MurmurCard(padding = 0) {
            Column(
                modifier = Modifier
                    .combinedClickable(
                        onClick = {
                            context.copyToClipboard(transcript.cleanText)
                            viewModel.copiedId = transcript.id
                        },
                        onLongClick = { menuOpen = true },
                    )
                    .padding(14.dp),
            ) {
                TranscriptRow(
                    transcript = transcript,
                    copied = viewModel.copiedId == transcript.id,
                )
                if (viewModel.rawShownId == transcript.id) {
                    Text(
                        text = transcript.rawText,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 8.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .padding(10.dp),
                    )
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = {
                            Text(
                                stringResource(
                                    if (viewModel.rawShownId == transcript.id) R.string.hide_raw
                                    else R.string.show_raw,
                                ),
                            )
                        },
                        onClick = {
                            viewModel.toggleRaw(transcript.id)
                            menuOpen = false
                        },
                    )
                }
            }
        }
    }
}
