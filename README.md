# HomeKit MCP (organisation-only fork)

A Mac Catalyst app that serves a **loopback-only MCP server over Apple's HomeKit framework**, so
AI agents running on the same Mac can read and tidy how a Home is organised in the Apple Home app:
rooms, which room each accessory is in, and names.

Fork of [TimCinel/homekit-mcp](https://github.com/TimCinel/homekit-mcp) (MIT). Main differences
(details in [docs/fork-changes.md](docs/fork-changes.md)):

- Binds `127.0.0.1` only and refuses browser-originated requests (`Origin` / `Host` checks).
- **No device control.** No tools to switch, dim, open, lock or unlock. Use Home Assistant or the
  Home app for that.
- Writes need an exact UUID, serial number or full name, and ambiguous matches are refused.
- Accessories bridged from Home Assistant can be addressed by entity_id, because HA publishes it
  as the serial number.
- Current MCP Streamable HTTP behaviour (protocol negotiation, `202` for notifications,
  `isError` tool results, `structuredContent`).

## Why an app?

HomeKit is only available to a **signed app with the `com.apple.developer.homekit`
entitlement**, running in the logged-in user's session. A plain CLI or daemon cannot get it.

## Tools

| Tool | Purpose |
|---|---|
| `list_homes` | Homes with room and accessory counts |
| `list_rooms` | Rooms (incl. the default room) with UUIDs |
| `list_accessories` | Accessories with room, category, serial number, reachability; filter by `room` / `query` |
| `set_accessory_room` | Move an accessory to a room |
| `rename_accessory` | Rename an accessory in Apple Home |
| `rename_room` | Rename a room |
| `add_room` | Create a room |

Full reference: [docs/tools.md](docs/tools.md).

## Quick start

Requirements: macOS 13+, full Xcode, an Apple ID in Xcode → Settings → Accounts whose team can
sign apps with HomeKit, and the Mac signed into iCloud as an admin member of the Home.

```bash
git clone https://github.com/machadolucas/homekit-mcp.git
cd homekit-mcp
export DEVELOPMENT_TEAM=XXXXXXXXXX          # your team ID (Xcode → Settings → Accounts)
deploy/install.sh                           # build, sign, install to ~/Applications, start LaunchAgent
curl -fsS http://127.0.0.1:3040/health
claude mcp add --scope user --transport http homekit http://127.0.0.1:3040/mcp
```

Approve the "would like to access your home data" dialog on first launch. Operations, re-signing
and troubleshooting: [docs/operations.md](docs/operations.md).

## CLI and room sync

- `scripts/homekitctl.py`: standard-library CLI over the HTTP endpoint
  (`homes`, `rooms`, `accessories`, `move`, `rename-accessory`, `rename-room`, `add-room`, `call`).
- `scripts/manage_homekit_rooms.py`: upstream's plan/apply tool that sets Apple Home rooms from
  Home Assistant areas, matching on the serial number (= HA entity_id). It needs `hass-cli` with
  `HASS_SERVER` and `HASS_TOKEN`, and `homekitctl` on `PATH`. It writes CSV plans and snapshots
  to `artifacts/`, which is gitignored. Review a plan before `--apply-plan`.

## Development

```bash
swift test                                   # SwiftPM core tests (no HomeKit needed)
xcodebuild -project HomeKitSync.xcodeproj -scheme HomeKitSync \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build   # compile check
```

Agent instructions for contributors: [CLAUDE.md](CLAUDE.md) (also `AGENTS.md`).

## License

MIT, see [LICENSE](LICENSE). Original work © Tim Cinel.
