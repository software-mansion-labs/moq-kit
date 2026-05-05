# Project Guidance

## Start Here

Read `ARCHITECTURE.md` before making code changes. It is the canonical codemap for layer
boundaries, public API shape, generated artifacts, and architectural invariants.

`README.md` is the public SDK overview and usage guide. Keep it user-facing. Keep agent
operational guidance in this file unless it belongs in the durable architecture document.

## Generated Artifacts

Never manually edit generated UniFFI bindings or binary artifacts. They are overwritten by
FFI build tasks. See `ARCHITECTURE.md` for the durable generated-artifact invariant.

- iOS generated Swift binding: `ios/Sources/MoQKitFFI/moq.swift`
- iOS generated XCFramework: `ios/Frameworks/moqffi.xcframework`
- Android generated Kotlin bindings: `android/moqkit/moqkit/src/main/java/uniffi/moq/`
- Android generated JNI libraries: `android/moqkit/moqkit/src/main/jniLibs/`

When unsure about generated FFI types or fields, inspect the generated bindings, then make
the durable change in Rust `moq-ffi` or the platform wrapper layer and regenerate.

## Command Surface

Use `mise.toml` and `mise-tasks/` as the source of truth for local commands. Prefer `mise
run ...` over ad hoc build commands because the tasks also regenerate and place FFI
artifacts correctly.

Common validation commands:

```bash
mise tasks
mise run ios:check
mise run android:check
mise run ios:build
mise run android:build
mise run rust:check
mise run docs:all
```

Use `ios:check` and `android:check` for Swift/Kotlin-only SDK changes. These fast checks
compile the platform SDKs against the currently checked-in/generated FFI artifacts and do
not regenerate bindings or binary artifacts.

Use `ios:build` and `android:build` when validating FFI changes, generated artifacts,
release artifacts, or anything that may depend on rebuilt Rust bindings. These full builds
run the FFI tasks first and overwrite generated outputs.

Avoid bare `swift build` from the repository root for iOS work. It targets the host
platform by default and can fail unless the macOS FFI slice has been generated. Use
`mise run ios:check` for the iOS simulator package compile instead.

Useful runtime commands:

```bash
mise run relay:run
mise run ios:run
mise run ios:run --simulator
mise run android:run
```

For generated bindings only:

```bash
mise run ios:ffi
mise run android:ffi
```

## Platform Notes

### iOS

- UniFFI low-level errors are named `MoqError` with a lowercase `q`.
- Use `try?` for best-effort cleanup `close()` calls when existing code follows that pattern.

### Android

- Current SDK module settings are AGP 9.0.1, Kotlin 2.0.21, `compileSdk 35`, and `minSdk 29`.
- Use coroutine, `Flow`, lifecycle-owned scope, and Android media API patterns consistent
  with the surrounding code.

### Rust

- Use `--package moq-ffi` for UniFFI-related Rust builds.
- Use `--profile release-with-debug` when debug symbols are needed.

## Examples And Tests

Formal test coverage is limited; see `ARCHITECTURE.md` for the current testing model. Use
the native demos as integration references when validating end-to-end relay, publish,
playback, and data-track workflows.

- iOS demo: `examples/ios/demo/MoQDemo/`
- Android demo: `examples/android/demo/MoQDemo/`
