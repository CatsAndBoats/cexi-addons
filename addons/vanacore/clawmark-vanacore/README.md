# Clawmark for VanaCore

Raid-style target marks and waymarks for CatsEyeXI. Put one of eight marks over a monster (or anything you can
target) and everyone in your party or alliance sees it there, floating just above its nameplate. Each mark sits on one
target at a time and each target carries one mark, so putting a mark somewhere new moves it. Put one of eight waymarks
down on the ground, where people should stand, and everyone sees a column of light there with its letter or number
over the top. It needs the CatsEyeXI server's `target_marks` module, which passes them around.

The marks: star, circle, diamond, triangle, moon, square, cross and skull, numbered 1 to 8. Each is drawn with the
same dark outline, a soft shadow and a light-to-deep shine, so they read on any ground.

The waymarks, as FFXIV has them: A, B, C and D, round, and 1, 2, 3 and 4, square, each a ring of light on the ground
in its colour (red, yellow, blue, purple), a column of light rising from it in streaks and its glyph glowing over the
top, so a raid can be told "tank at A, ranged at 3".

## Install

Copy this folder to `Vanacore\addons\vanacore\clawmark-vanacore`, then in game:

```
/addon load clawmark-vanacore
```

Add that line to `Vanacore\scripts\boot.txt` to load it at every start.

## Using it

The mark bar, a glass strip in Party Finder's style:

- **Click** a free mark: it goes on your target. Click a mark that's **out**: you target what carries it, the same
  for the one who set it and for everyone else in the party. Click the mark **your target carries**: it comes off.
- **Shift-click** a mark that's out: it moves onto your target.
- **Right-click** a mark: takes it off wherever it is.
- **X**: hold it for a moment (a ring fills) and every mark comes off; a click alone does nothing, so a slip can't wipe
  the raid's marks. An orange dot on it means the server doesn't relay marks, so yours are seen by you alone.
- **The grip** at the left end: click it to fold the bar down to the marks in use (and open it again), hold it and
  drag to move the bar. The **gear** under it opens the settings.
- **A line under the bar** says what a click on the thing under the pointer will do ("Target Tunnel Worm · 48y",
  "Mark Wild Rabbit", "Unmark Tunnel Worm"), and nothing more: the bar is used in fights.
- **The waymarks' row** under the marks, A to D and 1 to 4: click a free one and it goes down at your feet; click one
  that's out and it comes off; **Shift-click** moves it to your feet; **right-click** takes it off. The X held takes the
  waymarks off with the marks. `/wp bar` hides the row for a bar of marks alone.
- **Right-click the ground** anywhere in sight and a menu of the waymarks opens at the cursor, the spot ringed on the
  ground: click one and it goes down there, within 60 yalms of you, so a spot in a room full of monsters can be marked
  from the door. (It needs a VanaCore with `vana.world.pick`; an older one has the row and the commands.)

A mark in use is tinted in its colour with a line under it; hover it to see on what and who put it there.

A marked target has a **ring of light** on the ground under it in its mark's colour, breathing, with a ripple going
out from it now and then. When you target something marked, the game's **Target window** glows in the mark's colour
and carries the mark in its top corner.

A **waymark** is a ring of light on the ground too (a square for 1 to 4), as wide as the Width setting, with a column of
light rising from it as tall as the Column setting (6 yalms as shipped; 0 for the ring alone) and its glyph floating
over the column's top, a yalm and a half tall there. Someone standing in the column is lit in front of it, it shows
against the sky, and whoever stands between you and the glyph hides it (on an older VanaCore the addon draws the glyph
itself over the screen, thinned while your own character is in front of it). A waymark stays where it was put until it's taken off, moved, or the whole group has left the
zone.

There are no modes: what a click does is in the mark itself, so a marker and a follower use the same bar the same
way. A mark that's out glows softly in its colour, the one your target carries most. The bar folds down to the marks
in use (the paw when none is), where the clicks work the same. The settings' **Clicks** block lists the rules.

**Right-click** a monster, a player or a mark floating over one: a menu opens at the cursor. Its head names the
target, what it is and how far, and which mark it carries and who put it there. Below are the eight marks as tiles:
the one it carries is ringed, one in use elsewhere is greyed with a dot, and hovering a tile says what clicking it will
do. Then **Take its mark off**, **Target it** and **Take every mark off**. A click elsewhere or Esc closes it. Only a
click opens it: holding the right button and dragging still turns the camera. A right-click on the ground, with nothing
targetable under the pointer, opens the waymarks' menu instead.

**Settings** (the gear, or `/mark settings`), a sheet that unfolds under the bar (drag its head to move it; it keeps
the offset):

