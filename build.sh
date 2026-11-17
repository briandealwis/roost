#!/usr/bin/env bash
#
# Build script for Roost.
#
# Usage: ./build.sh [command]
#
# Commands:
#   build     Build a Release Roost.app into build/ (default)
#   debug     Build a Debug Roost.app into build/
#   test      Run the unit tests
#   run       Build (Debug) and launch the app
#   install   Build (Release) and copy Roost.app to ~/Applications
#   dist      Build (Release, universal) and package build/Roost-<version>.zip
#   clean     Remove build output
#   reset-permissions
#             Forget Roost's Accessibility and keystroke permissions, so macOS
#             asks again (needed after an ad-hoc rebuild; see Signing below)
#
# Signing:
#   By default the app is ad-hoc signed ("-"), which is fine for running
#   locally, but macOS forgets the Accessibility grant after every rebuild.
#   To sign with your Apple Developer identity (keeps the grant), set:
#     DEVELOPMENT_TEAM=ABCDE12345 ./build.sh build
#   Optionally also set CODE_SIGN_IDENTITY (defaults to "Apple Development").
#   Set UNIVERSAL=1 to build for both arm64 and x86_64.

set -euo pipefail

cd "$(dirname "$0")"

PRODUCT="Roost"
APP_NAME="Roost"
BUILD_DIR="build"
INFO_PLIST="Resources/Info.plist"

ARCH_ARGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

check_swift() {
    if ! command -v swift >/dev/null 2>&1; then
        echo "error: swift not found; install Xcode 15 or later (or the Command Line Tools)." >&2
        exit 1
    fi
}

# Prints the identity to pass to codesign: "-" (ad-hoc), or the SHA-1 of the
# keychain identity matching CODE_SIGN_IDENTITY and DEVELOPMENT_TEAM.
signing_identity() {
    if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
        echo "-"
        return
    fi
    local name="${CODE_SIGN_IDENTITY:-Apple Development}"
    local hash
    hash="$(security find-identity -v -p codesigning |
        grep -F "$name" | grep -F "($DEVELOPMENT_TEAM)" | head -n 1 | awk '{print $2}')"
    if [[ -z "$hash" ]]; then
        echo "error: no \"$name\" signing identity for team $DEVELOPMENT_TEAM in your keychain." >&2
        echo "       Available identities:" >&2
        security find-identity -v -p codesigning >&2
        exit 1
    fi
    echo "$hash"
}

# Builds the given configuration (release|debug) and assembles build/Roost.app.
build_app() {
    local config="$1"
    check_swift
    local label="$config"
    if [[ ${#ARCH_ARGS[@]} -gt 0 ]]; then label="$config, universal"; fi
    log "Building $APP_NAME ($label)"
    swift build -c "$config" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
    local bin_dir
    bin_dir="$(swift build -c "$config" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

    local app="$BUILD_DIR/$APP_NAME.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin_dir/$PRODUCT" "$app/Contents/MacOS/$PRODUCT"
    cp "$INFO_PLIST" "$app/Contents/Info.plist"

    local identity
    identity="$(signing_identity)"
    log "Signing with ${identity/#-/ad-hoc identity}"
    codesign --force --options runtime --timestamp=none --sign "$identity" "$app"
    log "Built $app"
}

app_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist"
}

quit_running_app() {
    if pgrep -x "$APP_NAME" >/dev/null; then
        log "Quitting running $APP_NAME"
        osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || pkill -x "$APP_NAME" || true
        sleep 1
    fi
}

cmd="${1:-build}"
case "$cmd" in
    build)
        build_app release
        ;;
    debug)
        build_app debug
        ;;
    test)
        check_swift
        log "Running tests"
        swift test
        ;;
    run)
        build_app debug
        quit_running_app
        log "Launching $APP_NAME"
        open "$BUILD_DIR/$APP_NAME.app"
        ;;
    install)
        build_app release
        quit_running_app
        dest="$HOME/Applications"
        mkdir -p "$dest"
        rm -rf "${dest:?}/$APP_NAME.app"
        cp -R "$BUILD_DIR/$APP_NAME.app" "$dest/"
        log "Installed to $dest/$APP_NAME.app"
        ;;
    dist)
        ARCH_ARGS=(--arch arm64 --arch x86_64)
        build_app release
        zip="$BUILD_DIR/$APP_NAME-$(app_version).zip"
        rm -f "$zip"
        ditto -c -k --keepParent "$BUILD_DIR/$APP_NAME.app" "$zip"
        log "Packaged $zip"
        ;;
    clean)
        log "Removing $BUILD_DIR/ and .build/"
        rm -rf "$BUILD_DIR" .build
        ;;
    reset-permissions)
        bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")"
        quit_running_app
        log "Resetting Accessibility and keystroke permissions for $bundle_id"
        tccutil reset Accessibility "$bundle_id"
        tccutil reset PostEvent "$bundle_id"
        log "Launch $APP_NAME again and approve the prompts"
        ;;
    -h|--help|help)
        sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "Unknown command: $cmd" >&2
        echo "Run '$0 help' for usage." >&2
        exit 1
        ;;
esac
