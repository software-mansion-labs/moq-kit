#!/usr/bin/env bash
set -euo pipefail

# Build moq-ffi for Android (arm64-v8a), generate UniFFI Kotlin bindings,
# and place outputs under moq-kit/android/.
#
# Usage: ./scripts/build-android.sh [--debug]
#
#   --debug  Build Rust with debug symbols (debug profile)
#
# Produces:
#   android/jniLibs/arm64-v8a/moq_ffi.so
#   android/uniffi/ (Kotlin bindings)

DEBUG=0
for arg in "$@"; do
  case "$arg" in
  --debug) DEBUG=1 ;;
  *)
    echo "Unknown argument: $arg" >&2
    exit 1
    ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_CARGO="$ROOT_DIR/vendor/moq/Cargo.toml"
TARGET_BASE="$ROOT_DIR/vendor/moq/target"
ANDROID_OUT="$ROOT_DIR/android/moqkit/MoQKit/src/main"

if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "Error: cargo-ndk is not installed. Install with: cargo install cargo-ndk" >&2
  exit 1
fi

# if ! command -v uniffi-bindgen >/dev/null 2>&1; then
#   echo "Error: uniffi-bindgen is not installed. Install with: cargo install uniffi_bindgen" >&2
#   exit 1
# fi
TARGETS=(
  aarch64-linux-android
)

# --- Install Rust targets if missing ---

echo "Checking Rust targets..."
INSTALLED=$(rustup target list --installed)
for target in "${TARGETS[@]}"; do
  if ! echo "$INSTALLED" | grep -q "^${target}$"; then
    echo "Installing Rust target: $target"
    rustup target add "$target"
  fi
done

resolve_ndk() {
  if [[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]]; then
    echo "$ANDROID_NDK_HOME"
    return 0
  fi

  local sdk_root=""
  if [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
    sdk_root="$ANDROID_SDK_ROOT"
  elif [[ -n "${ANDROID_HOME:-}" ]]; then
    sdk_root="$ANDROID_HOME"
  fi

  if [[ -z "$sdk_root" ]]; then
    if [[ -d "$HOME/Library/Android/sdk" ]]; then
      sdk_root="$HOME/Library/Android/sdk"
    elif [[ -d "$HOME/Android/Sdk" ]]; then
      sdk_root="$HOME/Android/Sdk"
    elif [[ -d "$HOME/AppData/Local/Android/Sdk" ]]; then
      sdk_root="$HOME/AppData/Local/Android/Sdk"
    fi
  fi

  if [[ -n "$sdk_root" ]]; then
    if [[ -d "$sdk_root/ndk" ]]; then
      local latest_ndk
      latest_ndk="$(ls -1 "$sdk_root/ndk" 2>/dev/null | sort -V | tail -n 1)"
      if [[ -n "$latest_ndk" && -d "$sdk_root/ndk/$latest_ndk" ]]; then
        echo "$sdk_root/ndk/$latest_ndk"
        return 0
      fi
    fi
    if [[ -d "$sdk_root/ndk-bundle" ]]; then
      echo "$sdk_root/ndk-bundle"
      return 0
    fi
  fi

  return 1
}

check_ndk_version() {
  local ndk_dir="$1"
  echo "NDK DIR $ndk_dir"
  local props="$ndk_dir/source.properties"
  if [[ ! -f "$props" ]]; then
    return 0
  fi
  local rev
  rev="$(sed -n 's/^Pkg\\.Revision[[:space:]]*=[[:space:]]*//p' "$props" | head -n 1 | tr -d '[:space:]')"
  if [[ -z "$rev" ]]; then
    return 0
  fi
  local major="${rev%%.*}"
  # if [[ "$major" =~ ^[0-9]+$ && "$major" -lt 23 ]]; then
  #   echo "Error: NDK version $rev at $ndk_dir is not supported. Install NDK r23+ and point ANDROID_NDK_HOME to it." >&2
  #   return 2
  # fi
  return 0
}

if ! NDK_DIR="$(resolve_ndk)"; then
  echo "Error: Android NDK not found. Set ANDROID_NDK_HOME or ANDROID_SDK_ROOT/ANDROID_HOME." >&2
  exit 1
fi
export ANDROID_NDK_HOME="$NDK_DIR"
if ! check_ndk_version "$NDK_DIR"; then
  exit 1
fi

if [[ $DEBUG -eq 1 ]]; then
  CARGO_PROFILE="debug"
  PROFILE_FLAGS=""
  echo "Building in debug mode"
else
  CARGO_PROFILE="release"
  PROFILE_FLAGS="--release"
fi

echo "==> Building host library for UniFFI metadata..."
cargo build $PROFILE_FLAGS --package moq-ffi \
  --manifest-path "$WORKSPACE_CARGO"

echo "==> Generating Kotlin bindings..."
UNIFFI_OUT="$ANDROID_OUT/java"
mkdir -p "$UNIFFI_OUT"

case "$(uname -s)" in
Darwin) HOST_LIB_EXT="dylib" ;;
Linux) HOST_LIB_EXT="so" ;;
MINGW* | MSYS* | CYGWIN*) HOST_LIB_EXT="dll" ;;
*) HOST_LIB_EXT="so" ;;
esac

HOST_LIB=""
for candidate in \
  "$TARGET_BASE/$CARGO_PROFILE/moq_ffi.$HOST_LIB_EXT"; do
  if [[ -f "$candidate" ]]; then
    HOST_LIB="$candidate"
    break
  fi
done

if [[ -z "$HOST_LIB" ]]; then
  HOST_LIB="$(find "$TARGET_BASE/$CARGO_PROFILE" -maxdepth 1 -type f \( -name 'libmoq_ffi.*' -o -name 'moq_ffi.*' \) | head -n 1)"
fi

if [[ -z "$HOST_LIB" || ! -f "$HOST_LIB" ]]; then
  echo "Error: host library not found under $TARGET_BASE/$CARGO_PROFILE" >&2
  exit 1
fi

(cd "$ROOT_DIR/vendor/moq" &&
  cargo run $PROFILE_FLAGS --package moq-ffi --bin uniffi-bindgen \
    --manifest-path "$WORKSPACE_CARGO" \
    generate \
    --library "$HOST_LIB" \
    --language kotlin \
    --out-dir "$UNIFFI_OUT")

echo "==> Building Android shared library (arm64-v8a)..."
mkdir -p "$ANDROID_OUT/jniLibs"
(cd "$ROOT_DIR/vendor/moq" &&
  cargo ndk -t arm64-v8a -o "$ANDROID_OUT/jniLibs" \
    build $PROFILE_FLAGS --package moq-ffi \
    --manifest-path "$WORKSPACE_CARGO")

echo ""
echo "Done."
echo "JNI library: $ANDROID_OUT/jniLibs/arm64-v8a/moq_ffi.so"
echo "Kotlin bindings: $UNIFFI_OUT"
