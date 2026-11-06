-- Where the auction clerks stand, per zone: what lets the house trade, as the game's own window only trades at a
-- counter. From the server's NPC table (LandSandBoat's npc_list) for every NPC whose script opens the auction menu
-- (scripts/zones/<zone>/npcs/*.lua with xi.menuType.AUCTION), in VanaCore's entity axes (its x and y are the map
-- plane, z the height: the server's pos_x, pos_z, pos_y). A zone missing here has no counter, whatever the server's
-- zone flags say (CatsEyeXI flags a couple of zones for the delivery box), so nothing can be bought or sold there.
-- Regenerate from the server checkout when a clerk moves or a new one appears; /ah debug says the nearest one.
return {
    [26] = { -- Tavnazian Safehold
        { -115.3, -42.1, -27.2 }, -- Eliot
        { -109.2, -51.7, -26.8 }, -- Ferocious Artisan
        { -101.9, -59.0, -27.2 }, -- Senvaleget
    },
    [48] = { -- Al Zahbi
        { -33.4, -121.2, -0.4 }, -- Goyuyu
        { -41.5, -113.0, -0.4 }, -- Sojan-Tamjan
        { -37.3, -117.3, -0.4 }, -- Yando-Memondo
    },
    [50] = { -- Aht Urhgan Whitegate
        { -137.8, 79.2, -7.0 }, -- Auction Counter
        { -137.7, 84.6, -7.0 }, -- Auction Counter
        { -137.7, 73.9, -7.0 }, -- Auction Counter
    },
    [53] = { -- Nashmau
        { -26.1, 40.1, 0.0 }, -- Momoroon
        { 24.9, -40.0, 0.0 }, -- Pupuroon
    },
    [230] = { -- Southern San d'Oria
        { -8.9, -30.9, 1.7 }, -- Auction Counter
        { -3.9, -39.4, -3.3 }, -- Auction Counter
        { 2.2, -39.9, -3.3 }, -- Auction Counter
        { 8.9, -31.0, 1.7 }, -- Auction Counter
    },
    [232] = { -- Port San d'Oria
        { -15.0, -151.2, -9.3 }, -- Auction Counter
        { -10.0, -159.6, -13.3 }, -- Auction Counter
        { -3.9, -159.6, -13.3 }, -- Auction Counter
        { 3.0, -151.2, -9.3 }, -- Auction Counter
    },
    [234] = { -- Bastok Mines
        { -15.9, -48.4, -4.1 }, -- Auction Counter
        { -8.2, -50.5, -4.1 }, -- Auction Counter
        { -0.0, -51.6, -4.1 }, -- Auction Counter
        { 8.0, -50.6, -4.1 }, -- Auction Counter
        { 15.5, -48.7, -4.1 }, -- Auction Counter
    },
    [235] = { -- Bastok Markets
        { -334.0, -52.2, -15.3 }, -- Auction Counter
        { -334.0, -83.8, -15.3 }, -- Auction Counter
        { -332.0, -76.2, -15.0 }, -- Auction Counter
        { -331.9, -59.8, -15.3 }, -- Auction Counter
        { -330.9, -68.0, -15.3 }, -- Auction Counter
    },
    [239] = { -- Windurst Walls
        { 32.0, -56.5, -3.6 }, -- Auction Counter
        { 40.1, -56.6, -3.6 }, -- Auction Counter
        { 48.0, -56.7, -3.6 }, -- Auction Counter
        { 56.0, -56.6, -3.6 }, -- Auction Counter
    },
    [241] = { -- Windurst Woods
        { 63.3, -132.3, -3.6 }, -- Auction Counter
        { 63.4, -115.9, -3.6 }, -- Auction Counter
        { 63.4, -124.0, -3.6 }, -- Auction Counter
        { 63.5, -108.0, -3.6 }, -- Auction Counter
    },
    [243] = { -- Ru'Lude Gardens
        { -74.7, -16.5, 5.6 }, -- Auction Counter
        { -74.7, 0.7, 5.6 }, -- Auction Counter
        { -74.1, -10.9, 5.6 }, -- Auction Counter
        { -74.0, -4.9, 5.6 }, -- Auction Counter
    },
    [244] = { -- Upper Jeuno
        { -39.5, 99.6, 8.0 }, -- Indika
        { -68.1, 19.3, 1.0 }, -- Shama Pikholo
        { -37.0, 94.9, 8.0 }, -- Ulesa
        { -66.3, 16.2, 1.0 }, -- Wise Wolf
    },
    [245] = { -- Lower Jeuno
        { -16.1, -32.0, -0.1 }, -- Auction Counter
        { -13.8, -27.7, -0.1 }, -- Auction Counter
        { -11.3, -23.4, -0.1 }, -- Auction Counter
        { -8.7, -19.0, -0.1 }, -- Auction Counter
    },
    [246] = { -- Port Jeuno
        { -43.0, -4.0, 8.0 }, -- Basmus
        { -35.0, -4.0, 8.0 }, -- Kouang
        { -31.0, 3.7, 8.0 }, -- Rilve-Hitolve
        { -38.9, 3.8, 8.0 }, -- Sapladrepoin
    },
    [247] = { -- Rabao
        { 154.5, 59.7, 8.0 }, -- Cavalgrinne
        { 128.0, 50.6, 8.0 }, -- Hyesun
        { 151.1, 57.8, 8.0 }, -- Smiling Rat
    },
    [250] = { -- Kazham
        { -120.7, -45.9, -10.0 }, -- Cha Chalco
        { -120.8, -38.0, -10.0 }, -- Cophi Ricuub
        { -120.7, -30.0, -10.0 }, -- Sulo Mouzho
    },
    [252] = { -- Norg
        { -61.7, 80.0, -9.4 }, -- Agatsum
        { -77.8, 82.4, -9.7 }, -- Atrevaux
        { -66.7, 85.2, -10.6 }, -- Gofufu
        { -71.0, 86.0, -9.3 }, -- Zoldba
    },
    [256] = { -- Western Adoulin
        { -93.7, -64.9, 2.8 }, -- Auction Counter
        { -93.5, -77.6, 2.8 }, -- Auction Counter
        { -89.3, -81.9, 2.8 }, -- Auction Counter
        { -85.0, -86.1, 2.8 }, -- Auction Counter
        { -80.8, -90.2, 2.8 }, -- Auction Counter
        { -68.2, -90.2, 2.8 }, -- Auction Counter
    },
    [257] = { -- Eastern Adoulin
        { -21.0, -116.0, -0.6 }, -- Auction Counter
        { -21.0, -108.0, -0.6 }, -- Auction Counter
        { -21.0, -100.0, -0.6 }, -- Auction Counter
        { -21.0, -92.0, -0.6 }, -- Auction Counter
    },
}
