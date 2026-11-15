--[[---------------------------------------------------------------------------
    UI.lua - die Anzeige an fester Stelle

                    Lage (Gegner, Gefahr ...)
      [Warnung]  [        ] [Modus ]      Move 1 = beste Wahl, Move 2 = zweitbeste Wahl
                 [ Move 1 ] [Move 2]      die Taste steht als kleines Schild am unteren Rand
                    |          |          darunter, kleiner und leicht durchscheinend: was
                 [Folge]    [Folge]       nach dem jeweiligen Move am besten folgt
                 [Abklingzeiten ...]

    Aussehen: flache Symbole mit weichem Schatten und Rand in der Akzentfarbe (Klassenfarbe
    oder gewaehlt), abgerundet oder eckig (Einstellung "shape"). Die abgerundete Form und
    das weiche Leuchten kommen aus zwei eigenen Texturen (Media\round.tga, Media\glow.tga).

    An jedem Symbol steht die Taste, die den Move ausloest: weiss die Taste des Zaubers in
    den Aktionsleisten, gelb eine der zwei Hilfstasten (S- Umschalt, A- Alt, C- Strg),
    "Klick" wenn er auf einer Leiste ohne Taste liegt, ein rotes "?" wenn er nirgends liegt.
    Ein Symbol ist
      abgedunkelt mit Zahl   Kraft reicht noch nicht, Sekunden bis es geht
      rot                    Ziel nicht in Reichweite
      blass                  Dauerfeuer laeuft schon (Zauberstab): weiter so
    Move 1 leuchtet in der Akzentfarbe, solange er sofort gedrueckt werden kann.
    Das Warnsymbol links zeigt Reaktionen (Unterbrechen, Schutz, Heilung), mit Ton.
    Das Schild ueber Move 2 stellt Einzelziel / Flaeche um.

    Bewegung (alles abschaltbar ueber die Einstellung "animations"):
      Wechsel eines Moves        das neue Symbol federt herein, das alte von Move 1 verpufft
      Kraft reicht wieder        das Symbol blitzt kurz auf
      Move 1 bereit              sein Leuchten atmet
      Warnung                    pulsiert
      Abklingzeit wird bereit    kurzes Aufblitzen in der Reihe
    Animationen laufen nur ueber die Animationsgruppen des Clients, gerechnet wird nichts.

    Faehrt man mit der Maus ueber ein Symbol, zeigt ein Tooltip Zauber, Grund, Taste und den
    berechneten Wert. Ausserhalb des Kampfes loest ein Klick auf Move 1 oder Move 2 den Move
    aus (Click.lua); im Kampf gehen Klicks durch die Symbole hindurch. Ist die Anzeige
    entsperrt, stehen Platzhalter da.
    Text gibt es nur, wo die Symbole nicht reichen: ein Move ohne Taste, der Grund einer
    Warnung und - ausserhalb des Kampfes - was fehlt; darueber die Lage. Die Begruendung der
    Moves laesst sich im Fenster zuschalten.
    Verschieben: /nxm unlock, ziehen, /nxm lock.
-----------------------------------------------------------------------------]]

local _, NM = ...
local Call, Get, T = NM.Call, NM.Get, NM.T
local SP = NM.SPELLS

local UI = {}
NM.UI = UI

local MAIN = { 56, 44 }         -- Move 1, Move 2
local FOLLOW = { 30, 26 }       -- ihre Folgen
local FOLLOW_ALPHA = 0.8        -- 20 % durchscheinend
local RISE = 0.26               -- Dauer, in der die alte Vorschau zum Move aufsteigt
local ALERT, CD = 40, 22
local GAP = 8
local STEM = 20                 -- Abstand Move -> Folge: Platz fuer Tastenschild und Verbindung
local MAX_CD = 10
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local MEDIA = "Interface\\AddOns\\neXtMove\\Media\\"
local TEX_ROUND, TEX_GLOW = MEDIA .. "round.tga", MEDIA .. "glow.tga"
local TEX_WHITE = "Interface\\Buttons\\WHITE8X8"
local GLOW_RATIO = 64 / 44      -- glow.tga: der Koerper nimmt 44 von 64 Pixeln ein
local SOUNDS = { warning = 8959, ready = 8960, tell = 3081 }   -- Schlachtzugswarnung, Bereitschaftscheck, Fluestern
local RACIAL_COOLDOWNS = { "bloodfury", "berserking", "warstomp" }

-- Farben
local ACCENTS = {
    green = { 0.25, 0.85, 0.60 }, blue = { 0.35, 0.65, 1.00 }, gold = { 1.00, 0.78, 0.25 }, white = { 0.92, 0.94, 0.97 },
}
local DARK = { 0.045, 0.050, 0.065 }
local COL_SECOND = { 0.62, 0.66, 0.72 }     -- Rand von Move 2
local COL_QUIET = { 0.20, 0.22, 0.26 }      -- Rand der Folgen, wartende Symbole
local COL_RED = { 1.00, 0.27, 0.27 }
local accent = { 0.25, 0.85, 0.60 }

-- Akzentfarbe: gewaehlte Farbe, sonst die Klassenfarbe
function UI.Accent()
    local c = ACCENTS[NM.db and NM.db.accent or ""]
    if c then return c[1], c[2], c[3] end
    local ok, _, token = pcall(UnitClass, "player")
    local cc = ok and type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS[token or ""]
    if cc and cc.r then return cc.r, cc.g, cc.b end
    c = ACCENTS.green
    return c[1], c[2], c[3]
end

------------------------------------------------------------------------------
-- Schrift und Bewegung
------------------------------------------------------------------------------

local function Text(parent, size, outline)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pcall(function()
        local file = GameFontHighlightSmall:GetFont() or STANDARD_TEXT_FONT
        if file then fs:SetFont(file, size, outline and "OUTLINE" or "") end
    end)
    pcall(function()
        fs:SetShadowColor(0, 0, 0, outline and 0.6 or 0.95)
        fs:SetShadowOffset(1, -1)
    end)
    return fs
end

local function AnimOn() return NM.db.animations ~= false end
-- die Vorschau steigt zum Move auf: eigener Schalter, und nur solange Animationen an sind
local function FlowOn() return NM.db.animations ~= false and NM.db.flow ~= false end

