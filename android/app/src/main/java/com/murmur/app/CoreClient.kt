package com.murmur.app

import app.murmur.core.CleanResult
import app.murmur.core.Provider
import app.murmur.core.cleanText
import app.murmur.core.keyPageUrl

/**
 * Thin Kotlin facade over the UniFFI bindings generated from `murmur-core`.
 *
 * Every call here crosses the FFI into `libmurmur_core.so`, so nothing in this
 * object can run in a plain JVM unit test — the emulator is the check for it.
 */
object CoreClient {
    fun groqKeyPage(): String = keyPageUrl(Provider.GROQ)

    suspend fun cleanLocally(raw: String): CleanResult = cleanText(raw, null)
}
