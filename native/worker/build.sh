#!/bin/sh
set -eu
src=$(cd "$(dirname "$0")" && pwd)
out=${1:?Usage: native/worker/build.sh destination-directory}
mkdir -p "$out"
cache=${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/foi-surround-swift-cache}
mkdir -p "$cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -module-cache-path "$cache" -parse-as-library "$src/Worker.swift" -o "$out/FOIPlaybackWorker"
