package com.swmansion.moqkit.publish

/**
 * Lifecycle state for a [Publisher].
 */
sealed class PublisherState {
    /** Tracks can still be added and publishing has not started. */
    object Idle : PublisherState()

    /** Broadcast is open, including while every media track is disabled or waiting for capture. */
    object Publishing : PublisherState()

    /** Publishing has ended and this publisher should not be reused. */
    object Stopped : PublisherState()

    /**
     * Publishing failed.
     *
     * @property message Human-readable error description.
     */
    data class Error(val message: String) : PublisherState()
}

/**
 * Track-level publishing events emitted by [Publisher.events].
 */
sealed class PublisherEvent {
    /**
     * A track became active.
     *
     * @property name Track name passed to `addVideoTrack`, `addAudioTrack`, or `addDataTrack`.
     */
    data class TrackStarted(val name: String) : PublisherEvent()

    /**
     * A track stopped publishing.
     *
     * @property name Track name.
     */
    data class TrackStopped(val name: String) : PublisherEvent()

    /**
     * A track failed while starting or publishing.
     *
     * @property name Track name.
     * @property message Human-readable error description.
     */
    data class TrackError(val name: String, val message: String) : PublisherEvent()
}

/** Lifecycle state for an individual [PublishedTrack]. */
sealed class PublishedTrackState {
    data object Idle : PublishedTrackState()
    data object Disabled : PublishedTrackState()
    data object Starting : PublishedTrackState()
    data object Active : PublishedTrackState()
    data class Failed(val message: String) : PublishedTrackState()
    data object Stopped : PublishedTrackState()
}
