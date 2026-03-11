---
name: run-ios
description: Build and run the iOS subscriber demo on a connected device
---

# Run iOS Subscriber Demo

## 1. Build XCFramework
```bash
./scripts/build-xcframework.sh
```

## 2. Detect connected device
```bash
xcrun xctrace list devices
```
Prefer a **real device** over a simulator. Parse the output to find the device UDID.

## 3. Build
```bash
xcodebuild -project examples/ios/subscriber/MoQSubscriber.xcodeproj \
  -scheme MoQSubscriber \
  -sdk iphoneos \
  -destination "id=<DEVICE_UDID>" \
  build
```
Replace `<DEVICE_UDID>` with the actual device ID from step 2.

If no real device is connected, fall back to a simulator:
```bash
xcodebuild -project examples/ios/subscriber/MoQSubscriber.xcodeproj \
  -scheme MoQSubscriber \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  build
```

## 4. Install and launch

### Real device
Find the `.app` path from the build output (typically in `~/Library/Developer/Xcode/DerivedData/MoQSubscriber-*/Build/Products/Debug-iphoneos/MoQSubscriber.app`), then:
```bash
xcrun devicectl device install app --device <DEVICE_UDID> <PATH_TO_APP>
xcrun devicectl device process launch --device <DEVICE_UDID> com.example.MoQSubscriber
```

### Simulator
```bash
xcrun simctl boot "<SIMULATOR_UDID>"
xcrun simctl install "<SIMULATOR_UDID>" <PATH_TO_APP>
xcrun simctl launch "<SIMULATOR_UDID>" com.example.MoQSubscriber
```
