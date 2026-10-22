# CatsEyeXI addons

The client addons made for the CatsEyeXI server, for Ashita and for VanaCore, each in its own folder laid out the way
the clients keep them, so a folder copies straight into place.

| Addon | For | Folder | What it is |
|---|---|---|---|
| Party Finder 2.14 | Ashita | [`addons/ashita/partyfinder`](addons/ashita/partyfinder) | LFG/LFM listings, Duty Roulette, Mission Help and Venture parties |
| Party Finder 2.2 | VanaCore | [`addons/vanacore/partyfinder-vanacore`](addons/vanacore/partyfinder-vanacore) | The same finder rewritten for VanaCore's native API: glass cards, slots, themes, sound packs |
| Auction House 1.0 | VanaCore | [`addons/vanacore/auctionhouse-vanacore`](addons/vanacore/auctionhouse-vanacore) | The auction house as its own window: stock, sale history and graphs, watch list, selling, sold notices |

Each folder has its own README with what it does, its commands and how it talks to the server.

## Installing

- **Ashita:** copy `addons/ashita/partyfinder` to `Ashita\addons\` and `/addon load partyfinder`.
- **VanaCore:** copy a folder from `addons/vanacore/` to `Vanacore\addons\vanacore\` and `/addon load <folder name>`, for
  example `/addon load auctionhouse-vanacore`. Add the same line to `Vanacore\scripts\boot.txt` to load it at start.

Party Finder needs the server's Party Finder module (`party_finder` in the CatsEyeXI modules repo); the Auction House
runs on any LandSandBoat server and needs nothing server-side.

## Publishing to the launcher

**Actions → Publish to R2 → Run workflow** puts the VanaCore addons into the launcher's VanaCore build, at
`Vanacore\addons\vanacore\<folder>`, so players get them with the build and the launcher keeps them current. Only the
files that changed go up. Tick *dry run* to see what would change first; *addons* narrows it to some folders, *tags*
picks the builds (only `vanacore` for now). The Ashita Party Finder isn't published from here.

- A file taken out of an addon is deleted from players' installs at the launcher's next check. A whole folder taken out
  of this repository stays in the build until it's removed from the Manager.
- A new addon folder also goes in the launcher's `DEPLOY_IGNORE` (`.github/scripts/push_build.py`, and the Manager's
  `deploy_ignore`), so a VanaCore release pushed with deletes leaves it alone.
- The workflow needs the launcher repository's R2 secrets: `R2_S3_ENDPOINT`, `R2_ACCESS_KEY_ID`,
  `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`, and optionally `CLOUDFLARE_ZONE_ID` and `CLOUDFLARE_API_TOKEN` for the cache
  purge. The script is [`.github/scripts/publish_r2.py`](.github/scripts/publish_r2.py).

## Layout rules

- **A folder's name is its addon's name.** Clients load `addons\<folder>\<folder>.lua`, and the name is also what
  `/addon load` takes and where each character's settings are kept (`config\addons\<name>\`). Renaming a folder
  renames the addon, so players' settings and load lines would no longer find it.
- **Each addon folder stands alone.** Players install one folder at a time, so its fonts and images live inside it,
  even where two addons carry the same files.
- **Shared source lives in `tools/`.** [`tools/make_ui.py`](tools/make_ui.py) builds the Auction House's drawing kit
  and themes (`auctionhouse-vanacore/ui.lua`) from Party Finder's helpers, so the two look the same: change Party
  Finder, then run `python tools/make_ui.py` from anywhere.

## History

The three addons came from separate lines, each kept here with its full history under its folder: the Ashita Party
Finder from PartyFinder's `main`, the VanaCore one from its `vanacore` branch, and the Auction House from its own
repository. `git log -- addons/<client>/<addon>` shows an addon's history.
