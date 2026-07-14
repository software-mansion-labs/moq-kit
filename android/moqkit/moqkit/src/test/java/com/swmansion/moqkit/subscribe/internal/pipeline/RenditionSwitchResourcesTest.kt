package com.swmansion.moqkit.subscribe.internal.pipeline

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class RenditionSwitchResourcesTest {
    @Test
    fun activationClosesOldResourceAndPromotesPendingResource() {
        val closed = mutableListOf<Resource>()
        val old = Resource("old")
        val pending = Resource("pending")
        val resources = RenditionSwitchResources(old) { closed += it }

        resources.begin(pending)

        assertTrue(resources.activate(pending))
        assertSame(pending, resources.active)
        assertNull(resources.pending)
        assertEquals(listOf(old), closed)
    }

    @Test
    fun abortClosesPendingResourceAndKeepsActiveResource() {
        val closed = mutableListOf<Resource>()
        val old = Resource("old")
        val pending = Resource("pending")
        val resources = RenditionSwitchResources(old) { closed += it }

        resources.begin(pending)

        assertTrue(resources.abort(pending))
        assertSame(old, resources.active)
        assertNull(resources.pending)
        assertEquals(listOf(pending), closed)
    }

    @Test
    fun staleCallbacksCannotChangeNewerPendingResource() {
        val closed = mutableListOf<Resource>()
        val active = Resource("active")
        val first = Resource("first")
        val second = Resource("second")
        val resources = RenditionSwitchResources(active) { closed += it }

        resources.begin(first)
        resources.abort(first)
        resources.begin(second)

        assertEquals(false, resources.activate(first))
        assertSame(active, resources.active)
        assertSame(second, resources.pending)
        assertEquals(listOf(first), closed)
    }

    private data class Resource(val name: String)
}
