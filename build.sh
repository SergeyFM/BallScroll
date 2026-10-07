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

# Stable self-signed identity (NOT ad-hoc): TCC binds Accessibility / Input
# Monitoring to the signing identity. Ad-hoc signing changes the CDHash on every
# build, so each rebuild looked like a brand-new app and dropped the grant — the
# source of the "I already enabled it" churn. The "BallScroll Development" cert
# lives in the login keychain (created once); fall back to ad-hoc only if it's
# missing so a fresh machine still builds.
if security find-identity -p codesigning 2>/dev/null | grep -q "BallScroll Development"; then
    codesign --force --sign "BallScroll Development" "$APP"
else
    echo "codesign: 'BallScroll Development' identity not found — falling back to ad-hoc"
    codesign --force --sign - "$APP"
fi

echo "Built: $APP (identity: $(codesign -dvvv "$APP" 2>&1 | grep -o 'Authority=[^ ]*.*' | head -1))"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
