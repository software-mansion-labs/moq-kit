---
name: build-ios
description: Build iOS Swift package
---

# Build iOS

Run the Swift package build:

```bash
mise run ios:build
```

This compiles the MoQKit Swift package for the iOS simulator and resolves the upstream
`moq-dev/moq-swift` package for `MoqFFI`.

## Verify

- Check the Swift build succeeded with no errors
