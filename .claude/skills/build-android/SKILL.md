---
name: build-android
description: Build Android Kotlin bindings and AAR
---

# Build Android

Run the following steps sequentially:

## 1. Build JNI shared library + Kotlin bindings (Rust → UniFFI → .so + Kotlin)
```bash
./scripts/build-android.sh
```
This compiles Rust via `cargo ndk` for `arm64-v8a`, runs `uniffi-bindgen` to generate Kotlin bindings, and copies the `.so` into `android/moqkit/MoQKit/src/main/jniLibs/`.

## 2. Assemble AAR and copy to examples
```bash
cd android/moqkit && ./gradlew :MoQKit:manualBuild
```

## 3. Verify
- Confirm `android/moqkit/MoQKit/src/main/jniLibs/arm64-v8a/libuniffi_moq.so` exists
- Confirm Kotlin bindings were generated under `android/moqkit/MoQKit/src/main/java/uniffi/moq/`
- Confirm AAR was copied to the example app's `libs/` directory
- Check Gradle build succeeded with no errors

## Full build shortcut
```bash
./scripts/build-android.sh && cd android/moqkit && ./gradlew :MoQKit:manualBuild
```
Runs both steps above.
