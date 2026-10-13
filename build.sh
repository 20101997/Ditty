#!/bin/bash
# Builds build/Ditty.app and build/Ditty.zip. Pass --install to also copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

# Plain swiftc rather than SwiftPM, so it also builds with only the Command Line Tools installed.
mkdir -p build
BIN="build/Ditty"
APP="build/Ditty.app"
# Some Command Line Tools installs keep a stale module.modulemap next to bridging.modulemap; both define
# SwiftBridging and every compile fails. Mask the stale one instead of needing sudo to delete it.
SWIFT_INC="/Library/Developer/CommandLineTools/usr/include/swift"
OVERLAY=()
if [[ -f "$SWIFT_INC/module.modulemap" && -f "$SWIFT_INC/bridging.modulemap" ]]; then
    : > build/empty.modulemap
    printf '{ "version": 0, "roots": [ { "type": "file", "name": "%s", "external-contents": "%s" } ] }\n' \
        "$SWIFT_INC/module.modulemap" "$PWD/build/empty.modulemap" > build/vfs.yaml
    OVERLAY=(-vfsoverlay build/vfs.yaml)
fi
# Universal binary, so one download runs on both Apple Silicon and Intel Macs.
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" ${OVERLAY[@]+"${OVERLAY[@]}"} \
        -o "$BIN-$arch" Sources/Ditty/*.swift -lsqlite3
done
lipo -create "$BIN-arm64" "$BIN-x86_64" -output "$BIN"

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset
cp "$BIN" "$APP/Contents/MacOS/Ditty"
cp Info.plist "$APP/Contents/Info.plist"

"$BIN" --make-icon build/icon_1024.png
for size in 16 32 128 256 512; do
    sips -z $size $size build/icon_1024.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) build/icon_1024.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature by default. Set SIGN_ID to a real identity to keep the Accessibility grant across rebuilds.
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP"

# The zip attached to GitHub releases.
rm -f build/Ditty.zip
ditto -c -k --keepParent "$APP" build/Ditty.zip

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Ditty 2>/dev/null || true
    rm -rf /Applications/Ditty.app
    cp -R "$APP" /Applications/Ditty.app
    open /Applications/Ditty.app
    echo "Installed and launched /Applications/Ditty.app"
fi
