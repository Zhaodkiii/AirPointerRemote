#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$project_dir/DerivedData/WebsiteRelease"
team_id="4AN6PV98G7"
signing_identity="Developer ID Application: daokai hua ($team_id)"
notary_profile="${AIRPOINTER_NOTARY_PROFILE:-}"
edition="${1:---standard}"
if [[ ${1:-} == --help ]]; then
    echo "Usage: [AIRPOINTER_NOTARY_PROFILE=profile] ./scripts/build-mac-dmg.sh [--direct|--standard]"
    echo "Default: rebuild the standard Mac app and refresh the iPhone installer resource. Use --direct for Closed-Lid Desktop."
    echo "With a profile, notarizes the final DMG. Otherwise, Xcode notarizes the app inside it."
    exit 0
fi
if [[ $# -gt 1 ]]; then
    echo "Run with --help for usage." >&2
    exit 2
fi
case "$edition" in
    --direct)
        scheme='AirPointer Remote Mac Direct'
        product='AirPointerRemoteMacDirect.app'
        app_name='AirPointer Remote Direct.app'
        edition_suffix='-Direct'
        ;;
    --standard)
        scheme='AirPointer Remote Mac'
        product='AirPointerRemoteMac.app'
        app_name='AirPointer Remote.app'
        edition_suffix=''
        ;;
    *)
        echo "Run with --help for usage." >&2
        exit 2
        ;;
esac

mkdir -p "$output_dir"
work_dir="$(mktemp -d "$output_dir/.package.XXXXXX")"
mounted=""
cleanup() {
    if [[ -n "$mounted" ]] && ! hdiutil detach "$mounted" >/dev/null 2>&1; then
        echo "Could not detach $mounted. Temporary files retained at $work_dir." >&2
        return
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

archive="$work_dir/AirPointerRemote.xcarchive"
app="$archive/Products/Applications/$product"
echo "Archiving Mac Release for Apple silicon and Intel…"
xcodebuild -quiet -project "$project_dir/AirPointerRemote.xcodeproj" \
    -scheme "$scheme" -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$archive" -derivedDataPath "$output_dir/Build" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
    "DEVELOPMENT_TEAM=$team_id" "CODE_SIGN_IDENTITY=$signing_identity" \
    ENABLE_APP_SANDBOX=NO ENABLE_HARDENED_RUNTIME=YES archive
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"

suffix=""
if [[ -z "$notary_profile" ]]; then
    echo "Submitting the app for notarization with the signed-in Xcode account…"
    options="$work_dir/export.plist"
    plutil -create xml1 "$options"
    plutil -insert method -string developer-id "$options"
    plutil -insert destination -string upload "$options"
    plutil -insert signingStyle -string manual "$options"
    plutil -insert signingCertificate -string "$signing_identity" "$options"
    plutil -insert teamID -string "$team_id" "$options"
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
        -exportPath "$work_dir/upload" -allowProvisioningUpdates
    for ((attempt=1; attempt<=18; attempt++)); do
        if xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$work_dir/notarized" \
            >"$work_dir/notarization.log" 2>&1; then
            break
        fi
        if [[ $attempt == 18 ]] || grep -Eiq 'invalid|reject|no accounts|authentication' "$work_dir/notarization.log"; then
            cat "$work_dir/notarization.log" >&2
            exit 1
        fi
        echo "Waiting for App notarization ($attempt/18)…"
        sleep 10
    done
    app="$work_dir/notarized/$product"
    xcrun stapler validate "$app"
    suffix="-app-notarized"
fi

echo "Creating the Finder installation window…"
tools_dir="$output_dir/dmgbuild-1.6.7"
if ! "$tools_dir/bin/python" -c "import dmgbuild" >/dev/null 2>&1; then
    echo "Installing dmgbuild in the local build directory…"
    python3 -m venv "$tools_dir"
    "$tools_dir/bin/python" -m pip install --disable-pip-version-check 'dmgbuild==1.6.7'
fi
mkdir -p "$work_dir/contents" "$work_dir/mount"
ditto "$app" "$work_dir/contents/$app_name"
xcrun swift "$project_dir/scripts/dmg-background.swift" "$work_dir/install.png"
filename="AirPointer-Remote-${version}-${build}-macOS${edition_suffix}${suffix}.dmg"
image="$work_dir/$filename"
"$tools_dir/bin/python" -m dmgbuild -s "$project_dir/scripts/dmg-layout.py" \
    -D "app=$work_dir/contents/$app_name" -D "background=$work_dir/install.png" \
    'AirPointer Remote' "$image"
codesign --sign "$signing_identity" --identifier "$bundle_id.dmg" --timestamp "$image"

if [[ -n "$notary_profile" ]]; then
    echo "Submitting the signed DMG for notarization…"
    xcrun notarytool submit "$image" --keychain-profile "$notary_profile" --wait --timeout 30m --output-format plist >"$work_dir/submission.plist"
    status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$work_dir/submission.plist")"
    if [[ "$status" != Accepted ]]; then
        id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$work_dir/submission.plist")"
        xcrun notarytool log "$id" --keychain-profile "$notary_profile" >&2 || true
        exit 1
    fi
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
    spctl --assess --type open --context context:primary-signature "$image"
fi

echo "Verifying the mounted DMG…"
hdiutil verify -quiet "$image"
codesign --verify "$image"
hdiutil attach -quiet -readonly -noautoopen -nobrowse -mountpoint "$work_dir/mount" "$image"
mounted="$work_dir/mount"
test "$(readlink "$mounted/Applications")" = /Applications
"$tools_dir/bin/python" - "$mounted/.DS_Store" "$app_name" <<'PYTHON'
import sys
from ds_store import DSStore

with DSStore.open(sys.argv[1], "r") as store:
    icon_settings = store["."]["icvp"]
    if not icon_settings.get("backgroundImageAlias"):
        raise SystemExit("The DMG is missing its installer background.")
    for name, expected in [(sys.argv[2], (172, 190)), ("Applications", (468, 190))]:
        if store[name]["Iloc"] != expected:
            raise SystemExit(f"The DMG has an unexpected position for {name}.")
PYTHON
codesign --verify --deep --strict "$mounted/$app_name"
spctl --assess --type execute --verbose "$mounted/$app_name"
hdiutil detach -quiet "$mounted"
mounted=""

mv -f "$image" "$output_dir/$filename"
echo "DMG: $output_dir/$filename"
if [[ "$edition" == --standard ]]; then
    installer="$project_dir/iPhone/Resources/AirPointer Remote for Mac.dmg"
    cp "$output_dir/$filename" "$work_dir/embedded.dmg"
    mv -f "$work_dir/embedded.dmg" "$installer"
    echo "Updated iPhone resource: $installer"
fi
if [[ -z "$notary_profile" ]]; then
    echo "The app is notarized. Set AIRPOINTER_NOTARY_PROFILE to notarize the DMG itself for website distribution."
fi
