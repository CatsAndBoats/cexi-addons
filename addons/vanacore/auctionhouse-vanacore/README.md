# Auction House for VanaCore

The CatsEyeXI auction house as its own window, in the Party Finder's style: browse every category with live
stock, search all 10,000+ listed items by name, read an item's recent sales with the median, range and trend, and
bid from its card; sell from your bag with the house's fee quoted before you commit; see what you have up and
take it down. Item names, descriptions, stats and icons come from the game's own data files.

Nothing runs on the server. Buying, selling and your sales use the game's auction packets exactly as the native
window does, and the search server is asked for categories, stock and history the way the game asks it, so the
addon works on any LandSandBoat-based server, CatsEyeXI live and test included, with two exceptions that
need CatsEyeXI's server modules: **My Sales** lists your sales only because its `ah_pagination` module sends them
when asked (on a stock server that tab stays empty), and sold notices come from its `ah_announcement` module.

Talking to any auction clerk opens it in place of the game's menu (a setting; off, the game's menu comes back):
the city Auction Counters and the outpost clerks of Jeuno, Rabao, Norg, Kazham, Tavnazia, Al Zahbi, Nashmau and the
rest alike, since it goes by the server's answer, not the clerk's name. `/ah` (Ctrl+A by default) opens it anywhere
for browsing; bidding, selling and taking down always need you at a clerk, which `/ah` knows once you've talked to
one there (below). That isn't a setting: the server only checks that the zone has an auction house, so the addon
keeps trading at the counter, as the game's own window does.

## Install

