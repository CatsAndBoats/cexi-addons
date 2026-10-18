# Auction House for VanaCore

The CatsEyeXI auction house as its own window, in the Party Finder's style: browse every category with live
stock, search all 10,000+ listed items by name, read an item's recent sales with the median, range and trend, and
bid from its card; sell from your bag with the house's fee quoted before you commit; see what you have up and
take it down. Item names, descriptions, stats and icons come from the game's own data files.

Nothing runs on the server. Buying, selling and your sales use the game's auction packets exactly as the native
window does, and the search server is asked for categories, stock and history the way the game asks it, so the
addon works on any LandSandBoat-based server, CatsEyeXI live and test included.

`/ah` opens it (Ctrl+A by default). Stand by an Auction Counter, as you would.

## Install

Copy the `auctionhouse-vanacore` folder to `Vanacore\addons\vanacore\` and add `/addon load auctionhouse-vanacore`
to `Vanacore\scripts\boot.txt`. Needs VanaCore 0.7.47 or newer (its `vana.imgui`).

## Using it

**Buy.** Categories are grouped on the left (Weapons, Armor, Scrolls, Items, Materials, Food, Others); a count
beside each category is how many of its items are up right now. The list shows each item's icon, level and jobs,
how many singles and stacks are up, and the last sale once it's known. The search box finds any listed item by
name, across every category. Click an item for its card: description, the jobs that can use it, stock, the last
ten sales for singles or stacks with **last · median · range** and the trend, and the bid box. The house fills
the cheapest listing at or under your bid and you pay what you bid, as always; the box starts at the last sale.

**Sell.** Your bag, with the items the house doesn't take greyed. Pick one, choose single or full stack, set a
price (recent sales are shown), and **Ask the fee**: the house quotes its listing fee, then **Put it up for sale**
commits. **My sales** lists what you have up, with the price and when, and takes a listing down.

**Settings** (the gear): only at an Auction Counter, confirm before bidding, opacity, scale, and the search server
in use.

## Commands

| Command | Action |
|---|---|
| `/ah` | Open or close the window (Esc closes it too) |
| `/ah buy` / `sell` / `sales` | Open on that tab |
| `/ah search <name>` | Open with a name search |
| `/ah pick <id or name>` | Open on an item's card |
| `/ah server <host[:port]>` | Which search server to ask; `/ah server auto` finds it from your login again |
| `/ah scale <percent>` | Window size, 50 to 300 |
| `/ah opacity <percent>` | Window opacity, 40 to 100 |
| `/ah refresh` | Forget fetched lists and histories |
| `/ah debug` | Counters, the search server, whether a counter is near, the last error |

Settings are kept per character in `Vanacore\config\addons\auctionhouse-vanacore\<name>.lua`.

## How it talks to the server

- **Buying, selling, your sales:** packet `0x04E` out and `0x04C` in (`map/packets/c2s/0x04e_auc.h`): WorkCheck when
  the window opens, Bid, AskCommit then LotIn to sell (both carry an auction work slot 0–6 at 0x05; the server refuses
  −1 there without a word), Info for the sales list (the server's AH pagination module
  pages it six at a time; its chat lines are hidden while the window is asking), LotCancel to take one down. The
  server checks the zone has an auction house; standing at a counter is the addon's own rule (settings).
- **Categories, stock, history:** the search server (`src/search`), over TCP on the login host, port 54002. The
  addon speaks its protocol itself (`search.lua`): a length-prefixed packet, Blowfish over the body with a key made
  from 16 fixed bytes, 4 random bytes sent in the clear and, for the reply, 4 more carried inside the request; an
  MD5 of the payload inside. One detail worth knowing if you port this: the server reads its key as *signed* bytes,
  so any key byte of 0x80 or more sign-extends across the word in its key schedule, and the cipher's round function
  is LandSandBoat's own, not textbook Blowfish. Both are reproduced. Sockets are non-blocking and stepped from the
  frame; the game never waits on the network.
- The search host is read from VanaCore's log ("Game start: on <host>"), the host you logged in to; override it
  with `/ah server`.

## Files

- `auctionhouse-vanacore.lua` — the addon: state, the game packets, the window
- `search.lua`, `bf_tables.lua` — the search-server client and LandSandBoat's Blowfish boxes
- `items.lua` — the game's item data through the resource manager, icon textures, the catalogue and name search
- `catalogue.lua` — every item the house lists (`item_basic.aH > 0`), with its category, stack size, level, jobs
  and slot. Regenerate from the server database when items change:
  `SELECT b.itemid, b.aH, b.stackSize, b.flags, COALESCE(e.level,0), COALESCE(e.jobs,0), COALESCE(e.slot,0) FROM item_basic b LEFT JOIN item_equipment e ON e.itemId = b.itemid WHERE b.aH > 0 ORDER BY b.itemid`
  into `{id,cat,stack,flags,level,jobs,slot},` rows.
- `ui.lua` — the drawing kit, generated from the Party Finder addon's helpers by `tools/make_ui.py` so the two look
  the same; edit there, not here
- `fonts/` — Inter and Rajdhani (SIL Open Font License, licenses included); `images/jobs.png` — the job sprites
