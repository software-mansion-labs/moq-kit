---
description: Rust crate conventions for vendor/moq
globs:
  - "vendor/**"
---

# Rust / vendor/moq Rules

## Crate Layout

- `vendor/moq/rs/moq-ffi/` — UniFFI bindings crate (used by both iOS and Android)
- `vendor/moq/rs/libmoq/` — pure C bindings crate (separate from UniFFI)
- Always use `--package moq-ffi` for UniFFI builds

## Development

- `cd vendor/moq && just check` — tests + linting
- `cd vendor/moq && just fix` — auto-format
- Use `--profile release-with-debug` instead of `--release` to include DWARF debug symbols
