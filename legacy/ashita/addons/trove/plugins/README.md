# trove-cxi

Server-specific Trove plugins for CatsEyeXI. Requires [trove](https://github.com/LoxleyX/trove) (core addon).

## Install

Clone trove, then clone this repo as its `plugins/` directory:

```
cd <Ashita>/addons
git clone git@github.com:LoxleyX/trove.git
cd trove
git clone git@github.com:LoxleyX/trove-cxi.git plugins
```

### Expected file structure

```
<Ashita>/addons/trove/
├── trove.lua              (core framework — from trove repo)
├── trove.addon
├── core/                  (built-in plugins — from trove repo)
│   ├── crafting.lua
│   ├── currency.lua
│   ├── points.lua
│   ├── quest.lua
│   ├── settings.lua
│   └── slips.lua
├── utils/                 (shared utilities — from trove repo)
├── themes/                (color themes — from trove repo)
├── quest/                 (quest browser — from trove repo)
├── data/                  (shared data — from trove repo)
└── plugins/               (THIS REPO — cloned as plugins/)
    ├── ebox.lua
    ├── squire.lua
    ├── partyfinder.lua
    ├── ultimates.lua
    ├── vault.lua
    ├── profile.lua
    ├── scrolls.lua
    ├── ... (all other .lua files)
    ├── data/              (plugin data files)
    │   └── scroll_data.lua
    └── images/            (plugin image assets)
        ├── lfp.png
        ├── pf_bg.png
        └── cw.png
```

The plugin loader auto-discovers `.lua` files from both `core/` and `plugins/`.

## Updating

```
cd <Ashita>/addons/trove && git pull
cd plugins && git pull
```

Then in-game: `/addon reload trove`

## Plugins

| Plugin | Type | Description |
|--------|------|-------------|
| E.Box | Tab | Ephemeral Box browser with search, withdraw, Crystal Warrior gating |
| Squire | Tab | Squire storage browser by category |
| Party Finder | Window | LFG/LFM listings and party registration |
| Ultimates | Window | Relic, mythic, ergon, and incursion weapon progress |
| Vault | Window | Mog Vault deposit/withdraw |
| Profile | Window | Job levels, prestige, crafting skills |
| VNM | Window | VNM armor tracker with Populox zone alerts |
| Stronghold | Window | SCNM artifact collection |
| Lumoria | Window | Sea collection tracker |
| Garrison | Window | Garrison Pass item tracker |
| Keyring | Window | Goblin Keyring chest/coffer tracker |
| Scrolls | Window | Scroll collection tracker |
| Odious Codex | Window | Dynamis pop item collection |
| Dragonslaying | Window | Dragonslaying weapon/armor progress |
| Incursion | Window | Incursion weapon progress |
| Export | Menu | Export inventory to Lua file |
| Dailies | Window | Goblin Dailies and Storming Sea tracker |
| Sand | Window | Falling sand game |
| Crystal Wars | Window | Shmup minigame |

## License

MIT
