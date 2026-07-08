# Party Finder Addon

Custom Party Finder for the **CatsEyeXI** private server. Provides LFG/LFM listings, Duty Roulette (random BCNM matchmaking with PFP rewards), Mission Help, and Venture parties — all driven by a custom server-side packet protocol (0x1A2).

This addon is **only useful on CatsEyeXI** — it depends on server-side modules (`modules/catseyexi/cpp/party_finder.cpp` and the `party_finder` Lua system) and won't function on a stock LSB server.

## Quick Start

1. `/addon load partyfinder`
2. Press **Ctrl+G** to toggle the window (or `/pf`)
3. Click **Create Listing** to register as LFG or LFM (party leader only for LFM)
4. Hover over listings to see party composition, double-click to join, right-click for options
5. As a party leader, click **Roulette** to start a random duty, or **Start Duty** for missions

## Commands

| Command | Action |
|---|---|
| `/pf` | Toggle window open/closed |
| `/pf toggle` | Toggle between full mode and mini mode |
| `/pf settings` | Open the settings window |
| `/pf notify` | Toggle LFM server notifications on/off |
| `/pf tooltips` | Toggle UI tooltips on/off |
| `/pf block <name>` | Blacklist a player |
| `/pf unblock <name>` | Remove from blacklist |
| `/pf blocklist` | Show blacklisted players |
| `/pf tutorial` | Re-show the first-time tutorial |
| `/pf dev` | Toggle debug log (developer use) |
| **Ctrl+G** | Cycle: closed → full → mini → full (customizable in Settings) |

## Settings Window

Open with `/pf settings` or click the **gear icon** (top-right of the main window, just left of the bell).

| Setting | Default | Description |
|---|---|---|
| Show tooltips | on | Hover tooltips on UI elements |
| LFM notifications in chat | on | Server-wide LFM broadcasts |
| Confirm before withdrawing | on | Yes/No popup when clicking Withdraw |
| Window opacity | 1.0 | Slider from 0.20 (mostly transparent) to 1.00 (opaque) |
| Background image | bg.png | Filename in `images/` folder (blank = none) |
| Background opacity | 0.15 | Slider from 0.0 to 1.0 for background image transparency |
| Toggle keybind | ^G | Ashita bind string (^ = Ctrl, ! = Alt). Click "Set" to apply live. |

Plus buttons for **Reset Tutorial** and **Print Blocklist**.

All settings persist per character via the Ashita settings module.

## Contextual Action Bar

The top action bar changes based on your registration state:

**Not registered:**
```
[Create Listing]                                    [↻] [⚙] [🔔]
```

**Registered as LFG:**
```
>> Looking for Group - Category                     [↻] [⚙] [🔔]
         [Withdraw]
```

**Registered as LFM:**
```
>> Recruiting - Category (3/6)                      [↻] [⚙] [🔔]
         [Withdraw] [Roulette] [Start Duty]
```

Only actions relevant to your current state are visible. Registering as LFM auto-switches to the LFG tab (to see potential recruits), and vice versa. The leader's LFM listing persists through duty completion for easy chaining.

## Listing Cards

Each listing shows the player's name, job/level/sub, zone, category, role composition (for LFM), and comment. Hover over an LFM card to see the full party composition with names and jobs. Cards are semi-transparent when a background image is set.

- **Double-click** a listing to join (LFM) or invite (LFG)
- **Right-click** for context menu (join, invite, send tell, search, block)
- Tooltips explain available actions on hover

## Compact Duty Frame

When a duty commences, the main window auto-minimizes and a compact raid frame appears:

```
┌─ Active Duty ─────────────────── X ─┐
│  >> Horlais Peak BCNM               │
│  [WAR] Carver     NIN99/WAR49 ████  │
│  [WHM] Testy      WHM75/SMN37 ███░  │
└──────────────────────────────────────┘
```

- Draggable, always-on-screen during duty
- Live HP bars (green/yellow/red) update in real-time
- Job icons and sub jobs shown
- Automatically appears for all party members (leader and followers)
- Clears when you return from the battlefield

## Mini Mode

Click the X on the main window to collapse to a 48×48 icon. The badge shows:

- **Green circle + number** when registered: count of relevant opposite listings (LFM registered → shows LFG count, and vice versa)
- **Blue circle + number** when not registered: total listing count
- No badge when 0 listings

During active duty, mini mode shows the compact duty frame instead of the icon.

## Notification Slider

When someone sends a join request, a floating panel slides out from the Party Finder window — works in both full and mini mode:

- **Y** (green) — Accept and invite to party (server handles the invite directly)
- **N** (red) — Deny the request
- Player name, job, level, and countdown timer (turns red under 10s)
- Requests expire after 60 seconds

## Real-Time Updates

All listing changes are pushed immediately via `S2C_LISTINGS_CHANGED` packets:

- Player registers or withdraws → all clients refresh
- Player joins a party → LFG listing auto-removed, party size updates
- Party disbands → stale LFM listing removed, leader notified
- LFM registration → server-wide chat announcement

No polling delays — listings are always current.

## Duty Lifecycle

### Zone Protection
- **Zone lines blocked** during active duty — prevents zone exploration abuse
- **Homepoints blocked** — prevents unlocking homepoints in unearned zones
- **Teleport/warp allowed** — but leaving the area forfeits your participation

### Duty State Notifications
- **On arrival**: "You have a duty assignment. Proceed to the battlefield entrance to begin."
- **During duty**: "You have an active duty in progress. Leaving the area will result in a forfeit."
- **On forfeit (warp out)**: "You have abandoned the duty. Your participation has been forfeited."
- **Zone line blocked**: "You cannot leave the area during an active duty."

### After Duty Completion
- Players are returned to their original location
- PFP is awarded (with daily bonus for first clear)
- Leader's LFM listing persists for easy duty chaining

## Crash / Disconnect Recovery

If your session ends mid-duty, the server detects the orphan state on your next zone-in:

```
[PartyFinder] Your previous duty was interrupted.
[PartyFinder] You may re-form your party and re-enter the BCNM to continue.
```

Your `[PF]DutyBCNM` ticket stays valid (30-min expiry). Stale listings are purged on server restart.

## Chat Colors

All addon messages use SYSTEM_3 chat mode and are colored via the `customcolors` addon:

- **Green** — positive (registered, accepted, ready, duty commenced)
- **Red** — negative (withdrawn, denied, declined, forfeit, errors)
- **Gold** — informational (join requests, settings changes, login summary)
- **Purple** — categories and group counts

## Files

| File | Purpose |
|---|---|
| `partyfinder.lua` | Main addon |
| `images.lua` | Texture loader (includes `loadFromFile` for custom backgrounds) |
| `imguiwrap.lua` | ImGui version compatibility wrapper |
| `images/` | Sprite sheets (jobs, icons, modes, LFG, bell, roles, gear) + optional bg.png |
| `sounds/` | Audio (register, withdraw, join_request, join_accepted, roulette_roll) |
