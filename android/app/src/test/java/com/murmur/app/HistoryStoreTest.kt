package com.murmur.app

import androidx.test.core.app.ApplicationProvider
import com.murmur.app.data.history.HistoryDatabase
import com.murmur.app.data.history.HistoryStore
import com.murmur.app.data.history.TranscriptEntity
import com.murmur.app.data.history.TranscriptSource
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class HistoryStoreTest {

    private lateinit var db: HistoryDatabase
    private lateinit var store: HistoryStore

    @Before
    fun setUp() {
        db = HistoryDatabase.inMemory(ApplicationProvider.getApplicationContext())
        store = HistoryStore(db.transcripts())
    }

    @After
    fun tearDown() {
        db.close()
    }

    private suspend fun add(raw: String, clean: String, source: TranscriptSource = TranscriptSource.KEYBOARD) =
        store.insert(
            TranscriptEntity(rawText = raw, cleanText = clean, source = source.id, createdAt = 1_000L),
        )

    @Test
    fun `insert returns the row with its assigned id`() = runTest {
        val saved = add("um hello world", "Hello world.", TranscriptSource.IN_APP)

        assertTrue(saved.id > 0)
        assertEquals("um hello world", saved.rawText)
        assertEquals("Hello world.", saved.cleanText)
        assertEquals("in-app", saved.source)
        assertEquals(1_000L, saved.createdAt)
    }

    @Test
    fun `list is newest first and honours the limit`() = runTest {
        add("one", "One.")
        add("two", "Two.")
        add("three", "Three.")

        assertEquals(listOf("Three.", "Two.", "One."), store.list().map { it.cleanText })
        assertEquals(listOf("Three.", "Two."), store.list(limit = 2).map { it.cleanText })
    }

    @Test
    fun `search matches the cleaned or the raw text`() = runTest {
        add("um call the dentist", "Call the dentist.")
        add("buy milk", "Buy milk.")

        assertEquals(listOf("Call the dentist."), store.list(query = "dentist").map { it.cleanText })
        // "um" only survives in the raw column, and the search still finds it.
        assertEquals(listOf("Call the dentist."), store.list(query = "um call").map { it.cleanText })
        // Case-insensitive for ASCII, which is what the search field wants.
        assertEquals(listOf("Buy milk."), store.list(query = "MILK").map { it.cleanText })
        assertEquals(emptyList<String>(), store.list(query = "helicopter").map { it.cleanText })
    }

    @Test
    fun `a blank query lists everything`() = runTest {
        add("one", "One.")
        add("two", "Two.")

        assertEquals(2, store.list(query = "   ").size)
        assertEquals(2, store.list(query = null).size)
    }

    @Test
    fun `delete removes only that row`() = runTest {
        val first = add("one", "One.")
        add("two", "Two.")

        store.delete(first.id)

        assertEquals(listOf("Two."), store.list().map { it.cleanText })
    }

    @Test
    fun `recent returns the n newest`() = runTest {
        add("one", "One.")
        add("two", "Two.")
        add("three", "Three.")

        assertEquals(listOf("Three.", "Two."), store.recent(2).map { it.cleanText })
    }

    @Test
    fun `observeRecent emits the newest rows`() = runTest {
        add("one", "One.")
        add("two", "Two.")

        assertEquals(listOf("Two.", "One."), store.observeRecent(3).first().map { it.cleanText })
    }
}
