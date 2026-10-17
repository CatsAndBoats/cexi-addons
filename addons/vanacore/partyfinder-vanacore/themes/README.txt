Themes: one Lua file each, named <id>.lua, returning a table. They join the built-in themes in /pf settings
(a file with a built-in id replaces it). Every colour is '#RRGGBB'; leave one out and Aurora's is used.

return {
    name = 'Midnight',          -- shown in the Theme list
    art = 'cexi_ninja',         -- a file in bg\ (its name without the extension), or 'none'
    focus = 0.4,                -- which part of the art's height the listings show, 0 top to 1 bottom
    artist = 'Redkat',          -- signed in the art's corner (optional)
    palette = {
        bg = '#070A14', glass = '#0C1020', card = '#111630', card_hi = '#181F40', line = '#242C52', well = '#04060C',
        accent = '#F5C542', accent2 = '#7C8CFF', cyan = '#FFE28A',
    },
}

Share a whole look (theme, art, icon, opacities) with /pf export; others apply it with /pf import <line>.
