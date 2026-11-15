--[[---------------------------------------------------------------------------
    Bars.lua - die Aktionsleisten: welcher Knopf, welche Taste

    * Taste eines Zaubers: gesucht wird der Knopf, der den Zauber GERADE traegt. Leisten
      wechseln ihre Belegung (Verstohlenheit, Gestalten, Seiten); deshalb wird nicht der
      Platz, sondern der Knopf gefragt, welche Aktion er im Moment hat.
    * EllesmereUI: dessen Aktionsleisten ersetzen die von Blizzard durch eigene Knoepfe
      (EABButton<Platz>, Attribut "action" = aktuelle Aktion, Feld commandName = Befehl der
      Taste). Gibt es sie, werden nur sie benutzt; sonst die Knoepfe von Blizzard. Von den
      Knoepfen wird nur gelesen - geschuetzte Knoepfe fremder Addons veraendert neXtMove nie.
    * Haltungs- und Begleiterleiste: Zauber wie Verstohlenheit, Gestalten oder die
      Zaubersperre des Begleiters liegen oft dort und haben dort ihre Taste
      (SHAPESHIFTBUTTONn, BONUSACTIONBUTTONn). Sie zaehlen wie Leistenplaetze.
    * Leuchten: ueber dem Knopf von Move 1 liegt ein eigener Rahmen; mit EllesmereUI zeichnet
      dessen Leucht-Engine darin, sonst ein pulsierender Rand.
    * Leisten-Assistent (/nxm bars): Zauber der Klasse, die auf keiner Leiste und keiner
      Hilfstaste liegen, kommen nach Rueckfrage auf freie Plaetze - zuerst auf solche mit
      Taste. Geht nur ausserhalb des Kampfes.
-----------------------------------------------------------------------------]]

local _, NM = ...
local Plain, Call, Get, T, Print = NM.Plain, NM.Call, NM.Get, NM.T, NM.Print
local SP = NM.SPELLS

local Bars = {}
NM.Bars = Bars

local GetTime, ipairs, pairs, type, wipe = GetTime, ipairs, pairs, type, wipe

function NM.ShortKey(key)
    if not key then return nil end
    key = key:gsub("SHIFT%-", "S-"):gsub("CTRL%-", "C-"):gsub("ALT%-", "A-"):gsub("META%-", "M-")
    key = key:gsub("MOUSEWHEELUP", "MWU"):gsub("MOUSEWHEELDOWN", "MWD"):gsub("BUTTON", "M"):gsub("NUMPAD", "N")
    return key
end
local Short = NM.ShortKey

-- Knoepfe von Blizzard und der Befehl ihrer Taste
local BLIZZARD = {
    { "ActionButton", "ACTIONBUTTON" },
    { "MultiBarBottomLeftButton", "MULTIACTIONBAR1BUTTON" },
    { "MultiBarBottomRightButton", "MULTIACTIONBAR2BUTTON" },
    { "MultiBarRightButton", "MULTIACTIONBAR3BUTTON" },
    { "MultiBarLeftButton", "MULTIACTIONBAR4BUTTON" },
    { "MultiBar5Button", "MULTIACTIONBAR5BUTTON" },
    { "MultiBar6Button", "MULTIACTIONBAR6BUTTON" },
    { "MultiBar7Button", "MULTIACTIONBAR7BUTTON" },
}

local buttons = {}      -- { frame, cmd }
local byAction = {}     -- [Aktionsplatz] = { frame, key, shown, action }
local extraById = {}    -- Haltungs- und Begleiterleiste: [Zauber-ID] = Eintrag
local extraByName = {}  -- dasselbe ueber den Zaubernamen (ein anderer Rang desselben Zaubers)
local itemBy = {}       -- [Gegenstands-ID] = Eintrag
local spellCache = {}   -- [Zauber-ID] = Eintrag oder false
local dirty, builtAt = true, 0

