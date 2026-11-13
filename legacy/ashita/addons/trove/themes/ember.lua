--[[
* trove/themes/ember.lua — Warm dark theme
*
* Oranges, reds, and golds on dark brown/charcoal. Campfire warmth.
]]--

return {
    -- Window chrome
    windowBg         = { 0.12, 0.08, 0.06, 0.95 },
    windowTitleBg    = { 0.18, 0.10, 0.06, 0.95 },
    windowTitleBgAct = { 0.28, 0.16, 0.08, 0.95 },
    windowBorder     = { 0.50, 0.30, 0.15, 0.60 },
    childBg          = { 0.16, 0.10, 0.07, 0.80 },
    tooltipBg        = { 0.10, 0.06, 0.04, 0.95 },
    panelBg          = { 0.12, 0.08, 0.06, 0.95 },

    -- Frame / input
    frameBg          = { 0.16, 0.10, 0.08, 0.80 },
    frameBgHovered   = { 0.22, 0.14, 0.10, 0.80 },

    -- Scrollbar
    scrollbarBg      = { 0.12, 0.08, 0.06, 0.50 },
    scrollbarGrab    = { 0.55, 0.32, 0.15, 0.60 },
    scrollbarHover   = { 0.68, 0.42, 0.22, 0.80 },
    scrollbarActive  = { 0.80, 0.52, 0.30, 1.00 },

    -- Tabs
    tab              = { 0.20, 0.12, 0.06, 0.95 },
    tabHovered       = { 0.45, 0.25, 0.10, 0.95 },
    tabActive        = { 0.55, 0.32, 0.14, 0.95 },

    -- Selectable / header (list items, menu items)
    selectHeader     = { 0.35, 0.20, 0.10, 0.60 },
    selectHovered    = { 0.45, 0.26, 0.12, 0.55 },
    selectActive     = { 0.58, 0.34, 0.16, 0.75 },

    -- Text
    header           = { 1.00, 0.75, 0.35, 1.00 },
    accent           = { 0.95, 0.60, 0.25, 1.00 },
    dimmed           = { 0.55, 0.48, 0.40, 1.00 },
    white            = { 1.00, 0.96, 0.90, 1.00 },
    desc             = { 0.78, 0.72, 0.65, 1.00 },
    yellow           = { 1.00, 0.90, 0.45, 1.00 },
    blue             = { 0.55, 0.75, 1.00, 1.00 },
    green            = { 0.55, 0.85, 0.45, 1.00 },
    red              = { 1.00, 0.45, 0.35, 1.00 },

    -- Status
    statusOk         = { 0.55, 0.85, 0.45, 1.00 },
    statusErr        = { 1.00, 0.45, 0.35, 1.00 },
    statusWarn       = { 1.00, 0.80, 0.25, 1.00 },

    -- Items
    rare             = { 1.00, 0.85, 0.30, 1.00 },
    ex               = { 0.45, 0.85, 0.40, 1.00 },
    rareBg           = { 0.40, 0.30, 0.08, 0.80 },
    exBg             = { 0.12, 0.30, 0.12, 0.80 },
    qty              = { 1.00, 0.82, 0.60, 1.00 },
    qtyLow           = { 1.00, 0.55, 0.30, 1.00 },
    empty            = { 0.55, 0.48, 0.42, 0.80 },
    slotText         = { 0.88, 0.82, 0.75, 1.00 },
    jobText          = { 0.95, 0.85, 0.70, 1.00 },

    -- Categories & navigation
    category         = { 0.70, 0.85, 0.40, 1.00 },
    headerBg         = { 0.20, 0.12, 0.06, 1.00 },
    catBtnBg         = { 0.16, 0.10, 0.06, 1.00 },
    selected         = { 0.30, 0.18, 0.08, 0.90 },
    searchHint       = { 0.48, 0.40, 0.32, 1.00 },
    breadcrumb       = { 0.90, 0.72, 0.50, 1.00 },

    -- Buttons: primary action
    btnPrimary       = { 0.50, 0.28, 0.10, 1.00 },
    btnPrimaryHover  = { 0.62, 0.35, 0.14, 1.00 },
    btnPrimaryActive = { 0.72, 0.42, 0.18, 1.00 },
    btnDimmed        = { 0.22, 0.16, 0.12, 0.50 },

    -- Buttons: feature (secondary)
    btnFeature       = { 0.40, 0.25, 0.15, 1.00 },
    btnFeatureHover  = { 0.52, 0.32, 0.18, 1.00 },
    btnFeatureActive = { 0.62, 0.40, 0.22, 1.00 },

    -- Buttons: positive (store/confirm)
    btnPositive      = { 0.30, 0.42, 0.15, 1.00 },
    btnPositiveHover = { 0.38, 0.52, 0.20, 1.00 },
    btnPositiveActive= { 0.45, 0.62, 0.25, 1.00 },

    -- Buttons: back/cancel
    btnBack          = { 0.25, 0.18, 0.12, 1.00 },
    btnBackHover     = { 0.35, 0.25, 0.18, 1.00 },
    btnBackActive    = { 0.45, 0.32, 0.22, 1.00 },

    -- Currency / Points
    currencyName     = { 1.00, 0.90, 0.60, 1.00 },
    currencyTotal    = { 1.00, 0.92, 0.65, 1.00 },
    currencyBrk      = { 0.65, 0.58, 0.50, 1.00 },
    pointsGroup      = { 0.95, 0.65, 0.30, 1.00 },
    pointsLabel      = { 0.92, 0.88, 0.82, 1.00 },
    pointsValue      = { 1.00, 0.92, 0.65, 1.00 },

    -- VNM-specific
    alertGlow        = { 1.00, 0.75, 0.20, 1.00 },
    ownedTick        = { 0.50, 0.85, 0.40, 1.00 },
    notOwned         = { 0.25, 0.18, 0.12, 1.00 },
    dimText          = { 0.55, 0.48, 0.40, 1.00 },
};
