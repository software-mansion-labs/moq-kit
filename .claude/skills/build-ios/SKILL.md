---
name: build-ios
description: Build iOS XCFramework and Swift package
---

# Build iOS

Run the following steps sequentially:

## 1. Build XCFramework (Rust → UniFFI → XCFramework)
```bash
./scripts/build-xcframework.sh
```
This compiles Rust for `aarch64-apple-ios` and `aarch64-apple-ios-sim`, runs `uniffi-bindgen` to generate `ios/Sources/MoQKit/moq.swift`, and creates `ios/Frameworks/libmoq.xcframework`.

## 2. Build Swift package
```bash
swift build --package-path ios --sdk iphonesimulator --triple arm64-apple-ios16.0-simulator
```

## 3. Verify
- Confirm `ios/Frameworks/libmoq.xcframework/` exists
- Confirm `ios/Sources/MoQKit/moq.swift` was freshly generated
- Check the Swift build succeeded with no errors

## Full build shortcut
```bash
./scripts/build-ios.sh
```
Runs both steps above.
