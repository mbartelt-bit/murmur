package com.murmur.app.data.history

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

/**
 * Room's view of the history table. [HistoryStore] is what the rest of the app talks to;
 * this stays thin enough that a test can implement it by hand.
 */
@Dao
interface TranscriptDao {
    @Insert
    suspend fun insert(transcript: TranscriptEntity): Long

    /** Newest first. */
    @Query("SELECT * FROM transcripts ORDER BY id DESC LIMIT :limit")
    suspend fun recent(limit: Int): List<TranscriptEntity>

    /**
     * Newest first, keeping rows whose cleaned *or* raw text contains [query].
     * SQLite's `LIKE` is case-insensitive for ASCII, which is the match the search field wants.
     */
    @Query(
        "SELECT * FROM transcripts " +
            "WHERE clean_text LIKE '%' || :query || '%' OR raw_text LIKE '%' || :query || '%' " +
            "ORDER BY id DESC LIMIT :limit",
    )
    suspend fun search(query: String, limit: Int): List<TranscriptEntity>

    @Query("DELETE FROM transcripts WHERE id = :id")
    suspend fun delete(id: Long)

    /** The `limit` newest rows, re-emitted on every write — what the home screen observes. */
    @Query("SELECT * FROM transcripts ORDER BY id DESC LIMIT :limit")
    fun observeRecent(limit: Int): Flow<List<TranscriptEntity>>
}
