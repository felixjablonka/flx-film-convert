#!/bin/bash
# Builds FLX Film Convert into this folder only, from the engine snapshot
# (sync-engine.sh) and its own sources:
#
#   ./build.sh          build/flxconvert and "FLX Film Convert.app"
#   ./build.sh cli      build/flxconvert only
#   ./build.sh test     the app's executable alone, for the self-check
#   ./build.sh run      build the app and open it
#   ./build.sh dmg      build it and package build/FLX Film Convert.dmg
#   ./build.sh strict   typecheck as GitHub's older compiler would, before a public push
set -euo pipefail
cd "$(dirname "$0")"
[[ -f engine/SOURCES ]] || { echo "no engine snapshot: run ./sync-engine.sh first" >&2; exit 1; }

APP_NAME="FLX Film Convert"
# The release this builds; CHANGELOG.md names what is in it.
VERSION="${VERSION:-0.1.1}"
APP="$APP_NAME.app"
BUNDLE_ID="lab.flx.FLXFilmConvert"
TARGET="arm64-apple-macosx26.0"
# The Command Line Tools ship no plugin for SwiftUI's @State macro, which
# the newest SDK needs; FLX Film Lab's build.sh picks the newest installed SDK
# that compiles SwiftUI without it, and records it as SDKROOT. Same here.
default_sdk="$(xcrun --show-sdk-path)"
probe="build/sdk-probe.swift"
mkdir -p build
printf 'import SwiftUI\nstruct Probe: View { @State var n = 0; var body: some View { Text("\\(n)") } }\n' > "$probe"
SDK=""
for sdk in "$default_sdk" $(ls -d "$(dirname "$default_sdk")"/MacOSX[0-9]*.sdk 2>/dev/null | sort -V -r); do
  if swiftc -typecheck -parse-as-library -sdk "$sdk" -target "$TARGET" "$probe" >/dev/null 2>&1; then SDK="$sdk"; break; fi
