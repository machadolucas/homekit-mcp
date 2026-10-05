# Operations

| What | Value |
|---|---|
| Listener | `127.0.0.1:3040` (`HOMEKIT_MCP_PORT` in the LaunchAgent) |
| MCP URL | `http://127.0.0.1:3040/mcp` |
| Health | `curl -fsS http://127.0.0.1:3040/health` |
| Installed app | `~/Applications/HomeKitMCP.app` |
| LaunchAgent | `~/Library/LaunchAgents/com.local.homekit-mcp.plist` (label `com.local.homekit-mcp`, rendered from `deploy/com.local.homekit-mcp.plist.template`) |
| Log | `~/Library/Logs/homekit-mcp.log` (app stdout/stderr; writes are logged as `WRITE …`), `~/Library/Logs/homekit-mcp.launchd.log` (the `open` wrapper) |
| Signing team | `DEVELOPMENT_TEAM` in `~/.config/macserver/homekit-mcp.env` (host-local, never committed) |
| Build output | `DerivedData` under `/Volumes/SSD-Cache/dev/homekit-mcp-dd` when that exists, else `build/` |

## Prerequisites

1. Full Xcode, with its first-launch setup done (open it once).
2. An Apple ID added in **Xcode → Settings → Accounts**; its team must be able to sign apps with
   the HomeKit capability. A free Personal Team works, but its provisioning profiles expire after
   7 days (see "Re-signing").
3. **Create the provisioning profile once in the Xcode GUI**: open `HomeKitSync.xcodeproj`, target
   HomeKitSync → Signing & Capabilities → tick "Automatically manage signing" → pick the team.
   Xcode registers the App ID with HomeKit and writes the profile to
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. Discard the resulting
   `DEVELOPMENT_TEAM` change in `project.pbxproj` (`git checkout -- HomeKitSync.xcodeproj`).
   Command-line `xcodebuild` then signs with that local profile. `-allowProvisioningUpdates` from the
   command line can fail with "No Account for Team" even when the account works in the GUI, so
   `install.sh` only passes it when `ALLOW_PROVISIONING_UPDATES=1`.
4. The Mac signed into iCloud with an Apple ID that is a member of the Home. Changing rooms and
   names needs that member to be an **admin**.
5. A logged-in GUI session. HomeKit is only available to an app in the user's session, so this is
   a user LaunchAgent, not a system daemon.

## Install or update

```bash
echo 'DEVELOPMENT_TEAM=XXXXXXXXXX' > ~/.config/macserver/homekit-mcp.env   # once; find the ID in Xcode → Accounts
chmod 600 ~/.config/macserver/homekit-mcp.env
deploy/install.sh
```

`install.sh` builds Release for Mac Catalyst, checks the signature and the HomeKit entitlement,
stops the LaunchAgent **and quits the running app** (`bootout` alone only stops the `open`
wrapper), copies the app to `~/Applications`, re-bootstraps the LaunchAgent and waits for
`/health`.

The LaunchAgent starts the app with `/usr/bin/open -W -g --env … --stdout … --stderr …`, not by
running `Contents/MacOS/HomeKitMCP`. A Mac Catalyst app run directly by launchd aborts with
`NSInternalInconsistencyException: _mainSceneIdentifier should have been set by now!`. `-W` keeps
`open` alive while the app runs, so KeepAlive restarts it after a quit or crash. If an instance is
already running, `open` attaches to it and its log and port settings are ignored ("was already
running and so the additional environment variables … could not be set" in
`homekit-mcp.launchd.log`). Quit it and kickstart.
`deploy/install.sh --no-build` reinstalls the last build.

**First launch:** macOS shows a "HomeKitMCP would like to access your home data" dialog **on the
console**. Until someone clicks Allow, `/health` reports `authorization: not_determined` and
every tool fails. If it was denied, re-enable it in System Settings → Privacy & Security → Home.

The app also opens a small status window. It can be minimised; quitting it stops the server
until launchd restarts it (KeepAlive, 30 s throttle).

## Register with agents

Claude Code (user scope, available in every project):

```bash
claude mcp add --scope user --transport http homekit http://127.0.0.1:3040/mcp
```

Codex (`config.toml`, user- or project-level):

```toml
[mcp_servers.homekit]
url = "http://127.0.0.1:3040/mcp"
```

## Common operations

```bash
launchctl print gui/$(id -u)/com.local.homekit-mcp | head -20     # state, pid, last exit
pkill -x HomeKitMCP                                               # restart (KeepAlive relaunches within ~30 s)
launchctl bootout gui/$(id -u)/com.local.homekit-mcp              # stop until next bootstrap/login
tail -50 ~/Library/Logs/homekit-mcp.log
```

## Re-signing

With a free Personal Team the profile is valid for 7 days. After that macOS refuses to launch the
app, launchd keeps retrying, and the log shows nothing new. Run `deploy/install.sh` again within
the week. A paid Apple Developer Program team gives profiles valid for a year.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `/health` refuses the connection | Agent not running: check `launchctl print …` for the last exit code; check the log for `Listener failed` (port in use) |
| `authorization: not_determined` | Permission dialog waiting on the console |
| `authorization: denied` | Re-enable in System Settings → Privacy & Security → Home, then restart the agent |
| `serial_number` empty everywhere | Check the log line `Serial numbers: N of M`. The value is read explicitly after homes load; `HMCharacteristic.value` alone stays nil on macOS 27 |
| `status: starting` for more than a minute | HomeKit daemon has not delivered homes; check iCloud sign-in and Home membership |
| Write returns "did not answer within 10 s" | `homed` busy or the Home hub unreachable. Re-read the state before retrying; the change may still land |
| Build fails on signing | Apple ID missing in Xcode → Accounts, or team lacks the HomeKit capability |
| `403 Forbidden` from a client | The client sent an `Origin` or non-loopback `Host` header. Use `127.0.0.1`, not the LAN hostname |
