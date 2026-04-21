package com.swmansion.moqkit.subscribe

/** Base interface for a single media track within a broadcast. */
interface TrackInfo {
    /** Track name as announced in the catalog (e.g. `"video/high"`, `"audio/main"`). */
    val name: String
}
