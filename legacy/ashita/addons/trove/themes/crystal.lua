--[[
* trove/themes/crystal.lua — Clean/minimal theme
*
* Lighter grays, white text, subtle blue accents. Less saturated, more neutral.
]]--

return {
    -- Window chrome
    windowBg         = { 0.14, 0.14, 0.16, 0.95 },
    windowTitleBg    = { 0.18, 0.18, 0.20, 0.95 },
    windowTitleBgAct = { 0.24, 0.24, 0.28, 0.95 },
    windowBorder     = { 0.38, 0.38, 0.42, 0.60 },
    childBg          = { 0.16, 0.16, 0.18, 0.80 },
    tooltipBg        = { 0.10, 0.10, 0.12, 0.95 },
    panelBg          = { 0.14, 0.14, 0.16, 0.95 },

    -- Frame / input
    frameBg          = { 0.20, 0.20, 0.22, 0.80 },
    frameBgHovered   = { 0.25, 0.25, 0.28, 0.80 },

    -- Scrollbar
    scrollbarBg      = { 0.18, 0.18, 0.20, 0.50 },
    scrollbarGrab    = { 0.38, 0.38, 0.44, 0.60 },
    scrollbarHover   = { 0.48, 0.48, 0.54, 0.80 },
    scrollbarActive  = { 0.58, 0.58, 0.65, 1.00 },

    -- Tabs
    tab              = { 0.20, 0.20, 0.24, 0.95 },
    tabHovered       = { 0.30, 0.32, 0.42, 0.95 },
    tabActive        = { 0.35, 0.38, 0.52, 0.95 },

    -- Selectable / header (list items, menu items)
    selectHeader     = { 0.25, 0.27, 0.35, 0.60 },
    selectHovered    = { 0.30, 0.32, 0.42, 0.55 },
    selectActive     = { 0.38, 0.40, 0.52, 0.75 },

    -- Text
    header           = { 0.72, 0.78, 0.92, 1.00 },
    accent           = { 0.55, 0.65, 0.85, 1.00 },
    dimmed           = { 0.52, 0.52, 0.56, 1.00 },
    white            = { 0.95, 0.95, 0.97, 1.00 },
    desc             = { 0.72, 0.72, 0.76, 1.00 },
    yellow           = { 1.00, 0.92, 0.58, 1.00 },
    blue             = { 0.58, 0.72, 0.95, 1.00 },
    green            = { 0.50, 0.85, 0.55, 1.00 },
    red              = { 0.95, 0.50, 0.50, 1.00 },

    -- Status
    statusOk         = { 0.50, 0.85, 0.55, 1.00 },
    statusErr        = { 0.95, 0.50, 0.50, 1.00 },
    statusWarn       = { 1.00, 0.85, 0.35, 1.00 },

    -- Items
    rare             = { 1.00, 0.85, 0.35, 1.00 },
    ex               = { 0.45, 0.85, 0.45, 1.00 },
    rareBg           = { 0.38, 0.34, 0.12, 0.80 },
    exBg             = { 0.12, 0.30, 0.15, 0.80 },
    qty              = { 0.78, 0.80, 0.90, 1.00 },
    qtyLow           = { 1.00, 0.65, 0.40, 1.00 },
    empty            = { 0.50, 0.50, 0.55, 0.80 },
    slotText         = { 0.82, 0.82, 0.86, 1.00 },
    jobText          = { 0.78, 0.80, 0.88, 1.00 },

    -- Categories & navigation
    category         = { 0.55, 0.78, 0.65, 1.00 },
    headerBg         = { 0.18, 0.18, 0.22, 1.00 },
    catBtnBg         = { 0.16, 0.16, 0.18, 1.00 },
    selected         = { 0.22, 0.22, 0.30, 0.90 },
    searchHint       = { 0.42, 0.42, 0.48, 1.00 },
    breadcrumb       = { 0.68, 0.70, 0.82, 1.00 },

    -- Buttons: primary action
    btnPrimary       = { 0.28, 0.32, 0.45, 1.00 },
    btnPrimaryHover  = { 0.35, 0.40, 0.55, 1.00 },
    btnPrimaryActive = { 0.42, 0.48, 0.65, 1.00 },
    btnDimmed        = { 0.20, 0.20, 0.22, 0.50 },

    -- Buttons: feature (secondary)
    btnFeature       = { 0.25, 0.28, 0.38, 1.00 },
    btnFeatureHover  = { 0.32, 0.36, 0.48, 1.00 },
    btnFeatureActive = { 0.40, 0.44, 0.58, 1.00 },

    -- Buttons: positive (store/confirm)
    btnPositive      = { 0.22, 0.40, 0.30, 1.00 },
    btnPositiveHover = { 0.28, 0.50, 0.38, 1.00 },
    btnPositiveActive= { 0.35, 0.60, 0.45, 1.00 },

    -- Buttons: back/cancel
    btnBack          = { 0.22, 0.22, 0.26, 1.00 },
    btnBackHover     = { 0.30, 0.30, 0.36, 1.00 },
    btnBackActive    = { 0.38, 0.38, 0.45, 1.00 },

    -- Currency / Points
    currencyName     = { 0.92, 0.90, 0.75, 1.00 },
    currencyTotal    = { 0.95, 0.95, 0.80, 1.00 },
    currencyBrk      = { 0.58, 0.58, 0.62, 1.00 },
    pointsGroup      = { 0.58, 0.68, 0.90, 1.00 },
    pointsLabel      = { 0.88, 0.88, 0.92, 1.00 },
    pointsValue      = { 0.95, 0.95, 0.80, 1.00 },

    -- VNM-specific
    alertGlow        = { 1.00, 0.85, 0.35, 1.00 },
    ownedTick        = { 0.45, 0.85, 0.50, 1.00 },
    notOwned         = { 0.22, 0.22, 0.25, 1.00 },
    dimText          = { 0.52, 0.52, 0.56, 1.00 },
};
