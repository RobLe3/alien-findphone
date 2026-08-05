#!/usr/bin/env bash
# Build a universal macOS archive directory into ./dist/alien-findphone (or $1).
#
# Builds arm64 and x86_64 single-arch binaries and joins them with lipo so the
# executable bundle continues to be self-contained next to SwiftPM resources.
set -euo pipefail

DEPLOYMENT_TARGET=13
OUT="${1:-dist}"
APP_DIR="$OUT/alien-findphone"
BUNDLE_NAME="findphone_findphone.bundle"

for arch in arm64 x86_64; do
    echo "==> building $arch"
    swift build -c release \
        --scratch-path ".build-$arch" \
        -Xswiftc -target -Xswiftc "$arch-apple-macos$DEPLOYMENT_TARGET"
done

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"

lipo -create -output "$APP_DIR/findphone" \
    ".build-arm64/release/findphone" \
    ".build-x86_64/release/findphone"

bundle_source=""
for candidate in ".build-arm64" ".build-x86_64"; do
    found="$({
        find "$candidate" -type d -name "$BUNDLE_NAME" -print -quit || true
    })"
    if [ -n "$found" ]; then
        bundle_source="$found"
        break
    fi
done

if [ -z "$bundle_source" ]; then
    echo "error: required resource bundle '$BUNDLE_NAME' not found" >&2
    exit 1
fi

cp -R "$bundle_source" "$APP_DIR/"

test -f "$APP_DIR/$BUNDLE_NAME/alien_original_motion_tracker.m4a"

test -x "$APP_DIR/findphone"
if ! lipo "$APP_DIR/findphone" -verify_arch arm64; then
    echo "error: arm64 architecture missing from universal executable" >&2
    exit 1
fi

if ! lipo "$APP_DIR/findphone" -verify_arch x86_64; then
    echo "error: x86_64 architecture missing from universal executable" >&2
    exit 1
fi
"$APP_DIR/findphone" --help >/dev/null

echo "==> built $APP_DIR/findphone"
lipo -info "$APP_DIR/findphone"
