package com.swmansion.moqkit.subscribe.internal.playback

/**
 * Clamps the audio-driven playback clock used for video scheduling so it never advances past the
 * video playhead (the jitter buffer's target playback point, `liveEdge - targetBuffering`).
 *
 * If the audio clock drifts ahead of the video timeline, every decoded frame is judged "late" — at
 * dequeue (marked unplayable) and at render (late-drop) — and the video freezes while audio keeps
 * playing. Clamping to the playhead decouples video pacing from the audio clock so video keeps
 * playing at its own live edge instead of freezing.
 *
 * The ceiling must be the playhead (a frame that is actually buffered), not the extrapolated live
 * edge: the live edge sits ahead of every buffered frame, so clamping to it would still mark every
 * frame unplayable.
 *
 * @param clockUs         current audio-driven clock value (audio time domain).
 * @param videoPlayheadUs video target playback PTS in the same domain, or null when unknown
 *                        (then the clock is returned unchanged).
 */
internal fun clampSchedulingClockToVideoPlayhead(clockUs: Long, videoPlayheadUs: Long?): Long =
    if (videoPlayheadUs != null && clockUs > videoPlayheadUs) videoPlayheadUs else clockUs
