---
name: build-rust
description: Build Rust moq-ffi for iOS/Android targets
---

# Build Rust

All commands run from the moq-kit root directory.

## iOS targets
```bash
cargo build --release --package moq-ffi --target aarch64-apple-ios
cargo build --release --package moq-ffi --target aarch64-apple-ios-sim
```

## Android targets
```bash
cargo ndk -t arm64-v8a build --release --package moq-ffi
```

## C bindings only (libmoq)
```bash
cargo build --release --package libmoq
```

## Debug symbols
Use `--profile release-with-debug` instead of `--release` to include DWARF debug info.

## Lint and test (inside vendor/moq)
```bash
cd vendor/moq && just check   # tests + linting
cd vendor/moq && just fix     # auto-format
```
