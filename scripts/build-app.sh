#!/bin/zsh
set -e

echo "Running RebesSelfTest..."
swift run RebesSelfTest

echo "Building Rebes..."
swift build -c release --arch arm64

echo "Assembling Rebes.app..."
APP_DIR="dist/Rebes.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp .build/out/Products/Release/Rebes "$APP_DIR/Contents/MacOS/"
cp .build/out/Products/Release/RebesHelper "$APP_DIR/Contents/MacOS/"

# App icon
cp assets/AppIcon.icns "$APP_DIR/Contents/Resources/"

# Create Info.plist
cat <<EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Rebes</string>
    <key>CFBundleIdentifier</key>
    <string>com.lqmnah.rebes</string>
    <key>CFBundleName</key>
    <string>Rebes</string>
    <key>CFBundleDisplayName</key>
    <string>Rebes!</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>114</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Rebes! uses Finder to empty the Trash when you ask it to.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2026 Rebes!. Fair Source license — free with credit, no resale.</string>
</dict>
</plist>
EOF

echo "Signing Rebes.app..."
codesign --force --deep -s - "$APP_DIR"

echo "Verifying signature..."
codesign -v "$APP_DIR"

echo "App built successfully at $APP_DIR"
