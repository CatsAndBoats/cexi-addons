--[[
* trove/themes/default.lua — Default Trove theme
*
* Copy this file and modify to create custom themes.
* Set the theme in trove.lua: local THEME = 'mytheme'
* Place your theme at: themes/mytheme.lua
*
* Colors are RGBA tables: { R, G, B, A } where each value is 0.0 to 1.0
]]--

return {
    -- Window chrome — deeper background, subtle blue tint for depth
    windowBg         = { 0.04, 0.04, 0.07, 0.94 },
    windowTitleBg    = { 0.08, 0.07, 0.14, 0.95 },
    windowTitleBgAct = { 0.14, 0.10, 0.22, 0.98 },
    windowBorder     = { 0.25, 0.20, 0.38, 0.15 },  -- subtle border
    childBg          = { 0.08, 0.07, 0.12, 0.40 },   -- lower alpha for layered depth
    tooltipBg        = { 0.06, 0.05, 0.10, 0.96 },
    panelBg          = { 0.07, 0.06, 0.11, 0.95 },

    -- Frame / input — slightly lifted from bg
    frameBg          = { 0.10, 0.09, 0.16, 0.90 },
    frameBgHovered   = { 0.16, 0.14, 0.24, 0.90 },

    -- Scrollbar — thin, unobtrusive
    scrollbarBg      = { 0.04, 0.04, 0.07, 0.30 },
    scrollbarGrab    = { 0.28, 0.22, 0.40, 0.50 },
    scrollbarHover   = { 0.38, 0.30, 0.52, 0.70 },
    scrollbarActive  = { 0.48, 0.38, 0.62, 0.90 },

    -- Tabs — clearer active state
    tab              = { 0.10, 0.09, 0.16, 0.80 },
    tabHovered       = { 0.22, 0.18, 0.35, 0.90 },
    tabActive        = { 0.28, 0.22, 0.45, 1.00 },

    -- Selectable / header
    selectHeader     = { 0.22, 0.18, 0.34, 0.50 },
    selectHovered    = { 0.30, 0.24, 0.48, 0.45 },
    selectActive     = { 0.38, 0.30, 0.58, 0.65 },

    -- Text — stronger hierarchy
    header           = { 0.82, 0.65, 1.00, 1.00 },
    accent           = { 0.65, 0.48, 0.92, 1.00 },
    dimmed           = { 0.45, 0.45, 0.50, 1.00 },
    white            = { 0.95, 0.95, 0.97, 1.00 },
    desc             = { 0.65, 0.65, 0.72, 1.00 },
    yellow           = { 1.00, 0.92, 0.55, 1.00 },
    blue             = { 0.55, 0.75, 1.00, 1.00 },
    green            = { 0.50, 0.88, 0.50, 1.00 },
    red              = { 1.00, 0.50, 0.50, 1.00 },

    -- Status
    statusOk         = { 0.50, 0.88, 0.50, 1.00 },
    statusErr        = { 1.00, 0.50, 0.50, 1.00 },
    statusWarn       = { 1.00, 0.85, 0.30, 1.00 },

    -- Items
    rare             = { 1.00, 0.85, 0.30, 1.00 },
    ex               = { 0.40, 0.88, 0.40, 1.00 },
    rareBg           = { 0.40, 0.35, 0.10, 0.70 },
    exBg             = { 0.10, 0.32, 0.15, 0.70 },
    qty              = { 0.88, 0.75, 1.00, 1.00 },
    qtyLow           = { 1.00, 0.70, 0.40, 1.00 },
    empty            = { 0.55, 0.50, 0.65, 0.70 },
    slotText         = { 0.78, 0.78, 0.84, 1.00 },
    jobText          = { 0.82, 0.78, 0.92, 1.00 },

    -- Categories & navigation
    category         = { 0.50, 0.78, 0.50, 1.00 },
    headerBg         = { 0.12, 0.10, 0.20, 0.90 },
    catBtnBg         = { 0.10, 0.09, 0.16, 0.90 },
    selected         = { 0.20, 0.16, 0.32, 0.85 },
    searchHint       = { 0.38, 0.38, 0.44, 1.00 },
    breadcrumb       = { 0.68, 0.62, 0.82, 1.00 },

    -- Buttons: primary action — slightly more vibrant
    btnPrimary       = { 0.30, 0.22, 0.50, 0.90 },
    btnPrimaryHover  = { 0.40, 0.32, 0.62, 0.95 },
    btnPrimaryActive = { 0.50, 0.40, 0.72, 1.00 },
    btnDimmed        = { 0.18, 0.16, 0.22, 0.40 },

    -- Buttons: feature (secondary)
    btnFeature       = { 0.22, 0.22, 0.40, 0.85 },
    btnFeatureHover  = { 0.32, 0.32, 0.52, 0.90 },
    btnFeatureActive = { 0.42, 0.42, 0.62, 1.00 },

    -- Buttons: positive (store/confirm)
    btnPositive      = { 0.18, 0.40, 0.22, 0.85 },
    btnPositiveHover = { 0.24, 0.52, 0.28, 0.90 },
    btnPositiveActive= { 0.30, 0.62, 0.35, 1.00 },

    -- Buttons: back/cancel
    btnBack          = { 0.18, 0.16, 0.25, 0.80 },
    btnBackHover     = { 0.28, 0.25, 0.38, 0.85 },
    btnBackActive    = { 0.38, 0.32, 0.48, 0.95 },

    -- Currency / Points
    currencyName     = { 0.95, 0.88, 0.65, 1.00 },
    currencyTotal    = { 1.00, 0.95, 0.72, 1.00 },
    currencyBrk      = { 0.60, 0.60, 0.68, 1.00 },
    pointsGroup      = { 0.55, 0.75, 1.00, 1.00 },
    pointsLabel      = { 0.88, 0.88, 0.92, 1.00 },
    pointsValue      = { 1.00, 0.95, 0.72, 1.00 },

    -- VNM-specific (plugins can extend the theme)
    alertGlow        = { 1.00, 0.85, 0.30, 1.00 },
    ownedTick        = { 0.40, 0.88, 0.40, 1.00 },
    notOwned         = { 0.28, 0.18, 0.18, 1.00 },
    dimText          = { 0.45, 0.45, 0.50, 1.00 },
};
