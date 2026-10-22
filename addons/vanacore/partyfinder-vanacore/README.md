# Party Finder for VanaCore

A from-scratch rewrite of the CatsEyeXI Party Finder for VanaCore's native addon API. It speaks the same
server protocol (packet 0x1A2 / 0x1A3) as the Ashita addon on the `main` branch, with its own window:
glass cards, the job sprites, role icons, live badges, a floating beacon in mini mode, and the Duty Roulette,
Mission Help and join-request flows.

It speaks protocol v2 when the server does (modules `pf-protocol-v2`: deltas instead of full lists, LFM
announcements as packets, "seen" and timeout feedback on join requests, server-side blocks, error codes) and
falls back to v1 traffic against an older server. See `documentation/party_finder_protocol.md` in the modules repo.

## Install

This branch is the addon itself. Put its contents in a folder named `partyfinder-vanacore` under
`Vanacore\addons\vanacore\` (the folder name is the addon's name; a download named `PartyFinder-vanacore` must be
renamed), then in game:

```
/addon load partyfinder-vanacore
```

It takes over `/pf` and Ctrl+G from the Ashita addon, and unloads that one if it's running (both would answer
the same packets).

Add that line to `Vanacore\scripts\boot.txt` to load it at every start. Ctrl+G opens it unless the key is
already bound. Closing the window tucks it into a beacon at the edge of the screen; click that to bring it back.
Whichever it is, the window or the beacon, is kept: zoning, a reload or the next login brings it back the same.
During a cutscene or a conversation with an NPC the finder and its beacon step aside, and come back as they were
when it ends.

## Themes and looks

Thirteen themes in settings (or `/pf theme`): each is a palette and a piece of art behind the listings, the art
with its own opacity. Picking a theme sets its art; the Artwork page (a thumbnail grid of everything in `bg/`)
or the Art dropdown can then swap it for any other.

Themes are also files: drop `themes/<id>.lua` beside the addon (see `themes/README.txt` and `themes/midnight.lua`)
and it joins the list. A whole look (theme, art, icon, opacities, logo motion) travels as one line: **Copy look** in
settings or `/pf export` puts it on the clipboard; **Paste look** or `/pf import <line>` applies it.

## Slots

When recruiting, the new-listing sheet has a chip per open slot. Each starts as the role you picked; click a chip to say exactly what that slot wants — a role glyph, or any set of jobs from the badge grid — or use a preset (Standard, Manaburn, TP burn) and "apply to all". On a v2 server the slots travel with the listing: cards and tooltips show what is genuinely still needed as members fill them, the join confirm tells you which slot you'd fill (or that your job isn't on the list — you can still ask), the request card tells the leader where a requester fits, auto-accept turns away jobs with no open slot, and "Only listings I can join" uses them.

## Pins and the roster

Hover a card and click its star to pin it: pinned listings stay on top, and when a pinned party's slot opens the
beacon pulses gold and a toast says so. While you're in a party, the action bar shows every member as a badge
with an HP ring (hover for details).

The first time the window opens, a three-step tour points out the essentials; `/pf tour` shows it again.

## Handheld mode

For the Steam Deck and other small screens: a narrow panel docked at the screen's edge, with compact cards, a
category dropdown instead of the chips, and the listing sheet and settings as dialogs. Auto (the default) turns it
on at 1280x800 or less; the setting under Window, or `/pf handheld on|off|auto`, forces it.

## Commands

| Command | Action |
|---|---|
| `/pf` | The window, or tucked into the beacon; the X and Esc tuck it too |
| `/pf hide` / `/pf show` | Hide both, or bring the window back |
| `/pf mini` | Tuck the window into the beacon, or bring it back. Drag the beacon to move it; it stays on screen. "Start as the beacon" in settings always starts there; otherwise it starts the way you left it |
| `/pf reset` | The beacon back at the right edge, scale and opacity at their defaults |
| `/pf create` | Open the new-listing sheet |
| `/pf refresh` | Ask the server for the listings again |
| `/pf notify` | LFM announcements in chat on or off |
| `/pf settings [art]` | The settings panel (`art` opens the Artwork page) |
| `/pf tour` | The three-step tour again |
| `/pf icon flag\|gem\|crest\|beacon` | The icon in the header and the beacon: the updated flag (FFXI's seek flag, drawn), the legacy flag (the original sprite), Social (a party crest), or the CatsEyeXI gem (also in settings; a PNG in `images/icons/` is offered too) |
| `/pf handheld auto\|on\|off` | Handheld mode (see above) |
| `/pf export` / `/pf import <line>` | Share a look, or apply one |
| `/pf theme <name>` | A theme: its colours and its art. `aurora` (the default), `gems`, `banner`, `ember`, `ranger`, `inferno`, `ninja`, `harvest`, `gunslinger`, `rose`, `bard`, `jade` |
| `/pf scale <percent>` | Window size, 50 to 300 |
| `/pf background <name>` | The art behind the listings, by file name, or `none` (also in settings, with its own opacity) |
| `/pf sounds [<pack>\|test]` | List the sound packs, pick one, or hear the current one |
| `/pf block <name>` / `unblock <name>` / `blocklist` | The block list; on a v2 server it is kept there too, so blocked players' requests never reach you |
| `/pf debug` | Packet counters and the last error |

Settings are kept per character in `Vanacore\config\addons\partyfinder-vanacore\<name>.lua`.

## Files

- `partyfinder-vanacore.lua`: the addon
- `fonts/`: Inter (text) and Rajdhani (display), SIL Open Font License; licenses included
- `images/`: the sprite sheets (`jobs.png`, `modes.png`, `lfg.png`; the role glyphs are drawn) and `gem.png`, the CatsEyeXI gem as an 11x11 frame grid (the server avatar at 128 px, 50 fps); `icons/` takes extra square PNGs for the icon picker
- `sounds/`: sound packs, one folder each, picked in settings or with `/pf sounds <pack>`: `classic/` (the original effects, levelled and trimmed) and `glass/` (a synthesized set of soft bell tones). A pack can leave out the newer sounds (`announce`, `join_denied`, `ready`); the nearest older one plays instead. Drop a folder of WAVs (16-bit PCM) here to add a pack
- `themes/`: theme files; `midnight.lua` is an example
- `bg/`: art for behind the listings: `cexi_gems.jpg` (the invite banner), `cexi_banner.12x7x84@33.jpg` (the server banner as a frame grid) and nine pieces by **Redkat** (`cexi_ember`, `cexi_ranger`, `cexi_inferno`, `cexi_ninja`, `cexi_harvest`, `cexi_gunslinger`, `cexi_rose`, `cexi_bard`, `cexi_jade`), signed in the corner when shown. Any PNG or JPG dropped here is offered too; a file named `name.COLSxROWSxFRAMES@FPS.jpg` plays as an animation.
