#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${CONFIGURATION:-debug}"
version="${VERSION:-0.1.0}"
build_number="${BUILD_NUMBER:-1}"
if [[ "$configuration" != debug && "$configuration" != release ]] ||
   [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
   [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    print -u2 "Expected CONFIGURATION=debug|release, VERSION=major.minor.patch, and a positive BUILD_NUMBER."
    exit 1
fi
app="$PWD/.build/Comet.app"
[[ "$configuration" == release ]] && app="$PWD/.build/release/Comet.app"
if /bin/ps -ww -axo comm= | /usr/bin/grep -Fx "$app/Contents/MacOS/Comet" >/dev/null; then
    print -u2 "Quit Comet before packaging it. Replacing the running app can break its local network access."
    exit 1
fi
# Pass the SDK to Clang explicitly so the executable records the SDK version correctly.
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swift build -c "$configuration" --sdk "$sdk_path" -Xswiftc -Xclang-linker -Xswiftc "-isysroot$sdk_path"
bin_dir=$(swift build -c "$configuration" --show-bin-path)
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
python3 scripts/customize-sparkle.py "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$app/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Sparkle-LICENSE.txt"
cp Artwork/Credits.html "$app/Contents/Resources/Credits.html"
mkdir -p "$app/Contents/Resources/Licenses"
for dependency in swift-sdk swift-nio swift-log swift-system eventsource swift-atomics swift-collections; do
    for notice in ".build/checkouts/$dependency"/LICENSE*(N.) ".build/checkouts/$dependency"/NOTICE*(N.); do
        install -m 644 "$notice" "$app/Contents/Resources/Licenses/$dependency-${notice:t}"
    done
done
install -m 644 .build/checkouts/swift-nio/Sources/CNIOLLHTTP/LICENSE "$app/Contents/Resources/Licenses/swift-nio-llhttp-LICENSE"
cp "$bin_dir/Comet" "$app/Contents/MacOS/Comet"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
linked_sdk="$(xcrun vtool -show-build "$app/Contents/MacOS/Comet" | awk '$1 == "sdk" { print $2 }')"
if [[ "$linked_sdk" != "$sdk_version" ]]; then
    print -u2 "Expected SDK $sdk_version, executable records $linked_sdk"
    exit 1
fi
xcrun actool Artwork/Comet.icon Artwork/Colors.xcassets --compile "$app/Contents/Resources" \
    --platform macosx --target-device mac --minimum-deployment-target 15.0 \
    --app-icon Comet --output-partial-info-plist "$PWD/.build/Comet-IconInfo.plist" \
    --standalone-icon-behavior all --output-format human-readable-text --warnings --errors
rm -f "$app/Contents/Resources/AppIcon.icns"
ditto "$bin_dir/Comet_Runner.bundle" "$app/Contents/Resources/Comet_Runner.bundle"
ditto "$bin_dir/swift-nio_NIOPosix.bundle" "$app/Contents/Resources/swift-nio_NIOPosix.bundle"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Comet</string>
<key>CFBundleIdentifier</key><string>dev.runnerbar.app</string>
<key>CFBundleName</key><string>Comet</string>
<key>CFBundleDisplayName</key><string>Comet</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccentColorName</key><string>AccentColor</string>
<key>SUFeedURL</key><string>https://github.com/captenmasin/comet/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>j+/uEsdU7zn6KkdtXCihGkGc3UvU0bNUGmyAFm7Mb6c=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAutomaticallyUpdate</key><true/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Comet connects to its macOS virtual machines to manage runners and read their status and logs.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Merge .build/Comet-IconInfo.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
codesign --force --sign - --entitlements Comet.entitlements "$app"
echo "$app"
