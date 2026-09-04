package com.murmur.app

import androidx.test.core.app.ApplicationProvider
import com.murmur.app.data.history.HistoryDatabase
import com.murmur.app.data.history.HistoryStore
import com.murmur.app.data.history.TranscriptEntity
import com.murmur.app.data.history.TranscriptSource
import com.murmur.app.ui.history.HistoryViewModel
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The History screen's list, search and delete, over a real (in-memory) Room database — the
 * search runs in SQLite, so a fake DAO would be testing the wrong thing.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class HistoryViewModelTest {

    private lateinit var database: HistoryDatabase
    private lateinit var store: HistoryStore
    private lateinit var model: HistoryViewModel

    @Before
    fun setUp() {
        database = HistoryDatabase.inMemory(ApplicationProvider.getApplicationContext())
        store = HistoryStore(database.transcripts())
        model = HistoryViewModel(store)
    }

    @After
    fun tearDown() {
        database.close()
    }

    private suspend fun seed() {
        store.insert(
            TranscriptEntity(
                rawText = "um so can you send me the deck",
                cleanText = "Can you send me the deck?",
                source = TranscriptSource.IN_APP.id,
                createdAt = 1_000,
            ),
        )
        store.insert(
            TranscriptEntity(
                rawText = "picking up milk and uh coffee",
                cleanText = "Picking up milk and coffee.",
                source = TranscriptSource.KEYBOARD.id,
                createdAt = 2_000,
            ),
        )
    }

    @Test
    fun `reload lists everything, newest first`() = runTest {
        seed()

        model.reload()

        assertEquals(2, model.items.size)
        assertEquals("Picking up milk and coffee.", model.items.first().cleanText)
    }

    @Test
    fun `an empty history lists nothing`() = runTest {
        model.reload()

        assertTrue(model.items.isEmpty())
    }

    @Test
    fun `search filters on the cleaned text`() = runTest {
        seed()

        model.query = "milk"
        model.reload()

        assertEquals(1, model.items.size)
        assertEquals("Picking up milk and coffee.", model.items.single().cleanText)
    }

    @Test
    fun `search also finds words the cleanup pass removed`() = runTest {
        seed()

        // "um" survives only in the raw transcript.
        model.query = "um so"
        model.reload()

        assertEquals(1, model.items.size)
        assertEquals("Can you send me the deck?", model.items.single().cleanText)
    }

    @Test
    fun `a query that matches nothing empties the list`() = runTest {
        seed()

        model.query = "helicopter"
        model.reload()

        assertTrue(model.items.isEmpty())
    }

    @Test
    fun `a whitespace-only query is not a filter`() = runTest {
        seed()

        model.query = "   "
        model.reload()

        assertEquals(2, model.items.size)
    }

    @Test
    fun `delete removes the row and reloads`() = runTest {
        seed()
        model.reload()
        val target = model.items.first()

        model.delete(target.id)

        assertEquals(1, model.items.size)
        assertEquals("Can you send me the deck?", model.items.single().cleanText)
        assertEquals(1, store.list().size)
    }

    @Test
    fun `deleting the row whose raw text is showing closes it`() = runTest {
        seed()
        model.reload()
        val target = model.items.first()
        model.toggleRaw(target.id)
        assertEquals(target.id, model.rawShownId)

        model.delete(target.id)

        assertNull(model.rawShownId)
    }

    @Test
    fun `show raw toggles one row at a time`() = runTest {
        seed()
        model.reload()
        val (newest, oldest) = model.items

        model.toggleRaw(newest.id)
        assertEquals(newest.id, model.rawShownId)

        model.toggleRaw(oldest.id)
        assertEquals(oldest.id, model.rawShownId)

        model.toggleRaw(oldest.id)
        assertNull(model.rawShownId)
    }

    @Test
    fun `delete respects the current search`() = runTest {
        seed()
        model.query = "milk"
        model.reload()
        val target = model.items.single()

        model.delete(target.id)

        assertTrue(model.items.isEmpty())
        // The other row is still there — it simply does not match "milk".
        assertEquals(1, store.list().size)
    }
}
