#!/bin/bash
#
# Developer ID release pipeline: build -> sign -> notarize -> staple -> DMG.
#
# This is the distribution path for DesktopExtend. The app cannot ship on the
# Mac App Store (it depends on the private CGVirtualDisplay API), so Developer
# ID + notarization is the only way to hand it to someone whose Gatekeeper will
# accept it.
#
# Configuration (environment):
#   DE_SIGN_IDENTITY     "Developer ID Application: Name (TEAMID)"
#                        Auto-detected when exactly one is installed.
#   DE_KEYCHAIN_PROFILE  notarytool credential profile (default: DesktopExtend)
#   DE_SKIP_NOTARIZE=1   Sign and package only — useful for testing the
#                        mechanics before a certificate exists.
#   DE_SKIP_DMG=1        Skip disk image creation.
#   DE_BUILD_DIR         Output directory (default: build). Point tests at a
#                        scratch directory so they cannot overwrite a signed
#                        release — re-signing discards a stapled ticket.
#
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
de_install_cleanup_trap

BUILD_DIR="${DE_BUILD_DIR:-build}"
mkdir -p "$BUILD_DIR"
APP="$BUILD_DIR/$APP_NAME.app"
ZIP="$BUILD_DIR/$APP_NAME.zip"
DMG="$BUILD_DIR/$APP_NAME.dmg"
PROFILE="${DE_KEYCHAIN_PROFILE:-DesktopExtend}"
SKIP_NOTARIZE="${DE_SKIP_NOTARIZE:-0}"

WANT_DMG=1
[[ "${DE_SKIP_DMG:-0}" == "1" ]] && WANT_DMG=0

# ---------------------------------------------------------------- preflight

de_step "Preflight"

if [[ -n "${DE_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$DE_SIGN_IDENTITY"
else
    # macOS ships bash 3.2, which has no `mapfile`.
    FOUND=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && FOUND+=("$line")
    done < <(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | tr -d '"' | sort -u)

    case "${#FOUND[@]}" in
        0)
            cat >&2 <<'MSG'
error: no "Developer ID Application" certificate found.

Notarization accepts ONLY this certificate type. "Apple Development" and
"Apple Distribution" certificates are rejected — Apple Development is for
local testing, Apple Distribution is for the App Store.

To create one:
  1. You need an Apple Developer Program membership, with the Account Holder
     or Admin role on the team.
  2. https://developer.apple.com/account/resources/certificates
     -> "+" -> Developer ID -> "Developer ID Application"
  3. Download the .cer and double-click to install into your login keychain.
  4. Confirm it landed:
       security find-identity -v -p codesigning | grep "Developer ID Application"

To test everything up to notarization without a certificate:
  DE_SKIP_NOTARIZE=1 DE_SIGN_IDENTITY="-" ./Scripts/release.sh
MSG
            exit 1
            ;;
        1) IDENTITY="${FOUND[0]}" ;;
        *)
            printf 'error: multiple Developer ID Application certificates found:\n' >&2
            printf '  %s\n' "${FOUND[@]}" >&2
            printf 'Choose one with DE_SIGN_IDENTITY="..."\n' >&2
            exit 1
            ;;
    esac
fi

echo "    identity: $(de_identity_name "$IDENTITY")"

# Catch the most likely mistake on a machine holding many certificate types.
if [[ "$IDENTITY" != "-" ]] && ! de_is_developer_id "$IDENTITY"; then
    de_fail "'$(de_identity_name "$IDENTITY")' cannot be notarized. Only 'Developer ID Application' certificates are accepted."
fi

if [[ "$SKIP_NOTARIZE" != "1" ]]; then
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        cat >&2 <<MSG
error: no stored notarization credentials for profile "$PROFILE".

Store them once (needs an app-specific password from appleid.apple.com).
Do NOT run this under sudo — it would write to root's keychain instead of yours:

  xcrun notarytool store-credentials "$PROFILE" \\
      --apple-id "you@example.com" \\
      --team-id "YOURTEAMID" \\
      --password "abcd-efgh-ijkl-mnop"

Then re-run. Or set DE_SKIP_NOTARIZE=1 to sign and package only.
MSG
        exit 1
    fi
    echo "    notarytool profile: $PROFILE (credentials OK)"
else
    echo "    notarization: SKIPPED (DE_SKIP_NOTARIZE=1)"
fi

# ---------------------------------------------------------------- build

de_step "Building release binary"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || de_fail "binary not found at $BIN"

de_step "Assembling $APP"
rm -f "$ZIP" "$DMG"
de_assemble_app "$BIN" "$APP" Resources/Info.plist

# ---------------------------------------------------------------- sign

de_step "Signing with hardened runtime"
SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime)
# A secure timestamp is mandatory for notarization; ad-hoc cannot provide one.
if [[ "$IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--timestamp)
else
    SIGN_ARGS+=(--timestamp=none)
fi
[[ -f Resources/DesktopExtend.entitlements ]] && \
    SIGN_ARGS+=(--entitlements Resources/DesktopExtend.entitlements)

codesign "${SIGN_ARGS[@]}" "$APP"

de_step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d -v "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|flags" | sed 's/^/    /'

if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    if [[ "$WANT_DMG" == "1" ]]; then
        de_step "Building disk image"
        de_build_dmg "$APP" "$DMG" "$IDENTITY"
        echo "    $DMG"
    fi
    de_step "Done (unnotarized)"
    echo "    app: $APP"
    [[ -f "$DMG" ]] && echo "    dmg: $DMG"
    echo
    echo "    Gatekeeper on another Mac will reject this until it is notarized."
    exit 0
fi

# ---------------------------------------------------------------- notarize

de_step "Notarizing the app"
# notarytool takes an archive, never a bare .app bundle. ditto preserves the
# signature and symlinks in a way `zip` does not.
de_track_temp "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
de_notarize "$ZIP" "$PROFILE" "$BUILD_DIR/.notarize-app.id" "$(de_cdhash "$APP")" \
    || de_fail "app notarization failed"

de_step "Stapling the ticket to the app"
# Stapling embeds the ticket so Gatekeeper validates without network access.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"

if [[ "$WANT_DMG" == "1" ]]; then
    # Built from the already-stapled app, so the app stays valid once dragged out.
    de_step "Building disk image"
    de_build_dmg "$APP" "$DMG" "$IDENTITY"
    de_step "Notarizing the disk image"
    de_notarize "$DMG" "$PROFILE" "$BUILD_DIR/.notarize-dmg.id" "$(shasum -a 256 "$DMG" | awk '{print $1}')" \
        || de_fail "disk image notarization failed"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

# ---------------------------------------------------------------- verify

de_step "Gatekeeper assessment"
spctl --assess --type exec --verbose=4 "$APP" 2>&1 | sed 's/^/    /'

de_step "Done"
echo "    app: $APP"
[[ -f "$DMG" ]] && echo "    dmg: $DMG"
