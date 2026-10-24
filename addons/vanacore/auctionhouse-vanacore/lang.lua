-- Language: the window's text in the client's language. English is the keys themselves; Japanese is the table below
-- (the strings of Hando's localization, PR #11). Which one: the player's choice in Settings (auto, English, 日本語),
-- else VanaCore's [language] playonline (1 Japanese, 2 English), else what the client's item names look like (the
-- sniff items.lua registers), decided once and kept until the setting changes.
local L = {}

local JA = {
    ['LANGUAGE'] = '言語', ["Auto (the client's)"] = '自動（クライアントに合わせる）',
    ['Item names, the window and the help  ·  /ah lang auto|en|ja'] = 'アイテム名・画面・ヘルプ  ·  /ah lang auto|en|ja',
    ['Single / stack'] = '単品 / スタック', ['Select, then Bid'] = '選択、もう一度で入札へ', ['Back'] = '戻る', ['Tabs'] = 'タブ',
    ['Category'] = '区分', ['Price'] = '金額', ['In stock'] = '在庫あり', ['Compare'] = '比較', ['Settings'] = '設定',
    ['Select'] = '選択', ['Page'] = 'ページ', ['Filter'] = '絞り込み', ['Digit'] = '数字', ['Column'] = '桁', ['Keep'] = '決定', ['Undo'] = '元に戻す',
    ['Talk to an auction clerk to trade'] = '取引には競売の係員に話しかけてください', ['Not logged in'] = '未ログイン',
    ["Talking to a clerk opens this, not the game's menu"] = '係員に話しかけるとゲームのメニューではなくこの画面が開く',
    ["Price graph on an item's card"] = 'アイテムカードに価格グラフ', ['Japanese localization: thanks to Hando'] = '日本語化: Hando（ありがとう）',
    ['Talk to an auction clerk to sell'] = '出品には競売の係員に話しかけてください',
    ['MARKET'] = '相場', ['LAST'] = '直近', ['MEDIAN'] = '中央値', ['RANGE'] = '範囲', ['stacks'] = 'スタック', ['steady'] = '横ばい',
    ['Ask this price'] = 'この金額にする', ['No singles sold lately'] = '最近の単品の取引なし', ['No stacks sold lately'] = '最近のスタックの取引なし',
    ['Nobody has bought one here lately: your price sets the market'] = '最近の取引はありません。あなたの値段が相場になります',
    ['at the median'] = '中央値どおり', ['%d%% above the median'] = '中央値より%d%%高い', ['%d%% under the median'] = '中央値より%d%%安い',
    ['ICON'] = 'アイコン', ['Gil'] = 'ギル',
        ['Auction House'] = 'オークションハウス',
        ['Buy'] = '入札',
        ['Sell'] = '出品',
        ['Listings'] = '出品中',
        ['Activity'] = '履歴',
        ['Watch'] = 'ウォッチ',
        ['Settings'] = '設定',
        ['In stock'] = '在庫あり',
        ['Usable'] = '装備可能',
        ['Compare'] = '比較',
        ['Sellable'] = '出品可能',
        ['Search'] = '検索',
        ['Recent sales'] = '最近の取引',
        ['Bid'] = '入札',
        ['List for'] = '出品する',
        ['Take down'] = '取り消し',
        ['Refresh'] = '更新',
        ['No sales recorded yet'] = 'まだ取引履歴がありません',
        ['The house did not answer'] = 'オークションハウスから応答がありません',
        ['Your sales'] = 'あなたの出品',
        ['Reading your listings'] = '出品一覧を読み込み中',
        ['List it'] = '出品する',
        ['Confirm'] = '確認',
        ['Cancel'] = 'キャンセル',
        ['BUY'] = '入札',
        ['SELL'] = '出品',
        ['LISTINGS'] = '出品中',
        ['ACTIVITY'] = '履歴',
        ['WATCH'] = 'ウォッチ',
        ['COMPARE'] = '比較',
        ['IN STOCK'] = '在庫あり',
        ['USABLE'] = '装備可能',
        ['NAME'] = '名前',
        ['LEVEL'] = 'レベル',
        ['STOCK'] = '在庫',
        ['Pick an item'] = 'アイテムを選択',
        ['Search every item by name'] = 'アイテム名で検索',
        ['At the counter'] = 'カウンター前',
        ['Weapons'] = '武器',
        ['Armor'] = '防具',
        ['Scrolls'] = 'スクロール',
        ['Items'] = 'アイテム',
        ['Materials'] = '素材',
        ['Food'] = '食品',
        ['Others'] = 'その他',
        ['Its stock, sale history and a buy box show here'] = '在庫・取引履歴・入札欄がここに表示されます',
        ['Head'] = '頭', ['Body'] = '胴', ['Hands'] = '両手', ['Legs'] = '両脚', ['Feet'] = '両足',
        ['Neck'] = '首', ['Waist'] = '腰', ['Earrings'] = '耳', ['Rings'] = '指', ['Back'] = '背',
        ['Shields'] = '盾', ['Hand-to-Hand'] = '格闘', ['Daggers'] = '短剣', ['Swords'] = '片手剣',
        ['Great Swords'] = '両手剣', ['Axes'] = '片手斧', ['Great Axes'] = '両手斧', ['Scythes'] = '両手鎌',
        ['Polearms'] = '両手槍', ['Katana'] = '片手刀', ['Great Katana'] = '両手刀', ['Clubs'] = '片手棍',
        ['Staves'] = '両手杖', ['Ranged'] = '射撃', ['Instruments'] = '楽器', ['Ammo & Misc'] = '矢・弾',
        ['White Magic'] = '白魔法', ['Black Magic'] = '黒魔法', ['Summoning'] = '召喚',
        ['Ninjutsu'] = '忍術', ['Songs'] = '歌', ['Medicines'] = '薬品', ['Furnishings'] = '調度品',
        ['Crystals'] = 'クリスタル', ['Cards'] = 'カード', ['Cursed Items'] = '呪物',
        ['Smithing'] = '鍛冶', ['Goldsmithing'] = '彫金', ['Clothcraft'] = '裁縫',
        ['Leathercraft'] = '革細工', ['Bonecraft'] = '骨細工', ['Woodworking'] = '木工',
        ['Alchemy'] = '錬金術材', ['Alchemy 2'] = '錬金術材2', ['Geomancy'] = '風水',
        ['Misc.'] = '雑貨', ['Misc. 2'] = '雑貨2', ['Misc. 3'] = '雑貨3',
        ['Fishing Gear'] = '釣り具',
        ['Pet Items'] = 'ペット用品', ['Ninja Tools'] = '忍具', ['Beast-made'] = '獣人製品',
        ['Fish'] = '魚', ['Meat & Eggs'] = '肉・卵', ['Seafood'] = '魚介', ['Vegetables'] = '野菜',
        ['Soups'] = 'スープ', ['Breads & Rice'] = 'パン・米', ['Sweets'] = '菓子', ['Drinks'] = '飲料',
        ['Ingredients'] = '食材', ['Dice'] = 'ダイス', ['Automaton'] = 'からくり部品', ['Grips'] = 'グリップ',
        ['Special'] = '特殊', ['Other'] = 'その他',
        ['entries'] = '件',
        ['entry'] = '件',
        ['ALL'] = 'すべて',
        ['BOUGHT'] = '購入',
        ['SOLD'] = '売却',
        ['LISTED'] = '出品',
        ['TAKEN DOWN'] = '取下げ',
        ['SPENT'] = '支出',
        ['EARNED'] = '収入',
        ['FEES'] = '手数料',
        ['NET'] = '収支',
        ['purchase'] = '購入',
        ['purchases'] = '購入',
        ['sale'] = '売却',
        ['sales'] = '売却',
        ['listing'] = '出品',
        ['listings'] = '出品',
        ['sales less purchases and fees'] = '売却 − 購入 − 手数料',
        ['Nothing yet'] = 'まだありません',
        ['What you buy, list, take down and sell here is kept, per character, across restarts'] = '購入・出品・取下げ・売却の記録はキャラクターごとに保存されます',
        ['YOUR BAG'] = 'バッグ',
        ['items'] = '個',
        ['item'] = '個',
        ['the house won\'t take, hidden'] = '出品不可（非表示）',
        ['SELLABLE'] = '出品可能',
        ['Pick something from your bag'] = 'バッグから選択',
        ['Greyed items are ones the house does not take'] = 'グレーのアイテムは出品できません',
        ['UP FOR SALE'] = '出品中',
        ['History'] = '履歴',
        ['Hide'] = '隠す',
        ['stack of'] = 'スタック',
        ['WATCHING'] = 'ウォッチ中',
        ['checks every'] = '確認間隔',
        ['min'] = '分',
        ['Check now'] = '今すぐ確認',
        ['Nothing watched yet'] = 'まだウォッチしていません',
        ['in stock of'] = '在庫',
        ['singles'] = '個',
        ['single'] = '個',
        ['jobs'] = 'ジョブ',
        ['of'] = '/',
        ['in stock'] = '在庫あり',
        ['usable'] = '装備可能',
        ['usable, in stock'] = '装備可能・在庫あり',
        ['SINGLE'] = '単品',
        ['FULL STACK'] = 'フルスタック',
        ['STACK of'] = 'スタック',
        ['RECENTLY SOLD FOR'] = '最近の取引価格',
        ['RECENT SALES'] = '最近の取引',
        ['ASKING PRICE'] = '出品価格',
        ['You have'] = '所持',
        ['stacks of'] = 'スタック',
        ['type a price'] = '価格を入力',
        ['last sold'] = '最終取引',
        ['The house quotes its listing fee first; nothing is listed until you say so'] = '出品手数料が先に表示されます。確認するまで出品されません',
        ['TELL ME UNDER'] = 'この価格以下で通知',
        ['any price'] = '価格指定なし',
        ['last'] = '最終',
        ['median'] = '中央値',
        ['range'] = '範囲',
        ['SETTINGS'] = '設定',
        ['Bid and sell only at an auction clerk'] = 'オークション係員の前でのみ売買',
        ['Talking to a clerk opens this, not the game\'s menu'] = '係員に話しかけるとこの画面を開く（ゲームメニューではなく）',
        ['Confirm before bidding'] = '入札前に確認',
        ['Price graph on an item\'s card'] = 'アイテムカードに価格グラフを表示',
        ['Check watched items every'] = 'ウォッチ確認間隔',
        ['min, even with this closed'] = '分（画面を閉じていても）',
        ['WINDOW'] = 'ウィンドウ',
        ['Opacity'] = '不透明度',
        ['Scale'] = '拡大率',
        ['KEYS'] = 'キー',
        ['Sort button'] = '並びのボタン',
        ['None'] = 'なし',
        ['Sort'] = '並び',
        ['Filter'] = 'フィルター',
        ['Move'] = '移動',
        ['Page'] = 'ページ',
        ['Categories'] = '区分',
        ['To close'] = '閉じるへ',
        ['Results'] = '検索結果',
        ['Amount'] = '金額',
        ['Single or stack'] = '単品 / スタック',
        ['Switch'] = '切替',
        ['On or off'] = '有効 / 無効',
        ['Direction'] = '昇順 / 降順',
        ['Return'] = '戻る',
        ['Open category'] = '区分を開く',
        ['Pick item'] = '項目を選ぶ',
        ['Price, then Bid'] = '金額から入札',
        ['Select'] = '選択',
        ['Go back'] = '戻る',
        ['Tabs'] = 'タブ',
        ['Category'] = '区分',
        ['Price'] = '金額',
        ['Digit'] = '桁',
        ['Column'] = '列',
        ['Keep'] = '確定',
        ['Undo'] = '取り消し',
        ['Select, then Bid'] = '選択して入札',
        ['Scroll'] = 'スクロール',
        ['opens the house'] = 'で開く',
        ['Esc closes it'] = 'Escで閉じる',
        ['THEME'] = 'テーマ',
        ['The same themes as Party Finder  ·  /ah theme <name>'] = 'Party Finderと同じテーマ  ·  /ah theme <name>',
        ['SOUND AS IT OPENS'] = '開くときの音',
        ['Off'] = 'オフ',
        ['/ah sound <name>  ·  /ah sound off'] = '/ah sound <name>  ·  /ah sound off',
        ['Clear the search'] = '検索を消す',
        ['Close (Esc)'] = '閉じる（Esc）',
        ['Close'] = '閉じる',
        ['Refresh the list and the item'] = '一覧と選択中のアイテムを更新',
        ['Stop watching'] = 'ウォッチをやめる',
        ['Watch this item'] = 'このアイテムをウォッチ',
        [' (stacks)'] = '（スタック）',
        [' (singles)'] = '（単品）',
        ['Hide the price graph'] = '価格グラフを隠す',
        ['Show the price graph'] = '価格グラフを表示',
        ['The house does not take this'] = 'このアイテムは出品できません',
        ['Open its card'] = 'カードを開く',
        ['Play it'] = '再生する',
        ['Showing only what is up for sale'] = '出品中のものだけを表示しています',
        ['Show only what is up for sale'] = '出品中のものだけを表示する',
        ['Hovering gear sets it against what you wear'] = '装備に合わせると、今着ているものと比べます',
        ['Hover gear to set it against what you wear in that slot'] = '装備に合わせると、その部位に着ているものと比べます',
        ["Hiding what the house won't take"] = '出品できないものを隠しています',
        ["Hide what the house won't take"] = '出品できないものを隠す',
}

-- the client's own one-character job marks, in the game's job order (1 WAR ... 22 RUN)
local JOBS_JA = {
    [1] = '戦', [2] = 'モ', [3] = '白', [4] = '黒', [5] = '赤', [6] = 'シ', [7] = 'ナ', [8] = '暗',
    [9] = '獣', [10] = '詩', [11] = '狩', [12] = '侍', [13] = '忍', [14] = '竜', [15] = '召', [16] = '青',
    [17] = 'コ', [18] = 'か', [19] = '踊', [20] = '学', [21] = '風', [22] = 'ル',
}

local mode = 'auto'   -- 'auto', 'en' or 'ja': the setting
local lang = nil      -- 'en' or 'ja' once decided
local sniff = nil     -- function () -> true when the client's item names are Japanese (items.lua)

function L.set_sniff(fn) sniff = fn lang = nil end

-- the setting; a change decides again
function L.set(m)
    m = (m == 'en' or m == 'ja') and m or 'auto'
    if m ~= mode then mode = m lang = nil end
end
function L.mode() return mode end

local function decide()
    if mode ~= 'auto' then return mode end
    local ok, v = pcall(vana.config.get, 'language', 'playonline')
    v = ok and tostring(v or '') or ''
    if v == '1' then return 'ja' end
    if v == '2' then return 'en' end
    if sniff then
        local ok2, is_ja = pcall(sniff)
        if ok2 and is_ja then return 'ja' end
    end
    return 'en'
end

function L.lang()
    if lang == nil then lang = decide() end
    return lang
end
function L.ja() return L.lang() == 'ja' end

-- the string for the language: the Japanese one, or the key itself
function L.t(key)
    if key == nil then return '' end
    if L.lang() == 'ja' then return JA[key] or key end
    return key
end

-- a job's mark: the one character on a Japanese client, the English code (as given) otherwise
function L.job_label(job, en)
    if L.lang() == 'ja' then return JOBS_JA[job] or en or '?' end
    return en or '?'
end

return L
