package com.murmur.app.ui.history

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import com.murmur.app.data.history.HistoryStore
import com.murmur.app.data.history.TranscriptEntity

/**
 * The History screen's list, search and row actions. The iOS twin is `HistoryViewModel`.
 *
 * The search itself runs in SQLite rather than over the loaded rows, so [PAGE_SIZE] is a
 * display cap and not a search cap: a phrase from six months ago is still findable.
 */
class HistoryViewModel(private val history: HistoryStore) : ViewModel() {

    /** The search field. The screen reloads on a change; typing never blocks on SQLite. */
    var query by mutableStateOf("")

    var items by mutableStateOf<List<TranscriptEntity>>(emptyList())
        private set

    /** The row whose "Copied" check is showing, if any. */
    var copiedId by mutableStateOf<Long?>(null)

    /** The row whose raw transcript is expanded — the long-press "Show raw". */
    var rawShownId by mutableStateOf<Long?>(null)
        private set

    /** Newest first, filtered by [query] when it has anything in it. */
    suspend fun reload() {
        val trimmed = query.trim()
        items = history.list(limit = PAGE_SIZE, query = trimmed.ifEmpty { null })
    }

    suspend fun delete(id: Long) {
        history.delete(id)
        if (rawShownId == id) rawShownId = null
        reload()
    }

    fun toggleRaw(id: Long) {
        rawShownId = if (rawShownId == id) null else id
    }

    companion object {
        /** How many rows the screen keeps in memory. */
        const val PAGE_SIZE = 200
    }
}
