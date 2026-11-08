#!/bin/sh

# Builds .build/Jeep.app (or $JEEP_APP_DIR): universal release binary, stripped,
# signed with the hardened runtime. The signing identity comes from
# JEEP_SIGN_IDENTITY, else the first line of the git-ignored .signing-identity
# file, else ad-hoc ("-").

set -eu

jeep_project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

# Build output stays out of the source tree, which may sync to iCloud: a
# missing .build becomes a link into ~/Library/Caches. An existing .build
# (link or folder) is used as is.
if [ ! -e "$jeep_project_dir/.build" ] && [ ! -L "$jeep_project_dir/.build" ]; then
    jeep_cache_root="$HOME/Library/Caches/Jeep-build"
    mkdir -p "$jeep_cache_root"
    ln -s "$jeep_cache_root" "$jeep_project_dir/.build"
fi

jeep_app_dir=${JEEP_APP_DIR:-"$jeep_project_dir/.build/Jeep.app"}
jeep_sign_identity=${JEEP_SIGN_IDENTITY:-}
if [ -z "$jeep_sign_identity" ] && [ -f "$jeep_project_dir/.signing-identity" ]; then
    jeep_sign_identity=$(sed -n '1p' "$jeep_project_dir/.signing-identity")
fi
jeep_sign_identity=${jeep_sign_identity:--}
jeep_entitlements="$jeep_project_dir/Support/Jeep.entitlements"
jeep_module_cache="$jeep_project_dir/.build/module-cache"
jeep_icon_source="$jeep_project_dir/Resources/AppIcon-master.png"
jeep_work_dir=$(mktemp -d "${TMPDIR:-/tmp}/Jeep-build.XXXXXX")
jeep_clean_dir=$(mktemp -d "${TMPDIR:-/tmp}/Jeep-sign.XXXXXX")
trap 'rm -rf "$jeep_work_dir" "$jeep_clean_dir"' EXIT

jeep_asset_catalog="$jeep_work_dir/Assets.xcassets"
jeep_iconset_dir="$jeep_asset_catalog/AppIcon.appiconset"
jeep_menu_bar_imageset_dir="$jeep_asset_catalog/MenuBarJeepTemplate.imageset"
jeep_actool_log="$jeep_work_dir/actool.log"

cd "$jeep_project_dir"
rm -rf "$jeep_app_dir"

jeep_swift_build() {
    SWIFTPM_MODULECACHE_OVERRIDE="$jeep_module_cache" \
    CLANG_MODULE_CACHE_PATH="$jeep_module_cache" \
    swift build --disable-sandbox -c release \
        -Xswiftc -file-prefix-map -Xswiftc "$jeep_project_dir=." \
        "$@"
}

if jeep_swift_build --arch arm64 --arch x86_64; then
    jeep_bin_dir=$(jeep_swift_build --arch arm64 --arch x86_64 --show-bin-path)
else
    echo "build_app.sh: universal build failed; falling back to host architecture only." >&2
    jeep_swift_build
    jeep_bin_dir=$(jeep_swift_build --show-bin-path)
fi

mkdir -p "$jeep_app_dir/Contents/MacOS" "$jeep_app_dir/Contents/Resources"
mkdir -p "$jeep_iconset_dir" "$jeep_menu_bar_imageset_dir"

for jeep_size in 16 32 128 256 512; do
    jeep_double=$((jeep_size * 2))
    sips -z "$jeep_size" "$jeep_size" "$jeep_icon_source" \
        --out "$jeep_iconset_dir/icon_${jeep_size}x${jeep_size}.png" >/dev/null
    sips -z "$jeep_double" "$jeep_double" "$jeep_icon_source" \
        --out "$jeep_iconset_dir/icon_${jeep_size}x${jeep_size}@2x.png" >/dev/null
done
cp "$jeep_project_dir/Resources/AppIcon-Contents.json" "$jeep_iconset_dir/Contents.json"
CLANG_MODULE_CACHE_PATH="$jeep_module_cache" \
swift "$jeep_project_dir/Scripts/render_menu_bar_icon.swift" "$jeep_menu_bar_imageset_dir"
cp "$jeep_project_dir/Resources/MenuBarJeepTemplate-Contents.json" \
    "$jeep_menu_bar_imageset_dir/Contents.json"

cp "$jeep_bin_dir/Jeep" "$jeep_app_dir/Contents/MacOS/Jeep"
strip -rSTx "$jeep_app_dir/Contents/MacOS/Jeep"
cp "$jeep_project_dir/Support/Info.plist" "$jeep_app_dir/Contents/Info.plist"
# Owner-local icon words go into personal builds only; package_dmg.sh sets JEEP_PUBLIC_BUILD=1.
if [ "${JEEP_PUBLIC_BUILD:-0}" != 1 ] && [ -f "$jeep_project_dir/Support/IconKeywords.local.json" ]; then
    cp "$jeep_project_dir/Support/IconKeywords.local.json" "$jeep_app_dir/Contents/Resources/"
fi
# The profile rail shows the original artwork (not the menu-bar template) at
# about 34pt; 256px covers @2x with margin. sips re-encoding drops metadata.
sips -z 256 256 "$jeep_icon_source" \
    --out "$jeep_app_dir/Contents/Resources/JeepArtwork.png" >/dev/null

# Info.plist already names AppIcon, so actool's partial plist is discarded.
if ! xcrun actool \
        --compile "$jeep_app_dir/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$jeep_work_dir/AppIcon-partial.plist" \
        "$jeep_asset_catalog" >"$jeep_actool_log" 2>&1; then
    sed -n '1,240p' "$jeep_actool_log" >&2
    exit 1
fi

# macOS attaches com.apple.provenance / com.apple.macl extended attributes to
# files written under the build tree by processes descended from a downloaded
# app. They cannot be stripped (xattr -c leaves them silently) and codesign can
# reject the bundle as "detritus". Recreate the bundle without any extended
# attributes or resource forks, sign that copy, and put it in place; the verify
# below aborts the build (set -e) rather than shipping an invalid signature,
# which can cost the app its Accessibility and Automation grants.
jeep_clean_app="$jeep_clean_dir/$(basename "$jeep_app_dir")"
ditto --noextattr --norsrc "$jeep_app_dir" "$jeep_clean_app"
# Notarization needs a secure timestamp; ad-hoc signatures cannot carry one.
jeep_timestamp_flag=--timestamp
if [ "$jeep_sign_identity" = "-" ]; then jeep_timestamp_flag=--timestamp=none; fi
codesign --force --options runtime "$jeep_timestamp_flag" \
    --entitlements "$jeep_entitlements" \
    --sign "$jeep_sign_identity" "$jeep_clean_app"
rm -rf "$jeep_app_dir"
ditto "$jeep_clean_app" "$jeep_app_dir"
codesign --verify --deep --strict "$jeep_app_dir"

echo "$jeep_app_dir"
