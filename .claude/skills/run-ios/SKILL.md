---
name: run-ios
description: Build and run the iOS subscriber demo on a connected device
---

# Run iOS Subscriber Demo

## Quick run

```bash
mise run run-ios
```

Builds XCFramework, detects a connected device, builds the Xcode project, installs and launches the app.

To target a simulator instead:

```bash
mise run run-ios -- --simulator
```
