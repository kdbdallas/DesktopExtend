# Shared helpers for the DesktopExtend build scripts. Sourced, never executed.
# shellcheck shell=bash

APP_NAME="DesktopExtend"

de_step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
de_fail() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# Intermediate artifacts that must not outlive the run, however it ends. The
# notarization archive and the disk-image staging directory are both created
# well before the step that would delete them, so a failure or a Ctrl-C in
# between used to strand them next to the real output.
DE_TEMP_PATHS=()

de_track_temp() { DE_TEMP_PATHS+=("$1"); }

de_cleanup() {
    # bash 3.2 errors on expanding an empty array under `set -u`.
    if [[ ${#DE_TEMP_PATHS[@]} -gt 0 ]]; then
        rm -rf "${DE_TEMP_PATHS[@]}"
    fi
    return 0
}

# Signals exit rather than cleaning up directly, so there is one cleanup path
# and the exit status still reflects how the run ended.
de_install_cleanup_trap() {
    trap de_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# Resolves a signing identity to its certificate common name. Accepts either a
# full name or the 40-character SHA-1 fingerprint that `security find-identity`
# prints, so callers can pass whichever form they have.
de_identity_name() {
    local id="$1"
    if [[ "$id" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        security find-identity -v -p codesigning 2>/dev/null \
            | grep -i "$id" | grep -o '"[^"]*"' | tr -d '"' | head -1
    else
        printf '%s' "$id"
    fi
}

# True only for a "Developer ID Application" certificate. This is the sole
# certificate type Apple's notary service accepts, so it is also the signal
# that a build is intended for distribution rather than local use.
de_is_developer_id() {
    case "$(de_identity_name "$1")" in
        "Developer ID Application:"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Assembles a .app bundle around an already-built executable. The app icon is
# taken from AppIcon.icns next to the plist, matching CFBundleIconFile.
de_assemble_app() {
    local binary="$1" app="$2" plist="$3"
    local icon
    icon="$(dirname "$plist")/AppIcon.icns"
    [[ -f "$icon" ]] || de_fail "missing app icon: $icon"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$binary" "$app/Contents/MacOS/$APP_NAME"
    cp "$plist" "$app/Contents/Info.plist"
    cp "$icon" "$app/Contents/Resources/AppIcon.icns"
    printf 'APPL????' > "$app/Contents/PkgInfo"
}

# Builds a distributable disk image containing the app alongside an
# /Applications symlink, so the drag-to-install gesture works on mount.
de_build_dmg() {
    local app="$1" dmg="$2" identity="${3:--}"
    local staging
    staging="$(mktemp -d)"
    de_track_temp "$staging"
    cp -R "$app" "$staging/"
    ln -s /Applications "$staging/Applications"
    rm -f "$dmg"
    hdiutil create -volname "$APP_NAME" -srcfolder "$staging" \
        -ov -format UDZO "$dmg" >/dev/null
    rm -rf "$staging"
    # A signed disk image is what lets Gatekeeper vouch for the container
    # itself, not just the app inside it.
    [[ "$identity" != "-" ]] && codesign --force --sign "$identity" --timestamp "$dmg"
    return 0
}

# Submits an archive to the notary service and waits for a verdict.
#
# `notarytool submit --wait` aborts the whole run on a transient network error
# and loses track of an already-uploaded submission, which wastes a round trip
# that can take many minutes. This submits and polls as separate steps, treats
# connectivity blips as retryable, and records the submission id so an
# interrupted run can pick the same submission back up instead of re-uploading.
#
#   de_notarize <archive> <profile> <id-file> <fingerprint>
de_notarize() {
    local archive="$1" profile="$2" idfile="$3" fingerprint="$4"
    local id="" out status saved_fp saved_id attempts=0

    if [[ -f "$idfile" ]]; then
        read -r saved_fp saved_id < "$idfile" || true
        if [[ "$saved_fp" == "$fingerprint" && -n "$saved_id" ]]; then
            id="$saved_id"
            echo "    resuming submission $id"
        else
            # The artifact changed, so the stored submission describes something
            # else and must not be reused.
            rm -f "$idfile"
        fi
    fi

    if [[ -z "$id" ]]; then
        out="$(xcrun notarytool submit "$archive" --keychain-profile "$profile" 2>&1)" || {
            printf '%s\n' "$out" >&2; return 1; }
        id="$(printf '%s' "$out" | sed -n 's/^ *id: *//p' | head -1)"
        [[ -n "$id" ]] || { printf '%s\n' "$out" >&2; return 1; }
        printf '%s %s' "$fingerprint" "$id" > "$idfile"
        echo "    submission $id"
    fi

    while (( attempts < 160 )); do
        out="$(xcrun notarytool info "$id" --keychain-profile "$profile" 2>&1)"
        status="$(printf '%s' "$out" | sed -n 's/^ *status: *//p' | head -1)"
        case "$status" in
            Accepted)
                echo "    accepted"
                rm -f "$idfile"
                return 0 ;;
            Invalid|Rejected)
                printf '    %s — notary log follows\n' "$status" >&2
                xcrun notarytool log "$id" --keychain-profile "$profile" >&2 2>/dev/null || true
                rm -f "$idfile"
                return 1 ;;
            *)
                # "In Progress", or empty because the status call itself failed.
                [[ -n "$status" ]] && printf '    %s\r' "$status" ;;
        esac
        attempts=$((attempts + 1))
        sleep 15
    done

    printf '    timed out; re-run to resume submission %s\n' "$id" >&2
    return 1
}

# A stable fingerprint for a signed bundle, used to decide whether a recorded
# notarization submission still describes the artifact on disk.
de_cdhash() {
    codesign -d --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1
}
