---
name: build-android
description: Build Android Kotlin bindings, moq library and final library AAR file
---

# Build Android

Run the following steps sequentially:

## 1. Build JNI shared library + Kotlin bindings (Rust -> UniFFI -> .so + Kotlin)

```bash
mise run android:ffi
```

This compiles Rust via `cargo ndk` for `arm64-v8a`, runs `uniffi-bindgen` to generate Kotlin bindings, and copies the `.so` into `android/moqkit/moqkit/src/main/jniLibs/`.

## 2. Assemble AAR

```bash
mise run android:build
```

## 3. Verify

- Confirm `android/moqkit/moqkit/src/main/jniLibs/arm64-v8a/moq_ffi.so` exists
- Confirm Kotlin bindings were generated under `android/moqkit/moqkit/src/main/java/uniffi/moq/`
- Confirm the AAR was built under `android/moqkit/moqkit/build/outputs/aar/`
- Check Gradle build succeeded with no errors

## Full build shortcut

```bash
mise run android:build
```

Runs both steps above.
