#!/bin/sh

# Builds Jeep.app and wraps it in a drag-to-install disk image at
# Release/Jeep-<version>.dmg. The volume carries an /Applications symlink so the
# app is installed by dragging rather than run from the mounted image.

set -eu

jeep_project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
jeep_release_dir="$jeep_project_dir/Release"
jeep_staging_root=$(mktemp -d "${TMPDIR:-/tmp}/Jeep-dmg.XXXXXX")
jeep_volume="$jeep_staging_root/volume"
jeep_app="$jeep_volume/Jeep.app"
jeep_staging_dmg="$jeep_staging_root/Jeep.dmg"
jeep_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$jeep_project_dir/Support/Info.plist")
jeep_dmg="$jeep_release_dir/Jeep-$jeep_version.dmg"

# Same identity as build_app.sh: the environment, else .signing-identity.
if [ -z "${JEEP_SIGN_IDENTITY:-}" ] && [ -f "$jeep_project_dir/.signing-identity" ]; then
    JEEP_SIGN_IDENTITY=$(sed -n '1p' "$jeep_project_dir/.signing-identity")
    export JEEP_SIGN_IDENTITY
fi

trap 'rm -rf "$jeep_staging_root"' EXIT

mkdir -p "$jeep_volume"

cd "$jeep_project_dir"
# A distributable image never carries the owner's local icon words.
JEEP_PUBLIC_BUILD=1 JEEP_APP_DIR="$jeep_app" sh Scripts/build_app.sh

# Finder can attach metadata to a bundle path after an earlier install or copy.
# Clear it before packaging so stale com.apple.FinderInfo never invalidates the
# signature inside the image.
xattr -cr "$jeep_app"
codesign --verify --deep --strict "$jeep_app"
plutil -lint "$jeep_app/Contents/Info.plist" >/dev/null

ln -s /Applications "$jeep_volume/Applications"

mkdir -p "$jeep_release_dir"
hdiutil create \
    -quiet \
    -volname "Jeep $jeep_version" \
    -srcfolder "$jeep_volume" \
    -ov \
    -format UDZO \
    "$jeep_staging_dmg"
hdiutil verify -quiet "$jeep_staging_dmg"

# Optional notarization: a "Developer ID Application" signing identity
# (JEEP_SIGN_IDENTITY or .signing-identity) plus JEEP_NOTARY_PROFILE, a
# `xcrun notarytool store-credentials` keychain profile. Without both, the
# image stays ad-hoc signed.
if [ -n "${JEEP_SIGN_IDENTITY:-}" ] && [ "${JEEP_SIGN_IDENTITY}" != "-" ] \
        && [ -n "${JEEP_NOTARY_PROFILE:-}" ]; then
    codesign --force --timestamp --sign "$JEEP_SIGN_IDENTITY" "$jeep_staging_dmg"
    xcrun notarytool submit "$jeep_staging_dmg" \
        --keychain-profile "$JEEP_NOTARY_PROFILE" --wait
    xcrun stapler staple "$jeep_staging_dmg"
    xcrun stapler validate "$jeep_staging_dmg"
else
    echo "package_dmg.sh: JEEP_SIGN_IDENTITY/JEEP_NOTARY_PROFILE not set; skipping notarization." >&2
fi

rm -f "$jeep_dmg"
mv "$jeep_staging_dmg" "$jeep_dmg"

echo "$jeep_dmg"
