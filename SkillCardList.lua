-- Skill Card List: browse every Ascension skill card (abilities and talents), see which ones your
-- account owns and which are in your current build, and click a card to see the talents that improve
-- an ability (or the abilities a talent improves).
-- /cards opens the window.  /cards scan  rescans.  /cards synergies  lists talent/ability links.
-- /cards build  checks the current-build match.  /cards index  shows list counts.
-- /cards minimap  shows or hides the minimap button.  /cards why <talent spell> <ability spell>  explains a missing link.
-- /cards shift <spell>  tests whether holding Shift changes a tooltip.  /cards holdshift  toggles pausing until Shift is held.
-- /cards <text>  searches.

local MAXID, PER_FRAME = 120000, 2000      -- card IDs scanned one by one
local ROWS, ROW_H = 14, 26

local cards, view = {}, {}
local syn = nil                 -- synergy index by spell id, built on demand
local ShowDetail                -- opens the synergy detail window (defined below)
local scanning, scanned, nextID = false, false, 1
local filters = { owned = 3, kind = 1, gold = 1 }   -- opens on: All owned states, All kinds, Normal + Golden
local OWNED = { "Owned", "Not owned", "All owned states" }
local KIND  = { "All kinds", "Abilities", "Talents" }
local GOLD  = { "Normal + Golden", "Normal only", "Golden only" }

local function QualityColor(q)
    q = tostring(q or ""):upper()
    if q:find("LEGENDARY") then return "ffff8000"
    elseif q:find("EPIC") then return "ffa335ee"
    elseif q:find("UNCOMMON") then return "ff1eff00"
    elseif q:find("RARE") then return "ff0070dd" end
    return "ffffffff"
end

local function CardName(c)
    if c.name then return c.name end
    local n = c.spell and GetSpellInfo(c.spell)
    if not n and c.item then
        local iname = GetItemInfo(c.item)
        if iname then n = iname:gsub("^Golden Skill Card %- ", ""):gsub("^Skill Card %- ", "") end
    end
    if n then c.name = n return n end
    return "Spell " .. tostring(c.spell or c.id)       -- not cached yet; retried next time
end

local function CardIcon(c)
    local icon = c.spell and select(3, GetSpellInfo(c.spell))
    if not icon and c.item then icon = GetItemIcon(c.item) end
    return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

---------------------------------------------------------------- window
local frame = CreateFrame("Frame", "SkillCardListFrame", UIParent)
frame:SetSize(580, 560)
frame:SetPoint("CENTER")
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetFrameStrata("DIALOG")
frame:Hide()
tinsert(UISpecialFrames, "SkillCardListFrame")

local header = frame:CreateTexture(nil, "ARTWORK")
header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
header:SetSize(300, 64)
header:SetPoint("TOP", 0, 12)
local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", header, "TOP", 0, -14)
title:SetText("Skill Card List")

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)

local box = CreateFrame("EditBox", "SkillCardListBox", frame, "InputBoxTemplate")
box:SetSize(260, 22)
box:SetPoint("TOPLEFT", 28, -40)
box:SetAutoFocus(false)
local boxHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
boxHint:SetPoint("LEFT", box, "RIGHT", 8, 0)
boxHint:SetText("name, card id, item id or spell id")

local function MakeCycler(key, list, x)
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(160, 22)
    b:SetPoint("TOPLEFT", x, -68)
    b:SetText(list[filters[key]])
    b.list, b.key = list, key
    return b
end
local bOwned = MakeCycler("owned", OWNED, 24)
local bKind  = MakeCycler("kind", KIND, 200)
local bGold  = MakeCycler("gold", GOLD, 376)

local status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
status:SetPoint("TOPLEFT", 28, -96)
status:SetText("Open with /cards")

