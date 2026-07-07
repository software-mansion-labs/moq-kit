# Project Guidance

## Start Here

Read `ARCHITECTURE.md` before making code changes. It is the canonical codemap for layer
boundaries, public API shape, generated artifacts, and architectural invariants.

`README.md` is the public SDK overview and usage guide. Keep it user-facing. Keep agent
operational guidance in this file unless it belongs in the durable architecture document.

## Generated Artifacts

Never manually edit generated UniFFI bindings or binary artifacts. They are either resolved
from upstream packages. See `ARCHITECTURE.md` for the durable generated-artifact invariant.

- iOS generated Swift bindings and XCFramework come from the `moq-dev/moq-swift` Swift
  package dependency, not from local moq-kit build scripts.
- Android generated Kotlin bindings and JNI libraries come from the `dev.moq:moq` Maven
  dependency, not from local moq-kit build scripts.

When unsure about generated FFI types or fields, inspect the resolved generated bindings
(`MoqFFI` from `moq-swift` for iOS, `uniffi.moq` from `dev.moq:moq` for Android), then
make the durable change in Rust `moq-ffi` upstream or the platform wrapper layer.

## Command Surface

Use `mise.toml` and `mise-tasks/` as the source of truth for local commands. Prefer `mise
run ...` over ad hoc build commands because the tasks set up the expected package and build
caches.

Common validation commands:

```bash
mise tasks
mise run ios:check
mise run ios:demo:build
mise run android:check
mise run ios:build
mise run android:build
mise run rust:check
mise run docs:all
```

Use `ios:check` and `android:check` for Swift/Kotlin-only SDK changes. These fast checks
compile the platform SDKs without regenerating bindings or binary artifacts.

Use `ios:demo:build` for iOS demo-app changes. It compiles the `MoQDemo` Xcode project
for a generic iOS simulator without installing or launching the app. `ios:check` only
compiles the Swift package; it does not build the demo app or ReplayKit extension.

Use `ios:build` for the iOS Swift package compile. Use `android:build` when validating
Android SDK packaging or release artifacts.

Avoid bare `swift build` from the repository root for iOS work. It targets the host
platform by default. Use `mise run ios:check` for the iOS simulator package compile
instead.

Useful runtime commands:

```bash
mise run relay:run
mise run ios:run
mise run ios:run --simulator
mise run android:run
```

Use `ios:run` and `ios:run --simulator` for manual runtime smoke tests after the demo
builds successfully. These commands install and launch the demo on a device or simulator.

## Local moq-ffi Development

The committed package setup must keep using published `moq-ffi` artifacts. Do not commit
local path dependencies, generated UniFFI bindings, XCFrameworks, JNI libraries, or
`Package.swift` changes made only for local `vendor/moq` testing.

### Android local moq-ffi

Android local FFI testing uses Maven local plus an intentionally uncommitted
`settings.gradle.kts` edit.

- `mise run android:ffi-local` builds local arm64 `moq-ffi`, publishes `dev.moq:moq` to
  Maven local.
- To make Gradle or Android Studio resolve that local artifact, temporarily add
  `mavenLocal()` before `mavenCentral()` in the relevant `dependencyResolutionManagement`
  repositories block.
- For the Android SDK project, edit `android/moqkit/settings.gradle.kts` locally:

  ```kotlin
  dependencyResolutionManagement {
      repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
      repositories {
          mavenLocal()
          google()
          mavenCentral()
      }
  }
  ```

- For the Android demo, make the same local edit in
  `examples/android/demo/MoQDemo/settings.gradle.kts`. If the demo also builds the included
  SDK project, keep the matching local edit in `android/moqkit/settings.gradle.kts`.
- Before committing, restore any `settings.gradle.kts` files changed only for local FFI
  testing.
- `mise run android:ffi-local --clean` removes the local staged artifacts from
  `vendor/moq`; remove the temporary `mavenLocal()` edits separately.

### iOS local moq-ffi

iOS local FFI testing requires an intentionally uncommitted `Package.swift` edit. SwiftPM
and Xcode do not have a repo-local Gradle-style property that can swap the dependency
without changing the manifest.

1. Run `mise run ios:ffi-local` to build `vendor/moq/swift/MoqFFI.xcframework` and
   `vendor/moq/swift/Sources/MoqFFI/Generated.swift`.
2. Temporarily change `Package.swift` locally, replacing the published dependency:

   ```swift
   .package(url: "https://github.com/moq-dev/moq-swift", from: "0.2.27")
   ```

   with:

   ```swift
   .package(name: "moq-swift", path: "vendor/moq/swift")
   ```

3. If local code needs APIs that are not in the published package, add this temporary
   setting to the `MoQKit` target:

   ```swift
   swiftSettings: [.define("MOQKIT_LOCAL_MOQ_FFI")]
   ```

4. Build from Xcode or run the usual iOS mise tasks. Before committing, restore
   `Package.swift` and any changed `Package.resolved` files.
5. Use `mise run ios:ffi-local --clean` to remove local iOS FFI artifacts when done.

## Platform Notes

### iOS

- UniFFI low-level errors are named `MoqError` with a lowercase `q`.
- Use `try?` for best-effort cleanup `close()` calls when existing code follows that pattern.

### Android

- Current SDK module settings are AGP 9.0.1, Kotlin 2.0.21, `compileSdk 35`, and `minSdk 29`.
- Use coroutine, `Flow`, lifecycle-owned scope, and Android media API patterns consistent
  with the surrounding code.

### Rust

- Use `--package moq-ffi` for upstream UniFFI-related Rust builds in `vendor/moq`.
- Use `--profile release-with-debug` when debug symbols are needed.

## Examples And Tests

Formal test coverage is limited; see `ARCHITECTURE.md` for the current testing model. Use
the native demos as integration references when validating end-to-end relay, publish,
playback, and data-track workflows.

- iOS demo: `examples/ios/demo/MoQDemo/`
- Android demo: `examples/android/demo/MoQDemo/`
