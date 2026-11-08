#!/bin/sh

# Release artifact for a public release: a Developer ID-signed, notarized
# Jeep-<version>.dmg written to $PUBLISH_OUTPUT. The artifact's path is the
# last line printed. Release images are never ad-hoc or Apple Development
# signed: neither can be notarized, so macOS would block them on other Macs.
#
# Needs JEEP_SIGN_IDENTITY ("Developer ID Application: …") and
# JEEP_NOTARY_PROFILE (an `xcrun notarytool store-credentials` profile).

set -eu

jeep_project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

: "${PUBLISH_OUTPUT:?package.sh: PUBLISH_OUTPUT must name the folder for the disk image}"
: "${JEEP_NOTARY_PROFILE:?package.sh: set JEEP_NOTARY_PROFILE to an xcrun notarytool keychain profile}"
case "${JEEP_SIGN_IDENTITY:-}" in
    "Developer ID Application:"*) ;;
    *)
        echo "package.sh: set JEEP_SIGN_IDENTITY to a \"Developer ID Application: …\" identity" >&2
        exit 1
        ;;
esac

# Keep build output in this tree, not the shared build cache build_app.sh
# links to when .build is missing.
[ -e "$jeep_project_dir/.build" ] || mkdir "$jeep_project_dir/.build"

jeep_dmg=$(sh "$jeep_project_dir/Scripts/package_dmg.sh" | tail -n 1)
mkdir -p "$PUBLISH_OUTPUT"
mv "$jeep_dmg" "$PUBLISH_OUTPUT/"
echo "$PUBLISH_OUTPUT/$(basename "$jeep_dmg")"
