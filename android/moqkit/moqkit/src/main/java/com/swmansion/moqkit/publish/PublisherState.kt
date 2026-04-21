package com.swmansion.moqkit.publish

sealed class PublisherState {
    object Idle : PublisherState()
    object Publishing : PublisherState()
    object Stopped : PublisherState()
    data class Error(val message: String) : PublisherState()
}

sealed class PublisherEvent {
    data class TrackStarted(val name: String) : PublisherEvent()
    data class TrackStopped(val name: String) : PublisherEvent()
    data class TrackError(val name: String, val message: String) : PublisherEvent()
}

enum class PublishedTrackState { Idle, Starting, Active, Stopped }
