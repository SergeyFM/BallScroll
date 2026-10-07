#!/bin/bash
# BallScroll build — swiftc + hand-written Info.plist (no Xcode required).
# Consistent ad-hoc signing keeps the Accessibility permission stable (§8.10).
set -euo pipefail

cd "$(dirname "$0")"
APP=build/BallScroll.app
BIN="$APP/Contents/MacOS/BallScroll"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc \
    -O \
    -target arm64-apple-macosx26.0 \
    -framework AppKit -framework SwiftUI -framework CoreGraphics \
    -framework IOKit -framework ServiceManagement -framework Combine \
    Sources/BallScroll/*.swift \
    -o "$BIN"

cp Resources/Info.plist "$APP/Contents/Info.plist"
# PkgInfo (harmless, helps some launchers)
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Consistent ad-hoc signature — TCC (Accessibility) binds to this identity.
codesign --force --sign - "$APP"

echo "Built: $APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
