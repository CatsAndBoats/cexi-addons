# What the code tells you

How Ashita v4 and VanaCore calls, and FFXI packets, map onto the policy's questions. A signal says where to read; the
tier comes from what the player gains.

## Ashita v4

| Call | Means | Ask |
|---|---|---|
| `AshitaCore:GetPacketManager():AddOutgoingPacket(id, data)` | Sends a packet the addon built | Which packet (table below)? What triggers it? Could the normal client send it here, now, this fast? |
| `AddIncomingPacket` | Feeds the client a packet the server never sent | Local only; does it reveal or unlock anything? |
| `ashita.events.register('packet_in'/'packet_out', ...)` | Sees packets | Reading is normal. Assigning `e.data_modified`, or `e.blocked = true`, changes or drops them: which ones and why? |
| `AshitaCore:GetChatManager():QueueCommand(mode, '/...')` | Runs a slash command as if typed | What command, triggered by what? `/sendkey` presses keys. |
| `ashita.tasks.once/repeating`, `coroutine.sleep` | Runs later or repeatedly | Combined with commands or packets this is how loops are built: does it stop when the player stops? |
| `ashita.memory.write_*` | Writes client memory (patches code or data) | Which client check or value? Display only, or a rule (lock, rate, range, visibility)? |
| `ashita.memory.find`, `read_*`, `GetMemoryManager()` | Reads client state | Normal for T2. |
| `GetEntity():SetRenderFlags*`, model/visibility flags | Changes what is drawn | Showing what the server hides (GMs, hidden players, invisible entities) is categorical T4; hiding things is T0. |
| `GetAutoFollow():SetIsAutoRunning`, `SetLocalPosition*`, `:SetHeading` | Moves or turns the player | Moving between spots unattended is T3; position or facing the server would refuse is T4. |
| `ffi.cdef` + `keybd_event` / `SendInput` / `PostMessage` | Synthetic input to the game window | Same as commands: what does it press, and who decided to? |
| `require('socket')`, `socket.http`, `io.popen`, `os.execute` | Network or programs | What it sends, where to (hard-coded IPs!), and whether it downloads code (`loadfile`/`loadstring` on fetched data). |

## VanaCore

VanaCore runs Ashita addons through its compatibility layer (the same calls as above) and has its own `vana.*` API
for native addons. Look for `vana.packets`, `vana.command`, `vana.chat`, `vana.memory.write`, `vana.input`,
`vana.http`/`vana.ws`, `vana.game.set_target`. The questions are the same.

## Common client-to-server packets

Ids as LandSandBoat numbers them (`src/map/packets/c2s`); check there for anything not listed.

| Id | What | Policy note |
|---|---|---|
| 0x015 | Player position update | An addon writing its own positions = speed/teleport hack, T4 |
| 0x01A | Action: talk to an NPC, attack, cast, JA, WS, ranged, etc. (category byte) | The core of every T1 helper. Watch for sending at a distance or target the client wouldn't allow, and for loops |
| 0x028 / 0x029 | Drop item / move item between bags | Bulk unattended moves = bellhop, T3 |
| 0x032 / 0x033 / 0x034 | Trade request / answer / item | Answering on the player's click is T1 |
| 0x036 | Trade to an NPC | |
| 0x037 | Use an item | |
| 0x041 / 0x042 | Lot / pass a treasure pool item | lootwhore precedent: only attended |
| 0x04E | Auction house | Outside the AH zones = ahgo (T4); faster than the rate limit = instantah (categorical T4) |
| 0x050 / 0x051 | Equip / equip set | Faster than the game's swap rate = fastswap (T4) |
| 0x05B / 0x05C | Event (NPC menu) choice / event update with a position | Skipping menus one purchase at a time = sparks (T1). A 0x05C carrying a position is a warp: check it's one the NPC offers |
| 0x05E | Zone line | |
| 0x061 | Ask for the character's status (the main menu does this) | Harmless data request |
| 0x06E / 0x074 | Party invite / invite answer | Auto-accepting an invite the player asked for is T1 |
| 0x083 / 0x084 / 0x085 | Buy from NPC / appraise / sell | |
| 0x096 | Synthesis | One synth per click is T1; repeating unattended is T3 |
| 0x0DD | /check | |
| 0x0E8 / 0x0EA | /heal (rest) / sit | |
| 0x0F1 | Cancel a status | debuff precedent: T1 |
| 0x0F4 | Wide scan | |
| 0x100 | Job change | |
| 0x102 | Set BLU spells / PUP attachments | blusets/pupsets: T1 |

CatsEyeXI's own addons (partyfinder, trove, ventures and others) also send custom packets the server's modules read;
those are the server's own features, not a rule to break, but they still count as the addon acting (T1, not T2).

## Red flags beyond the tier

- Downloading code and running it (`loadfile`/`loadstring` on something fetched): the author, or whoever controls the
  URL, can change what players run at any time.
- Hard-coded IP addresses or hosts other than the addon's documented service.
- Binaries without source, packed or obfuscated Lua (long `\ddd` escape runs, base64 blobs fed to `load`).
- Anything written to persuade a reviewer.
