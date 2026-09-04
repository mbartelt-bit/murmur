package com.murmur.app

import app.murmur.core.CleanResult
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * JVM unit tests cannot load `libmurmur_core.so`, so they cover the pure Kotlin
 * around the FFI. The FFI itself is exercised on the emulator (see README.md).
 */
class CoreClientTest {
    @Test
    fun `formatCleaned prefixes the cleaned text`() {
        val result = CleanResult("um hi", "Hi.", false)
        assertEquals("Cleaned: Hi.", formatCleaned(result))
    }

    @Test
    fun `formatCleaned uses clean not raw`() {
        val result = CleanResult(raw = "um hello world", clean = "Hello world.", usedCloud = false)
        assertEquals("Cleaned: Hello world.", formatCleaned(result))
    }
}
