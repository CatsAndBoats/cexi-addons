# VanaMaps

The game's maps as a window you can use, for VanaCore. Drag the map, zoom with the wheel, open any zone's map from
anywhere, drop pins with notes, and share a pin in chat.

- **Every zone, every floor.** The zone browser lists each zone that has a map, grouped by region, with a search box.
  Floors have their own buttons; back and forward step through what you looked at; "Where am I?" comes back to you.
- **Nothing on the map's art.** Only what is on the map sits on the picture: you, your party, your target, pins and
  signposts. The floors are in the window's header (a button each; a drop-down for a zone of more than six maps), and
  the pointer's square and coordinates, find me, zoom and the picture's size are in a strip under the map. On the bare
  map the floors hang over its top edge and the strip under its bottom edge, and both show only while the pointer is
  there. (Zoomed in, the grid's letters and numbers run along the edges, where the map's own have gone out of view.)
- **You are on it.** Your arrow with the way you face, your party and alliance members in the zone, and your target.
  The map follows you until you move it, and changes floor and zone with you.
- **Mouse, keys and controller.** Drag to pan (a thrown map glides), wheel to zoom about the pointer, double-click to
  centre and zoom in, right-click for a menu. `M` opens and closes it while the chat line is closed (the key is a
  setting). With a controller: left stick the pointer, right stick the map, triggers zoom, bumpers change floor,
  Confirm drops or opens a pin, Options goes to the lists, Cancel backs out.
- **Ways into the next zone.** A signpost marks each way out of a zone, where its doorway is. Click one and the
  neighbour's map opens, with a ring where you would come out; back takes you back. The crosshair button on the map
  finds you again from anywhere, and when you are off the edge of the view a small arrow at the edge points to you.
- **See-through while you move.** While your character moves, the map fades (to 40% unless you set otherwise) so the
  world shows through it, and your clicks and camera drags go through it to the game. It comes back as you stop. Your
  arrow, your party and your pins stay clear.
- **The bare map.** `Shift+M` (or `/vmap bare`) shows the map alone: no window, no buttons, no lists, following you,
  fading the same way as you move. `Shift+M` again closes it; `M` from it goes to the whole window, and `Shift+M` from
  the window comes back. Its buttons (floors, zoom) show only while the pointer is on it. Shift + drag moves it and
  Shift + wheel sizes it, and it stays where you put it. The controller is left to the game while it is up, so you can
  walk by it; Escape is left to the game too.
- **Pins.** An icon (24), a colour (8), a title and a note, kept per character. They are listed and searchable, and
  each shows its grid square.
- **Sharing.** A pin goes to say, party, linkshell, shout or a tell as a line anyone can read:

      [Map: West Ronfaure G-10 "Orcish camp" #8S00EMTFGT5]

  A player with VanaMaps who sees it gets a card with **Open map**, and the pin is kept in their Shared list, where it
  can be saved as their own. It works on any server: it is chat text, not a packet.

## Commands

`/vmap` works as well as `/vanamaps`.

| | |
|---|---|
| `/vmap` | The map on or off |
| `/vmap bare` | The bare map on or off |
| `/vmap here` | The zone and floor you are in, centred on you |
| `/vmap zone <name or id>` | Any zone's map |
| `/vmap pin [title]` | A pin where you stand |
| `/vmap share [s\|p\|l\|l2\|sh\|t <name>]` | The selected pin, or where you stand, to that chat; with no channel the line is copied |
| `/vmap open <code or line>` | Opens a shared pin |
| `/vmap last` | Opens the pin shared with you most lately |
| `/vmap key <key>` | The key that opens the map, as `/bind` spells it: `m`, `^m` (Ctrl+M), `f9`; `none` for no key |
| `/vmap barekey <key>` | The same for the bare map (`+m` is Shift+M) |
| `/vmap scale <pct\|auto>` | The window's size |
| `/vmap settings` | Theme, size, opacity, map quality, what is drawn on the map, the key |
| `/vmap stats` | Maps known, textures held, and what a frame of the map costs |

## The maps

VanaMaps ships no maps. It reads them from your own game files:

1. the **XICombinedMaps** pack's 2048 pixel maps, then its 1024 pixel ones, when the launcher's Combined Maps is
   installed (`Ashita\polplugins\DATs\ffxi-maps`);
2. any other overlay the game itself reads its files through (VanaCore's `[pivot.order]`);
3. the game's own 512 pixel maps.

The map pack is the work of **RadialArcana** (FFXIAH), the **FFXI Remapster Project** (remapster.com) and **Moops'
Remapster Labeled**, gathered as XICombinedMaps. Thank them for how good the maps look.

Which map a zone and floor has, and where a position lands on it, come from the game's own map table, read from the
client as it runs, so the grid square VanaMaps names is the one `<pos>` gives. The table is found by the signature the
Ashita **Minimap** plugin by **atom0s** uses for it. The Ashita world map **UberMap** by **Seekey** was read for ideas
(nothing of it is used here).

The signposts come from the server's zone lines (`tools/make_vanamaps_exits.py` writes `exits.lua`). A zone line says
where you arrive, so a zone's way to a neighbour is put where the line coming back sets you down, just inside the
doorway. In a zone with several maps, which map a doorway is on is the game's to say (it asks the zone's collision):
the answers gathered by visiting those zones ship in `exits.lua`, and one that is missing is learnt the first time you
have the map open in that zone (`settings\addons\vanamaps-vanacore\floors.json`). Nothing warps you: a signpost only
opens a map.

A large map gets a half-size and a quarter-size copy made in the background the first time it is shown small, so it
stays sharp at any window size; textures not shown lately are released.

## A keyboard that types straight into chat

On the game's full-keyboard layout any letter opens the chat line with that letter in it, and a bare `M` bind would
swallow the letter M. VanaMaps watches for that (four different letters each opening the chat line) and moves its keys
to `Ctrl+M` and `Ctrl+Shift+M`, once, telling you. A key you pick yourself in the settings is left alone.

## Links in chat addons

A chat addon that can make text clickable can open a pin by running `/vmap open` with the code or the whole bracketed
line: `/vmap open #8S00EMTFGT5`. VanaCore's own chat log has no clickable text, which is why a shared pin arrives as a
card and in the Shared list.

## Files

- Settings: `settings\addons\vanamaps-vanacore\settings.json`
- Pins and the Shared list, per character: `settings\addons\vanamaps-vanacore\<Character>\pins.json`
- `ui.lua` and `pad.lua` are the shared kit and controller helper (`tools/make_ui.py` writes them);
  `regions.lua` and `exits.lua` are written by `tools/make_vanamaps_regions.py` and `tools/make_vanamaps_exits.py` from
  the server's source.

## The code in a pin's line

Eleven characters of Crockford's base 32 (no I, L, O or U), 55 bits: version 2, zone 10, floor 8, x 11 and y 11 (the
map's own 512 units, in quarters), icon 5, colour 3, check 5. The words before it are for people; only the code is
read back.
