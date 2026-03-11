---
name: run-android
description: Build and run the Android subscriber demo on a connected device
---

# Run Android Subscriber Demo

## 1. Build library AAR
```bash
cd android/moqkit && ./gradlew :MoQKit:manualBuild
```

## 2. Check for connected device
```bash
adb devices
```
Prefer a **real device** over an emulator. If no device is connected, inform the user.

## 3. Build and install
```bash
cd examples/android/subscriber/MoQSubscriber && ./gradlew installDebug
```

## 4. Launch
```bash
adb shell am start -n com.swmansion.moqsubscriber/.MainActivity
```