local scroll = CreateFrame("ScrollFrame", "SkillCardListScroll", frame, "FauxScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 20, -114)
scroll:SetPoint("BOTTOMRIGHT", -40, 52)

-- Current build: what this character has learned (separate from the account-wide collection).
-- The build can hold a different entry than the card's (e.g. two "Cleave" entries), so a card
-- counts as in build if its spell is in a known entry, its entry is known, or an exact
-- name + kind match exists.
local buildIDs, buildSpells, buildNames = {}, {}, {}
local function UpdateBuild()
    wipe(buildIDs) wipe(buildSpells) wipe(buildNames)
    local CA = C_CharacterAdvancement
    if not CA then return end
    for _, fn in ipairs({ "GetKnownSpellEntries", "GetKnownTalentEntries" }) do
        if CA[fn] then
            local ok, list = pcall(CA[fn])
            if ok and type(list) == "table" then
                for _, e in ipairs(list) do
                    if type(e) == "table" then
                        if e.ID then buildIDs[e.ID] = true end
                        if type(e.Spells) == "table" then
                            for k, v in pairs(e.Spells) do
                                if type(v) == "number" then buildSpells[v] = true end
                                if type(v) == "table" then
                                    local id = v.SpellID or v.ID
                                    if type(id) == "number" then buildSpells[id] = true end
                                end
                                if type(k) == "number" and k >= 1000 then buildSpells[k] = true end
                            end
                        end
                        if e.Name then buildNames[tostring(e.Name):lower() .. "|" .. tostring(e.Type or ""):lower()] = true end
                    end
                end
            end
        end
    end
end

local function InBuild(spell, name, kind)
    local CA = C_CharacterAdvancement
    if not CA then return false end
    if spell and buildSpells[spell] then return true end
    if name and kind and buildNames[name:lower() .. "|" .. kind:lower()] then return true end
    if spell and CA.GetEntryBySpellID then
        local ok, e = pcall(CA.GetEntryBySpellID, spell)
        if ok and type(e) == "table" and e.ID and buildIDs[e.ID] then return true end
    end
    if spell and CA.IsKnownSpellID then
        local ok, r = pcall(CA.IsKnownSpellID, spell)
        if ok and r and r ~= 0 then return true end
    end
    if spell and CA.GetTalentRankBySpellID then
        local ok, r = pcall(CA.GetTalentRankBySpellID, spell)
        if ok and type(r) == "number" and r > 0 then return true end
    end
    return false
end

local rows = {}
local function Refresh()
    UpdateBuild()
    local offset = FauxScrollFrame_GetOffset(scroll)
    for i = 1, ROWS do
        local row, c = rows[i], view[offset + i]
        if c then
            row.card = c
            row.icon:SetTexture(CardIcon(c))
            row.name:SetText("|c" .. QualityColor(c.quality) .. CardName(c) .. "|r" .. (c.gold and "  |cffffd100(Golden)|r" or ""))
            row.info:SetText(("%s   card %d   item %s   spell %s"):format(c.kind, c.id, tostring(c.item or "?"), tostring(c.spell or "?")))
            if c.owned then
                row.state:SetText("|cff1eff00Owned|r" .. ((c.maxrank or 1) > 1 and (" " .. c.rank .. "/" .. c.maxrank) or ""))
            else
                row.state:SetText("|cff808080Not owned|r")
            end
            row.build:SetText(InBuild(c.spell, CardName(c), c.kind) and "|cff00ccffIn build|r" or "|cff808080Not in build|r")
            row:Show()
        else
            row:Hide()
        end
    end
    FauxScrollFrame_Update(scroll, #view, ROWS, ROW_H)
end
scroll:SetScript("OnVerticalScroll", function(self, delta) FauxScrollFrame_OnVerticalScroll(self, delta, ROW_H, Refresh) end)

for i = 1, ROWS do
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(500, ROW_H)
    row:SetPoint("TOPLEFT", 24, -116 - (i - 1) * ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT")
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, 0)
    row.name:SetWidth(300)
    row.name:SetJustifyH("LEFT")
    row.info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.info:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 0)
    row.state = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.build = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")   -- right-most column: current build
    row.build:SetPoint("RIGHT", 0, 0)
    row.build:SetWidth(90)
    row.build:SetJustifyH("RIGHT")
    row.state:SetPoint("RIGHT", row.build, "LEFT", -6, 0)                          -- next column: owned
    row.state:SetWidth(80)
    row.state:SetJustifyH("RIGHT")
    row:SetScript("OnEnter", function(self)
        local c = self.card
        if not c then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local ok = c.spell and pcall(GameTooltip.SetHyperlink, GameTooltip, "spell:" .. c.spell)
        if not ok then GameTooltip:SetText(CardName(c)) end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Card " .. c.id .. "  |  Item " .. tostring(c.item) .. "  |  Spell " .. tostring(c.spell), 0.7, 0.7, 0.7)
        GameTooltip:AddLine(c.typ .. "  |  " .. c.quality, 0.7, 0.7, 0.7)
        if InBuild(c.spell, CardName(c), c.kind) then GameTooltip:AddLine("In your current build", 0, 0.8, 1)
        else GameTooltip:AddLine("Not in your current build", 0.6, 0.6, 0.6) end
        local sy = syn and c.spell and syn[c.spell]
        if sy then
            local function Names(list)
                local o = {}
                for k = 1, math.min(#list, 6) do o[k] = list[k].name .. ({ "", " (mentions)", " (related)", " (modifiers)" })[list[k].tier or 1] end
                return table.concat(o, ", ") .. (#list > 6 and (", +" .. (#list - 6) .. " more") or "")
            end
            if #sy.improvedBy > 0 then GameTooltip:AddLine("Improved by: " .. Names(sy.improvedBy), 0.4, 1, 0.4, true) end
            if #sy.improves > 0 then GameTooltip:AddLine("Improves: " .. Names(sy.improves), 0.4, 0.8, 1, true) end
            if #sy.shares > 0 then GameTooltip:AddLine("Shares modifiers with: " .. Names(sy.shares), 1, 0.8, 0.4, true) end
        end
        GameTooltip:AddLine("Click to show synergies", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self) if self.card then ShowDetail(self.card) end end)
    rows[i] = row
end

---------------------------------------------------------------- filtering
local extraFound = 0
local function Rebuild()
    wipe(view)
    UpdateBuild()
    local q = strtrim(box:GetText() or ""):lower()
    for _, c in ipairs(cards) do
        local pass = true
        if filters.owned == 1 and not c.owned then pass = false end
        if filters.owned == 2 and c.owned then pass = false end
        if filters.kind == 2 and c.kind ~= "Ability" then pass = false end
        if filters.kind == 3 and c.kind ~= "Talent" then pass = false end
        if filters.gold == 2 and c.gold then pass = false end
        if filters.gold == 3 and not c.gold then pass = false end
        if pass and q ~= "" then
            if not (CardName(c):lower():find(q, 1, true) or tostring(c.id) == q or tostring(c.item) == q or tostring(c.spell) == q) then
                pass = false
            end
        end
        if pass then view[#view + 1] = c end
    end
    table.sort(view, function(a, b)
        local x, y = CardName(a):lower(), CardName(b):lower()
        if x ~= y then return x < y end
        if a.gold ~= b.gold then return not a.gold end
        return a.id < b.id
    end)
    local owned = 0
    for _, c in ipairs(cards) do if c.owned then owned = owned + 1 end end
    status:SetText(("%d shown   |   %d cards found (%d via list), %d owned"):format(#view, #cards, extraFound, owned))
    scroll:SetVerticalScroll(0)
    Refresh()
end

for _, b in ipairs({ bOwned, bKind, bGold }) do
    b:SetScript("OnClick", function(self)
        filters[self.key] = filters[self.key] % 3 + 1
        self:SetText(self.list[filters[self.key]])
        if not scanning then Rebuild() end
    end)
end
box:SetScript("OnEnterPressed", function(self) self:ClearFocus() if not scanning then Rebuild() end end)
box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

---------------------------------------------------------------- scanning
-- Kind comes from the card's own Type: *_TALENT_* = talent, *_DEFAULT_* = ability.
local function AddCardFromInfo(t)
    local spell = t.SpellID
    local typ = tostring(t.Type)
    local tu = typ:upper()
    local kind = "Other"
    if tu:find("TALENT") then
        kind = "Talent"
    elseif tu:find("DEFAULT") or tu:find("ABILITY") then
        kind = "Ability"
    else
        local CA = C_CharacterAdvancement
        if CA and spell then
            local okT, isT = pcall(CA.IsTalentSpellID, spell)
            local okA, isA = pcall(CA.IsAbilitySpellID, spell)
            if okT and isT then kind = "Talent" elseif okA and isA then kind = "Ability" end
        end
    end
    cards[#cards + 1] = {
        id = t.CardID, spell = spell, item = t.ItemID, kind = kind,
        typ = typ, quality = tostring(t.Quality),
        gold = tu:find("GOLD") ~= nil,
        owned = t.IsCollected and true or false,
        rank = t.CollectedRank or 0, maxrank = t.MaxRank or 1,
    }
end

local function ProbeCard(id)
    local ok, t = pcall(C_SkillCard.GetSkillCardInfo, id)
    if not (ok and type(t) == "table" and t.CardID) then return end
    AddCardFromInfo(t)
end

-- Second source: the collection list the Skill Cards window uses, read by index per card type.
-- It reaches cards the per-ID lookup returns nothing for (e.g. cards you do not own yet).
local indexCounts = {}
local function EnumerateByIndex(keep)
    if not keep then wipe(indexCounts) end
    local have, types, seen = {}, {}, {}
    for _, c in ipairs(cards) do have[c.id] = true end
    local function AddType(t) if t and t ~= "" and not seen[t] then seen[t] = true types[#types + 1] = t end end
    for _, c in ipairs(cards) do AddType(c.typ) end
    for _, t in ipairs({ "SKILL_CARD_DEFAULT_NORMAL", "SKILL_CARD_TALENT_NORMAL",
                         "SKILL_CARD_DEFAULT_GOLDEN", "SKILL_CARD_TALENT_GOLDEN" }) do AddType(t) end
    local added = 0
    local GetAt = C_SkillCardCollection and C_SkillCardCollection.GetSkillCardAtIndex
    if not GetAt then return 0 end
    for _, typ in ipairs(types) do
        local n = 0
        for i = 1, 20000 do
            local ok, t = pcall(GetAt, typ, i)
            if not (ok and type(t) == "table" and t.CardID) then break end
            n = i
            if not have[t.CardID] then
                have[t.CardID] = true
                added = added + 1
                AddCardFromInfo(t)
            end
        end
        indexCounts[typ] = math.max(indexCounts[typ] or 0, n)
    end
    return added
end

-- The game's list only fills while its Collections window is open on the Skill Cards tab (tab 3).
-- Open it briefly, wait for it to load, run `callback`, then put the window back as it was.
local SKILL_CARDS_TAB = 3
local TALENT_SUBTAB = 4                 -- SkillCardsFrameTab4 = "Talent Cards"
local prep = CreateFrame("Frame")
prep:Hide()
local function Wait(seconds, fn)
    local waited = 0
    prep:SetScript("OnUpdate", function(self, el)
        waited = waited + el
        if waited < seconds then return end
        self:Hide()
        fn()
    end)
    prep:Show()
end

local function PrepareList(callback)
    local C = _G.Collections
    if not (C and C.SelectTabID) then callback(function() end) return end
    local wasShown = C:IsShown() and true or false
    local ourShown = frame:IsShown() and true or false     -- opening/closing the game's window can close ours
    local function KeepOurs() if ourShown and not frame:IsShown() then frame:Show() end end
    local prevTab
    if C.GetCurrentTabID then local ok, id = pcall(C.GetCurrentTabID, C) if ok then prevTab = id end end
    if not wasShown and not pcall(ShowUIPanel, C) then pcall(C.Show, C) end
    pcall(C.SelectTabID, C, SKILL_CARDS_TAB)
    KeepOurs()
    local function finish()
        if prevTab and prevTab ~= SKILL_CARDS_TAB then pcall(C.SelectTabID, C, prevTab) end
        if not wasShown then if not pcall(C.Hide, C) then pcall(HideUIPanel, C) end end
        KeepOurs()
    end
    Wait(0.7, function()
        local ok, err = pcall(callback, finish)
        if not ok then print("Skill Card List: " .. tostring(err)) finish() end
    end)
end

-- The game's list follows its window's filter (default: Collected Only).  SetSkillCardFilter takes
-- (cardType, searchText, { "FILTER_COLLECTED" | "FILTER_NOT_COLLECTED", ... }); an empty list shows all cards.
local FILTER_TYPES = { "SKILL_CARD_DEFAULT_NORMAL", "SKILL_CARD_DEFAULT_GOLDEN",
                       "SKILL_CARD_TALENT_NORMAL", "SKILL_CARD_TALENT_GOLDEN" }
local function SetGameFilters(list)
    local set = C_SkillCardCollection and C_SkillCardCollection.SetSkillCardFilter
    if not set then return end
    for _, typ in ipairs(FILTER_TYPES) do pcall(set, typ, "", list) end
end

-- Show all cards, read the Ability list, click the Talent Cards sub-tab, read that list, then restore.
local function ReadBothLists(done)
    local S = _G.SkillCardsFrame
    local talentTab = _G["SkillCardsFrameTab" .. TALENT_SUBTAB]
    local prevSub = S and S.selectedTab
    local added = 0
    local function restore()
        SetGameFilters({ "FILTER_COLLECTED" })          -- the game's default
        local prevBtn = prevSub and prevSub ~= TALENT_SUBTAB and _G["SkillCardsFrameTab" .. prevSub]
        if prevBtn and prevBtn.Click then pcall(prevBtn.Click, prevBtn) end
        done(added)
    end
    SetGameFilters({})
    Wait(0.5, function()
        added = EnumerateByIndex()
        if not (talentTab and talentTab.Click) then restore() return end
        pcall(talentTab.Click, talentTab)
        Wait(0.5, function()
            SetGameFilters({})                          -- the tab may have re-applied its default
            Wait(0.5, function()
                added = added + EnumerateByIndex(true)
                restore()
            end)
        end)
    end)
end

local scanner = CreateFrame("Frame")
scanner:Hide()
scanner:SetScript("OnUpdate", function(self)
    local last = math.min(nextID + PER_FRAME - 1, MAXID)
    for id = nextID, last do ProbeCard(id) end
    nextID = last + 1
    if nextID > MAXID then
        self:Hide()
        status:SetText("Reading the game's card list...")
        PrepareList(function(finish)
            ReadBothLists(function(added)
                finish()
                scanning, scanned = false, true
                extraFound = added
                local total = 0
                for _, n in pairs(indexCounts) do total = total + n end
                if total < 100 then
                    print("Skill Card List: the game's card list returned only " .. total .. " cards. If the Skill Cards window has a search or filter set, clear it and click Rescan.")
                end
                if #cards == 0 then
                    status:SetText("|cffff2020No cards found.|r Open the Skill Cards window once, then click Rescan.")
                end
                Rebuild()
            end)
        end)
    else
        status:SetText("Scanning... " .. math.floor(nextID * 100 / MAXID) .. "%")
    end
end)

local function StartScan()
    if scanning then return end
    wipe(cards) wipe(view)
    syn = nil
    extraFound = 0
    nextID, scanning = 1, true
    Refresh()
    scanner:Show()
end

---------------------------------------------------------------- report window (used by /cards synergies)
local ex = CreateFrame("Frame", "SkillCardListExport", UIParent)
ex:SetSize(520, 380)
ex:SetPoint("CENTER", 40, -20)
ex:SetBackdrop(frame:GetBackdrop())
ex:SetFrameStrata("FULLSCREEN_DIALOG")
ex:EnableMouse(true)
ex:Hide()
tinsert(UISpecialFrames, "SkillCardListExport")
local exTitle = ex:CreateFontString(nil, "OVERLAY", "GameFontNormal")
exTitle:SetPoint("TOP", 0, -16)
exTitle:SetText("Synergy report - Ctrl+A then Ctrl+C to copy")
local exClose = CreateFrame("Button", nil, ex, "UIPanelCloseButton")
exClose:SetPoint("TOPRIGHT", -6, -6)
local exScroll = CreateFrame("ScrollFrame", "SkillCardListExportScroll", ex, "UIPanelScrollFrameTemplate")
exScroll:SetPoint("TOPLEFT", 20, -44)
exScroll:SetPoint("BOTTOMRIGHT", -40, 20)
local exBox = CreateFrame("EditBox", nil, exScroll)
exBox:SetMultiLine(true)
exBox:SetFontObject(ChatFontNormal)
exBox:SetWidth(440)
exBox:SetAutoFocus(false)
exBox:SetMaxLetters(0)
exBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() ex:Hide() end)
exScroll:SetScrollChild(exBox)

---------------------------------------------------------------- synergies
-- Tier 1: ability name is in the talent's name.  Tier 2: ability name is in the talent's text.
-- Tier 3: they share a family word ("Judgement" for "Judgement of Wisdom").
local scanTip = CreateFrame("GameTooltip", "SkillCardListScanTip", nil, "GameTooltipTemplate")

local function RawSpellText(spell)
    if not spell then return "" end
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    -- Some tooltips only show their full text while Shift is really held ("Hold SHIFT for more information").
    if not pcall(scanTip.SetHyperlink, scanTip, "spell:" .. spell) then return "" end
    local out = {}
    for i = 2, scanTip:NumLines() do
        local fs = _G["SkillCardListScanTipTextLeft" .. i]
        local t = fs and fs:GetText()
        if t then out[#out + 1] = t end
    end
    return table.concat(out, " ")
end

-- Tooltip lines can carry colour codes, textures, links and odd spacing around ability names
-- (e.g. "|cff00ccffPresence of Mind|r"), which breaks whole-word matching.  Strip them.
local function CleanText(t)
    t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|H.-|h(.-)|h", "%1")
    t = t:gsub("\194\160", " "):gsub("%s+", " ")
    return t
end

local function SpellText(spell)
    return (CleanText(RawSpellText(spell)))
end

-- "This uses X modifiers" only shows with the real Shift key down, so remember what we have seen.
-- Saved between sessions in SkillCardListDB.alias[spellID] = "x".  Known ones are built in.
local seedAlias = SkillCardSeedAlias or {}                 -- built-in list (SkillCardSeed.lua)
local function AliasFor(spell)
    local db = SkillCardListDB and SkillCardListDB.alias
    return (db and db[spell]) or seedAlias[spell]
end
local function RememberAlias(spell, text)
    local nm = CleanText(text or ""):lower():match("this uses (.-) modifiers")
    if not nm then return end
    nm = strtrim(nm)
    if nm == "" or #nm > 40 then return end
    SkillCardListDB = SkillCardListDB or {}
    SkillCardListDB.alias = SkillCardListDB.alias or {}
    SkillCardListDB.alias[spell] = nm
end
-- Whenever you hover a spell with Shift held, record the line (no dedicated scan needed).
hooksecurefunc(GameTooltip, "SetHyperlink", function(self, link)
    if not IsShiftKeyDown() then return end
    local id = tonumber(tostring(link):match("spell:(%d+)"))
    if not id then return end
    local out = {}
    for i = 2, self:NumLines() do
        local fs = _G["GameTooltipTextLeft" .. i]
        local t = fs and fs:GetText()
        if t then out[#out + 1] = t end
    end
    RememberAlias(id, table.concat(out, " "))
end)

local function WordFind(hay, needle)                 -- plain find that respects word boundaries
    local init = 1
    while true do
        local a, b = hay:find(needle, init, true)
        if not a then return false end
        local before, after = hay:sub(a - 1, a - 1), hay:sub(b + 1, b + 1)
        if not before:find("%a") and not after:find("%a") then return true end
        init = a + 1
    end
end

local synBuilder = CreateFrame("Frame")
synBuilder:Hide()
local synState

local function ShowText(text)
    exBox:SetText(text)
    ex:Show()
    exBox:SetCursorPosition(0)
end

local function FinishSynergies()
    local st = synState
    syn = {}
    local function Slot(spell) syn[spell] = syn[spell] or { improves = {}, improvedBy = {}, shares = {} } return syn[spell] end
    local byAbility = {}
    for _, l in ipairs(st.links) do
        local a, t = l.a, l.t
        table.insert(Slot(a.spell).improvedBy, { spell = t.spell, name = t.name, owned = t.owned, strong = l.strong, tier = l.tier,
            via = (l.tier == 3 and a.key) or (l.tier == 4 and a.alias) or nil, quality = t.quality, kind = "Talent" })
        table.insert(Slot(t.spell).improves, { spell = a.spell, name = a.name, owned = a.owned, strong = l.strong, tier = l.tier,
            via = (l.tier == 3 and a.key) or (l.tier == 4 and a.alias) or nil, quality = a.quality, kind = "Ability" })
        byAbility[a.spell] = byAbility[a.spell] or {}
        table.insert(byAbility[a.spell], l)
    end
    for _, A in ipairs(st.abilities) do
        local B = A.alias and st.byName[A.alias]
        if B and B.spell ~= A.spell then
            table.insert(Slot(A.spell).shares, { spell = B.spell, name = B.name, owned = B.owned, tier = 4, via = A.alias, quality = B.quality, kind = "Ability" })
            table.insert(Slot(B.spell).shares, { spell = A.spell, name = A.name, owned = A.owned, tier = 4, via = A.alias, quality = A.quality, kind = "Ability" })
        end
    end
    local out = { "SYNERGIES  (talent improves ability)",
        "'name' = ability name is in the talent's name; 'text' = only in its description; 'related' = shares a family word (e.g. Judgement).", "" }
    out[#out + 1] = "== Abilities you own, and talents that improve them =="
    table.sort(st.abilities, function(x, y) return x.lname < y.lname end)
    local shown = 0
    for _, a in ipairs(st.abilities) do
        local links = byAbility[a.spell]
        if a.owned and links then
            shown = shown + 1
            out[#out + 1] = a.name
            table.sort(links, function(x, y)
                if x.tier ~= y.tier then return x.tier < y.tier end
                return x.t.lname < y.t.lname
            end)
            for _, l in ipairs(links) do
                out[#out + 1] = ("   %s  [%s]  %s"):format(l.t.owned and "OWNED  " or "missing", ({ "name", "text", "related", "modifiers" })[l.tier], l.t.name)
            end
        end
    end
    if shown == 0 then out[#out + 1] = "(none found)" end
    out[#out + 1] = ""
    out[#out + 1] = "== Talents you own whose ability you do not own =="
    local orphans, seen = 0, {}
    for _, l in ipairs(st.links) do
        if l.strong and l.t.owned and not l.a.owned and not seen[l.t.spell .. ":" .. l.a.spell] then
            seen[l.t.spell .. ":" .. l.a.spell] = true
            orphans = orphans + 1
            out[#out + 1] = ("   %s  ->  %s"):format(l.t.name, l.a.name)
        end
    end
    if orphans == 0 then out[#out + 1] = "(none found)" end
    out[#out + 1] = ""
    out[#out + 1] = ("%d talents read, %d had no readable description."):format(#st.talents, st.empty)
    status:SetText("Synergies built: " .. #st.links .. " links.  Click a card to see them.")
    if st.showReport then
        exTitle:SetText("Synergies - Ctrl+A then Ctrl+C to copy")
        ShowText(table.concat(out, "\n"))
    end
    Refresh()
    if st.pending then ShowDetail(st.pending) end
end

synBuilder:SetScript("OnUpdate", function(self)
    local st = synState
    if SkillCardListDB and SkillCardListDB.holdShift and not IsShiftKeyDown() then
        status:SetText("Hold Shift to keep reading full tooltips...")
        return
    end
    local n = 0
    if st.ai <= #st.abilities then                  -- phase 1: abilities that "use X modifiers"
        while st.ai <= #st.abilities and n < 40 do
            local A = st.abilities[st.ai]
            local raw = RawSpellText(A.spell)
            RememberAlias(A.spell, raw)                 -- only matches when Shift text was visible
            A.alias = AliasFor(A.spell)
            st.ai, n = st.ai + 1, n + 1
        end
        status:SetText(("Reading abilities... %d%%"):format(math.floor(math.min(st.ai, #st.abilities) * 100 / #st.abilities)))
        return
    end
    while st.i <= #st.talents and n < 25 do
        local T = st.talents[st.i]
        local ldesc = SpellText(T.spell):lower()
        if ldesc == "" then st.empty = st.empty + 1 end
        for _, A in ipairs(st.abilities) do
            if A.spell ~= T.spell then
                local tier
                if #A.lname >= 5 then
                    if WordFind(T.lname, A.lname) then tier = 1
                    elseif ldesc ~= "" and WordFind(ldesc, A.lname) then tier = 2 end
                end
                if not tier and A.key then
                    local k = A.key
                    if WordFind(T.lname, k) or WordFind(T.lname, k .. "s")
                        or (ldesc ~= "" and (WordFind(ldesc, k) or WordFind(ldesc, k .. "s"))) then
                        tier = 3
                    end
                end
                if not tier and A.alias and A.alias ~= A.lname then
                    if WordFind(T.lname, A.alias) or (ldesc ~= "" and WordFind(ldesc, A.alias)) then tier = 4 end
                end
                if tier then
                    st.links[#st.links + 1] = { a = A, t = T, tier = tier, strong = (tier == 1) }
                end
            end
        end
        st.i, n = st.i + 1, n + 1
    end
    if st.i > #st.talents then
        self:Hide()
        FinishSynergies()
    else
        status:SetText(("Reading talents for synergies... %d%%"):format(math.floor(st.i * 100 / #st.talents)))
    end
end)

local function StartSynergies(showReport, pending)
    if scanning then status:SetText("Wait for the card scan to finish first.") return end
    if #cards == 0 then status:SetText("No cards loaded yet. Click Rescan first.") return end
    local abilities, talents, aBy, tBy = {}, {}, {}, {}
    for _, c in ipairs(cards) do
        if c.spell then
            local map, list = nil, nil
            if c.kind == "Ability" then map, list = aBy, abilities
            elseif c.kind == "Talent" then map, list = tBy, talents end
            if map then
                local e = map[c.spell]
                if not e then
                    local nm = CardName(c)
                    e = { spell = c.spell, name = nm, lname = nm:lower(), owned = false, quality = c.quality, kind = c.kind }
                    map[c.spell] = e
                    list[#list + 1] = e
                end
                if c.owned then e.owned = true end
            end
        end
    end
    local keyCount = {}                           -- "X of Y" abilities share the family word X
    for _, a in ipairs(abilities) do
        local head = a.name:match("^(%a+) of ")
        if head and #head >= 4 then
            a.key = head:lower()
            keyCount[a.key] = (keyCount[a.key] or 0) + 1
        end
    end
    for _, a in ipairs(abilities) do
        if a.key and keyCount[a.key] < 2 then a.key = nil end
    end
    local byName = {}
    for _, a in ipairs(abilities) do byName[a.lname] = byName[a.lname] or a end
    synState = { abilities = abilities, talents = talents, byName = byName, links = {}, i = 1, ai = 1, empty = 0, showReport = showReport, pending = pending }
    synBuilder:Show()
end

---------------------------------------------------------------- synergy detail window
local DROWS, DROW_H = 11, 28
local det = CreateFrame("Frame", "SkillCardListDetail", UIParent)
det:SetSize(380, 430)
det:SetPoint("TOPLEFT", frame, "TOPRIGHT", -6, 0)
det:SetBackdrop(frame:GetBackdrop())
det:SetFrameStrata("DIALOG")
det:SetMovable(true)
det:EnableMouse(true)
det:RegisterForDrag("LeftButton")
det:SetScript("OnDragStart", det.StartMoving)
det:SetScript("OnDragStop", det.StopMovingOrSizing)
det:Hide()
frame:HookScript("OnHide", function() det:Hide() end)

local detClose = CreateFrame("Button", nil, det, "UIPanelCloseButton")
detClose:SetPoint("TOPRIGHT", -6, -6)
local detTitle = det:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
detTitle:SetPoint("TOPLEFT", 26, -22)
detTitle:SetWidth(310)
detTitle:SetJustifyH("LEFT")
local detSub = det:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
detSub:SetPoint("TOPLEFT", 26, -50)
detSub:SetWidth(330)
detSub:SetJustifyH("LEFT")
local detHint = det:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
detHint:SetPoint("TOPLEFT", 26, -68)
detHint:SetText("Hover for the tooltip, click an entry to see its own synergies.")

local detList, detRows = {}, {}
local detScroll = CreateFrame("ScrollFrame", "SkillCardListDetailScroll", det, "FauxScrollFrameTemplate")
detScroll:SetPoint("TOPLEFT", 20, -88)
detScroll:SetPoint("BOTTOMRIGHT", -40, 20)

local function DetRefresh()
    UpdateBuild()
    local offset = FauxScrollFrame_GetOffset(detScroll)
    for i = 1, DROWS do
        local row, e = detRows[i], detList[offset + i]
        if e then
            row.entry = e
            row.icon:SetTexture(select(3, GetSpellInfo(e.spell)) or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.name:SetText("|c" .. QualityColor(e.quality) .. e.name .. "|r")
            local how = "  -  name match"
            if e.tier == 2 then how = "  -  mentioned in its text"
            elseif e.tier == 3 then how = "  -  related" .. (e.via and (" (shares '" .. e.via .. "')") or "")
            elseif e.tier == 4 then how = "  -  uses " .. tostring(e.via or "shared") .. " modifiers" end
            row.info:SetText(e.kind .. how)
            row.state:SetText(e.owned and "|cff1eff00Owned|r" or "|cff808080Not owned|r")
            row.build:SetText(InBuild(e.spell, e.name, e.kind) and "|cff00ccffIn build|r" or "")
            row:Show()
        else
            row:Hide()
        end
    end
    FauxScrollFrame_Update(detScroll, #detList, DROWS, DROW_H)
end
detScroll:SetScript("OnVerticalScroll", function(self, delta) FauxScrollFrame_OnVerticalScroll(self, delta, DROW_H, DetRefresh) end)

for i = 1, DROWS do
    local row = CreateFrame("Button", nil, det)
    row:SetSize(310, DROW_H)
    row:SetPoint("TOPLEFT", 24, -90 - (i - 1) * DROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(24, 24)
    row.icon:SetPoint("LEFT")
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, 0)
    row.name:SetWidth(200)
    row.name:SetJustifyH("LEFT")
    row.info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.info:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 0)
    row.state = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.state:SetPoint("TOPRIGHT", 0, -2)
    row.build = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.build:SetPoint("BOTTOMRIGHT", 0, 2)
    row:SetScript("OnEnter", function(self)
        local e = self.entry
        if not e then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if not pcall(GameTooltip.SetHyperlink, GameTooltip, "spell:" .. e.spell) then GameTooltip:SetText(e.name) end
        GameTooltip:AddLine(" ")
        if e.owned then GameTooltip:AddLine("You own this card", 0.3, 1, 0.3)
        else GameTooltip:AddLine("You do not own this card", 0.6, 0.6, 0.6) end
        if InBuild(e.spell, e.name, e.kind) then GameTooltip:AddLine("In your current build", 0, 0.8, 1)
        else GameTooltip:AddLine("Not in your current build", 0.6, 0.6, 0.6) end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self) if self.entry then ShowDetail(self.entry) end end)
    detRows[i] = row
end

ShowDetail = function(c)
    if not c or not c.spell then return end
    if synBuilder:IsShown() then synState.pending = c return end      -- still building; opens when done
    if not syn then StartSynergies(false, c) return end
    local sy = syn[c.spell]
    wipe(detList)
    local function Add(list) for _, e in ipairs(list or {}) do detList[#detList + 1] = e end end
    local heading
    if c.kind == "Ability" then
        Add(sy and sy.improvedBy)
        Add(sy and sy.shares)
        heading = "Talents that improve it, and abilities sharing its modifiers"
    elseif c.kind == "Talent" then
        Add(sy and sy.improves)
        heading = "Abilities this talent improves"
    else
        Add(sy and sy.improvedBy) Add(sy and sy.improves) Add(sy and sy.shares)
        heading = "Related abilities and talents"
    end
    table.sort(detList, function(x, y)
        if (x.tier or 1) ~= (y.tier or 1) then return (x.tier or 1) < (y.tier or 1) end
        if x.owned ~= y.owned then return x.owned end
        return x.name:lower() < y.name:lower()
    end)
    detTitle:SetText("|c" .. QualityColor(c.quality) .. CardName(c) .. "|r")
    detSub:SetText(#detList > 0 and (heading .. ": " .. #detList) or "No synergies found for this card.")
    det:Show()
    detScroll:SetVerticalScroll(0)
    DetRefresh()
end

---------------------------------------------------------------- bottom buttons + slash
local bScan = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
bScan:SetSize(90, 24)
bScan:SetPoint("BOTTOMLEFT", 28, 22)
bScan:SetText("Rescan")
bScan:SetScript("OnClick", StartScan)

frame:SetScript("OnShow", function()
    if not scanned and not scanning then StartScan() else Refresh() end
end)

---------------------------------------------------------------- minimap button
-- Round button on the minimap edge: left-click opens/closes the list, drag to move it around
-- the minimap.  Position and visibility are saved between sessions (SkillCardListDB).
local mmButton = CreateFrame("Button", "SkillCardListMinimapButton", Minimap)
mmButton:SetSize(31, 31)
mmButton:SetFrameStrata("MEDIUM")
mmButton:SetFrameLevel(8)
mmButton:RegisterForClicks("LeftButtonUp")
mmButton:RegisterForDrag("LeftButton")
mmButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
local mmBorder = mmButton:CreateTexture(nil, "OVERLAY")
mmBorder:SetSize(53, 53)
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mmBorder:SetPoint("TOPLEFT")
local mmIcon = mmButton:CreateTexture(nil, "BACKGROUND")
mmIcon:SetSize(20, 20)
mmIcon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
mmIcon:SetPoint("CENTER", 0, 1)

local function MinimapPlace()
    local angle = math.rad((SkillCardListDB and SkillCardListDB.angle) or 220)
    mmButton:ClearAllPoints()
    mmButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function MinimapDragging(self)
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    local deg = math.deg(math.atan2(cy - my, cx - mx))
    SkillCardListDB = SkillCardListDB or {}
    SkillCardListDB.angle = deg
    MinimapPlace()
end

mmButton:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", MinimapDragging) end)
mmButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
mmButton:SetScript("OnClick", function()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end)
mmButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Skill Card List")
    GameTooltip:AddLine("Click to open or close", 1, 1, 1)
    GameTooltip:AddLine("Drag to move this button", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
mmButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function MinimapApply()
    if SkillCardListDB and SkillCardListDB.hideMinimap then mmButton:Hide() else mmButton:Show() end
    MinimapPlace()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
    if name ~= "SkillCardList" then return end
    SkillCardListDB = SkillCardListDB or {}
    MinimapApply()
    self:UnregisterEvent("ADDON_LOADED")
end)
MinimapPlace()                                   -- default spot until saved settings load

SLASH_SKILLCARDLIST1 = "/cards"
SLASH_SKILLCARDLIST2 = "/skillcardlist"
SlashCmdList.SKILLCARDLIST = function(msg)
    msg = strtrim(msg or "")
    frame:Show()
    if msg == "scan" then
        StartScan()
    elseif msg == "minimap" then
        SkillCardListDB = SkillCardListDB or {}
        SkillCardListDB.hideMinimap = not SkillCardListDB.hideMinimap
        MinimapApply()
        print("Skill Card List: minimap button " .. (SkillCardListDB.hideMinimap and "hidden" or "shown") .. ".")
    elseif msg == "index" then
        print("Skill Card List: cards read by index, per type:")
        for typ, n in pairs(indexCounts) do print("  " .. typ .. ": " .. n) end
        print(("  %d cards total, %d found only through the list."):format(#cards, extraFound))
    elseif msg == "build" then
        UpdateBuild()
        local n, marked = 0, 0
        for _ in pairs(buildIDs) do n = n + 1 end
        for _, c in ipairs(cards) do if InBuild(c.spell, CardName(c), c.kind) then marked = marked + 1 end end
        print(("Skill Card List: %d entries in your current build, %d scanned card rows match them."):format(n, marked))
    elseif msg:match("^shift") then
        local id = tonumber(msg:match("^shift%s+(%d+)"))
        if not id then
            print("Usage: /cards shift <spell id>   (then hold Shift for 4 seconds)")
        else
            local delay, t = 4, 0
            local before = CleanText(RawSpellText(id))
            print("Skill Card List: HOLD SHIFT NOW - reading spell " .. id .. " in " .. delay .. " seconds...")
            local f = CreateFrame("Frame")
            f:SetScript("OnUpdate", function(self, el)
                t = t + el
                if t < delay then return end
                self:SetScript("OnUpdate", nil)
                local down = IsShiftKeyDown() and true or false
                local after = CleanText(RawSpellText(id))
                print("Shift held at read time: " .. tostring(down))
                print("text before: " .. before)
                print("text now: " .. after)
                print("text changed: " .. tostring(before ~= after))
            end)
        end
    elseif msg == "holdshift" then
        SkillCardListDB = SkillCardListDB or {}
        SkillCardListDB.holdShift = not SkillCardListDB.holdShift
        print("Skill Card List: pause reading until Shift is held is " .. (SkillCardListDB.holdShift and "ON" or "OFF") .. ".")
    elseif msg:match("^why") then
        local ts, as = msg:match("^why%s+(%d+)%s+(%d+)")
        ts, as = tonumber(ts), tonumber(as)
        if not (ts and as) then
            print("Usage: /cards why <talent spell id> <ability spell id>")
        else
            local tn, an = GetSpellInfo(ts), GetSpellInfo(as)
            local raw = RawSpellText(ts)
            local clean = CleanText(raw):lower()
            print(("Skill Card List: talent %s (%d)  /  ability %s (%d)"):format(tostring(tn), ts, tostring(an), as))
            print("raw text: " .. (raw:sub(1, 220):gsub("|", "||")))
            print("ability name found in the cleaned text: " .. tostring((an and WordFind(clean, an:lower())) and true or false))
        end
    elseif msg == "synergies" then
        StartSynergies(true)
    elseif msg ~= "" then
        box:SetText(msg)
        if not scanning then Rebuild() end
    end
end
