#!/bin/sh
set -eu
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dest=${1:?Pass the app playback resources directory}
mkdir -p "$dest"
install -m 755 "$src/resolve-audio" "$dest/resolve-audio"
install -m 644 "$src/resolve.py" "$src/yt-dlp.pyz" "$src/YT-DLP-LICENSE.txt" "$dest/"
