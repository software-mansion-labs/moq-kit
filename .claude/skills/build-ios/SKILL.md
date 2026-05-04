---
name: build-ios
description: Build iOS XCFramework and Swift package
---

# Build iOS

Run the following steps sequentially:

## 1. Build XCFramework (Rust -> UniFFI -> XCFramework)

```bash
mise run ios:ffi
```

This compiles Rust for `aarch64-apple-ios` and `aarch64-apple-ios-sim`, runs `uniffi-bindgen` to generate `ios/Sources/MoQKitFFI/moq.swift`, and creates `ios/Frameworks/moqffi.xcframework`.

## 2. Build Swift package

```bash
mise run ios:build
```

## 3. Verify

- Confirm `ios/Frameworks/moqffi.xcframework/` exists
- Confirm `ios/Sources/MoQKitFFI/moq.swift` was freshly generated
- Check the Swift build succeeded with no errors

## Full build shortcut

```bash
mise run ios:build
```

Runs both steps above.
