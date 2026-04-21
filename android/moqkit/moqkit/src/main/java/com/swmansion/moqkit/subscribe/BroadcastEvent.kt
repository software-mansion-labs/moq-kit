package com.swmansion.moqkit.subscribe

import com.swmansion.moqkit.Session

/**
 * Lifecycle event emitted on [Session.broadcasts] for a single broadcast path.
 */
sealed class BroadcastEvent {
    /**
     * A broadcast became available or its catalog was updated.
     *
     * @property info The latest catalog snapshot for this broadcast.
     */
    data class Available(val info: BroadcastInfo) : BroadcastEvent()

    /**
     * A broadcast is no longer available (publisher disconnected or path unannounced).
     *
     * @property path The broadcast path that went away.
     */
    data class Unavailable(val path: String) : BroadcastEvent()
}
