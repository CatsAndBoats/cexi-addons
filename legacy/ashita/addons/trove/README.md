# Trove

Modular Ashita v4 addon for FFXI private servers. Plugin-based UI framework
with themed windows, tabs, and floating panels.

## Install

```
cd <Ashita>/addons
git clone git@github.com:LoxleyX/trove.git
```

Server-specific plugins (optional):
```
cd <Ashita>/addons/trove
git clone <your-server-plugin-repo> plugins
```

Then in-game:
```
/addon load trove
```

`Ctrl+Z` toggles the window. `/trove` also works.

## Architecture

```
trove/
├── trove.lua              Core window, shared helpers, plugin init
├── core/                  Built-in plugins (auto-discovered)
├── plugins/               Server/user plugins (separate repo, gitignored)
├── quest/                 Quest browser sub-modules
├── utils/                 Shared: packet, plugins, ui, textures, difficulty
├── themes/                Color themes (5 built-in)
└── data/                  Shared data files
```

## Built-in Plugins

| Plugin | Type | Description |
|--------|------|-------------|
| Currency | Tab | Currency balances grouped by section |
| Points | Tab | Point balances grouped by category |
| Crafting | Tab | Recipe browser with ingredient navigation |
| Quests | Window | Quest browser, tracker HUD, toast notifications |
| Slips | Window | Storage Slip contents browser |
| Settings | Window | Theme, background style, plugin list |

## Server Plugins

Server-specific content goes in `plugins/` — a separate git repo cloned
into place. The plugin loader auto-discovers `.lua` files from both
`core/` and `plugins/`.

Plugins can register as:
- **Tabs** in the main window
- **Floating windows** (toggled from Menu)
- **Quest sub-tabs** (inside the Quest window)

## Writing Plugins

A plugin is a `.lua` file that returns a table:

```lua
return {
    name = 'My Plugin',
    tab = {
        label = 'Tab Name',
        render = function(state) end,
    },
    window = {
        label    = 'Window Title',
        category = 'Utility',  -- menu grouping
        icon     = 12345,      -- item ID for menu icon
        isOpen   = { false },
        render   = function() end,
    },
    -- Also: commands, onPacketIn, onRender, init, onUnload, etc.
}
```

Menu categories: `Utility`, `Storage`, `Collections`, `Games`, `Account`

See `utils/plugins.lua` for the full interface.

## Themes

Five built-in themes: `default`, `crystal`, `ember`, `forest`, `midnight`.
Change via Settings, or copy `themes/default.lua` to create your own.

Game menu backgrounds can also be enabled in Settings — textures are
extracted directly from your FFXI game files.

## License

MIT
