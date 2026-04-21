# ReplayKit Broadcast Upload Extension Setup

1. In Xcode, add a new target: `Broadcast Upload Extension`.
2. Replace the generated `SampleHandler.swift` with this folder's `SampleHandler.swift`.
3. Add `MoQKit` Swift package dependency to the extension target.
4. Enable the same App Group for both targets:
   - `MoQPublisher` app target
   - Broadcast Upload Extension target
5. In the app UI, set:
   - `App Group ID` to that shared group
   - `Broadcast Extension Bundle ID` to the extension bundle identifier (recommended)
6. Tap `Prepare ReplayKit Config`, then start broadcast via the system picker.

This uses `MoQReplayKitBroadcastSampleHandler`, which:
- starts an independent MoQ session in the extension process
- prefers setupInfo config when provided
- falls back to App Group descriptor (`relayURL` + `broadcastPath`)
- publishes one screen video track and app audio by default (mic optional)

This flow enables full-device screen sharing that continues when switching apps.
