#!/bin/bash
set -eu -o pipefail

# Builds a local Apple Silicon companion and Safari Web Extension. Set
# CODE_SIGN_IDENTITY to an Apple Development identity for a signed developer build.
root="$(cd "$(dirname "$0")" && pwd)"
host="$root/native/host"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/foi-yt-surround.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
# Store only portable bundle contents in the archive. iCloud Documents sometimes
# attaches FinderInfo to .app and .appex directories after they are copied.
# These attributes are unrelated to the executable/resource signatures.
make_archive() {
    local source="$1" destination="$2" clean extracted pending
    clean="$temporary/export/FOI YouTube Surround.app"
    extracted="$temporary/extracted"
    mkdir -p "$clean" "$extracted" "$(dirname "$destination")"
    /usr/bin/rsync -rltp "$source/" "$clean/"
    /usr/bin/codesign --verify --deep --strict "$clean"
    (cd "$temporary/export" && /usr/bin/zip -q -r -y -X "$temporary/verified.zip" "FOI YouTube Surround.app")
    pending="$(mktemp "$(dirname "$destination")/.foi-export.XXXXXX")"
    if ! cp "$temporary/verified.zip" "$pending" ||
       ! /usr/bin/unzip -oq "$pending" -d "$extracted" ||
       ! /usr/bin/codesign --verify --deep --strict "$extracted/FOI YouTube Surround.app" ||
       ! (cd "$temporary/export" && diff -qr "FOI YouTube Surround.app" "$extracted/FOI YouTube Surround.app"); then
        rm -f "$pending"
        return 1
    fi
    chmod 644 "$pending"
    mv -f "$pending" "$destination"
    printf 'Verified archive %s\n' "$destination"
}

if [[ "${1:-}" == "--archive" ]]; then
    [[ $# == 3 ]] || { echo 'Usage: build.sh --archive EXISTING_APP OUTPUT_ZIP' >&2; exit 2; }
    make_archive "$2" "$3"
    exit
fi
app="${1:-$root/FOI YouTube Surround.app}"
stage="$temporary/FOI YouTube Surround.app"
extension="$stage/Contents/PlugIns/FOIYouTubeSafari.appex"
playback="$stage/Contents/Resources/Playback"
mkdir -p "$stage/Contents/MacOS" "$extension/Contents/MacOS" "$extension/Contents/Resources" "$playback"
export CLANG_MODULE_CACHE_PATH="$temporary/ModuleCache"
swift=(xcrun swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library -module-cache-path "$temporary/ModuleCache" -target arm64-apple-macos13.0)
python3 - "$temporary/SignatureSeed.swift" "$stage" "$extension" <<'PY'
import pathlib, plistlib, secrets, sys
seed, host, extension = map(pathlib.Path,sys.argv[1:])
seed.write_text("import Foundation\nlet signatureSeed = Data([" + ",".join(map(str,secrets.token_bytes(32))) + "])\n")
common = dict(CFBundleInfoDictionaryVersion="6.0", CFBundleVersion="4", CFBundleShortVersionString="1.0.3",
              NSHumanReadableCopyright="Made by Sourish Mukherjee · FOI Studios · 2026",
              CFBundleDevelopmentRegion="en", LSMinimumSystemVersion="13.0")
def info(folder, **values):
    with (folder/"Contents/Info.plist").open("wb") as file: plistlib.dump(dict(common, **values),file)
info(host, CFBundleIdentifier="studio.foi.youtubesurround", CFBundleName="FOI YouTube Surround",
     CFBundleDisplayName="FOI YouTube Surround", CFBundlePackageType="APPL", CFBundleExecutable="FOIYouTubeSurround",
     CFBundleIconFile="AppIcon", NSHighResolutionCapable=True, NSPrincipalClass="NSApplication", LSApplicationCategoryType="public.app-category.video")
info(extension, CFBundleIdentifier="studio.foi.youtubesurround.Extension", CFBundleName="FOI YouTube Surround",
     CFBundleDisplayName="FOI YouTube Surround", CFBundlePackageType="XPC!", CFBundleExecutable="FOIYouTubeSafari",
     NSExtension=dict(NSExtensionPointIdentifier="com.apple.Safari.web-extension",NSExtensionPrincipalClass="SafariWebExtensionHandler"))
PY
cp "$host/Wire.swift" "$host/Companion.swift" "$host/SafariWebExtensionHandler.swift" "$temporary/"
"${swift[@]}" "$temporary/Wire.swift" "$temporary/SignatureSeed.swift" "$temporary/Companion.swift" -o "$stage/Contents/MacOS/FOIYouTubeSurround"
"${swift[@]}" -application-extension "$temporary/Wire.swift" "$temporary/SignatureSeed.swift" "$temporary/SafariWebExtensionHandler.swift" -Xlinker -e -Xlinker _NSExtensionMain -o "$extension/Contents/MacOS/FOIYouTubeSafari"
copy_bundle_tree() {
    python3 - "$1" "$2" <<'PYTHON'
import pathlib, shutil, stat, sys
def copy_file(src, dst):
    shutil.copyfile(src, dst)
    pathlib.Path(dst).chmod(stat.S_IMODE(pathlib.Path(src).stat().st_mode))
    return dst
shutil.copytree(sys.argv[1], sys.argv[2], symlinks=True, dirs_exist_ok=True, copy_function=copy_file)
PYTHON
}
copy_bundle_tree "$root/extension" "$extension/Contents/Resources"
install -m 644 "$host/AppIcon.icns" "$stage/Contents/Resources/AppIcon.icns"
install -m 644 "$root/THIRD-PARTY-NOTICES.md" "$stage/Contents/Resources/THIRD-PARTY-NOTICES.md"
/bin/sh "$root/native/resolver/build.sh" "$playback"
/bin/sh "$root/native/worker/build.sh" "$playback"
test -x "$playback/FOIPlaybackWorker"
test -x "$playback/resolve-audio"
id="${CODE_SIGN_IDENTITY:--}"
/usr/bin/codesign --force --sign "$id" --timestamp=none "$playback/FOIPlaybackWorker"
/usr/bin/codesign --force --sign "$id" --timestamp=none --entitlements "$host/extension.entitlements" "$extension"
/usr/bin/codesign --force --sign "$id" --timestamp=none "$stage"
/usr/bin/codesign --verify --deep --strict "$stage"
mkdir -p "$(dirname "$app")"
# Move existing builds aside until the new bundle has been copied in full.
candidate="$(mktemp -d "$(dirname "$app")/.foi-build.XXXXXX")"
if ! copy_bundle_tree "$stage" "$candidate/FOI YouTube Surround.app"; then
    rm -rf "$candidate"
    exit 1
fi
if [[ -e "$app" ]]; then
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)" != "studio.foi.youtubesurround" ]]; then
        echo "Destination belongs to another app: $app" >&2
        rm -rf "$candidate"
        exit 1
    fi
    mv "$app" "$candidate/previous.app"
fi
if ! mv "$candidate/FOI YouTube Surround.app" "$app"; then
    if [[ -d "$candidate/previous.app" ]]; then mv "$candidate/previous.app" "$app"; fi
    exit 1
fi
rm -rf "$candidate"
# File Provider can attach FinderInfo when registering nested .app/.appex directories.
# Only strip disallowed Finder metadata on the two bundles this build created.
for bundle in "$app" "$app/Contents/PlugIns/FOIYouTubeSafari.appex"; do
    /usr/bin/xattr -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
done
make_archive "$app" "${app%.app}.zip"
printf 'Built %s\n' "$app"
