# homekit-mcp (fork)

A Mac Catalyst app that serves a small **MCP server over the Apple HomeKit framework**, so AI
agents on the same Mac can read and fix how a Home is *organised* in the Apple Home app: rooms,
room assignments and names. Forked from
[TimCinel/homekit-mcp](https://github.com/TimCinel/homekit-mcp) (MIT); see
[docs/fork-changes.md](docs/fork-changes.md) for what differs and why.

> **This repository is public.** Never commit secrets, Apple IDs, developer team IDs,
> provisioning profiles, household or room names, IP addresses, accessory inventories, logs, or
> `artifacts/` output. The signing team ID lives in a host-local env file (see
> [docs/operations.md](docs/operations.md)). Host-specific operating notes belong in the host's
> private documentation, not here.

## Working with Claude and Codex

`CLAUDE.md` and `.claude/skills/` are the shared sources. `AGENTS.md` links to `CLAUDE.md`;
`.agents/skills` links to `../.claude/skills`. Edit the sources, not copies. Codex project
config is `.codex/config.toml` (no secrets). Claude's tool allow-list lives in
`.claude/settings.json` and applies only to Claude.

## Scope rules

- **Organisation only.** Tools may list homes/rooms/accessories and change rooms, room
  assignments and names. Do **not** add tools that read or write accessory characteristics
  (power, brightness, locks, garage doors, thermostats, alarms, scenes, automations). Device
  control belongs to Home Assistant, which already bridges these accessories; duplicating it here
  would give agents an unaudited second path to locks and alarms.
- **No destructive tools** (removing rooms, accessories, homes, users) without an explicit design
  decision recorded in `docs/`.
- **Exact matching for writes.** Write tools resolve targets by UUID, serial number or exact
  (case-insensitive) name and refuse ambiguous matches. Never reintroduce substring matching for
  writes.
- **Loopback only.** The listener binds `127.0.0.1`; requests with an `Origin` header or a
  non-loopback `Host` are refused (browser CSRF / DNS-rebinding guard). Keep it that way.

## Repository layout

| Path | Purpose |
|---|---|
| `HomeKitSync/HTTPMCPServer.swift` | HTTP listener, MCP JSON-RPC (Streamable HTTP, JSON responses), tools, HomeKit calls |
| `HomeKitSync/MCPApp.swift` | SwiftUI shell: status window, owns the server |
| `HomeKitSync/MCPServer.swift`, `HomeKitManager.swift` | Upstream leftovers (shared models used by tests; unused stdio server) |
| `HomeKitSync/HomeKitSync.entitlements` | `com.apple.developer.homekit` |
| `Sources/`, `Tests/` | Upstream SwiftPM core + tests (`swift test`, no HomeKit needed) |
| `scripts/homekitctl.py` | Stdlib-only CLI over the HTTP endpoint |
| `scripts/manage_homekit_rooms.py` | Plan/apply Apple Home rooms from Home Assistant areas (needs `hass-cli`) |
| `deploy/install.sh` | Build, sign, install to `~/Applications`, (re)start the LaunchAgent |
| `deploy/com.local.homekit-mcp.plist.template` | LaunchAgent template (`@HOME@`, `@PORT@`) |
| `docs/` | Design and operations docs (index below) |

## Build and verify

- Requires full Xcode (not just Command Line Tools). Use `DEVELOPER_DIR` rather than
  `xcode-select` if the active developer dir is the CLT.
- The app must be **signed with a team that has the HomeKit capability**; unsigned builds compile
  but HomeKit returns no homes. `deploy/install.sh` passes `DEVELOPMENT_TEAM` and
  `-allowProvisioningUpdates`.
- Builds are heavy on the reference host: `deploy/install.sh` wraps `xcodebuild` in the host's
  `heavy-job.sh` guard when present. Exit code 75 means "refused, not enough headroom": stop and
  report, do not retry in a loop.
- Quick compile check without signing:
  `xcodebuild ... -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build`.
- After installing: `curl -fsS http://127.0.0.1:3040/health` and
  `python3 scripts/homekitctl.py tools`.

## Doc index

- [docs/fork-changes.md](docs/fork-changes.md) — differences from upstream and the reasons (security, scope, protocol).
- [docs/tools.md](docs/tools.md) — MCP tool reference, argument resolution rules, result shapes.
- [docs/operations.md](docs/operations.md) — signing, install, LaunchAgent, logs, re-signing, troubleshooting, registering with Claude Code and Codex.
