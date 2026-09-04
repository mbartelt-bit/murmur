package com.murmur.app.data.history

import kotlinx.coroutines.flow.Flow

/**
 * The history, as the rest of the app sees it. Every dictation is written here *before* it is
 * committed into a text field (design spec section 1), which makes this the one place a
 * transcript can never be lost.
 */
class HistoryStore(private val dao: TranscriptDao) {

    /** Writes [transcript] and returns it with the id Room assigned. */
    suspend fun insert(transcript: TranscriptEntity): TranscriptEntity =
        transcript.copy(id = dao.insert(transcript))

    /** Newest first; [query], when given and non-blank, filters on the cleaned or raw text. */
    suspend fun list(limit: Int = 50, query: String? = null): List<TranscriptEntity> =
        if (query.isNullOrBlank()) dao.recent(limit) else dao.search(query, limit)

    suspend fun delete(id: Long) = dao.delete(id)

    /** The `n` newest transcripts — what the home screen shows. */
    suspend fun recent(n: Int): List<TranscriptEntity> = dao.recent(n)

    /** The same list, re-emitted whenever a dictation lands. */
    fun observeRecent(n: Int): Flow<List<TranscriptEntity>> = dao.observeRecent(n)
}
