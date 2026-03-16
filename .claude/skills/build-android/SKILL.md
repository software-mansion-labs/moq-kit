---
name: build-android
description: Build Android Kotlin bindings, moq library and final library AAR file
---

# Build Android

Run the following steps sequentially:

## 1. Build JNI shared library + Kotlin bindings (Rust → UniFFI → .so + Kotlin)

```bash
mise run build-android
```

This compiles Rust via `cargo ndk` for `arm64-v8a`, runs `uniffi-bindgen` to generate Kotlin bindings, and copies the `.so` into `android/moqkit/MoQKit/src/main/jniLibs/`.

## 2. Assemble AAR and copy to examples

```bash
mise run android:aar
```

## 3. Verify

- Confirm `android/moqkit/MoQKit/src/main/jniLibs/arm64-v8a/libuniffi_moq.so` exists
- Confirm Kotlin bindings were generated under `android/moqkit/MoQKit/src/main/java/uniffi/moq/`
- Confirm AAR was copied to the example app's `libs/` directory
- Check Gradle build succeeded with no errors

## Full build shortcut

```bash
mise run android:build
```

Runs both steps above.
