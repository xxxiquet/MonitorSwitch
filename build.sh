#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
make -C vendor/m1ddc
bundle="${MONITORSWITCH_BUNDLE:-$PWD/build/MonitorSwitch.app}"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-incompatible-pointer-types -framework Cocoa -framework IOKit -framework Security MonitorSwitch.m -o "$bundle/Contents/MacOS/MonitorSwitch"
cp vendor/m1ddc/m1ddc "$bundle/Contents/Resources/m1ddc"
cp vendor/m1ddc/LICENSE "$bundle/Contents/Resources/m1ddc-LICENSE.txt"
cp LICENSE "$bundle/Contents/Resources/LICENSE.txt"
cp README.md "$bundle/Contents/Resources/README.md"
cp network_follow.py "$bundle/Contents/Resources/network_follow.py"
cp assets/MonitorSwitch.icns "$bundle/Contents/Resources/MonitorSwitch.icns"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MonitorSwitch</string>
<key>CFBundleIdentifier</key><string>local.xiquet.MonitorSwitch</string>
<key>CFBundleName</key><string>MonitorSwitch</string>
<key>CFBundleDisplayName</key><string>MonitorSwitch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.9.0</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleIconFile</key><string>MonitorSwitch.icns</string>
<key>NSLocalNetworkUsageDescription</key><string>Receive authenticated Easy-Switch device events on your local network to switch your display input.</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Local utility. Includes m1ddc (MIT).</string>
</dict></plist>
PLIST
codesign --force --sign - "$bundle/Contents/Resources/m1ddc"
codesign --force --sign - "$bundle"
"$bundle/Contents/MacOS/MonitorSwitch" --self-test
printf '%s\n' "$bundle"
