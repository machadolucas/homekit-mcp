# Tool reference

Endpoint: `POST http://127.0.0.1:3040/mcp` (MCP Streamable HTTP, JSON responses only).

All tools return a JSON text block, plus `structuredContent`: the object itself, or
`{"items": [...]}` for lists. A failure returns `isError: true` and a one-line message.
Before HomeKit has loaded the homes (a few seconds after launch, or forever if HomeKit access was
denied), every tool fails with a message that includes the authorization state.

## Resolution rules

- `home`: home name or UUID, case-insensitive. Optional when only one home exists. Write tools
  for rooms (`rename_room`, `add_room`) require it when there are several homes.
- `room`: exact room name or UUID, case-insensitive, within the resolved home. The default room
  (`roomForEntireHome`, shown with `default_room: true`) is also addressable.
- `accessory`: exact UUID, exact `serial_number`, or exact full name (case-insensitive), across
  the selected homes. More than one match is refused, and the error lists the candidates with
  their UUIDs.
- Names (`new_name`, `name`): trimmed, 1–64 characters.

Writes are idempotent: if the target state already holds, the tool returns `changed: false`
without calling HomeKit.

## Tools

| Tool | Arguments | Returns |
|---|---|---|
| `list_homes` | — | `[{name, uuid, rooms, accessories}]` |
| `list_rooms` | `home?` | `[{home, name, uuid, default_room, accessories}]` |
| `list_accessories` | `home?`, `room?`, `query?` | `[{home, name, uuid, room, category, manufacturer, model, serial_number, firmware, reachable, bridged}]`. `query` is a case-insensitive substring over name, serial_number and room |
| `set_accessory_room` | `accessory`, `room`, `home?` | `{changed, accessory, from, to}` |
| `rename_accessory` | `accessory`, `new_name`, `home?` | `{changed, from, to, uuid}`. Changes the Apple Home name only |
| `rename_room` | `room`, `new_name`, `home?` | `{changed, from, to, uuid}` |
| `add_room` | `name`, `home?` | `{changed, room, uuid}`. Returns the existing room if the name already exists |

## Home Assistant bridged accessories

Home Assistant's HomeKit Bridge sets each accessory's serial number to the entity_id
(for example `climate.living_room`). So `set_accessory_room accessory=climate.living_room
room="Living Room"` works without first looking up a UUID, and
`scripts/manage_homekit_rooms.py` can map HA areas to Apple Home rooms.

Renaming in Apple Home does not rename the HA entity. Removing an entity from the bridge in HA
removes the accessory, and its room assignment is lost; re-adding it puts it back in the
default room.

## CLI

`scripts/homekitctl.py` wraps the tools (Python standard library only):

```bash
python3 scripts/homekitctl.py homes
python3 scripts/homekitctl.py rooms
python3 scripts/homekitctl.py accessories --query climate.
python3 scripts/homekitctl.py move climate.living_room "Living Room"
python3 scripts/homekitctl.py rename-room "Office" "Study"
python3 scripts/homekitctl.py --json call list_accessories room="Kitchen"
```
