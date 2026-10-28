#!/bin/bash
#
# Builds DesktopExtend.app for local use.
#
# Screen Recording permission is keyed to the code signature, so an ad-hoc
# signature (which changes on every build) makes macOS re-ask each time. Set
# DE_CODESIGN_IDENTITY to a stable certificate to keep the grant:
#
#   DE_CODESIGN_IDENTITY="Apple Development: You (TEAMID)" ./Scripts/build-app.sh
#
# When that identity is a "Developer ID Application" certificate the build is
# treated as a distribution build: it is signed with the hardened runtime and a
# secure timestamp, and a .dmg is produced alongside the .app. Notarizing it is
# a separate step — see Scripts/release.sh.
#
#   DE_SKIP_DMG=1   suppress the disk image on a distribution build
#   DE_BUILD_DIR    output directory (default: build). Point tests at a scratch
#                   directory so they cannot overwrite a signed release.
#
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
de_install_cleanup_trap

CONFIG="${CONFIG:-release}"
BUILD_DIR="${DE_BUILD_DIR:-build}"
mkdir -p "$BUILD_DIR"
APP="$BUILD_DIR/$APP_NAME.app"
DMG="$BUILD_DIR/$APP_NAME.dmg"
IDENTITY="${DE_CODESIGN_IDENTITY:--}"

de_step "swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

de_step "Assembling $APP"
# Drop any .dmg from an earlier distribution build so a stale image can never
# outlive the app it was built from.
rm -f "$DMG"
de_assemble_app "$BIN" "$APP" Resources/Info.plist

if de_is_developer_id "$IDENTITY"; then
    DISTRIBUTION=1
    # Hardened runtime and a secure timestamp are both prerequisites for
    # notarization; signing without them now would produce a .dmg that could
    # never be notarized later.
    SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime --timestamp)
    de_step "Signing for distribution (hardened runtime)"
else
    DISTRIBUTION=0
    SIGN_ARGS=(--force --sign "$IDENTITY" --timestamp=none)
    de_step "Signing for local use"
fi
echo "    identity: $(de_identity_name "$IDENTITY")"

[[ -f Resources/DesktopExtend.entitlements ]] && \
    SIGN_ARGS+=(--entitlements Resources/DesktopExtend.entitlements)

codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

if [[ "$DISTRIBUTION" == "1" && "${DE_SKIP_DMG:-0}" != "1" ]]; then
    de_step "Building disk image"
    de_build_dmg "$APP" "$DMG" "$IDENTITY"
    echo "    $DMG"
fi

de_step "Done"
echo "    app: $APP"
if [[ -f "$DMG" && "$DISTRIBUTION" == "1" ]]; then
    echo "    dmg: $DMG"
    echo
    echo "    Signed but NOT notarized — Gatekeeper on another Mac will still"
    echo "    reject it. Run ./Scripts/release.sh to notarize and staple."
else
    echo "    run it with:  open $APP"
fi
