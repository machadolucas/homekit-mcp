# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.0-fork] - 2026-10-05 (machadolucas fork)

### Changed
- Listener binds 127.0.0.1:3040 (configurable via `HOMEKIT_MCP_PORT`); `Origin`/`Host` checks; no CORS.
- Tool set reduced to organisation tools: `list_homes`, `list_rooms`, `list_accessories`,
  `set_accessory_room`, `rename_accessory`, `rename_room`, `add_room`.
- Write tools resolve by exact UUID / serial number / full name; ambiguous matches are refused.
- MCP Streamable HTTP compliance: protocol negotiation, 202 for notifications, `ping`,
  `isError` results, `structuredContent`; legacy `/mcp/tools/*` and `/events` routes removed.
- HomeKit writes complete asynchronously with a 10 s timeout instead of blocking the main queue.
- Bundle ID `com.machadolucas.homekit-mcp`; team ID supplied at build time.

### Removed
- `accessory_on`, `accessory_off`, `accessory_toggle` (device control is out of scope).

### Added
- `deploy/install.sh` and a LaunchAgent template; `/health` endpoint; docs under `docs/`.

## [Upstream Unreleased]

### Added
- Initial HomeKit MCP Server implementation
- HTTP-based MCP protocol support with Server-Sent Events
- Three core tools: `get_all_accessories`, `get_all_rooms`, `set_accessory_room`
- Mac Catalyst app for HomeKit framework access on macOS
- Comprehensive test suite with CI-friendly Swift Package Manager tests
- SwiftLint integration for code quality
- GitHub Actions CI/CD pipeline
- Full documentation and API reference

### Features
- 🏠 Direct HomeKit integration for accessories and rooms
- 🔧 Move accessories between rooms with UUID-based targeting
- 🌐 RESTful HTTP API with JSON-RPC 2.0 protocol
- 🤖 Claude Code compatible MCP transport
- 🔒 Local-only operation for privacy and security
- 📱 Native macOS app with iOS HomeKit framework

### Technical
- Swift 5.9+ with Mac Catalyst target
- Network framework for HTTP server implementation
- SwiftUI for minimal native interface
- XCTest-based testing with cross-platform support
- SwiftLint for code style enforcement
- Makefile-based build automation

## [1.0.0] - TBD

Initial release targeting full HomeKit MCP functionality.