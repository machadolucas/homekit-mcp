#!/bin/bash
# Build, sign, install and (re)start the HomeKit MCP server on this Mac.
#
#   deploy/install.sh            build + install + restart the LaunchAgent
#   deploy/install.sh --no-build install the last build + restart
#
# Signing: the Apple Developer team ID is read from DEVELOPMENT_TEAM, or from
# ~/.config/macserver/homekit-mcp.env (DEVELOPMENT_TEAM=XXXXXXXXXX). It is kept
# out of the repo, which is public. The Apple ID itself must be added in
# Xcode -> Settings -> Accounts once; xcodebuild then creates/renews the
# provisioning profile (-allowProvisioningUpdates).
#
# On the macserver host, heavy jobs go through ~/claude/scripts/heavy-job.sh
# when it exists (exit 75 = refused for lack of headroom; do not retry blindly).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${HOMEKIT_MCP_ENV:-$HOME/.config/macserver/homekit-mcp.env}"
PORT="${HOMEKIT_MCP_PORT:-3040}"
LABEL="com.local.homekit-mcp"
APP_DEST="$HOME/Applications/HomeKitMCP.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ -d /Volumes/SSD-Cache/dev ]]; then
    DERIVED="${DERIVED_DATA:-/Volumes/SSD-Cache/dev/homekit-mcp-dd}"
else
    DERIVED="${DERIVED_DATA:-$REPO/build/DerivedData}"
fi
BUILT_APP="$DERIVED/Build/Products/Release-maccatalyst/HomeKitMCP.app"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

build() {
    if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
        echo "DEVELOPMENT_TEAM is not set (env or $ENV_FILE)" >&2
        exit 1
    fi
    local runner=()
    [[ -x "$HOME/claude/scripts/heavy-job.sh" ]] && runner=("$HOME/claude/scripts/heavy-job.sh")
    ${runner[@]+"${runner[@]}"} xcodebuild \
        -project "$REPO/HomeKitSync.xcodeproj" \
        -scheme HomeKitSync \
        -configuration Release \
        -destination 'platform=macOS,variant=Mac Catalyst' \
        -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        CODE_SIGN_STYLE=Automatic \
        build
}

[[ "${1:-}" == "--no-build" ]] || build

[[ -d "$BUILT_APP" ]] || { echo "No build at $BUILT_APP" >&2; exit 1; }
codesign --verify --strict "$BUILT_APP"
codesign -d --entitlements - "$BUILT_APP" 2>/dev/null | grep -q com.apple.developer.homekit \
    || { echo "Built app lacks the HomeKit entitlement" >&2; exit 1; }

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$APP_DEST"
ditto "$BUILT_APP" "$APP_DEST"

sed -e "s|@HOME@|$HOME|g" -e "s|@PORT@|$PORT|g" \
    "$REPO/deploy/com.local.homekit-mcp.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST"

for _ in $(seq 1 20); do
    if curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null; then
        echo
        echo "Installed $APP_DEST; $LABEL is running on 127.0.0.1:$PORT"
        exit 0
    fi
    sleep 1
done
echo "Server did not answer on 127.0.0.1:$PORT; see ~/Library/Logs/homekit-mcp.log" >&2
exit 1
