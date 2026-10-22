#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${VERSION:?Set VERSION to the release version}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER to the build number}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
: "${SPARKLE_PRIVATE_KEY:?Set SPARKLE_PRIVATE_KEY to the Sparkle Ed25519 signing key}"
sparkle_bin="$PWD/.build/artifacts/sparkle/Sparkle/bin"
signing_arguments=(--sign "$SIGNING_IDENTITY" --timestamp)
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
    signing_arguments+=(--keychain "$SIGNING_KEYCHAIN")
fi
notary_arguments=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
    notary_arguments+=(--keychain "$NOTARY_KEYCHAIN")
fi
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
   [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] ||
   [[ "$SIGNING_IDENTITY" != "Developer ID Application: "* ]]; then
    print -u2 "Expected VERSION=major.minor.patch, a positive BUILD_NUMBER, and a Developer ID Application identity."
    exit 1
fi
app="$PWD/.build/release/Comet.app"
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$BUILD_NUMBER" ]]
[[ "$(lipo -archs "$app/Contents/MacOS/Comet")" == arm64 ]]

work=$(mktemp -d "$PWD/.build/release-package.XXXXXX")
# ZERR also cleans up when zsh exits from a failed function under errexit.
trap 'rm -rf "$work"' EXIT ZERR
mkdir -p .build/dist
dmg="$PWD/.build/dist/Comet.dmg"
# Remove stale deliverables so a failed attempt cannot leave an older release ready to upload.
rm -f "$dmg" .build/dist/appcast.xml .build/dist/SHA256SUMS
framework="$app/Contents/Frameworks/Sparkle.framework"
for component in "$framework/Versions/B/XPCServices/Downloader.xpc" \
    "$framework/Versions/B/XPCServices/Installer.xpc" "$framework/Versions/B/Autoupdate" \
    "$framework/Versions/B/Updater.app" "$framework"; do
    codesign --force "${signing_arguments[@]}" --options runtime --preserve-metadata=entitlements "$component"
done
codesign --force "${signing_arguments[@]}" --options runtime \
    --entitlements Comet.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"

notarize() {
    local archive="$1" result="$2"
    local submission_status submission_id
    # notarytool's successful exit alone does not guarantee Apple accepted the submission.
    if xcrun notarytool submit "$archive" "${notary_arguments[@]}" \
        --wait --timeout 30m --output-format json > "$result"; then
        submission_status=$(plutil -extract status raw -o - "$result")
    else
        submission_status=Failed
    fi
    if [[ "$submission_status" != Accepted ]]; then
        cat "$result" >&2
        if submission_id=$(plutil -extract id raw -o - "$result" 2>/dev/null); then
            xcrun notarytool log "$submission_id" "${notary_arguments[@]}" >&2 || true
        fi
        return 1
    fi
}

ditto -c -k --sequesterRsrc --keepParent "$app" "$work/Comet.zip"
notarize "$work/Comet.zip" "$work/app-notarization.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

mkdir "$work/image"
ditto "$app" "$work/image/Comet.app"
ln -s /Applications "$work/image/Applications"
mkdir "$work/image/.background"
cp Artwork/Installer/background.png "$work/image/.background/background.png"
cp Artwork/Installer/FinderLayout "$work/image/.DS_Store"
chflags hidden "$work/image/.background"
hdiutil create -volname Comet -srcfolder "$work/image" -fs HFS+ -format UDZO "$work/Comet.dmg"
codesign "${signing_arguments[@]}" "$work/Comet.dmg"
notarize "$work/Comet.dmg" "$work/dmg-notarization.json"
xcrun stapler staple "$work/Comet.dmg"
xcrun stapler validate "$work/Comet.dmg"
codesign --verify --verbose=2 "$work/Comet.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$work/Comet.dmg"
mkdir "$work/updates"
mv "$work/Comet.dmg" "$work/updates/Comet.dmg"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/generate_appcast" --ed-key-file - --maximum-deltas 0 \
    --download-url-prefix "https://github.com/captenmasin/comet/releases/download/v$VERSION/" \
    --link "https://github.com/captenmasin/comet/releases/tag/v$VERSION" "$work/updates"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/sign_update" --verify --ed-key-file - "$work/updates/appcast.xml"
mv "$work/updates/Comet.dmg" "$dmg"
mv "$work/updates/appcast.xml" .build/dist/appcast.xml
(cd .build/dist && shasum -a 256 Comet.dmg appcast.xml > SHA256SUMS)
print "Release ready: $dmg"
