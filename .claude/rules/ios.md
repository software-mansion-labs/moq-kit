---
description: iOS SDK conventions and patterns
globs:
  - "ios/**"
  - "examples/ios/**"
  - "mise-tasks/ios/**"
---

# iOS SDK Rules

## Package Structure
- `Package.swift` — Swift package depending on `moq-dev/moq-swift`
- `ios/Sources/MoQKit` — public Swift SDK and iOS wrapper implementation
- `MoqFFI` — generated UniFFI bindings provided by the resolved `moq-swift` package

## Conventions
- `MoQSession` is `@MainActor`
- Use `try?` on `close()` calls to swallow errors during cleanup
- Error types: `MoQSessionError` (high-level), `MoqError` (low-level UniFFI — note lowercase 'q')
- When in doubt about UniFFI types/fields, read `Sources/MoqFFI/Generated.swift` in the
  resolved `moq-swift` checkout — don't guess
