# CatsEyeXI addon policy, in full

Source: https://catseyexi.com/addon-policy (copied 2026-11-12). The Known Addons table is kept separately in
`tools/addon_vet/known_addons.json`, refreshed from the page by `tools/addon_vet/sync_policy.py`.

## The five tiers

Classification is by what the addon achieves in gameplay, not by how it works internally.

| Tier | Name | Status | What it is |
|---|---|---|---|
| T0 | Cosmetic / Quality of Life | Allowed by default, no GM action | Pure UI, visual, audio or accessibility changes. No automation, no information advantage, no server interaction. |
| T1 | Sanctioned Active | Whitelist: allowed only when this specific addon is on the approved list; unlisted ones must be reviewed before use | Takes real actions for the player, but only actions a normal client could send, and only while the player is at the keyboard. Gear-swap helpers, attended healing, helpers that respond to the player's commands. |
| T2 | Information Display | Allowed by default at CatsEyeXI, no GM action | Shows game information: recast timers, distances, party TP/HP, drop trackers, scoreboards. Only reads data; never sends anything to the server and doesn't play the game for the player. |
| T3 | Unattended Automation | Prohibited. Botting is a permanent ban on first offense | Plays the game while the player is away: xp, gil, items, drops, claims, or automation loops that act on the world. The defining test is character progression without a human at the controls. Idle overlays and HUDs are not T3; nor are attended helpers that need real-time input. |
| T4 | Cheating | Prohibited | Breaks a game rule the server is supposed to enforce, however it works inside. Ignoring recasts, facing/standing/engaged checks, acting while dead, opening the AH outside its zone, seeing hidden players or GMs, defeating server rate limits. |

### T4 penalties

- **Categorical T4**: a permanent ban on first offense however it was used. truesight, paranormal, casper, gateway,
  skeletonkey, instantah, peekaboo.
- **Contextual T4**: a permanent ban when used to progress the character (in combat, while gaining xp/gil/items); a
  14-day suspension on first offense when used purely for convenience. ja0wait, ahgo, fastswap.

## How staff decide

For any addon, including ones not yet listed, walk these in order. The first rule that matches decides the tier.

1. **Will the addon progress the player's character while they're away from the keyboard?**
   If the player walks away, does it keep playing for them: gaining xp, capacity, gil, items, drops, mob claims, or
   moving them between spots? Bulk action loops on a timer (mass inventory shuffles, scheduled command runners) count
   too. The definition is progression-without-a-human. Overlays and HUDs (recast timers, party status, chat filters)
   don't count: they only display. Attended helpers that need real-time input (Ashitacast, attended CurePlease) don't
   count either: they answer the next question.
   **Yes: T3.**
2. **Does the addon break a game rule the server is supposed to enforce?**
   Bypassing a recast, ignoring facing/standing/engaged checks, acting while dead, opening the AH outside its zone,
   opening locked doors, defeating game-imposed rate limits, seeing hidden players or GMs, walking through other
   players. How it achieves this doesn't matter, only what it lets the player do.
   **Yes: T4.**
3. **Does the addon take actions for the player in response to what the player is doing right now, or to what's
   happening in the game?**
   Gear-swap reacting to a spell cast (Ashitacast); attended healing reacting to a party member's HP (CurePlease); chat
   aliases that fire real /commands (shorthand). Questions 1 and 2 already removed AFK automation and rule-breaking, so
   this asks: does it help the player respond faster to what's happening in real time? T1 also requires the specific
   addon to be on the approved list.
   **Yes: T1.**
4. **Does the addon show game information the normal interface doesn't show?**
   Recast timers, distance numbers, party TP/HP percentages, drop trackers, mob databases, COR roll values. It only
   reads; it never sends anything to the server.
   **Yes: T2. No: T0.**

**Why effect, not method?** Two addons can work very differently and have the same impact in game, or work alike and
have very different impact. Ashitacast lands at T1 and ja0wait at T4 even though both touch the same kind of thing.

## Adding a new addon

Addons not on the approved list need review before use: players open a GM ticket on Discord linking the source, and
staff walk the decision tree and reply with a tier. Forks and renames are judged by behaviour, not name.

## Precedents worth knowing (from the Known Addons notes)

These are how the listed entries were decided; use them to place close cases.

- **Patching the client can still be T0.** macrofix removes the macro bar's display delay (not the macro rate, recasts
  or the GCD, which the server enforces). nolock removes the local engage/disengage animation lock but doesn't allow
  sliding during animations. instantchat removes a chat-log delay. drawdistance, aspect, fps write client memory. All
  T0: they change what the client shows, not a rule the server enforces.
- **The same mechanism can be T4.** ja0wait (job abilities while moving, past the animation lock) and fastswap (gear
  faster than the swap rate limit) are contextual T4. The difference from nolock and macrofix is the rule: an action
  or rate limit the game imposes on play.
- **Local-only effects can still be categorical T4** when they break a player-to-player or content rule: casper (walk
  through players, local only), gateway (locked doors look open), peekaboo/truesight (show hidden entities).
- **Chat replies are not automation; arbitrary commands are.** autorespond (canned reply to tells while AFK) is T0;
  onevent (any slash command on a chat pattern) is T3 bot scaffolding. repeater (commands on a timer, with "jitter"
  to look less bot-like) is the canonical T3.
- **Bulk unattended actions are T3 even if each action is legal.** bellhop (bulk inventory moves) is T3.
- **One action per click is T1.** sparks skips a sparks NPC's menus for one purchase at a time, at the NPC; sellit
  repeats sell-to-NPC actions; debuff cancels a status as the buff UI would; FancyTrusts summons trusts on click;
  pupsets/blusets equip sets. All T1, approved.
- **Attended reactive helpers are T1 with conditions.** CurePlease (a second client follows and heals on demand),
  luashitacast/ashitacast (gear on casts), lootwhore (auto-lot while present and engaged), autora (ranged attacks
  while engaged), rune-helper, jobhelper (keeps runes, maneuvers and Utsusemi up; noted as borderline T3, attended only).
- **Server-side gates still apply.** fastcs speeds up cutscenes locally but doesn't skip server gating (T0). multisend
  can't be used to get around /yell rules or chain-claim mobs. shorthand is allowed but using it to claim a mob breaks
  Rule 3.
- **Information can include data the server sends but the UI hides**, as long as it isn't hidden on purpose by the
  server or staff: kazenoeye (mob HP% and debuffs), motiontracker (scans the client's nearby-entity memory),
  ashitamcp (read-only state to a local MCP server). Showing hidden GMs or players is T4.
