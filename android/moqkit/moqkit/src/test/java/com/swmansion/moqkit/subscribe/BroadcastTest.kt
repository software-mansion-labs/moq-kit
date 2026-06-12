package com.swmansion.moqkit.subscribe

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.moq.MoqException

class BroadcastTest {
    @Test
    fun catalogNotFoundClassifierMatchesMuxRemoteNotFound() {
        assertTrue(
            MoqException.Mux("moq: remote error: code=13").isCatalogNotFoundError(),
        )
        assertTrue(
            MoqException.Mux("remote error: code=13").isCatalogNotFoundError(),
        )
    }

    @Test
    fun catalogNotFoundClassifierRejectsOtherMuxErrors() {
        assertFalse(
            MoqException.Mux("moq: remote error: code=12").isCatalogNotFoundError(),
        )
        assertFalse(
            MoqException.Mux("moq: remote error: code=130").isCatalogNotFoundError(),
        )
    }

    @Test
    fun catalogNotFoundClassifierRejectsNonMuxErrors() {
        assertFalse(
            MoqException.Protocol("remote error: code=13").isCatalogNotFoundError(),
        )
        assertFalse(
            IllegalStateException("remote error: code=13").isCatalogNotFoundError(),
        )
    }
}