done
[[ -n "$SDK" ]] || { echo "error: no installed macOS SDK compiles SwiftUI with this toolchain" >&2; exit 1; }
export SDKROOT="$SDK"
engine=()
while read -r f; do [[ -n "$f" ]] && engine+=("engine/$f"); done < engine/SOURCES
core=(Sources/Core/*.swift)
mkdir -p build

# The newest compiler's solver shortcuts off, as FLX Film Lab's build.sh does:
# GitHub's Xcode gives up on expressions this Mac's compiler takes in its stride.
if [[ "${1:-}" == "strict" ]]; then
  strict=(-Xfrontend -solver-disable-prune-disjunctions -Xfrontend -solver-disable-prepared-overloads
          -Xfrontend -solver-disable-optimize-operator-defaults -Xfrontend -solver-disable-performance-hacks)
  echo "==> typechecking as GitHub's compiler would"
  errors=$( { swiftc -typecheck -parse-as-library -sdk "$SDK" -target "$TARGET" -module-name FLXFilmConvert "${strict[@]}" \
                "${engine[@]}" "${core[@]}" Sources/App/*.swift 2>&1
              swiftc -typecheck -sdk "$SDK" -target "$TARGET" -module-name FLXFilmConvert "${strict[@]}" \
                "${engine[@]}" "${core[@]}" Sources/CLI/main.swift 2>&1; } | grep -E "error:" || true)
  [[ -z "$errors" ]] && { echo "==> no errors"; exit 0; }
  echo "$errors"; exit 1
fi

echo "==> flxconvert"
swiftc -O -sdk "$SDK" -target "$TARGET" -module-name FLXFilmConvert -o build/flxconvert \
  "${engine[@]}" "${core[@]}" Sources/CLI/main.swift
[[ "${1:-}" == "cli" ]] && exit 0

# The app's executable alone, outside a bundle, for the self-check: it leaves
# a running copy of the app alone and is not quarantined as a bundle is.
if [[ "${1:-}" == "test" ]]; then
  mkdir -p build/unbundled
  echo "==> build/unbundled/FLXFilmConvert (run it from engine/)"
  swiftc -O -parse-as-library -sdk "$SDK" -target "$TARGET" -module-name FLXFilmConvert \
    -o build/unbundled/FLXFilmConvert "${engine[@]}" "${core[@]}" Sources/App/*.swift
  exit 0
fi

# Replacing the bundle of a running app breaks its Open and Save panels.
if pgrep -f "$(pwd)/$APP/Contents/MacOS/" >/dev/null; then
  echo "error: $APP_NAME is running. Quit it first." >&2; exit 1
fi
echo "==> $APP"
swiftc -O -parse-as-library -sdk "$SDK" -target "$TARGET" -module-name FLXFilmConvert \
  -o "build/$APP_NAME" "${engine[@]}" "${core[@]}" Sources/App/*.swift
# As FLX Film Lab's build.sh does: the bundle is rebuilt where it stands, under
# the same name. (Moving a new bundle in while iCloud still synced the old one
# left "FLX Film Convert 2.app" and the like behind.) It is the build's own
# output, made again from the sources each time.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Shaders"
mv "build/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp -R engine/FLXFilmLab/Resources/packs "$APP/Contents/Resources/"
cp engine/FLXFilmLab/Resources/Shaders/flx.metal "$APP/Contents/Resources/Shaders/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp NOTICE.md LICENSE "$APP/Contents/Resources/" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
echo "APPL????" > "$APP/Contents/PkgInfo"
# Copied resources carry extended attributes that codesign rejects outright,
# and in a folder iCloud syncs it may put some back as soon as they are gone:
# so clear and sign until the signature verifies.
sign() {
  local bundle="$1" attempt
  : > build/sign.log
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    xattr -cr "$bundle"
    if codesign --force --deep --sign - "$bundle" 2>>build/sign.log && codesign -v "$bundle" 2>>build/sign.log; then return 0; fi
    sleep 1
  done
  return 1
}
sign "$APP" || echo "    (ad-hoc signing failed: $(grep -v 'replacing existing' build/sign.log | tail -1); the linker signature still lets it run here)"
echo "==> $(pwd)/$APP $VERSION (engine: FLX Film Lab $(cat engine/VERSION 2>/dev/null || cut -c1-7 engine/SNAPSHOT))"
[[ "${1:-}" == "run" ]] && open "$APP"

# The disk image, as FLX Film Lab's: the app, a link to Applications, and how
# to get past macOS's first-launch refusal of an app without a paid
# developer certificate.
if [[ "${1:-}" == "dmg" ]]; then
  echo "==> packaging $APP_NAME.dmg"
  # Staged outside the project, where nothing syncs, and signed there: a disk
  # image only ships an app whose signature verifies.
  stage="$(mktemp -d)/dmg"
  mkdir -p "$stage"
  cp -R "$APP" "$stage/"
  sign "$stage/$APP" || { echo "error: the app in the disk image does not verify" >&2; exit 1; }
  ln -s /Applications "$stage/Applications"
  cat > "$stage/Read me first.txt" <<NOTE
FLX Film Convert $VERSION
=====================

Install
-------
Drag "FLX Film Convert" onto the Applications folder in this window.

First launch
------------
macOS will refuse to open it the first time, with a message about the app being
damaged or from an unidentified developer. It is neither: the app just is not
signed with a paid Apple developer certificate, and macOS treats anything
downloaded without one this way.

To get past it, do this ONCE:

  1. Open Terminal (Applications > Utilities > Terminal).
  2. Paste this line and press Return:

       xattr -cr "/Applications/FLX Film Convert.app"

  3. Open the app normally from Applications.

That command removes the "downloaded from the internet" flag from the app. It
does not change the app itself.

What it does
------------
Open a folder of raw camera scans of film negatives (Open Roll), choose the film
and the paper, and it prints each negative through the film's own dyes, an
enlarger and the paper, as FLX Film Lab prints film. The scans must show the
film's rebate along both long edges: it is the only colour reference, so
nothing is guessed from the pictures.

FLX Film Convert is experimental: a companion to FLX Film Lab
(github.com/felixjablonka/flx-film-lab), younger and rougher around the edges.
Keep your raw files.

Requires macOS 26 or later, on a Mac with Apple silicon.

FLX Film Convert is free software under the GNU GPL v3. It prints with FLX Film
Lab's engine, a port of spektrafilm (github.com/andreavolpato/spektrafilm). See
NOTICE.md beside this file for full attribution.
NOTE
  cp NOTICE.md LICENSE "$stage/"
  rm -f "build/$APP_NAME.dmg"
  hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -ov -format UDZO -quiet "build/$APP_NAME.dmg"
  rm -rf "$(dirname "$stage")"
  echo "==> $(pwd)/build/$APP_NAME.dmg ($(du -h "build/$APP_NAME.dmg" | cut -f1))"
fi
exit 0
