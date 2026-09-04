package com.murmur.app.data.history

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * Where a dictation came from. The ids are the strings stored in `transcripts.source`,
 * hyphenated to match the desktop's vocabulary. Android has no Action Button, so the iOS
 * `action-button` case has no twin here.
 */
enum class TranscriptSource(val id: String) {
    IN_APP("in-app"),
    KEYBOARD("keyboard"),
    ;

    companion object {
        fun fromId(id: String?): TranscriptSource = entries.firstOrNull { it.id == id } ?: IN_APP
    }
}

/**
 * One saved dictation. `rawText` is what the speech engine heard, `cleanText` what the cleanup
 * pass produced and what actually gets committed — both are kept so a user can see what was
 * changed on their behalf.
 *
 * Column names, not property names: the schema is the desktop's (`src-tauri/src/lib.rs`) and
 * iOS's, so a future sync between the Mac and the phone is a copy, not a translation.
 */
@Entity(tableName = "transcripts")
data class TranscriptEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    @ColumnInfo(name = "raw_text") val rawText: String,
    @ColumnInfo(name = "clean_text") val cleanText: String,
    val source: String,
    /** Epoch milliseconds. */
    @ColumnInfo(name = "created_at") val createdAt: Long = System.currentTimeMillis(),
)
