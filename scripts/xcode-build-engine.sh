#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${TARGET_BUILD_DIR:?Run this script from the Xcode project}/${CONTENTS_FOLDER_PATH:?}/MacOS/fsearch"
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if [[ -n "${FSEARCH_BINARY:-}" ]]; then
    ENGINE="$FSEARCH_BINARY"
    if [[ ! -x "$ENGINE" ]]; then
        echo "error: FSEARCH_BINARY must point to an executable fsearch engine." >&2
        exit 1
    fi
elif command -v cargo >/dev/null 2>&1; then
    # The project defaults to the build Mac's architecture. Use a portable
    # CPU baseline rather than the repository's target-cpu=native setting.
    if [[ "$(uname -m)" == arm64 ]]; then
        export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=apple-m1}"
    fi
    (cd "$ROOT" && cargo build --release --locked)
    ENGINE="${CARGO_TARGET_DIR:-$ROOT/target}/release/fsearch"
    if [[ "$ENGINE" != /* ]]; then ENGINE="$ROOT/$ENGINE"; fi
elif [[ -x "$ROOT/target/release/fsearch" ]]; then
    ENGINE="$ROOT/target/release/fsearch"
    NEWER_SOURCE="$(find "$ROOT/src" "$ROOT/Cargo.toml" "$ROOT/Cargo.lock" "$ROOT/.cargo/config.toml" -type f -newer "$ENGINE" -print -quit)"
    if [[ -n "$NEWER_SOURCE" ]]; then
        echo "error: The existing fsearch engine is older than the Rust source ($NEWER_SOURCE). Install Rust and rebuild, or set FSEARCH_BINARY to a matching rebuilt engine. Refusing to bundle an outdated engine." >&2
        exit 1
    fi
    echo "warning: Rust is not installed. Bundling the existing target/release/fsearch engine; Rust source changes will not be rebuilt."
else
    echo "error: No Rust toolchain or previously built engine was found. Install Rust with rustup, or set FSEARCH_BINARY to an existing fsearch executable." >&2
    exit 1
fi

ENGINE_HELP="$("$ENGINE" --help 2>&1)"
if [[ "$ENGINE_HELP" != *"embedded-gui"* ]]; then
    echo "error: The engine must support embedded-gui. Rebuild it from the current source." >&2
    exit 1
fi

# Never silently bundle a helper that cannot run on the app's architecture.
for ARCH in ${ARCHS:?}; do
    /usr/bin/lipo -verify_arch "$ARCH" "$ENGINE"
done
mkdir -p "$(dirname "$DESTINATION")"
cp "$ENGINE" "$DESTINATION"
chmod +x "$DESTINATION"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
        --identifier io.fsearch.engine "$DESTINATION"
fi