- **Theme**: Party Finder's themes as gems; the bar, the menu and the settings all take it.
- **Scale**: the whole interface, or Auto (from the screen's height, as the Auction House does).
- **Opacity**: the bar's, with **Solid under the pointer** to bring it back to full when you reach for it.
- **Marks over targets**: their size, with a preview cycling through the eight at the size they're drawn in the world;
  how far over the name they float (0 to 3 of their own size, 0.3 as shipped); the ring of light under them.
- **Waymarks**: their row in the bar; the column of light's height; how wide they are.
- **Behaviour**: chat lines when others mark something; the right-click menu; the mark in the Target window.
- **Defaults** puts everything back but the bar's place.

Commands, for macros and key binds (`/claw` works the same as `/mark`):

| Command | What it does |
|---|---|
| `/mark` | The mark bar on or off |
| `/mark <mark>` | Puts the mark on your target, or takes it off if it's already there |
| `/mark <mark> <index>` | The same on that entity index |
| `/mark clear [<mark>]` | Takes one mark off, or all of them |
| `/mark target <mark>` | Targets what carries the mark |
| `/mark settings` | The settings |
| `/mark fold` | Folds the bar down to the marks in use, or opens it again |
| `/mark size <pct>` | The marks' size over targets, 50 to 300 |
| `/mark height <n>` | How far over the name they float, in their own sizes, 0 to 3 |
| `/mark chat` | Chat lines when other players mark something, on or off |
| `/mark rclick` | The right-click menu on or off |
| `/mark theme <name>` | The colours, one of Party Finder's themes |
| `/mark help` | The commands in chat |
| `/wp <waymark>` | Puts the waymark down at your feet, or moves it there (`/way` and `/waymark` work the same) |
| `/wp <waymark> target` | At your target's feet |
| `/wp <waymark> <yalms>` | So many yalms ahead of you |
| `/wp clear [<waymark>]` | Takes one waymark off, or all of them |
| `/wp bar` | The waymarks' row in the bar on or off |
| `/wp column <yalms>` | The column of light over a waymark, 0 (none) to 15 |
| `/wp width <yalms>` | How wide a waymark is, 0.5 to 4 |
| `/wp help` | The waymark commands in chat |

`<mark>` is 1 to 8 or the mark's name; `<waymark>` is A, B, C, D, 1, 2, 3 or 4. Some binds that work well:

```
/bind ^1 /mark skull
/bind ^2 /mark cross
/bind !1 /mark target skull
/bind ^a /wp a
```

Marks are hidden during cutscenes and fade out past 50 yalms. A mark comes off by itself when its target dies,
despawns or leaves the zone.

## How it talks to the server

It needs the server's `target_marks` module (CatsEyeXI modules repo, `cpp/target_marks.cpp`). Without it (no
answer within six seconds of the first sync), marks are kept for you alone.

Packet 0x1A6 both ways:

- **C2S**, 28 bytes: `0x04` action (1 set, 2 clear one, 3 clear all, 4 sync, 5 waymark down, 6 waymark off,
  7 all waymarks off), `0x05` mark 1-8, `0x06` u16 target index, `0x08` u32 target id, `0x0C` protocol version (1),
  `0x10` three floats x, y, z: the waymark's place, as the game has positions.
- **S2C**, always the whole state of one kind: `0x04` kind (1 the marks, 2 the waymarks), `0x05` version, `0x06`
  reason (0 sync, 1 set, 2 cleared, 3 all cleared, 4 target gone, 5 refused), `0x07` the mark that changed, `0x08` u32
  who changed it. The marks, 108 bytes: from `0x0C` eight 12-byte slots: u32 target id (0 unused), u16 target index,
  u16 0, u32 setter id. The waymarks, 140 bytes: from `0x0C` eight 16-byte slots: three floats x, y, z, then u32
  setter id (0 unused).

The server keeps marks and waymarks per group (alliance, else party, else just you) and zone. It sends the state to
every group member in the zone whenever it changes; the addon asks for it again on load, on zoning and when the party
or alliance changes. A waymark has to be within 60 yalms of whoever puts it down.

## Drawing

A mark sits over the target's name where the game draws it (`vana.world.name_at`, a VanaCore newer than 0.8.216), the
right height for any model; on an older VanaCore, over the target's top (the top face of the game actor's bounding box,
at actor `+0x958`) projected through the game's view and projection matrices, read from the Direct3D device each frame,
which puts it too high over a model whose box reaches above its head (a dragon's wings). The shapes are drawn with
ImGui's draw lists, so there are no image files: each shape is a set of polygons, circles and rounded boxes,
drawn grown by a fixed width in near-black for the outline (a thick line along every edge and a disc at every corner,
so all eight get the same outline), then filled in bands clipped to whole-pixel strips for the shine.

The ring of light under a target is VanaCore's (`vana.world.marks`, a VanaCore newer than 0.8.216, with the scene effects of the
Direct3D 11 and 12 renderers): laid onto the ground the scene's own depth shows, so it follows a slope and whatever
stands in front of it, the monster itself or a player, hides that part. The addon sends the marked targets' rings
each frame, as wide as each one's bounding box, and the waymarks' with them, each with its shape and the column's height
(a VanaCore newer still draws those: an older one draws the ring alone). On an older VanaCore, or the game's own Direct3D
8, the addon draws a ring over the screen instead, which nothing hides. A waymark's glyph is the addon's own drawing, a
rune of thick strokes with a glow, at the column's top projected through the same matrices. The mark in the Target window goes by `vana.gameui.rect('target_window')`
(the same VanaCore); an older one shows none.

Settings: `settings\addons\clawmark-vanacore\settings.json` (`bar`, `folded`, `size`, `chat`, `right_click`, `theme`,
`scale`: 0 sizes it from the screen, `opacity`, `solid`, `glow`, `in_target`, `height`, `settings_dx`, `settings_dy`: where the settings were dragged to,
`ways`: the waymarks' row, `beam`: their column's height, `way_radius`: their width). The bar's place is kept by ImGui, in `config\imgui.ini`.

`ui.lua` is the drawing kit Party Finder and the Auction House share, generated by `tools/make_ui.py` (edit Party
Finder, then run it). Fonts: Inter and Rajdhani in `fonts/`, both under the SIL Open Font License.
