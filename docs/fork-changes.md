# Fork changes

Upstream: [TimCinel/homekit-mcp](https://github.com/TimCinel/homekit-mcp), last upstream commit
2026-03-12. This fork rewrote `HomeKitSync/HTTPMCPServer.swift` and adjusted the CLI scripts. The
SwiftPM core under `Sources/` and its tests are unchanged.

| Area | Upstream | This fork | Why |
|---|---|---|---|
| Listen address | All interfaces, port 8080 | `127.0.0.1` only, port 3040 (`HOMEKIT_MCP_PORT`) | Upstream had no authentication, so anyone on the LAN could drive every HomeKit accessory, locks included |
| Browser access | `Access-Control-Allow-Origin: *`; any body parsed as JSON whatever its `Content-Type` | Requests with an `Origin` header → 403; `Host` must be `127.0.0.1`, `localhost` or `::1`; no CORS headers | A web page in a local browser could otherwise POST a `text/plain` "simple request" to a loopback port (CSRF), or reach it through DNS rebinding. MCP's transport spec requires `Origin` validation |
| Tools | 12, including `accessory_on/off/toggle` (power, covers, garage doors) | 7 organisation tools; **no** characteristic reads or writes | Device control already goes through Home Assistant. A second, unaudited path to locks and garage doors is not wanted |
| Name matching for writes | First accessory or room whose name *contains* the argument | Exact UUID, serial number or case-insensitive full name; ambiguous matches are refused with the candidates | Upstream's `rename_accessory "Lamp"` renamed whichever accessory with "Lamp" in its name came first |
| Serial numbers | Read from the cached `HMCharacteristic.value`, which is nil on macOS 27, so every serial came back "Unknown" | Read explicitly with `readValue` after homes load and cached by accessory UUID; the log reports `Serial numbers: N of M` | Without it, serial = HA entity_id matching (and upstream's room-sync script) cannot work |
| Accessory lookup by serial | Not supported (only shown in output) | `accessory` accepts the serial number | Home Assistant's HomeKit Bridge publishes the entity_id as the serial number, so agents can address an accessory by its entity_id |
| HomeKit writes | Blocked the main queue in `DispatchGroup.wait` for up to 5 s, on the same queue that delivers HomeKit callbacks | Asynchronous completion, 10 s timeout, one reply per request | Waiting on main risked timing out every write; a late callback could also run after the reply had been sent |
| HTTP parsing | One `receive` of up to 64 KB, body taken after the first blank line | Reads until `Content-Length` bytes are in, 1 MB cap, rejects chunked encoding | Requests split across TCP segments were truncated |
| MCP protocol | `protocolVersion` 2024-11-05 only; notifications answered with a JSON-RPC error; integer ids only; legacy `/mcp/tools/*` and `/events` routes | Negotiates 2025-06-18 / 2025-03-26 / 2024-11-05; notifications → `202 Accepted`; `ping`; any JSON id; `GET /mcp` → 405; tool failures returned as `isError: true` results, with `structuredContent` on success | Matches the Streamable HTTP transport (JSON responses, no SSE stream) |
| Health | Welcome HTML on `/` | `GET /health` (and `/`) → JSON: status, authorization, homes | Used by `deploy/install.sh` and monitoring |
| Logging | Emoji-heavy, logged full tool arguments | One ISO-timestamped line per write (`WRITE …`) plus lifecycle events | Writes can be audited in the LaunchAgent log |
| New tools | — | `list_homes`, `add_room`; `list_accessories` takes `room` and `query` filters | `get_accessory_by_name`, `get_room_by_name` and `get_room_accessories` are covered by the filters |
| Bundle ID / team | `com.timcinel.homekitmcp1`, upstream's team ID hard-coded | `com.machadolucas.homekit-mcp`; `DEVELOPMENT_TEAM` empty in the project, passed at build time | The team ID stays out of a public repo, and other people can build with their own team |
| Deployment | `make run` from Xcode | `deploy/install.sh` + LaunchAgent `com.local.homekit-mcp`, which starts the app through `open -W` | Runs unattended on an always-on Mac. Mac Catalyst apps cannot be started by launchd exec'ing the binary |

Upstream's `HomeKitSync/MCPServer.swift` (stdio prototype plus the shared `MCPRequest`/`AnyEncodable`
models) and `HomeKitManager.swift` are kept unchanged. The XCTest target still uses the models;
neither file is used at runtime.

## Merging upstream

Upstream changes are unlikely to apply cleanly to `HTTPMCPServer.swift`. Port fixes by hand and
keep the scope rules in `CLAUDE.md`.
