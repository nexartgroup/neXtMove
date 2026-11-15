--[[---------------------------------------------------------------------------
    Click.lua - die Symbole von Move 1 und Move 2 anklicken

    Ausserhalb des Kampfes liegt ueber jedem der beiden Symbole ein sicherer Knopf, der den
    gezeigten Move ausloest: buffen, Begleiter rufen, herstellen, den Kampf eroeffnen.

    Im Kampf geht das nicht: Blizzard verbietet Addons, im Kampf zu aendern, was ein Knopf
    ausloest (InCombatLockdown) - und der gezeigte Move wechselt dort staendig. Ein Knopf mit
    dem Stand von vor dem Kampf wuerde das Falsche wirken. Deshalb verschwinden die Knoepfe
    mit Kampfbeginn; im Kampf bleiben die Tasten und die Leistenknoepfe (der von Move 1
    leuchtet).

    Die Knoepfe haengen nicht an der Anzeige, sondern stehen fuer sich an deren Stelle: so
    bleibt die Anzeige selbst frei beweglich und wird im Kampf nicht gesperrt.
-----------------------------------------------------------------------------]]

local _, NM = ...

local Click = {}
NM.Click = Click

local btns, tokens = {}, {}
local inCombat = false

local function MacroFor(S, m)
    if m.kind == nil then
        local name = S:name(m.key)
        return name and ("/cast " .. name), "spell:" .. m.key
    elseif m.kind == "item" then
        return "/use item:" .. m.item, "item:" .. m.item
    elseif m.kind == "trinket" then
        return "/use " .. m.slot, "trinket:" .. m.slot
    elseif m.kind == "poison" then
        -- ein Waffengift braucht zwei Schritte: benutzen, dann die Waffe waehlen
        return "/use item:" .. m.item .. "\n/use " .. m.slot, "poison:" .. m.item .. ":" .. m.slot
    end
end

function Click:Init()
    for i = 1, 2 do
        local b = CreateFrame("Button", "NextMoveClick" .. i, UIParent, "SecureActionButtonTemplate")
        -- der Client loest je nach Einstellung beim Druecken oder beim Loslassen aus
        b:RegisterForClicks("AnyUp", "AnyDown")
        b:SetFrameStrata("MEDIUM")
        b:SetFrameLevel(60)
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        b:SetScript("OnEnter", function()
            local icon = NM.UI.main and NM.UI.main[i]
            if icon and NM.UI.ShowTip then NM.UI.ShowTip(icon) end
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- mitlesen, welcher Gegenstand angeklickt wurde (lehnt der Client ihn ab, etwa weil
        -- ein staerkerer Buff laeuft, weiss das Addon, welcher es war)
        b:HookScript("PostClick", function()
            local t = tokens[i]
            local id = t and (t:find("^item:") or t:find("^poison:")) and tonumber(t:match("^%a+:(%d+)"))
            if id and NM.Consumables and NM.Consumables.Tried then NM.Consumables.Tried(id, "click") end
        end)
        b:Hide()
        btns[i] = b
    end
    -- Kampfbeginn: in diesem Ereignis darf noch geaendert werden
    NM.On("PLAYER_REGEN_DISABLED", function()
        inCombat = true
        for i = 1, 2 do btns[i]:Hide() end
    end)
    NM.On("PLAYER_REGEN_ENABLED", function() inCombat = false end)
end

-- je Takt, nach dem Malen der Symbole
function Click:Update(strands)
    if inCombat or InCombatLockdown() or not btns[1] then return end
    local db = NM.db
    local on = db.clickIcons and db.enabled and db.locked
    for i = 1, 2 do
        local b, icon = btns[i], NM.UI.main[i]
        local strand = on and strands[i]
        local m = strand and strand.move
        local text, token
        if m then text, token = MacroFor(strand.state, m) end
        local left, bottom = icon:GetLeft(), icon:GetBottom()
        if text and left and bottom and icon:IsVisible() then
            if tokens[i] ~= token then
                b:SetAttribute("type", "macro")
                b:SetAttribute("macrotext", text)
                tokens[i] = token
            end
            -- an die Stelle des Symbols, in den Massen von UIParent
            local ratio = icon:GetEffectiveScale() / UIParent:GetEffectiveScale()
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left * ratio, bottom * ratio)
            b:SetSize(icon:GetWidth() * ratio, icon:GetHeight() * ratio)
            b:Show()
        else
            b:Hide()
        end
    end
end