Copy the `auctionhouse-vanacore` folder to `Vanacore\addons\vanacore\` and add `/addon load auctionhouse-vanacore`
to `Vanacore\scripts\boot.txt`. Needs VanaCore 0.7.47 or newer (its `vana.imgui`).

## Using it

**Buy.** Categories are grouped on the left (Weapons, Armor, Scrolls, Items, Materials, Food, Others); a count
beside each category is how many of its items are up right now. The list shows each item's icon, level and jobs,
how many singles and stacks are up, and the last sale once it's known; sort it by name, level or stock (names A to Z, level and stock highest first; click the sort in use again
to turn it round, and its arrow shows which way it runs), and the
**In stock** chip hides everything with nothing up, and the **Usable** chip hides gear your current main job,
at its level, and your race can't wear, and spell scrolls neither your main job nor your sub job can learn at
their current levels (the server's own rule when a scroll is used); anything else (food, medicines, materials) stays
listed (both chips at the right of the tab row, both remembered). Gear you can wear and scrolls you can learn have a
yellow name in the list, and the rest of those are dimmed. The search box in the header finds any listed item by
name, across every category. Click an item for its card: description, the jobs that can use it, stock, the last
ten sales for singles or stacks with **last · median · range** and the trend, a price graph, and the bid box. The
house fills the cheapest listing at or under your bid and you pay what you bid, as always; the box starts at the
last sale.

**The price graph.** Every sale the house ever tells this character about is kept (per server, see Files), so the
graph grows past the ten rows the search server hands out: the line is the price over time, the dashed line the
median of the latest ten, the marks at the left the gil scale, and hovering a point shows the sale. The graph icon
beside **Recent sales** hides or shows it (also in Settings).

**Compare.** With the **Compare** chip on, hovering a piece of gear in the list sets it against what you wear in
that slot (for earrings and rings, the one of the pair it would do most for, an empty one first): a card beside the
mouse with the verdict (upgrade, downgrade, trade-off, can't wear), how many stats get better or worse, and each stat
from what you have to what it gives, with the change. Weapons add damage a second from DMG and Delay. What isn't a
plain number (latent effects, set bonuses, added effects, Dynamis-only stats) is listed in words under **It also
has** and **You'd lose**, never counted. The stats are read from the game's own description of each item.

**Watch.** The star on an item's card follows it (singles or stacks, whichever is picked); `/ah watch <name>` does
too. The Watch tab is the one place to see them all: stock, the last price with how it moved over a week (or
lately, when the record is shorter), the median, a sparkline of the last thirty sales, and a **Tell me under** price.
Watched items are checked every five minutes while you play, house open or not, and a sale under your price or
stock coming back shows as a notice. Clicking a row opens its card.

**Sell.** Your bag, with the items the house doesn't take greyed (the **Sellable** chip above the bag hides them
instead, and is remembered). The two buttons beside it show the bag as icons or as a list with each item's name,
how many you have, its category and the last price it sold for once you've looked at it (also remembered). Pick one
and choose single or full stack (a stack's prices show even when you hold fewer; listing one waits for a full stack), and the **market** for it shows above the
price: how many are up right now (singles and stacks), last, median and range with the trend, the price graph
when there's room (each sale's difference from the median when there isn't), and the latest sales (price, when, who sold to whom).
Clicking last, median or any sale puts that price in the box, and beside the label it says how yours compares to the
median. Then **List for N gil**: the house quotes its listing fee, and a card spells out the
whole transaction (the item, the price, the fee paid now, the payout to your delivery box when it sells) for you to
say **List it** to.

**Listings.** Everything you have up, in one scrolling list, with the price and a **Take down** for each. The list
fills by itself when the tab opens, after you list or take something down, and on **Refresh**. The game's own window
shows seven listings; CatsEyeXI's server (its `ah_pagination` module) keeps more, six to a page, showing the next page
each time the list is asked for and answering once every 1.5 s, so a long list takes a few seconds to read; the rows
sit under a "Reading your listings" veil while it does, and nothing on them can be clicked until it lifts, so a
take-down never lands on a page the house has just turned. The pages stay the server's business: the one thing you may notice is that
taking down a listing the house isn't currently showing takes a moment (the confirmation says so) while the window
brings the house round to it. **History**
on a row asks the search server for that item's recent sales (only when you ask: nothing is fetched for rows nobody
looks at) and shows last, median, range and trend under the row, with where your price stands against the median.
**Relist** takes a listing down and puts it back up at a new price. Its dialog shows the price it's up for, the
median and the last sale, and offers cuts of 1, 5, 10 and 20 % with the price each gives, plus the median and the last
sale when they're lower; one is starred (the median when your price is above it, else a small cut), or type any price.
The listing comes down (the house's pages are turned to it first when needed), and once it's back in your bag the
house quotes the new fee, which you confirm as any listing: the fee is charged again and the old one isn't returned.
Cancel there, or anything the house refuses, leaves the item in your bag, and the window says so.
When one of your listings sells while you're on, CatsEyeXI's server says so (its `ah_announcement` module, a system
line naming the item, the buyer and the price): the window shows it as a notice, drops the listing, puts the sale on
the Activity tab, and keeps the price on the item's record. The chat line stays too.

**Activity.** A running record of what this character did at the house, kept across restarts: every purchase,
listing (with its fee), take-down and sale, newest first, twenty to a page (**Newer** / **Older**), with **All**,
**Bought** and **Sold** filters. The strip above it totals the gil over the whole record: spent on purchases, earned
from sales, paid in listing fees, and the net of the three. A sale is known only when the server announces it to you,
so one that happens while you're logged out shows in your delivery box, not here. **Clear** (beside the filters) empties the
whole record and its totals after asking; it doesn't touch anything you have up at the house.

**Typing a price.** The box you're typing in glows gold with a blinking caret; clicking a price box selects the
number so typing replaces it. Enter in the asking price is the List button, Enter in the bid box opens the bid's
confirmation (never a bid straight away), and Esc leaves the box, then a second Esc closes the window.

**A controller (experimental, off by default).** The switch is VanaCore's: `/vana`, Client, Gamepads, **XInput
gamepad support in VanaCore addons**, one for every addon (`vanacore.ini`'s `[addons] gamepad=1`; `/ah pad on` sets
it too). With two windows open, the one with the focus answers the pad. Tested with XInput
pads in mind; a DirectInput pad (a PlayStation controller without a wrapper) is read through the game's own button
map and may not line up. With it on, the window takes the pad while it's open, so your character stays put and the game's menus stay closed. The D-pad moves a ring between things and a stick walks it through whatever list it's in, faster the further the stick is pushed; a list stops at its ends. Confirm presses, Cancel backs out, the bumpers turn the tabs, Menu opens the settings, and **X and Y do what fits the pane the ring is in**, as the legend along the bottom says. **Buy** goes left to right, one pane at a time: the ring starts on the category in use in the sidebar; Confirm on a category moves it to that list's first item; Confirm on an item opens its card with the ring on the price box; Confirm there edits the price (below), Confirm again keeps it and moves to **Bid**, Confirm on Bid opens the confirmation, where Bid is already under the ring, so Confirm once more bids. Left and Right walk the same three panes (the list remembers its row, and Right from the list opens the highlighted item's card); Cancel walks back the same way (the confirmation, the card to its item, the list to its category, then the window). In the sidebar and the list, Y is the **In stock** filter, X the **Usable** filter, View the **Compare** chip and the triggers walk the categories; on the card, Y **watches** the item (or stops) and X swaps **single and stack**, which Up from the price box reaches too (Left and Right pick, Down goes back). **Sell:** the stick walks the bag a row at a time, Right from the bag is the price box and Left from it the picked item, Y is the **Sellable only** chip, X single or stack. **Listings:** the ring moves between each row's buttons; Y opens the row's **History**, X **relists** it. **Watch:** Y stops watching the row, X edits its **Tell me under** price. **Activity:** the triggers turn the pages, Y the filter, X the newest page. **Settings:** Y the next theme, X the next bell. A Confirm only ever does one thing: the press that keeps a price doesn't also press Bid. **A price:** the price box (Left from Bid, or Up from List on the Sell tab, gets back to it) takes Confirm as a digit editor, since a pad can't
type, worked as the game's own bid box is: the number starts at 0, right-aligned, with the ones digit lit; Left
moves the light up the columns (past the top digit it adds a zero in front, up to nine digits), Right brings it back
down and, at the ones, clears the number; Up and Down change the lit digit (carrying over, never below 0); Confirm
keeps the number and moves on to the button; Cancel puts back what was there. A legend of the buttons runs along the
bottom while the pad is in use; the mouse takes over the moment it moves. The game's Confirm and Cancel bindings are
honoured when VanaCore passes them (`[ffxi] gamepad.buttons`); otherwise A and B. With VanaCore 0.8.39 or later,
VanaCore itself feeds the pad to the window and keeps it from the game (`vana.gamepad.nav`); on an older VanaCore the
addon's own bridge (`pad.lua`) does the same from the game's controller reads. `/ah pad` shows the controller's
state, `/ah pad off` turns it off (a setting), and `/ah pad <button>` presses a button as a controller would, for
trying it without one.

**Settings** (the gear): the theme, talking to a clerk opens this window, confirm before
bidding, the price graph, background checks of watched items, opacity and scale, and the sound as it opens: a small
bell by default, or Counter bell, Door chime, Chapel bell, Crystal chime, Tiny bell, or Off (picking one plays it, and
the speaker beside it plays it again; `/ah sound <name>` and `/ah sound off` do the same). The search server isn't shown
there (it's your login server's address); `/ah debug` says which one is in use and `/ah server` changes it.

**Themes.** The same twelve themes as Party Finder, by the same names (Aurora, Gems, Banner, Ember, Ranger, Inferno,
Ninja, Harvest, Gunslinger, Rose, Bard, Jade): their colours only, the art stays with Party Finder. Pick one in
Settings or with `/ah theme <name>`. A `themes\<id>.lua` in the addon's folder adds one of your own or replaces a
built-in one, in Party Finder's format (`return { name = '…', palette = { bg = '#…', glass, card, card_hi, line,
well, accent, accent2, cyan } }`).

## Languages

On a Japanese client the window is in Japanese: item names and descriptions as the client has them (Shift-JIS, read
through Windows into UTF-8), the official auction-house category names, one-character job marks (戦 モ 白 …), the
window's own text, the compare card and the controller's help, drawn with Meiryo (or Yu Gothic, or MS Gothic) from
Windows; without those (Wine, a Mac), a `NotoSansJP-Regular.otf` dropped into `C:\Windows\Fonts` (Noto Sans JP, OFL,
from github.com/notofonts/noto-cjk) is used, and with no Japanese font at all the window says so once and stays
English. An English client stays English. Which one is decided from VanaCore's `[language] playonline` setting, then
from what the client's item names look like; **Settings → Language** (or `/ah lang auto|en|ja`) overrides it, with
a flag beside it for the language in use. The Japanese strings are in `lang.lua`.

The Japanese localization is Hando's work (cexi-addons PR #11) — thank you.

## Commands

| Command | Action |
|---|---|
| `/ah` | Open or close the window (Esc closes it too) |
| `/ah buy` / `sell` / `listings` / `activity` / `watch` | Open on that tab |
| `/ah watch <id or name>` | Follow an item on the Watch tab, or stop |
| `/ah search <name>` | Open with a name search |
| `/ah pick <id or name>` | Open on an item's card |
| `/ah server <host[:port]>` | Which search server to ask; `/ah server auto` finds it from your login again |
| `/ah theme <name>` | Switch theme; `/ah theme` lists them |
| `/ah sound <name>` / `off` / `on` | The sound as the window opens; `/ah sound` lists them |
| `/ah lang auto\|en\|ja` | The window's language: the client's own, English, or Japanese |
| `/ah scale <percent>` | Window size, 50 to 300 |
| `/ah opacity <percent>` | Window opacity, 40 to 100 |
| `/ah refresh` | Forget fetched lists and histories |
| `/ah debug` | Counters, the search server, whether you're at a clerk, the last error |
| `/ah pad [on\|off\|<button>]` | The controller: its state, the setting, or a press of `a`, `b`, `x`, `y`, `up`, `down`, `left`, `right`, `l1`, `r1`, `l2`, `r2`, `start`, `back`; `/ah pad stick <x> <y> [frames]` a stick |

Settings and the watch list are kept per character in `Vanacore\config\addons\auctionhouse-vanacore\<name>.lua`; the
activity record is `<name>-activity.lua` beside it (up to 2,000 entries); the price record is
`index-<search host>.lua` is what the house lists in each category, as its search server last said. Like the game's
own window, only the category you open is asked (again each time you open it); nothing about which items are sold
is shipped with the addon, so a new auction item shows up as soon as the server lists it. Search covers the
categories opened on that server so far; under the results, **Include the other categories** asks the rest once
(one at a time) and keeps them too. The Sell tab doesn't use it: what can be sold is judged as the game's own window
judges it, by the no-auction flag in the client's item data.
`prices-<search host>.lua`, one per server, up to 160 sales per item and kind, series with no sale in 120 days
dropped.

## How it talks to the server

- **The counter:** talking to any auction clerk makes the server send `0x04C` with command `Open`
  (`sendMenu(AUCTION)`), nothing more; the addon swallows that packet and opens its window, so the game never draws
  its menu and nothing is left waiting server-side. No NPC names are looked at. The Open is the server's word that
  this is an auction house, and where you stood when it came is kept in your settings, per zone (`spots`): within 8
  yalms of a kept spot counts as at the counter, so `/ah` there later can bid and sell too.
- **Buying, selling, your sales:** packet `0x04E` out and `0x04C` in (`map/packets/c2s/0x04e_auc.h`): WorkCheck when
  the window opens, Bid, AskCommit then LotIn to sell (both carry an auction work slot 0–6 at 0x05; the server refuses
  −1 there without a word), Info for the sales list (the server's AH pagination module
  pages it six at a time; its chat lines are hidden while the window is asking), LotCancel to take one down. The
  server checks the zone has an auction house; standing at a clerk is the addon's own rule (settings).
- **Categories, stock, history:** the search server (`src/search`), over TCP on the login host, port 54002. The
  addon speaks its protocol itself (`search.lua`): a length-prefixed packet, Blowfish over the body with a key made
  from 16 fixed bytes, 4 random bytes sent in the clear and, for the reply, 4 more carried inside the request; an
  MD5 of the payload inside. One detail worth knowing if you port this: the server reads its key as *signed* bytes,
  so any key byte of 0x80 or more sign-extends across the word in its key schedule, and the cipher's round function
  is LandSandBoat's own, not textbook Blowfish. Both are reproduced. Sockets are non-blocking and stepped from the
  frame; the game never waits on the network. A category list carries every item of the category (or, with the
  server's `OMIT_NO_HISTORY`, every one that has ever been listed), with its single and stack counts; the stack count
  of anything that doesn't stack is −1 (0xFFFFFFFF), which the addon reads as none.
- The search host is read from VanaCore's log ("Game start: on <host>"), the host you logged in to; override it
  with `/ah server`.

## Files

- `auctionhouse-vanacore.lua` — the addon: state, the game packets, the window
- `search.lua`, `bf_tables.lua` — the search-server client and LandSandBoat's Blowfish boxes
- `items.lua` — the game's item data through the resource manager, icon textures, what the house lists (from its
  own answers, kept per server) and the name search
- `prices.lua` — the price record (every sale seen, per server) and the graphs drawn from it
- `lang.lua` — the Japanese strings and which language is in use (the setting, VanaCore's, or the client's item names)
- `ledger.lua` — the activity record (bought, listed, taken down, sold; per character), its pages and totals
- `compare.lua` — gear stats read from the game's item descriptions, what you wear, and the Compare card
- `pad.lua` — the controller: VanaCore's XInput and DirectInput reads as ImGui's gamepad keys, the game kept from them
  while the window has the pad, the legend; shared source in `tools/pad.lua`, copied here by `tools/make_ui.py`
- `ui.lua` — the drawing kit and the themes, generated from the Party Finder addon's helpers by this repo's `tools/make_ui.py`
  so the two look the same; edit there, not here
- `fonts/` — Inter and Rajdhani (SIL Open Font License, licenses included); `images/jobs.png` — the job sprites
- `sounds/` — the bells the window opens with: `small_bell.wav` is BigSoundBank's "Small Bell #1" (CC0), the rest are
  synthesized for this addon; `sounds/README.txt` has the sources
- `fonts/` — Inter and Rajdhani (SIL Open Font License, licenses included); `images/jobs.png` — the job sprites;
  `images/badge_cat.png` — the header's badge (Settings → Icon: the cat and its coin, or the drawn glass gil)
