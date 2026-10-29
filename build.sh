#!/bin/zsh
# Builds "NX OS.app" next to this script and installs it into /Applications.
set -e
cd "${0:A:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
APP="build/NX OS.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/NXLibrary"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
ditto Resources/Fonts "$APP/Contents/Resources/Fonts"
ditto Resources/Characters "$APP/Contents/Resources/Characters"
ditto Resources/Avatars "$APP/Contents/Resources/Avatars"
ditto Resources/Art "$APP/Contents/Resources/Art"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NX OS</string>
  <key>CFBundleDisplayName</key><string>NX OS</string>
  <key>CFBundleExecutable</key><string>NXLibrary</string>
  <key>CFBundleIdentifier</key><string>com.shubham.nxlibrary</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
# a fixed local identity keeps the signature stable, so macOS remembers the T7 permission
if security find-identity -p codesigning | grep -q "NX OS Local Signing"; then
  codesign --force --sign "NX OS Local Signing" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "built $PWD/$APP"

# install a real copy (Launchpad and Spotlight skip symlinks) and register it
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# the launcher's earlier name
[[ -e "/Applications/NX Library.app" ]] && { $LSREG -u "/Applications/NX Library.app"; rm -rf "/Applications/NX Library.app"; }
rm -rf "build/NX Library.app"
rm -rf "/Applications/NX OS.app"
ditto "$APP" "/Applications/NX OS.app"
$LSREG -f "/Applications/NX OS.app"
echo "installed /Applications/NX OS.app"
