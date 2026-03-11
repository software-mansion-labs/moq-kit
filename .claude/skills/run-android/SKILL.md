---
name: run-android
description: Build and run the Android subscriber demo on a connected device
---

# Run Android Subscriber Demo

## Quick run
```bash
mise run run-android
```
Builds the AAR, installs the debug APK, and launches the app.

## Manual steps (if needed)

### 1. Build library AAR
```bash
mise run android:aar
```

### 2. Check for connected device
```bash
adb devices
```
Prefer a **real device** over an emulator. If no device is connected, inform the user.

### 3. Build and install
```bash
mise run android:install
```

### 4. Launch
```bash
mise run android:launch
```
