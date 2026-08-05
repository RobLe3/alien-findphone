#!/usr/bin/env bash
# Build a universal macOS archive directory into ./dist/alien-findphone (or $1).
#
# Builds arm64 and x86_64 single-arch binaries and joins them with lipo so the
# executable bundle continues to be self-contained next to SwiftPM resources.
set -euo pipefail

DEPLOYMENT_TARGET=13
OUT="${1:-dist}"
APP_DIR="$OUT/alien-findphone"

for arch in arm64 x86_64; do
    echo "==> building $arch"
    swift build -c release \
        --scratch-path ".build-$arch" \
        -Xswiftc -target -Xswiftc "$arch-apple-macos$DEPLOYMENT_TARGET"
 done

mkdir -p "$APP_DIR"

lipo -create -output "$APP_DIR/findphone" \
    ".build-arm64/release/findphone" \
    ".build-x86_64/release/findphone"

bundle_source=""
for candidate in ".build-arm64" ".build-x86_64"; do
    found="$(find "$candidate" -name '*.bundle' -type d | head -n 1 || true)"
    if [ -n "$found" ]; then
        bundle_source="$found"
        break
    fi
done

if [ -n "$bundle_source" ]; then
    cp -R "$bundle_source" "$APP_DIR/"
    echo "==> copied resource bundle $(basename "$bundle_source")"
else
    echo "warning: no target resource bundle found in release build directories"
fi

chmod +x "$APP_DIR/findphone"
echo "==> built $APP_DIR/findphone"
lipo -info "$APP_DIR/findphone"
