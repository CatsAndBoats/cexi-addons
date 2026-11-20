# VanaStore

The addons [ffxiprivateservers.com](https://ffxiprivateservers.com/addons) lists, in a window in the game.
Browse them, read about one, install it, update it, and switch it on or off without leaving the game.

- **Browse.** All addons, the ones you have, and the ones with an update; General or Server-specific, as the site
  sorts them; a search box. Each addon has a page of its own with its pictures, its description, its version and size,
  and a link to its page on the site.
- **Install and update.** One button. The file comes from the site, its SHA-256 is compared with the one the site's
  catalog gives before anything opens it, and VanaCore's own package installer does the rest. A file that doesn't
  match is deleted unopened, and the window says so.
- **Reviewed, or not.** An addon ffxiprivateservers.com has reviewed carries a small shield by its name. One it
  hasn't is marked "Not reviewed" and can still be installed: the store asks first, in plain words, before anything is
  downloaded. Either way the file must be one the site hosts, with its checksum.
- **Every framework the site lists.** VanaCore, Ashita and Windower addons are all shown, each card saying which.
  VanaCore's packages install VanaCore addons only so far, so the others have "View on FFXIPS" in place of Install
  (`catalog.lua`'s `D.INSTALLS` is the one switch); a native plugin is never installed from the store.
- **Taking over.** An addon the launcher installed, or one copied in by hand, can be handed to the store where
  VanaCore allows it: the store asks, replaces it with the site's package, and keeps it updated from then on.
- **On and off.** An installed addon has a switch: on loads it now and at every start, off unloads it and takes it
  out of `scripts\boot.txt`.
- **What it leaves alone.** VanaCore's own addons, and itself: the store ships and updates with VanaCore.
- **Mouse, keys and controller**, the same window size and opacity settings as the Auction House, VanaMaps and Party
  Finder windows, kept per character.

## Commands

`/store` works as well as `/vanastore`.

| | |
|---|---|
| `/store` | The store on or off |
| `/store search <words>` | Opens it on a search |
| `/store scale <pct\|auto>` | The window's size, 60 to 250 |
| `/store settings` | Size, opacity, controller |

## Files

| | |
|---|---|
| `settings\addons\vanastore\<Character>\settings.json` | The window's size, opacity and place |
| `settings\addons\vanastore\installed.json` | What the store installed, with each file's checksum |
| `settings\addons\vanastore\catalog.json` | The catalog as last fetched, for a start with no network |
| `cache\vanastore\` | Pictures, and a download while it is checked |

## For developers

- `catalog.lua`'s header has the catalog's format, as the site serves it at `/api/addons`.
- `tools/vanastore_test_origin.py <folder>` stands in for the site's routes on 127.0.0.1; `/store origin
  http://127.0.0.1:8765` points the store at it and `/store origin default` puts it back. Only https origins, or http
  on this PC, are taken.
- `ui.lua` and `pad.lua` are the family's, written by `tools/make_ui.py`: edit them there.
- Fonts: Inter, Press Start 2P and JetBrains Mono, each under the SIL Open Font License (`fonts\LICENSE-*.txt`).
