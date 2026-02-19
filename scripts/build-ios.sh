#!/usr/bin/env bash
set -euo pipefail

# Build libmoq and package as XCFramework, then build the Swift package.
#
# Usage: ./scripts/build-ios.sh [--debug]
#
#   --debug  Build Rust with debug symbols (optimized + DWARF)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Building XCFramework..."
bash "$SCRIPT_DIR/build-xcframework.sh" "$@"

echo ""
echo "==> Building Swift package..."
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
swift build \
    --package-path "$ROOT_DIR/ios" \
    --sdk "$SDK" \
    --triple arm64-apple-ios16.0-simulator

echo ""
echo "Done."
