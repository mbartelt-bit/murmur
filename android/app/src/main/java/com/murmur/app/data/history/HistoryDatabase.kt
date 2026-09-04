package com.murmur.app.data.history

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

/**
 * The dictation history. One Room database in the app's own storage; the input method reads
 * and writes the same rows because it runs in the app's process (design spec section 7.2).
 */
@Database(entities = [TranscriptEntity::class], version = 1, exportSchema = false)
abstract class HistoryDatabase : RoomDatabase() {
    abstract fun transcripts(): TranscriptDao

    companion object {
        const val FILE_NAME = "murmur.db"

        /** The app's database on disk. */
        fun file(context: Context): HistoryDatabase =
            Room.databaseBuilder(context.applicationContext, HistoryDatabase::class.java, FILE_NAME)
                .build()

        /** A throwaway database for tests and previews. Nothing is written to disk. */
        fun inMemory(context: Context): HistoryDatabase =
            Room.inMemoryDatabaseBuilder(context.applicationContext, HistoryDatabase::class.java)
                .build()
    }
}