local function Collect()
    wipe(buttons)
    for slot = 1, 180 do
        local b = _G["EABButton" .. slot]
        if b then buttons[#buttons + 1] = { frame = b, cmd = b.commandName } end
    end
    if #buttons > 0 then return end
    for _, def in ipairs(BLIZZARD) do
        for i = 1, 12 do
            local b = _G[def[1] .. i]
            if b then buttons[#buttons + 1] = { frame = b, cmd = def[2] .. i } end
        end
    end
end

-- die Aktion, die ein Knopf im Moment traegt
local function ActionOf(frame)
    local a = Plain((Call(frame.GetAttribute, frame, "action")))
    if type(a) ~= "number" or a < 1 then a = Plain(frame.action) end
    if type(a) == "number" and a >= 1 then return a end
end

local function Rebuild()
    Collect()
    wipe(byAction); wipe(itemBy); wipe(spellCache)
    for _, b in ipairs(buttons) do
        local f = b.frame
        local action = ActionOf(f)
        if action then
            local key = b.cmd and GetBindingKey(b.cmd)
            local shown = Get(f.IsVisible, f) and true or false
            local score = (key and 2 or 0) + (shown and 1 or 0)
            local e = byAction[action]
            if not e or score > e.score then
                byAction[action] = { frame = f, key = key and Short(key) or nil, shown = shown, action = action, score = score }
            end
        end
    end
    for action, e in pairs(byAction) do
        local kind, id = Call(GetActionInfo, action)
        kind, id = Plain(kind), Plain(id)
        if kind == "item" and id and (not itemBy[id] or e.score > itemBy[id].score) then itemBy[id] = e end
    end

    -- Haltungsleiste (Verstohlenheit, Gestalten, Haltungen, Auren) und Begleiterleiste: ihre
    -- Knoepfe tragen keine Aktionsplaetze, haben aber eigene Tasten. EllesmereUI benutzt
    -- hier die Knoepfe von Blizzard weiter.
    wipe(extraById); wipe(extraByName)
    local function extra(spellID, frameName, command)
        spellID = Plain(spellID)
        if type(spellID) ~= "number" then return end
        local f = _G[frameName]
        local key = GetBindingKey(command)
        local shown = f and Get(f.IsVisible, f) and true or false
        local e = { frame = f, key = key and Short(key) or nil, shown = shown, score = (key and 2 or 0) + (shown and 1 or 0) }
        if not extraById[spellID] or e.score > extraById[spellID].score then extraById[spellID] = e end
        local name = Get(C_Spell.GetSpellName, spellID)
        if name and (not extraByName[name] or e.score > extraByName[name].score) then extraByName[name] = e end
    end
    for i = 1, (Get(GetNumShapeshiftForms) or 0) do
        local _, _, _, spellID = Call(GetShapeshiftFormInfo, i)
        extra(spellID, "StanceButton" .. i, "SHAPESHIFTBUTTON" .. i)
    end
    if Plain(UnitExists("pet")) then
        for i = 1, 10 do
            local _, _, _, _, _, _, spellID = Call(GetPetActionInfo, i)
            extra(spellID, "PetActionButton" .. i, "BONUSACTIONBUTTON" .. i)
        end
    end
    dirty, builtAt = false, GetTime()
end

local function ExtraFor(id)
    local e = extraById[id]
    if e then return e end
    local name = Get(C_Spell.GetSpellName, id)
    return name and extraByName[name] or nil
end

local function Fresh()
    -- Seitenwechsel aendern die Aktionen der Knoepfe ohne eigenes Ereignis fuer Addons:
    -- deshalb zusaetzlich alle zwei Sekunden neu lesen
    if dirty or GetTime() - builtAt > 2 then Rebuild() end
end

-- Knopf und Taste, auf denen ein Zauber liegt: { frame, key, shown } oder nil.
-- stealthed: gilt die Frage fuer einen Moment in (true) oder ausserhalb (false) der
-- Verstohlenheit, der vom jetzigen abweicht - etwa fuer die Folge nach "Verstohlenheit" -,
-- dann wird die Seite der Hauptleiste umgerechnet: verstohlen zeigen ihre Knoepfe die
-- Aktionen 73-84 statt 1-12 (nur Klassen mit stealthBar).
function Bars:ForSpell(id, stealthed)
    if not id then return nil end
    Fresh()
    local shift = 0
    if stealthed ~= nil and NM.class.stealthBar then
        local now = Get(IsStealthed) and true or false
        if stealthed and not now then shift = 72 elseif now and not stealthed then shift = -72 end
    end
    local cacheKey = id + shift * 10000000
    local cached = spellCache[cacheKey]
    if cached ~= nil then return cached or nil end
    local best
    local slots = C_ActionBar and C_ActionBar.FindSpellActionButtons and Plain((Call(C_ActionBar.FindSpellActionButtons, id)))
    if type(slots) == "table" then
        for _, slot in ipairs(slots) do
            local e
            if type(slot) == "number" then
                local main, stealthPage = slot <= 12, slot >= 73 and slot <= 84
                if shift == 72 then
                    -- kuenftig verstohlen: Platz 73-84 liegt dann auf den Knoepfen, die jetzt 1-12 zeigen
                    if stealthPage then e = byAction[slot - 72] elseif not main then e = byAction[slot] end
                elseif shift == -72 then
                    if main then e = byAction[slot + 72] elseif not stealthPage then e = byAction[slot] end
                else
                    e = byAction[slot]
                end
            end
            if e and (not best or e.score > best.score) then best = e end
        end
    end
    -- die Haltungs- oder Begleiterleiste, wenn der Zauber dort (besser) liegt
    local e = ExtraFor(id)
    if e and (not best or e.score > best.score) then best = e end
    spellCache[cacheKey] = best or false
    return best
end

function Bars:ForItem(id)
    if not id then return nil end
    Fresh()
    return itemBy[id]
end

-- liegt der Zauber auf irgendeinem Leistenplatz (auch einer anderen Seite) oder auf der
-- Haltungs- oder Begleiterleiste?
function Bars:OnAnyBar(id)
    Fresh()
    if ExtraFor(id) then return true end
    local slots = C_ActionBar and C_ActionBar.FindSpellActionButtons and Plain((Call(C_ActionBar.FindSpellActionButtons, id)))
    return type(slots) == "table" and #slots > 0
end

------------------------------------------------------------------------------
-- Leuchten
------------------------------------------------------------------------------

-- Das Leuchten liegt in einem EIGENEN Rahmen ueber dem Knopf. Der Knopf selbst (bei
-- EllesmereUI ein geschuetzter EABButton) wird nie veraendert: keine Kinder, keine Texturen,
-- kein Eingriff in dessen eigene Leuchteffekte (Ausloeser, Blizzards Rotationshilfe).
-- Ist EllesmereUI geladen, zeichnet dessen Leucht-Engine in unseren Rahmen - dann passt das
-- Leuchten zum Rest der Oberflaeche (auch bei runden oder anders geformten Knoepfen). Sonst
-- ein einfacher pulsierender Rand.
local GLOW_R, GLOW_G, GLOW_B = 0.3, 1, 0.5
local EUI_STYLE = 1     -- "Pixel Glow": gezeichnet, braucht keine Grafik des Clients
local glow, glowOn

local function EUIGlows()
    local E = _G.EllesmereUI
    local G = type(E) == "table" and E.Glows
    if type(G) == "table" and type(G.StartGlow) == "function" and type(G.StopGlow) == "function" then return G end
end

local function MakeGlow()
    glow = CreateFrame("Frame", nil, UIParent)
    glow:SetFrameStrata("MEDIUM")
    glow.tex = glow:CreateTexture(nil, "OVERLAY")
    glow.tex:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    glow.tex:SetBlendMode("ADD")
    glow.tex:SetVertexColor(GLOW_R, GLOW_G, GLOW_B)
    glow.tex:SetPoint("CENTER")
    glow.tex:Hide()
    local ag = glow:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(1); a:SetToAlpha(0.35); a:SetDuration(0.45)
    glow.anim = ag
    glow:Hide()
end

local function StopLook()
    if glow.engine then
        pcall(glow.engine.StopGlow, glow)
        glow.engine = nil
    end
    glow.anim:Stop()
    glow.tex:Hide()
end

-- frame = der Knopf, der leuchten soll (nil = aus)
function Bars:Glow(frame)
    if not NM.db.glow then frame = nil end
    -- eine ausgeblendete Leiste (etwa eine, die nur unter der Maus erscheint) nicht beleuchten
    if frame then
        local alpha = Get(frame.GetEffectiveAlpha, frame)
        if alpha and alpha < 0.05 then frame = nil end
    end
    if frame == glowOn then return end
    glowOn = frame
    if not glow then MakeGlow() end
    StopLook()
    glow:SetAlpha(1)        -- die Engine von EllesmereUI blendet ihren Rahmen beim Stoppen aus
    if not frame then
        glow:Hide()
        return
    end
    glow:ClearAllPoints()
    glow:SetAllPoints(frame)
    -- auf der Ebene des Knopfes, knapp darueber: so verdeckt das Leuchten keine Fenster
    local strata, level = Get(frame.GetFrameStrata, frame), Get(frame.GetFrameLevel, frame)
    if strata then pcall(glow.SetFrameStrata, glow, strata) end
    if level then pcall(glow.SetFrameLevel, glow, level + 8) end
    local scale = (Get(frame.GetEffectiveScale, frame) or 1) / (glow:GetEffectiveScale() or 1)
    local w = (Get(frame.GetWidth, frame) or 36) * scale
    local h = (Get(frame.GetHeight, frame) or 36) * scale
    glow:Show()
    local engine = EUIGlows()
    if engine and pcall(engine.StartGlow, glow, EUI_STYLE, w, GLOW_R, GLOW_G, GLOW_B, nil, h) then
        glow.engine = engine
    else
        glow.tex:SetSize(w * 1.75, h * 1.75)
        glow.tex:Show()
        glow.anim:Play()
    end
end

------------------------------------------------------------------------------
-- Leisten-Assistent
------------------------------------------------------------------------------

-- Zauber der Klasse, die auf keiner Leiste und keiner Hilfstaste liegen
function Bars:Missing()
    local list = {}
    for key, d in pairs(SP) do
        if d.id and d.name and not (d.nobar or d.foreign or d.always or d.pet) then
            if not self:OnAnyBar(d.id) and not NM.Secure.built["spell:" .. key] then
                list[#list + 1] = key
            end
        end
    end
    table.sort(list, function(a, b) return SP[a].name < SP[b].name end)
    return list
end

-- freie Plaetze, die mit Taste zuerst
local function FreeSlots()
    Rebuild()
    local free, seen = {}, {}
    for _, b in ipairs(buttons) do
        local action = ActionOf(b.frame)
        if action and not seen[action] and not Get(HasAction, action) then
            seen[action] = true
            local key = b.cmd and GetBindingKey(b.cmd)
            local shown = Get(b.frame.IsVisible, b.frame) and true or false
            if key or shown then
                free[#free + 1] = { action = action, key = key and Short(key) or nil, shown = shown }
            end
        end
    end
    table.sort(free, function(a, b)
        if (a.key ~= nil) ~= (b.key ~= nil) then return a.key ~= nil end
        return a.action < b.action
    end)
    return free
end

local plan

local function Place()
    if not plan then return end
    if InCombatLockdown() then
        Print(T("Im Kampf lassen sich Leisten nicht ändern.", "Action bars cannot be changed in combat."))
        return
    end
    local done = 0
    for _, p in ipairs(plan) do
        local d = SP[p.key]
        if d and d.id and not Get(HasAction, p.action) then
            Call(ClearCursor)
            Call(C_Spell.PickupSpell, d.id)
            Call(PlaceAction, p.action)
            Call(ClearCursor)
            done = done + 1
        end
    end
    plan = nil
    dirty = true
    Print((T("%d Zauber auf die Leisten gelegt.", "%d spells placed on the action bars.")):format(done))
end

function Bars:Assist(go)
    if InCombatLockdown() then
        Print(T("Im Kampf lassen sich Leisten nicht ändern.", "Action bars cannot be changed in combat."))
        return
    end
    local missing, free = self:Missing(), FreeSlots()
    if #missing == 0 then
        Print(T("Alle Zauber der Rotation liegen auf einer Leiste oder Hilfstaste.", "All rotation spells are on an action bar or utility key."))
        return
    end
    plan = {}
    Print(T("Zauber ohne Platz:", "Spells without a slot:"))
    for i, key in ipairs(missing) do
        local slot = free[i]
        if slot then
            plan[#plan + 1] = { key = key, action = slot.action }
            DEFAULT_CHAT_FRAME:AddMessage(("  %s -> %s"):format(SP[key].name,
                slot.key and (T("Taste ", "key ") .. slot.key) or T("freier Platz ohne Taste", "free slot without a key")))
        else
            DEFAULT_CHAT_FRAME:AddMessage(("  %s -> %s"):format(SP[key].name, T("kein freier Platz mehr", "no free slot left")))
        end
    end
    if #plan == 0 then return end
    if go then Place(); return end
    StaticPopupDialogs["NEXTMOVE_BARS"] = StaticPopupDialogs["NEXTMOVE_BARS"] or {
        text = T("neXtMove: %d Zauber ohne Platz auf freie Leistenplätze legen? (Liste im Chat)",
                 "neXtMove: put %d spells without a slot onto free action bar slots? (list in chat)"),
        button1 = YES, button2 = NO,
        OnAccept = function() NM.Safe(Place) end,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }
    if not pcall(StaticPopup_Show, "NEXTMOVE_BARS", #plan) then
        Print(T("Zum Ausführen: /nxm bars go", "To do it: /nxm bars go"))
    end
end

function Bars:Init()
    local function mark() dirty = true end
    for _, ev in ipairs({ "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR",
                          "UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS", "UPDATE_STEALTH", "UPDATE_BINDINGS",
                          "PLAYER_ENTERING_WORLD", "SPELLS_CHANGED", "PET_BAR_UPDATE", "UNIT_PET" }) do
        NM.On(ev, mark)
    end
end
