#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
APP="$ROOT/dist/FSearch.app"
ENGINE="${FSEARCH_BINARY:-$ROOT/target/release/fsearch}"
GUI_ONLY=false
if [[ "${1:-}" == "--gui-only" ]]; then
    GUI_ONLY=true
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--gui-only]" >&2
    exit 1
fi

if [[ "$GUI_ONLY" == false ]]; then
    if [[ -n "${FSEARCH_BINARY:-}" ]]; then
        if [[ ! -x "$ENGINE" ]]; then
            echo "FSEARCH_BINARY must point to an executable fsearch engine." >&2
            exit 1
        fi
    else
        if ! command -v cargo >/dev/null 2>&1; then
            echo "Install Rust, or set FSEARCH_BINARY to an existing fsearch executable." >&2
            exit 1
        fi
        (
            cd "$ROOT"
            # Override target-cpu=native so the app runs on older Apple Silicon Macs.
            if [[ "$(uname -m)" == arm64 ]]; then
                export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=apple-m1}"
            fi
            cargo build --release --locked
        )
    fi
fi

if [[ "$GUI_ONLY" == false ]]; then
    ENGINE_HELP="$("$ENGINE" --help 2>&1)"
    if [[ "$ENGINE_HELP" != *"embedded-gui"* ]]; then
        echo "The engine must support embedded-gui. Rebuild it from the current source." >&2
        exit 1
    fi
fi

swift build --disable-sandbox --package-path "$ROOT/macos" -c release -debug-info-format none
BIN_DIR="$(swift build --disable-sandbox --package-path "$ROOT/macos" -c release -debug-info-format none --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FSearchGUI" "$APP/Contents/MacOS/FSearchGUI"
if [[ "$GUI_ONLY" == false ]]; then
    cp "$ENGINE" "$APP/Contents/MacOS/fsearch"
    codesign --force --sign - --identifier io.fsearch.engine "$APP/Contents/MacOS/fsearch"
else
    # Do not leave a previously bundled engine in a GUI-only build.
    rm -f "$APP/Contents/MacOS/fsearch"
fi
# Remove the helper location used by older GUI builds.
rm -f "$APP/Contents/Resources/fsearch"
cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/macos/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
