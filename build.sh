#!/bin/bash
# Builds TempBar.app and TempBar.zip next to this script. Requires Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP="TempBar.app"
rm -rf "$APP" TempBar.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/" # regenerate with: swift make_icon.swift AppIcon.icns

# Without -target, swiftc builds for the Mac's own macOS version and the app won't launch on older ones.
swiftc -O -target arm64-apple-macos12.0 TempBar.swift -o "$APP/Contents/MacOS/TempBar" -framework Cocoa

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TempBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>io.github.fray2869.TempBar</string>
    <key>CFBundleName</key><string>TempBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" TempBar.zip
echo "Built $APP and TempBar.zip. Launch it with: open $APP"
