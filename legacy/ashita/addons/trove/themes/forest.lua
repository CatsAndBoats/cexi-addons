--[[
* trove/themes/forest.lua — Green/earth tones theme
*
* Greens, browns, warm whites on dark forest green. Woodland calm.
]]--

return {
    -- Window chrome
    windowBg         = { 0.07, 0.10, 0.07, 0.95 },
    windowTitleBg    = { 0.10, 0.15, 0.08, 0.95 },
    windowTitleBgAct = { 0.15, 0.22, 0.12, 0.95 },
    windowBorder     = { 0.25, 0.40, 0.20, 0.60 },
    childBg          = { 0.10, 0.14, 0.09, 0.80 },
    tooltipBg        = { 0.06, 0.08, 0.05, 0.95 },
    panelBg          = { 0.07, 0.10, 0.07, 0.95 },

    -- Frame / input
    frameBg          = { 0.10, 0.14, 0.09, 0.80 },
    frameBgHovered   = { 0.14, 0.20, 0.12, 0.80 },

    -- Scrollbar
    scrollbarBg      = { 0.07, 0.10, 0.07, 0.50 },
    scrollbarGrab    = { 0.25, 0.42, 0.22, 0.60 },
    scrollbarHover   = { 0.35, 0.54, 0.30, 0.80 },
    scrollbarActive  = { 0.45, 0.65, 0.38, 1.00 },

    -- Tabs
    tab              = { 0.10, 0.16, 0.08, 0.95 },
    tabHovered       = { 0.20, 0.35, 0.18, 0.95 },
    tabActive        = { 0.28, 0.45, 0.24, 0.95 },

    -- Selectable / header (list items, menu items)
    selectHeader     = { 0.18, 0.30, 0.15, 0.60 },
    selectHovered    = { 0.24, 0.38, 0.20, 0.55 },
    selectActive     = { 0.32, 0.48, 0.28, 0.75 },

    -- Text
    header           = { 0.60, 0.90, 0.45, 1.00 },
    accent           = { 0.50, 0.80, 0.35, 1.00 },
    dimmed           = { 0.48, 0.52, 0.42, 1.00 },
    white            = { 0.95, 0.96, 0.90, 1.00 },
    desc             = { 0.72, 0.75, 0.65, 1.00 },
    yellow           = { 1.00, 0.90, 0.50, 1.00 },
    blue             = { 0.55, 0.75, 1.00, 1.00 },
    green            = { 0.50, 0.90, 0.50, 1.00 },
    red              = { 1.00, 0.50, 0.45, 1.00 },

    -- Status
    statusOk         = { 0.50, 0.90, 0.50, 1.00 },
    statusErr        = { 1.00, 0.50, 0.45, 1.00 },
    statusWarn       = { 1.00, 0.85, 0.30, 1.00 },

    -- Items
    rare             = { 1.00, 0.85, 0.30, 1.00 },
    ex               = { 0.45, 0.90, 0.45, 1.00 },
    rareBg           = { 0.38, 0.32, 0.08, 0.80 },
    exBg             = { 0.10, 0.32, 0.12, 0.80 },
    qty              = { 0.80, 0.92, 0.70, 1.00 },
    qtyLow           = { 1.00, 0.65, 0.35, 1.00 },
    empty            = { 0.48, 0.52, 0.42, 0.80 },
    slotText         = { 0.82, 0.85, 0.78, 1.00 },
    jobText          = { 0.78, 0.88, 0.72, 1.00 },

    -- Categories & navigation
    category         = { 0.65, 0.85, 0.50, 1.00 },
    headerBg         = { 0.10, 0.16, 0.08, 1.00 },
    catBtnBg         = { 0.10, 0.14, 0.08, 1.00 },
    selected         = { 0.15, 0.25, 0.12, 0.90 },
    searchHint       = { 0.40, 0.45, 0.35, 1.00 },
    breadcrumb       = { 0.68, 0.80, 0.58, 1.00 },

    -- Buttons: primary action
    btnPrimary       = { 0.22, 0.38, 0.18, 1.00 },
    btnPrimaryHover  = { 0.28, 0.48, 0.22, 1.00 },
    btnPrimaryActive = { 0.35, 0.58, 0.28, 1.00 },
    btnDimmed        = { 0.18, 0.20, 0.15, 0.50 },

    -- Buttons: feature (secondary)
    btnFeature       = { 0.20, 0.32, 0.18, 1.00 },
    btnFeatureHover  = { 0.28, 0.42, 0.25, 1.00 },
    btnFeatureActive = { 0.35, 0.52, 0.30, 1.00 },

    -- Buttons: positive (store/confirm)
    btnPositive      = { 0.25, 0.45, 0.20, 1.00 },
    btnPositiveHover = { 0.30, 0.55, 0.25, 1.00 },
    btnPositiveActive= { 0.38, 0.65, 0.32, 1.00 },

    -- Buttons: back/cancel
    btnBack          = { 0.18, 0.22, 0.15, 1.00 },
    btnBackHover     = { 0.25, 0.32, 0.22, 1.00 },
    btnBackActive    = { 0.32, 0.42, 0.28, 1.00 },

    -- Currency / Points
    currencyName     = { 0.95, 0.90, 0.65, 1.00 },
    currencyTotal    = { 1.00, 0.95, 0.70, 1.00 },
    currencyBrk      = { 0.58, 0.62, 0.52, 1.00 },
    pointsGroup      = { 0.50, 0.80, 0.45, 1.00 },
    pointsLabel      = { 0.88, 0.90, 0.82, 1.00 },
    pointsValue      = { 1.00, 0.95, 0.70, 1.00 },

    -- VNM-specific
    alertGlow        = { 1.00, 0.85, 0.30, 1.00 },
    ownedTick        = { 0.45, 0.90, 0.45, 1.00 },
    notOwned         = { 0.20, 0.22, 0.15, 1.00 },
    dimText          = { 0.48, 0.52, 0.42, 1.00 },
};