-- Bausteine. Folgen (order) nur fuer Deckkraft und Weg: dort ist sicher, wie der Client sie
-- verkettet (Deckkraft absolut, Wege addieren sich). Groessen laufen immer in einem Stueck.
local function Finish(a, duration, smooth, order)
    a:SetDuration(duration)
    if smooth and a.SetSmoothing then a:SetSmoothing(smooth) end
    if order and a.SetOrder then a:SetOrder(order) end
    return a
end

local function SetScaleTo(a, to)
    local setTo = a.SetScaleTo or a.SetToScale
    if setTo then setTo(a, to, to) end
end

local function AddScale(group, from, to, duration, smooth, order)
    local a = group:CreateAnimation("Scale")
    local setFrom = a.SetScaleFrom or a.SetFromScale
    if setFrom then setFrom(a, from, from) end
    SetScaleTo(a, to)
    if a.SetOrigin then a:SetOrigin("CENTER", 0, 0) end
    return Finish(a, duration, smooth, order)
end

local function AddFade(group, from, to, duration, smooth, order)
    local a = group:CreateAnimation("Alpha")
    a:SetFromAlpha(from); a:SetToAlpha(to)
    return Finish(a, duration, smooth, order)
end

local function AddMove(group, dx, dy, duration, smooth, order)
    local a = group:CreateAnimation("Translation")
    a:SetOffset(dx, dy)
    return Finish(a, duration, smooth, order)
end

-- einmal abspielen (von vorn, falls sie noch laeuft)
local function Play(group)
    if not (group and AnimOn()) then return end
    if group:IsPlaying() then group:Stop() end
    group:Play()
end

-- Dauerschleife an oder aus
local function Loop(group, on)
    if not group then return end
    if on and AnimOn() then
        if not group:IsPlaying() then group:Play() end
    elseif group:IsPlaying() then
        group:Stop()
    end
end

------------------------------------------------------------------------------
-- Tooltip eines Symbols: der Zauber oder Gegenstand, darunter der Grund und die Taste
------------------------------------------------------------------------------

local function ShowTip(icon)
    local m, S = icon.move, icon.state
    if not (m and S and NM.db.tooltips) then return end
    pcall(function()
        GameTooltip:SetOwner(icon, "ANCHOR_RIGHT")
        if m.kind == "item" or m.kind == "poison" then GameTooltip:SetItemByID(m.item)
        elseif m.kind == "trinket" then GameTooltip:SetInventoryItem("player", m.slot)
        else GameTooltip:SetSpellByID(S:id(m.key)) end
        if m.why and m.why ~= "" then GameTooltip:AddLine(m.why, 0.3, 1, 0.6, true) end
        if m.running then GameTooltip:AddLine(T("läuft schon: weiter so", "already running: keep going"), 0.7, 0.7, 0.7) end
        -- was das Schadensmodell fuer diesen Move rechnet
        if m.kind == nil and NM.db.useModel and NM.Model then
            local line = NM.Model:ValueText(S, m.key)
            if line then GameTooltip:AddLine(line, 0.6, 0.8, 1, true) end
        end
        if icon.keyText and icon.keyText ~= "" then
            GameTooltip:AddLine(T("Taste: ", "Key: ") .. icon.keyText, 1, 0.82, 0)
        end
        GameTooltip:Show()
    end)
end

UI.ShowTip = ShowTip

------------------------------------------------------------------------------
-- Ein Symbol
--   Ebenen von hinten nach vorn: Schatten, Leuchten, Rand, dunkler Grund, Bild,
--   Abdunkelung (wartet), Aufblitzen, Abklinguhr, Beschriftung
--   role: "m1", "m2", "follow", "alert", "cd"
------------------------------------------------------------------------------

local icons = {}

