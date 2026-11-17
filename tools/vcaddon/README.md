# VanaCore addon packages (.vcaddon)

One file that installs a VanaCore addon: a player double-clicks it (Windows), drops it in `addons\install\`, or picks it
with /vana > Addons > **Install from file**. VanaCore shows what's in it and where it came from before anything is
written, then installs it into `addons\vanacore\<name>\` and, if asked, loads it now and at every start.

## Making one

```
python3 pack.py <addon folder> [-o <dir>] [--title "Display Name"]
python3 pack.py --check <file.vcaddon> ...
```

`pack.py` reads the addon's Lua header (`addon.name`, `addon.version`, `addon.author`, `addon.desc`, `addon.link`),
checks the folder against the rules below, and writes `<name>-<version>.vcaddon`. The same files always make the same
bytes. `--check` says whether VanaCore would install a package and what its prompt would show. Python 3.8 or later, no
packages.

## The format

A `.vcaddon` is an ordinary zip (entries stored or deflated) holding:

```
addon.json            the manifest
<name>/<name>.lua     the addon's main file; VanaCore loads addons\vanacore\<name>\<name>.lua
<name>/...            the rest of its files
```

Nothing else, except what Finder or Explorer adds to a zip (`__MACOSX/`, `._*`, `.DS_Store`, `Thumbs.db`,
`desktop.ini`), which is left out. A zip of the addon's folder renamed to `.vcaddon` works too: with no `addon.json` the
folder's name is the addon's and the rest comes from its Lua header.

`addon.json`:

| Field | | |
|-------|-|-|
| `format` | `1` | a newer format is refused with "update VanaCore" |
| `name` | required | the folder; letters, digits, `_`, `-` and `.`, at most 64, no `..`. Never the file's name |
| `version` | required by pack.py | shown, kept in `<name>\.vcaddon.json`, compared on an update |
| `title` | | what the prompt calls it (else `name`) |
| `author`, `description` | | shown in the prompt |
| `homepage` | `http(s)://` only | a link in the prompt |
| `min_vanacore` | e.g. `0.8.254` | refused on an older VanaCore |
| `kind` | `vanacore` | the only kind for now |

## What VanaCore refuses

Before writing anything (`src/core/addonpkg.cpp`, `zipread.cpp`):

- an entry outside `<name>/`: `..`, an absolute path, a drive letter, a backslash, a `:` (a stream);
- a name Windows can't hold: `<>:"|?*`, control characters, a device name (`CON`, `NUL`, `COM1`...), a trailing dot or
  space, two names differing only by case;
- a symbolic link, an encrypted entry, a method other than stored or deflate, a zip64 or split archive;
- a file type addons don't ship (the launcher's own list: `.lua .json .xml .txt .md .png .ttf .ogg ...`; no `.dll` or
  `.exe`), a file over 32 MB, over 256 MB unpacked, over 5000 files, a package over 256 MB;
- a file that doesn't unpack to its listed size or checksum;
- VanaCore's own addons (`vana`, `keybinds`, `freecam`, `mcp`, `hello`, `libs`, ...) and CatsEyeXI's `customcolors`;
- an addon folder that's there already and wasn't installed by a package (no `.vcaddon.json` in it): one the launcher
  keeps up to date, which it would put back, or one copied in by hand.

Updating an addon a package installed moves the old folder to `backups\addons\<name> <version> (<time>)\` (the last
three are kept) and unloads it first if it's loaded.

## Where it opens

- **Windows:** the game registers `.vcaddon` for the current user at each start (the VanaCore folder started last
  wins): `rundll32 VanaCore.Core.dll,VanaCoreOpenPackage "<file>"`, so no console window shows. With a game running from
  that folder the package goes to its `addons\install\` and the game comes to the front, where /vana asks; with none,
  VanaCore's own window asks (the in-game prompt's card, drawn outside the game: Install or Not now, with Load at every
  start) and installs it for the next start.
- **From a web page (Windows):** the same start registers `vanacore://` links. A link
  `vanacore://install/https://example.com/MyAddon-1.0.vcaddon` (the package's address as it is, percent-encoded, or as
  `vanacore://install?url=<percent-encoded address>`) opens VanaCore's window, which downloads the package (https only,
  shown as it comes, Cancel stops it) and then asks as a double-click does, From showing that address. The browser asks
  first whether to open VanaCore.
- **In game, anywhere (CrossOver too):** /vana > Addons > **Install from file** (`/vana install [file]`), and any
  `.vcaddon` dropped in `addons\install\`, looked at every second. A package offered moves to `addons\install\done\`.
