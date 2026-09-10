# Capture and publication: physical-device acceptance

Run the updated publisher demo on one physical iOS device and one physical Android device.
Use a second device's player demo as the subscriber. Exercise both publisher/subscriber
platform combinations with H.264 and supported AAC/Opus configurations.

This checklist is manual acceptance work; simulator tests and demo builds do not verify
camera hardware, privacy indicators, CameraX surface lifetime or audible playback.

## Controls and expected behavior

| Action | Local preview/hardware | Publisher/subscriber |
| --- | --- | --- |
| Open publisher screen | Camera preview starts if Camera is selected | No broadcast or encoder required |
| Publish | Preview continues from the same camera | Camera and mic become active |
| Mute microphone | Microphone stays active | Silence; audio track remains active and catalog unchanged |
| Disable camera publication | Preview stays live | Video disappears from catalog/player; audio continues |
| Enable camera publication | Same preview/capture | Video returns under a fresh catalog track name |
| Disable mic publication | Mic remains explicitly running | Audio disappears; video continues |
| Stop camera capture | Preview stops; SDK releases camera | Video disappears; handle becomes idle if enabled |
| Enable video while camera stopped | Camera stays stopped | Enabled intent is retained, still idle |
| Start camera capture | Same capture object resumes preview | Enabled video republishes automatically |
| Stop/start mic capture | Mic hardware releases/restarts | Enabled audio disappears/returns; mute setting persists |
| Disable both publications | Started hardware remains active | Empty media catalog; broadcast remains discoverable |
| Re-enable both | Same capture objects | Player resumes without manually reselecting the broadcast |
| Stop broadcast | Preview continues | Broadcast ends; all encoders/producers stop |
| Leave publisher screen | Camera/mic released | No old startup task recreates capture/publication |

## Sequences to exercise

- Start a broadcast with both Camera and Microphone initially off. Start each with the
  runtime controls and verify its existing handle becomes active.
- Switch front/back with active video; verify no new video rendition is created for a
  compatible switch. Stop camera, select the other lens, start and verify the selection.
- Toggle publication and hardware repeatedly, including while a transition is pending.
  Controls show progress and prevent overlapping UI commands; errors remain visible.
- Recreate the Android preview surface (navigation/rotation as supported). Video publication
  continues while the preview detaches/reattaches; no stale EGL surface is drawn.
- Background/foreground the publisher and trigger a camera interruption. Verify unavailable
  media leaves the catalog, then returns when the capture resumes.
- Deny camera/microphone permission, retry after granting it, and verify startup reports
  failure without retaining partial hardware or encoders.
- Disconnect the relay during startup and while active; session cleanup ends publication.
  Explicitly started preview remains independent until the screen releases it.
- Leave the screen during startup and during an enable operation. Return and publish again;
  there must be one camera capture and one microphone reader.
- Confirm multicamera preview plus publishing still works on supported devices; confirm
  screen publication and chat/data tracks still start and stop.

## Evidence to record

Record device models, OS versions, codecs, the two platform directions, failures and
reproduction steps. Check catalog track names/counts in the player demo. Use platform
profiling/logging to confirm codec instances are released when publication disables and
camera/microphone resources release after capture stop. OS recent-use indicators may linger
and other app/OS consumers can independently use the device.

Automated gates: `mise run ios:check`, `mise run ios:test`, `mise run android:check`,
`mise run ios:demo:build`, `mise run android:demo:build`.
