package com.swmansion.moqkit.publish

sealed class MoQPublisherState {
    object Idle : MoQPublisherState()
    object Publishing : MoQPublisherState()
    object Stopped : MoQPublisherState()
    data class Error(val message: String) : MoQPublisherState()
}

sealed class MoQPublisherEvent {
    data class TrackStarted(val name: String) : MoQPublisherEvent()
    data class TrackStopped(val name: String) : MoQPublisherEvent()
    data class TrackError(val name: String, val message: String) : MoQPublisherEvent()
}

enum class MoQPublishedTrackState { Idle, Starting, Active, Stopped }
