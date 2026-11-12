--[[
* trove/themes/midnight.lua — Deep blue/teal dark theme
*
* Blues and cyans instead of purples. Cold, clean, and focused.
]]--

return {
    -- Window chrome
    windowBg         = { 0.06, 0.08, 0.14, 0.95 },
    windowTitleBg    = { 0.08, 0.12, 0.20, 0.95 },
    windowTitleBgAct = { 0.12, 0.18, 0.30, 0.95 },
    windowBorder     = { 0.20, 0.35, 0.50, 0.60 },
    childBg          = { 0.08, 0.12, 0.18, 0.80 },
    tooltipBg        = { 0.05, 0.07, 0.12, 0.95 },
    panelBg          = { 0.06, 0.08, 0.14, 0.95 },

    -- Frame / input
    frameBg          = { 0.08, 0.12, 0.20, 0.80 },
    frameBgHovered   = { 0.12, 0.18, 0.28, 0.80 },

    -- Scrollbar
    scrollbarBg      = { 0.06, 0.08, 0.14, 0.50 },
    scrollbarGrab    = { 0.20, 0.40, 0.55, 0.60 },
    scrollbarHover   = { 0.28, 0.48, 0.62, 0.80 },
    scrollbarActive  = { 0.35, 0.56, 0.70, 1.00 },

    -- Tabs
    tab              = { 0.08, 0.14, 0.22, 0.95 },
    tabHovered       = { 0.18, 0.32, 0.48, 0.95 },
    tabActive        = { 0.22, 0.40, 0.58, 0.95 },

    -- Selectable / header (list items, menu items)
    selectHeader     = { 0.15, 0.28, 0.40, 0.60 },
    selectHovered    = { 0.20, 0.35, 0.50, 0.55 },
    selectActive     = { 0.25, 0.45, 0.62, 0.75 },

    -- Text
    header           = { 0.45, 0.75, 1.00, 1.00 },
    accent           = { 0.30, 0.65, 0.95, 1.00 },
    dimmed           = { 0.45, 0.50, 0.58, 1.00 },
    white            = { 0.92, 0.95, 1.00, 1.00 },
    desc             = { 0.65, 0.72, 0.80, 1.00 },
    yellow           = { 1.00, 0.92, 0.55, 1.00 },
    blue             = { 0.50, 0.78, 1.00, 1.00 },
    green            = { 0.40, 0.88, 0.60, 1.00 },
    red              = { 1.00, 0.50, 0.50, 1.00 },

    -- Status
    statusOk         = { 0.40, 0.88, 0.60, 1.00 },
    statusErr        = { 1.00, 0.50, 0.50, 1.00 },
    statusWarn       = { 1.00, 0.85, 0.30, 1.00 },

    -- Items
    rare             = { 1.00, 0.85, 0.30, 1.00 },
    ex               = { 0.40, 0.90, 0.40, 1.00 },
    rareBg           = { 0.35, 0.32, 0.10, 0.80 },
    exBg             = { 0.10, 0.30, 0.15, 0.80 },
    qty              = { 0.70, 0.85, 1.00, 1.00 },
    qtyLow           = { 1.00, 0.65, 0.35, 1.00 },
    empty            = { 0.45, 0.50, 0.60, 0.80 },
    slotText         = { 0.78, 0.82, 0.90, 1.00 },
    jobText          = { 0.70, 0.82, 0.95, 1.00 },

    -- Categories & navigation
    category         = { 0.40, 0.80, 0.70, 1.00 },
    headerBg         = { 0.08, 0.14, 0.22, 1.00 },
    catBtnBg         = { 0.08, 0.12, 0.18, 1.00 },
    selected         = { 0.12, 0.22, 0.38, 0.90 },
    searchHint       = { 0.35, 0.40, 0.50, 1.00 },
    breadcrumb       = { 0.55, 0.70, 0.90, 1.00 },

    -- Buttons: primary action
    btnPrimary       = { 0.15, 0.30, 0.55, 1.00 },
    btnPrimaryHover  = { 0.20, 0.40, 0.65, 1.00 },
    btnPrimaryActive = { 0.25, 0.50, 0.75, 1.00 },
    btnDimmed        = { 0.15, 0.18, 0.25, 0.50 },

    -- Buttons: feature (secondary)
    btnFeature       = { 0.18, 0.28, 0.45, 1.00 },
    btnFeatureHover  = { 0.25, 0.38, 0.55, 1.00 },
    btnFeatureActive = { 0.30, 0.48, 0.65, 1.00 },

    -- Buttons: positive (store/confirm)
    btnPositive      = { 0.15, 0.40, 0.35, 1.00 },
    btnPositiveHover = { 0.20, 0.50, 0.42, 1.00 },
    btnPositiveActive= { 0.25, 0.60, 0.50, 1.00 },

    -- Buttons: back/cancel
    btnBack          = { 0.15, 0.18, 0.28, 1.00 },
    btnBackHover     = { 0.22, 0.28, 0.40, 1.00 },
    btnBackActive    = { 0.30, 0.38, 0.52, 1.00 },

    -- Currency / Points
    currencyName     = { 0.85, 0.92, 0.75, 1.00 },
    currencyTotal    = { 0.90, 0.95, 0.80, 1.00 },
    currencyBrk      = { 0.55, 0.60, 0.68, 1.00 },
    pointsGroup      = { 0.45, 0.75, 1.00, 1.00 },
    pointsLabel      = { 0.85, 0.88, 0.95, 1.00 },
    pointsValue      = { 0.90, 0.95, 0.80, 1.00 },

    -- VNM-specific
    alertGlow        = { 1.00, 0.85, 0.30, 1.00 },
    ownedTick        = { 0.40, 0.90, 0.40, 1.00 },
    notOwned         = { 0.18, 0.20, 0.28, 1.00 },
    dimText          = { 0.45, 0.50, 0.58, 1.00 },
};
