#!/usr/bin/env bash
# Build a universal macOS binary into ./dist (or $1).
#
# Two single-arch builds joined with lipo, rather than SwiftPM's --arch, which
# requires a full Xcode install and fails on a machine with only the Command
# Line Tools.
set -euo pipefail

DEPLOYMENT_TARGET=13
OUT="${1:-dist}"

for arch in arm64 x86_64; do
    echo "==> building $arch"
    swift build -c release \
        --scratch-path ".build-$arch" \
        -Xswiftc -target -Xswiftc "$arch-apple-macos$DEPLOYMENT_TARGET"
done

mkdir -p "$OUT"
lipo -create -output "$OUT/findphone" \
    ".build-arm64/release/findphone" \
    ".build-x86_64/release/findphone"

echo "==> built $OUT/findphone"
lipo -info "$OUT/findphone"