local function MakeIcon(parent, size, role)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.role = role
    f.baseAlpha = (role == "follow") and FOLLOW_ALPHA or 1
    f:SetAlpha(f.baseAlpha)
    local big = (role == "m1" or role == "m2" or role == "alert")
    -- Tooltip beim Ueberfahren; Klicks gehen durch das Symbol hindurch (nur wenn der Client
    -- beides getrennt schalten kann - sonst bleibt das Symbol ganz durchlaessig)
    if f.SetMouseClickEnabled and f.SetMouseMotionEnabled then
        f:EnableMouse(true)
        f:SetMouseClickEnabled(false)
        f:SetScript("OnEnter", ShowTip)
        f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local pad = size * (GLOW_RATIO - 1) / 2
    f.shadow = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    f.shadow:SetTexture(TEX_GLOW)
    f.shadow:SetPoint("TOPLEFT", -pad, pad - 1); f.shadow:SetPoint("BOTTOMRIGHT", pad, -pad - 1)
    f.shadow:SetVertexColor(0, 0, 0, big and 0.75 or 0.55)

    f.glow = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    f.glow:SetTexture(TEX_GLOW)
    f.glow:SetBlendMode("ADD")
    f.glow:SetPoint("TOPLEFT", -pad, pad); f.glow:SetPoint("BOTTOMRIGHT", pad, -pad)
    f.glow:SetAlpha(0.7)
    f.glow:Hide()
    -- das Leuchten atmet, solange der Move sofort geht
    f.breath = f.glow:CreateAnimationGroup()
    f.breath:SetLooping("BOUNCE")
    AddFade(f.breath, 1, 0.45, role == "alert" and 0.32 or 1.1, "IN_OUT")

    local edge = big and 2 or 1
    f.border = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    f.border:SetPoint("TOPLEFT", -edge, edge); f.border:SetPoint("BOTTOMRIGHT", edge, -edge)
    f.back = f:CreateTexture(nil, "BORDER")
    f.back:SetAllPoints()

    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.shade = f:CreateTexture(nil, "ARTWORK", nil, 2)
    f.shade:SetAllPoints()
    f.shade:SetColorTexture(0, 0, 0, 0.5)
    f.shade:Hide()
    f.flash = f:CreateTexture(nil, "OVERLAY")
    f.flash:SetAllPoints()
    f.flash:SetColorTexture(1, 1, 1, 1)
    f.flash:SetBlendMode("ADD")
    f.flash:SetAlpha(0)                         -- sichtbar nur, waehrend die Animation laeuft
    f.flashAnim = f.flash:CreateAnimationGroup()
    AddFade(f.flashAnim, 0.55, 0, 0.3, "OUT")
    if f.CreateMaskTexture then
        f.mask = f:CreateMaskTexture()
        f.mask:SetAllPoints(f.tex)
    end

    f.cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    f.cd:SetAllPoints()
    if f.cd.SetHideCountdownNumbers then f.cd:SetHideCountdownNumbers(true) end
    if f.cd.SetDrawEdge then f.cd:SetDrawEdge(false) end
    if f.cd.SetDrawBling then f.cd:SetDrawBling(false) end

    local over = CreateFrame("Frame", nil, f)
    over:SetAllPoints()
    over:SetFrameLevel(f.cd:GetFrameLevel() + 2)
    if big then
        -- Tastenschild: liegt mittig auf dem unteren Rand
        local p = CreateFrame("Frame", nil, over)
        p:SetSize(20, size >= 50 and 16 or 14)
        p:SetPoint("CENTER", f, "BOTTOM", 0, 0)
        p.edge = p:CreateTexture(nil, "BACKGROUND")
        p.edge:SetAllPoints()
        p.edge:SetColorTexture(1, 1, 1, 1)
        p.bg = p:CreateTexture(nil, "BORDER")
        p.bg:SetPoint("TOPLEFT", 1, -1); p.bg:SetPoint("BOTTOMRIGHT", -1, 1)
        p.bg:SetColorTexture(DARK[1], DARK[2], DARK[3], 1)
        f.key = Text(p, size >= 50 and 11 or 10)
        f.key:SetPoint("CENTER", 0, 0)
        f.pill = p
    else
        f.key = Text(over, 9, true)
        f.key:SetPoint("TOPRIGHT", 2, 1)
    end
    f.wait = Text(over, size >= 50 and 18 or (size >= 36 and 14 or 10), true)
    f.wait:SetPoint("CENTER", 0, big and 2 or 0)
    f.wait:SetTextColor(1, 1, 1)

    -- Wechsel: die grossen Symbole wachsen weich herein, die Folgen gleiten von unten an
    -- ihren Platz (erst ein Stueck nach unten gesetzt, dann zurueck: Wege addieren sich)
    f.pop = f:CreateAnimationGroup()
    if role == "follow" then
        AddMove(f.pop, 0, -8, 0.01, nil, 1)
        AddFade(f.pop, 0, 0, 0.01, nil, 1)
        AddMove(f.pop, 0, 8, 0.24, "OUT", 2)
        AddFade(f.pop, 0, f.baseAlpha, 0.24, "OUT", 2)
    else
        if role ~= "cd" then AddScale(f.pop, role == "m1" and 0.78 or 0.85, 1, 0.22, "OUT") end
        AddFade(f.pop, 0.2, f.baseAlpha, 0.16, "OUT")
    end
    if role == "m1" or role == "m2" then
        -- die Vorschau steigt gerade hierher auf: kurz unsichtbar, dann unter ihrem Abbild einblenden
        f.land = f:CreateAnimationGroup()
        AddFade(f.land, 0, 0, 0.09, nil, 1)
        AddFade(f.land, 0, 1, 0.15, "OUT", 2)
    end
    if role == "m1" then
        -- Lichtring, der sich beim Wechsel von Move 1 ausbreitet (unsichtbar ausser in der Animation)
        f.burst = f:CreateTexture(nil, "BACKGROUND", nil, -6)
        f.burst:SetTexture(TEX_GLOW)
        f.burst:SetBlendMode("ADD")
        f.burst:SetPoint("TOPLEFT", -pad, pad); f.burst:SetPoint("BOTTOMRIGHT", pad, -pad)
        f.burst:SetAlpha(0)
        f.burstAnim = f.burst:CreateAnimationGroup()
        AddScale(f.burstAnim, 0.9, 1.3, 0.38, "OUT")
        AddFade(f.burstAnim, 0.6, 0, 0.38, "OUT")
    end
    if role == "alert" then
        f.pulse = f:CreateAnimationGroup()
        f.pulse:SetLooping("BOUNCE")
        AddScale(f.pulse, 1, 1.08, 0.32, "IN_OUT")
    end

    f:Hide()
    icons[#icons + 1] = f
    return f
end

-- Form (abgerundet oder eckig) auf ein Symbol anwenden
local function Shape(f)
    local round = (NM.db.shape ~= "square") and f.mask ~= nil
    local base = round and TEX_ROUND or TEX_WHITE
    f.border:SetTexture(base)
    f.back:SetTexture(base)
    f.back:SetVertexColor(DARK[1], DARK[2], DARK[3], 1)
    if f.mask then
        if round and not f.masked then
            f.mask:SetTexture(TEX_ROUND, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            f.tex:AddMaskTexture(f.mask); f.shade:AddMaskTexture(f.mask); f.flash:AddMaskTexture(f.mask)
            f.masked = true
        elseif not round and f.masked then
            f.tex:RemoveMaskTexture(f.mask); f.shade:RemoveMaskTexture(f.mask); f.flash:RemoveMaskTexture(f.mask)
            f.masked = false
        end
    end
    if f.cd.SetSwipeTexture then pcall(f.cd.SetSwipeTexture, f.cd, base) end
    if f.cd.SetSwipeColor then pcall(f.cd.SetSwipeColor, f.cd, 0, 0, 0, 0.7) end
end

local function SetBorder(f, c, alpha)
    f.border:SetVertexColor(c[1], c[2], c[3], alpha or 1)
end

local function SetGlow(f, c, on)
    if on then
        f.glow:SetVertexColor(c[1], c[2], c[3])
        f.glow:Show()
    else
        f.glow:Hide()
    end
    Loop(f.breath, on)
end

-- Taste ans Symbol schreiben: als Schild (grosse Symbole) oder als kleine Zahl
local function SetKey(f, text, r, g, b)
    f.key:SetText(text or "")
    f.key:SetTextColor(r or 1, g or 1, b or 1)
    if f.pill then
        if text and text ~= "" then
            f.pill:SetWidth(math.max(20, (f.key:GetStringWidth() or 0) + 10))
            f.pill.edge:SetVertexColor(r or 1, g or 1, b or 1, 0.85)
            f.pill:Show()
        else
            f.pill:Hide()
        end
    end
end

local function HideIcon(f)
    f.shownId = nil
    f.wasWaiting = nil
    f:Hide()
end

------------------------------------------------------------------------------
-- Aufbau
------------------------------------------------------------------------------

-- Abbild eines Symbols, das nur waehrend seiner Animation zu sehen ist (Grunddeckkraft 0)
local function GhostFrame(parent, size, over, level)
    local g = CreateFrame("Frame", nil, parent)
    g:SetSize(size, size)
    g:SetPoint("CENTER", over, "CENTER")
    g:SetFrameLevel(UI.main[1]:GetFrameLevel() + level)
    g:SetAlpha(0)
    -- Weg und Deckkraft am aeusseren Rahmen, Groesse am inneren: so waechst das Abbild um
    -- seine eigene Mitte, wo immer der Weg es gerade hingetragen hat
    g.inner = CreateFrame("Frame", nil, g)
    g.inner:SetAllPoints()
    g.tex = g.inner:CreateTexture(nil, "OVERLAY")
    g.tex:SetAllPoints()
    g.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    if g.inner.CreateMaskTexture then
        g.mask = g.inner:CreateMaskTexture()
        g.mask:SetAllPoints(g.tex)
    end
    g.anim = g:CreateAnimationGroup()
    g.grow = g.inner:CreateAnimationGroup()
    return g
end

-- Form des Abbilds an die Einstellung anpassen (rund = Maske, eckig = ohne)
local function ShapeGhost(g)
    if not g.mask then return end
    local round = NM.db.shape ~= "square"
    if round and not g.masked then
        g.mask:SetTexture(TEX_ROUND, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        g.tex:AddMaskTexture(g.mask); g.masked = true
    elseif not round and g.masked then
        g.tex:RemoveMaskTexture(g.mask); g.masked = false
    end
end

-- Mitte eines Symbols, gerechnet ab der linken oberen Ecke der Anzeige
local function CenterOf(role, i)
    local x = (i == 1) and MAIN[1] / 2 or (MAIN[1] + GAP + MAIN[2] / 2)
    if role == "main" then return x, -MAIN[1] + MAIN[i] / 2 end
    return x, -MAIN[1] - STEM - FOLLOW[i] / 2
end

-- Die Vorschau von Strang "from" ist zum Move "to" geworden: ihr Abbild steigt dorthin auf
-- und waechst dabei auf dessen Groesse. Der Move selbst blendet unter dem Abbild ein (f.land).
local function Rise(from, to, texture)
    local r = UI.riser[from]
    if not (r and texture and AnimOn()) then return end
    local fx, fy = CenterOf("follow", from)
    local tx, ty = CenterOf("main", to)
    r.tex:SetTexture(texture)
    r.move:SetOffset(tx - fx, ty - fy)
    SetScaleTo(r.scale, MAIN[to] / FOLLOW[from])
    -- anhalten versteckt das Abbild (OnStop): erst danach zeigen und starten
    if r.anim:IsPlaying() then r.anim:Stop() end
    if r.grow:IsPlaying() then r.grow:Stop() end
    r:SetAlpha(1)
    r:Show()
    r.anim:Play(); r.grow:Play()
end

local MODE_TEXT = { auto = "AUTO", single = T("EINZEL", "SINGLE"), aoe = T("FLÄCHE", "AOE") }
local MODE_NEXT = { auto = "single", single = "aoe", aoe = "auto" }

function UI:Init()
    local f = CreateFrame("Frame", "NextMoveFrame", UIParent)
    f:SetSize(MAIN[1] + GAP + MAIN[2], MAIN[1] + STEM + FOLLOW[1])
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(s) if not NM.db.locked then s:StartMoving() end end)
    f:SetScript("OnDragStop", function(s)
        s:StopMovingOrSizing()
        local point, _, _, x, y = s:GetPoint(1)
        NM.db.point = { point, x, y }
    end)
    self.frame = f

    -- dunkle Flaeche hinter der Anzeige (auf Wunsch)
    f.panel = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    f.panel:SetPoint("TOPLEFT", -10, 10); f.panel:SetPoint("BOTTOMRIGHT", 10, -10)
    f.panel:SetColorTexture(0.03, 0.035, 0.045, 0.6)
    f.panelEdge = {}
    for i, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
                         { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
        local t = f:CreateTexture(nil, "BACKGROUND", nil, -7)
        t:SetPoint(e[1], f.panel, e[1]); t:SetPoint(e[2], f.panel, e[2])
        if e[3] then t:SetHeight(1) else t:SetWidth(1) end
        t:SetColorTexture(1, 1, 1, 0.10)
        f.panelEdge[i] = t
    end

    -- Griff zum Verschieben (nur entsperrt sichtbar)
    f.mover = f:CreateTexture(nil, "BACKGROUND", nil, -6)
    f.mover:SetPoint("TOPLEFT", -6, 6); f.mover:SetPoint("BOTTOMRIGHT", 6, -6)
    f.moverText = Text(f, 10)
    f.moverText:SetPoint("BOTTOM", f, "TOP", 0, 10)
    f.moverText:SetText(T("neXtMove · ziehen zum Verschieben", "neXtMove · drag to move"))

    -- zwei Straenge: Move oben, Folge darunter, dazwischen eine duenne Verbindung
    self.main, self.follow, self.stem = {}, {}, {}
    self.main[1] = MakeIcon(f, MAIN[1], "m1")
    self.main[2] = MakeIcon(f, MAIN[2], "m2")
    self.main[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    self.main[2]:SetPoint("BOTTOMLEFT", self.main[1], "BOTTOMRIGHT", GAP, 0)
    for i = 1, 2 do
        self.follow[i] = MakeIcon(f, FOLLOW[i], "follow")
        self.follow[i]:SetPoint("TOP", self.main[i], "BOTTOM", 0, -STEM)
        local stem = f:CreateTexture(nil, "ARTWORK")
        stem:SetWidth(2)
        stem:SetPoint("TOP", self.main[i], "BOTTOM", 0, -9)
        stem:SetPoint("BOTTOM", self.follow[i], "TOP", 0, 2)
        stem:Hide()
        self.stem[i] = stem
    end

    -- das alte Symbol von Move 1 verpufft beim Wechsel (unsichtbar ausser in der Animation)
    -- und zieht dabei nach oben weg: alles in der Anzeige fliesst von unten nach oben
    local ghost = GhostFrame(f, MAIN[1], self.main[1], 8)
    AddMove(ghost.anim, 0, 18, 0.34, "OUT")
    AddFade(ghost.anim, 0.6, 0, 0.34, "OUT")
    AddScale(ghost.grow, 1, 1.18, 0.34, "OUT")
    self.ghost = ghost

    -- die alte Vorschau steigt auf, wenn sie zum Move wird: ein Abbild von ihr wandert von
    -- ihrem Platz nach oben zum Move, waechst dabei und verblasst (Ziel wird beim Start gesetzt)
    self.riser = {}
    for i = 1, 2 do
        local r = GhostFrame(f, FOLLOW[i], self.follow[i], 7)
        r.move = AddMove(r.anim, 0, 0, RISE, "OUT")
        r.scale = AddScale(r.grow, 1, 1.8, RISE, "OUT")
        -- die erste Haelfte des Wegs deckend, dann in den Move uebergehen. Das Abbild ist nur
        -- waehrend der Animation gezeigt; danach versteckt es sich selbst.
        local fade = AddFade(r.anim, 1, 0, RISE * 0.5, "IN_OUT")
        if fade.SetStartDelay then fade:SetStartDelay(RISE * 0.5) else fade:SetDuration(RISE) end
        if r.anim.SetToFinalAlpha then r.anim:SetToFinalAlpha(true) end
        r:SetAlpha(1)
        r:Hide()
        r.anim:SetScript("OnFinished", function() r:Hide() end)
        r.anim:SetScript("OnStop", function() r:Hide() end)
        self.riser[i] = r
    end

    -- Warnsymbol
    self.alert = MakeIcon(f, ALERT, "alert")
    self.alert:SetPoint("BOTTOMRIGHT", self.main[1], "BOTTOMLEFT", -(GAP + 6), 0)

    -- Reihe der grossen Abklingzeiten
    f.cdRow = CreateFrame("Frame", nil, f)
    f.cdRow:SetSize(MAX_CD * (CD + 4), CD)
    f.cdRow:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -10)
    self.cds = {}
    for i = 1, MAX_CD do
        local icon = MakeIcon(f.cdRow, CD, "cd")
        icon:SetPoint("LEFT", f.cdRow, "LEFT", (i - 1) * (CD + 4), 0)
        self.cds[i] = icon
    end

    f.reason = Text(f, 11)
    f.reason:SetWidth(280)
    f.reason:SetJustifyH("LEFT")
    f.check = Text(f, 11)
    f.check:SetWidth(280)
    f.check:SetJustifyH("LEFT")
    f.check:SetTextColor(1, 0.80, 0.35)
    f.check:SetPoint("TOPLEFT", f.reason, "BOTTOMLEFT", 0, -3)
    f.status = Text(f, 10)
    f.status:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 7)
    f.status:SetWidth(340)
    f.status:SetJustifyH("LEFT")

    -- Umschalter Einzelziel / Flaeche: ein Schild im freien Platz ueber Move 2
    local mode = CreateFrame("Button", nil, f)
    mode:SetSize(MAIN[2], MAIN[1] - MAIN[2] - 2)
    mode:SetPoint("BOTTOMLEFT", self.main[2], "TOPLEFT", 0, 2)
    mode.bg = mode:CreateTexture(nil, "BACKGROUND")
    mode.bg:SetAllPoints()
    mode.bg:SetColorTexture(DARK[1], DARK[2], DARK[3], 0.8)
    mode.text = Text(mode, 8)
    mode.text:SetPoint("CENTER", 0, 0)
    mode:SetScript("OnClick", function()
        NM.db.aoeMode = MODE_NEXT[NM.db.aoeMode] or "auto"
        UI:ApplyLayout()
    end)
    mode:SetScript("OnEnter", function(s)
        s.bg:SetColorTexture(0.16, 0.17, 0.20, 0.95)
        GameTooltip:SetOwner(s, "ANCHOR_TOP")
        GameTooltip:SetText(T("Einzelziel oder Fläche", "Single target or area"))
        GameTooltip:AddLine(T("AUTO: nach Zahl der Gegner\nEINZEL: immer Einzelziel\nFLÄCHE: immer Fläche\nKlick wechselt.",
            "AUTO: by enemy count\nSINGLE: always single target\nAOE: always area\nClick to switch."), 1, 1, 1)
        GameTooltip:Show()
    end)
    mode:SetScript("OnLeave", function(s)
        s.bg:SetColorTexture(DARK[1], DARK[2], DARK[3], 0.8)
        GameTooltip:Hide()
    end)
    f.mode = mode

    self:ApplyLayout()
end

function UI:ApplyLayout()
    local f, db = self.frame, NM.db
    if not f then return end
    accent[1], accent[2], accent[3] = UI.Accent()
    f:SetScale(db.scale or 1)
    f:ClearAllPoints()
    local p = db.point
    f:SetPoint(p[1] or "CENTER", UIParent, p[1] or "CENTER", p[2] or 0, p[3] or 0)
    f:EnableMouse(not db.locked)
    f.mover:SetColorTexture(accent[1], accent[2], accent[3], 0.22)
    f.mover:SetShown(not db.locked)
    f.moverText:SetShown(not db.locked)
    f.moverText:SetTextColor(accent[1], accent[2], accent[3])
    local panel = db.panel and true or false
    f.panel:SetShown(panel)
    for _, t in ipairs(f.panelEdge) do t:SetShown(panel) end
    f.status:SetShown(db.showStatus and true or false)
    f.check:SetShown(db.showCheck and true or false)
    f.cdRow:SetShown(db.showCooldowns and true or false)
    f.reason:ClearAllPoints()
    f.reason:SetPoint("TOPLEFT", db.showCooldowns and f.cdRow or f, "BOTTOMLEFT", 0, -8)

    -- Form und Farben
    for _, icon in ipairs(icons) do Shape(icon) end
    ShapeGhost(self.ghost)
    ShapeGhost(self.riser[1]); ShapeGhost(self.riser[2])
    self.stem[1]:SetColorTexture(accent[1], accent[2], accent[3], 0.55)
    self.stem[2]:SetColorTexture(COL_SECOND[1], COL_SECOND[2], COL_SECOND[3], 0.4)

    -- Umschalter: von Hand gewaehlt = Akzentfarbe, automatisch = zurueckhaltend
    local forced = (db.aoeMode == "single" or db.aoeMode == "aoe")
    f.mode.text:SetText(MODE_TEXT[db.aoeMode] or "AUTO")
    if forced then f.mode.text:SetTextColor(accent[1], accent[2], accent[3])
    else f.mode.text:SetTextColor(0.62, 0.66, 0.72) end

    if not AnimOn() then
        for _, icon in ipairs(icons) do
            Loop(icon.breath, false); Loop(icon.pulse, false)
        end
    end
    f:SetShown(db.enabled and true or false)
    if not db.glow or not db.enabled then NM.Bars:Glow(nil) end
end

------------------------------------------------------------------------------
-- Malen
------------------------------------------------------------------------------

local function IconOf(S, m)
    if m.kind == "poison" or m.kind == "item" then return Get(C_Item.GetItemIconByID, m.item) end
    if m.kind == "trinket" then return Get(GetInventoryItemTexture, "player", m.slot) end
    local id = S:id(m.key)
    return id and Get(C_Spell.GetSpellTexture, id)
end

local function NameOf(S, m)
    if m.kind == "poison" or m.kind == "item" then return Get(C_Item.GetItemNameByID, m.item) or T("Gegenstand", "Item") end
    if m.kind == "trinket" then return T("Schmuckstück", "Trinket") end
    return S:name(m.key) or m.key
end

-- Die globale Abklingzeit laeuft als Uhr ueber Move 1. Die Werte gehen ungeprueft an den
-- Client (er darf auch geheime Werte zeichnen), gerechnet wird damit nicht.
local function PaintCooldown(cd, id)
    pcall(function()
        local info = id and C_Spell.GetSpellCooldown(id)
        if info then cd:SetCooldown(info.startTime, info.duration) end
    end)
end

local function GcdSpell()
    for _, k in ipairs(NM.State.gcdSpells or {}) do
        if SP[k] and SP[k].id then return SP[k].id end
    end
end

-- Malt einen Move in ein Symbol; gibt den Leistenknopf zurueck (zum Leuchten)
-- Art eines Moves, der nicht zur Rotation gehoert: "heal" (Essen, Verband, Heiltrank,
-- Gesundheitsstein), "mana" (Trinken, Manatrank, Manastein), "craft" (Herstellen: Wasser,
-- Brot, Steine), "buff" (Buffzauber, Elixiere, Bufffood, Rollen, Waffensteine, Gifte)
local CAT_KEY = { heal = "colHeal", mana = "colMana", craft = "colCraft", buff = "colBuff" }
local ITEM_CAT = { healthstone = "heal", potion = "heal", managem = "mana", manapotion = "mana",
                   ["rest:eat"] = "heal", ["rest:bandage"] = "heal", ["rest:drink"] = "mana" }
local function CategoryOf(m)
    local cat = ITEM_CAT[m.key or ""]
    if cat then return cat end
    if m.consum or m.kind == "poison" then return "buff" end
    if m.kind == nil then
        local d = SP[m.key]
        if d then
            if d.craft then return "craft" end
            -- Buff: haelt lange, ohne Abklingzeit, nicht auf den Gegner
            if d.dur and d.dur >= 120 and not d.cd and d.unit ~= "target" and not d.foreign then return "buff" end
        end
    end
    return nil
end
UI.CategoryOf = CategoryOf

local function IdOf(m) return m.key or m.item or m.slot or m.kind or "?" end

local function Paint(icon, S, m, landing)
    icon.move, icon.state = m, S
    if not m then HideIcon(icon); return nil end
    local texture = IconOf(S, m) or FALLBACK_ICON
    local id = IdOf(m)
    local changed = (icon.shownId ~= id)
    local cat = CategoryOf(m)
    local tint = cat and NM.db[CAT_KEY[cat]]
    if type(tint) ~= "table" then tint = nil end
    icon:Show()
    -- der alte Move 1 zieht nach oben weg, der neue waechst herein (erst zeigen, dann
    -- bewegen: an einem versteckten Rahmen laeuft keine Animation an)
    if changed then
        if icon.role == "m1" and AnimOn() then
            if icon.shownId and icon.shownTex then
                UI.ghost.tex:SetTexture(icon.shownTex)
                Play(UI.ghost.anim); Play(UI.ghost.grow)
            end
            local c = tint or accent
            icon.burst:SetVertexColor(c[1], c[2], c[3])
            Play(icon.burstAnim)
        end
        if landing and icon.land then
            -- die Vorschau steigt hierher auf: nicht hereinwachsen, sondern unter ihr einblenden
            if icon.pop:IsPlaying() then icon.pop:Stop() end
            Play(icon.land)
        else
            if icon.land and icon.land:IsPlaying() then icon.land:Stop() end
            Play(icon.pop)
        end
    end
    icon.shownId, icon.shownTex = id, texture
    icon.tex:SetTexture(texture)

    local key, where, button = NM.Secure:KeyFor(S, m)
    m.noKey = (where == nil)
    icon.keyText = key
    if where == "own" then SetKey(icon, key, 1, 0.82, 0.1)
    elseif where == "bar" or where == "click" then SetKey(icon, key, 1, 1, 1)
    elseif (m.kind or cat) and NM.db.clickIcons ~= false and not S.inCombat then
        -- Gegenstaende, Buffs und Herstellen liegen selten auf einer Leiste und werden ausserhalb
        -- des Kampfes am Symbol angeklickt: kein Fehler, also weder Rot noch Text
        SetKey(icon, nil)
    else SetKey(icon, "?", COL_RED[1], COL_RED[2], COL_RED[3]) end

    local waiting = (m.wait and m.wait > 0.2) and true or false
    icon.wait:SetText(waiting and (m.wait >= 10 and ("%d"):format(m.wait) or ("%.1f"):format(m.wait)) or "")
    icon.tex:SetDesaturated(waiting)
    icon.shade:SetShown(waiting)
    -- die Kraft reicht wieder: kurz aufblitzen
    if icon.wasWaiting and not waiting and not changed then Play(icon.flashAnim) end
    icon.wasWaiting = waiting
    -- Dauerfeuer, das schon laeuft (Zauberstab): blass - "weiter so", nichts zu druecken
    icon.tex:SetAlpha(m.running and 0.45 or 1)
    if m.running then button = nil end

    local d = (m.kind == nil) and SP[m.key]
    -- (Zauber auf einen selbst und solche ohne globale Abklingzeit brauchen kein Ziel in Reichweite)
    -- jeder Zauber hat seine eigene Reichweite; sagt der Client nichts, zaehlt die der Klasse
    -- (Gegenstaende haben keine Reichweite: reach bleibt nil. Bis 0.12.0 stand hier false,
    -- und jeder Gegenstand wurde rot gemalt, als waere das Ziel zu weit weg.)
    local reach
    if d and S.inRange then reach = S:inRange(m.key) end
    local far = reach == false
        or (reach == nil and d and d.unit ~= "player" and not d.offgcd and S.target.valid and S.target.melee == false)
    if far then icon.tex:SetVertexColor(1, 0.45, 0.45) else icon.tex:SetVertexColor(1, 1, 1) end

    -- Rand und Leuchten
    local role = icon.role
    if role == "alert" then
        SetBorder(icon, COL_RED)
        SetGlow(icon, COL_RED, true)
    elseif far then
        SetBorder(icon, COL_RED, 0.9)
        SetGlow(icon, COL_RED, false)
    elseif waiting or m.running then
        SetBorder(icon, COL_QUIET)
        SetGlow(icon, accent, false)
    elseif role == "follow" or role == "cd" then
        if tint then SetBorder(icon, tint, 0.85) else SetBorder(icon, COL_QUIET) end
        SetGlow(icon, accent, false)
    elseif role == "m1" then
        -- Heilen, Mana, Herstellen und Buffen tragen ihre eigene Farbe (Einstellungen > Aussehen)
        SetBorder(icon, tint or accent)
        SetGlow(icon, tint or accent, true)
    else
        if tint then SetBorder(icon, tint) else SetBorder(icon, COL_SECOND, 0.9) end
        SetGlow(icon, accent, false)
    end
    return button
end

local DANGER = { T("erhöht", "elevated"), T("hoch", "high"), T("kritisch", "critical") }
local C_DIM, C_WARN, C_BAD, C_END = "|cff9aa3b0", "|cffffb347", "|cffff5555", "|r"

-- Die Lage in einer Zeile: Wichtiges farbig, der Rest zurueckhaltend
local function StatusLine(S)
    local parts = {}
    local en, t = S.enemies, S.target
    -- Gruppe: vor dem Kampf die Zusammensetzung, im Kampf nur, was Handeln verlangt
    local P = S.party
    if P and P.n and P.n > 0 then
        if not S.inCombat then
            parts[#parts + 1] = NM.Party.Describe(P)
        else
            if P.threatHigh then parts[#parts + 1] = C_BAD .. T("Bedrohung hoch", "threat high") .. C_END .. C_DIM end
            if P.aggroSoft and P.myRole == "TANK" then
                parts[#parts + 1] = C_WARN .. T("Ziel greift ", "target attacks ") .. tostring(P.aggro.name or "?") .. T(" an", "") .. C_END .. C_DIM
            end
        end
    end
    if en.n > 0 then
        local s = ("|cffffffff%d|r %s"):format(en.n, T("Gegner", en.n == 1 and "enemy" or "enemies"))
        if en.far > 0 then s = s .. (", %d %s"):format(en.far, T("nicht erreichbar", "out of reach")) end
        if en.onMe > 0 then s = s .. (", %d %s"):format(en.onMe, T("an dir", "on you")) end
        parts[#parts + 1] = s
    end
    if t.valid and S.inCombat and S.ttd and S.ttd < 900 then
        parts[#parts + 1] = ("%s ~%ds"):format(T("Ziel", "target"), math.floor(S.ttd))
    end
    if S.hitRate and S.hitRate >= 0.4 then
        parts[#parts + 1] = ("%.1f %s"):format(S.hitRate, T("Treffer/s", "hits/s"))
    end
    if S.lowHealth then parts[#parts + 1] = C_BAD .. T("Gesundheit niedrig", "low health") .. C_END .. C_DIM end
    if S.danger > 0 then
        parts[#parts + 1] = (S.danger >= 2 and C_BAD or C_WARN) .. T("Gefahr ", "danger ") .. DANGER[S.danger] .. C_END .. C_DIM
    end
    if t.valid and t.melee == false then parts[#parts + 1] = C_BAD .. T("außer Reichweite", "out of range") .. C_END .. C_DIM end
    if S.inCombat and not t.valid and en.n > 0 then
        parts[#parts + 1] = C_WARN .. T("kein Ziel gewählt", "no target selected") .. C_END .. C_DIM
    end
    -- geschaetzte Werte mit Tilde: der Client gibt sie nicht heraus
    if S.inCombat and S.power and not S.powerRead then parts[#parts + 1] = ("E~%d"):format(math.floor(S.power)) end
    if S.moving then parts[#parts + 1] = T("in Bewegung", "moving") end
    if #parts == 0 then return "" end
    return C_DIM .. table.concat(parts, "  ·  ") .. C_END
end

local lastSound = 0

-- Platzhalter, solange die Anzeige entsperrt ist: so sieht man beim Verschieben ihre Groesse
local function Placeholder(icon, text)
    if icon.shownId then return end
    icon:Show()
    icon.tex:SetTexture(FALLBACK_ICON)
    icon.tex:SetDesaturated(true)
    icon.tex:SetVertexColor(1, 1, 1)
    icon.tex:SetAlpha(0.6)
    icon.shade:Hide()
    icon.wait:SetText("")
    SetKey(icon, text, 1, 1, 1)
    SetBorder(icon, COL_QUIET)
    SetGlow(icon, accent, false)
end

local NO_STRANDS = {}

-- ein Symbol der Abklingzeiten-Reihe: bereit = hell mit Akzentrand, sonst entsaettigt mit Uhr
function UI:PaintCooldownIcon(S, k)
    local n = self.cdCount
    if n >= MAX_CD or not S:known(k) then return end
    n = n + 1
    self.cdCount = n
    local c = self.cds[n]
    c:Show()
    SetKey(c, nil)
    c.move, c.state = { key = k }, S
    c.tex:SetTexture(Get(C_Spell.GetSpellTexture, S:id(k)) or FALLBACK_ICON)
    local ready = S:cd(k) <= S.gcd + 0.15
    c.tex:SetDesaturated(not ready)
    c:SetAlpha(ready and 1 or 0.6)
    SetBorder(c, ready and accent or COL_QUIET, ready and 0.85 or 1)
    if ready then c.cd:Clear() else PaintCooldown(c.cd, S:id(k)) end
    -- gerade bereit geworden: kurz aufblitzen
    if c.shownId == k and c.wasReady == false and ready then Play(c.flashAnim) end
    c.shownId, c.wasReady = k, ready
end

function UI:Show(S, strands, alert)
    local f = self.frame
    if not f then return end
    local db = NM.db
    local glowButton
    -- auf Wunsch nur im Kampf: davor bleibt nur der Vor-Kampf-Check
    if db.onlyCombat and not S.inCombat then strands, alert = NO_STRANDS, nil end

    -- was eben noch zu sehen war (fuer den Aufstieg der Vorschau)
    local flow = FlowOn()
    local wasMain1, wasMain2 = self.main[1].shownId, self.main[2].shownId
    local wasNext1, wasNext2 = self.follow[1].shownId, self.follow[2].shownId
    local wasTex1, wasTex2 = self.follow[1].shownTex, self.follow[2].shownTex

    -- Die Vorschau wird zum Move: die alte Vorschau steigt dorthin auf. Zuerst der eigene
    -- Strang; sonst die Vorschau des anderen (nach Move 2 folgt oft dessen Vorschau).
    -- Entschieden wird vor dem Malen, damit der Move dazu passend einblendet.
    local riseTo1, riseTo2
    if flow then
        local m1, m2 = strands[1] and strands[1].move, strands[2] and strands[2].move
        local now1, now2 = m1 and IdOf(m1), m2 and IdOf(m2)
        if now1 and now1 ~= wasMain1 then
            if wasNext1 == now1 then riseTo1 = 1 elseif wasNext2 == now1 then riseTo1 = 2 end
        end
        if now2 and now2 ~= wasMain2 then
            if wasNext2 == now2 and riseTo1 ~= 2 then riseTo2 = 2
            elseif wasNext1 == now2 and riseTo1 ~= 1 then riseTo2 = 1 end
        end
    end
    -- ein Abbild, das nach einer unterbrochenen Animation stehen blieb, verschwindet
    for i = 1, 2 do
        local r = self.riser[i]
        if r:IsShown() and not r.anim:IsPlaying() then r:Hide() end
    end

    for i = 1, 2 do
        local strand = strands[i]
        local landing = (i == 1 and riseTo1 or i == 2 and riseTo2) and true or false
        local button = Paint(self.main[i], strand and strand.state or S, strand and strand.move, landing)
        if i == 1 then glowButton = button end
        local follow = strand and strand.follow
        Paint(self.follow[i], follow and follow.state or S, follow and follow.move)
        self.stem[i]:SetShown((strand and follow) and true or false)
    end
    if riseTo1 then Rise(riseTo1, 1, riseTo1 == 1 and wasTex1 or wasTex2) end
    if riseTo2 then Rise(riseTo2, 2, riseTo2 == 1 and wasTex1 or wasTex2) end
    local m1 = strands[1] and strands[1].move
    if m1 then PaintCooldown(self.main[1].cd, GcdSpell()) end
    if NM.Click then NM.Click:Update(db.locked and strands or NO_STRANDS) end
    NM.Bars:Glow(glowButton)
    if not db.locked then
        Placeholder(self.main[1], "1"); Placeholder(self.main[2], "2")
        Placeholder(self.follow[1], ""); Placeholder(self.follow[2], "")
        self.stem[1]:Show(); self.stem[2]:Show()
    end

    -- Warnsymbol: eine Reaktion, der gerade nicht als Move 1 gefolgt wird
    local icon = self.alert
    if db.alerts and alert then
        Paint(icon, S, alert)
        Loop(icon.pulse, true)
        if db.sound and alert.fresh and S.now - lastSound > 2.5 then
            lastSound = S.now
            Call(PlaySound, SOUNDS[db.alertSound] or SOUNDS.warning, "Master")
        end
    else
        Loop(icon.pulse, false)
        Loop(icon.breath, false)
        HideIcon(icon)
    end

    -- Reihe der Abklingzeiten: bereit = hell, sonst entsaettigt mit Uhr
    if db.showCooldowns then
        local function each(list)
            for _, k in ipairs(list) do self:PaintCooldownIcon(S, k) end
        end
        self.cdCount = 0
        each(NM.class.cooldowns or {})
        each(RACIAL_COOLDOWNS)
        for i = self.cdCount + 1, MAX_CD do HideIcon(self.cds[i]) end
    end

    -- Text unter den Symbolen: von Haus aus nur, was die Symbole nicht sagen (ein Move ohne
    -- Taste, eine Warnung). Die Begruendung der Moves gibt es auf Wunsch dazu (showReason).
    local lines = {}
    if m1 then
        local s1, s2 = strands[1], strands[2]
        if db.showReason then
            local text = ("|cffffffff%s|r  %s%s|r"):format(NameOf(s1.state, m1), C_DIM, m1.why or "")
            if s1.follow then
                text = text .. ("  |cff7d8591%s %s|r"):format(T("dann", "then"), NameOf(s1.follow.state, s1.follow.move))
            end
            lines[#lines + 1] = text
            if s2 then
                text = ("%s%s|r |cffcccccc%s|r"):format(C_DIM, T("oder", "or"), NameOf(s2.state, s2.move))
                if s2.follow then
                    text = text .. ("  |cff7d8591%s %s|r"):format(T("dann", "then"), NameOf(s2.follow.state, s2.follow.move))
                end
                lines[#lines + 1] = text
            end
        end
        if m1.noKey then
            lines[#lines + 1] = C_BAD .. NameOf(s1.state, m1) .. T(" liegt auf keiner Taste: in eine Leiste ziehen oder /nxm bars",
                " is on no key: drag it onto an action bar or /nxm bars") .. "|r"
        end
    end
    if alert and db.alerts and (alert.demoted or not db.showReason) then
        lines[#lines + 1] = ("%s%s|r  |cffff9c9c%s|r"):format(C_BAD, NameOf(S, alert), alert.why or "")
    end
    f.reason:SetText(table.concat(lines, "\n"))

    -- Vor-Kampf-Check
    if db.showCheck then
        local text = ""
        if not S.inCombat and NM.class.precheck then
            local missing = {}
            local function note(what) missing[#missing + 1] = what end
            NM.class.precheck(S, note)
            if NM.Consumables then NM.Consumables:Check(S, note) end
            if #missing > 0 then text = T("Fehlt: ", "Missing: ") .. "|cffffffff" .. table.concat(missing, "|r, |cffffffff") .. "|r" end
        end
        f.check:SetText(text)
    end

    if db.showStatus then
        f.status:SetText((m1 or S.inCombat or (S.party and S.party.n and S.party.n > 0)) and StatusLine(S) or "")
    end
end
