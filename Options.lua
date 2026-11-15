--[[---------------------------------------------------------------------------
    Options.lua - das Einstellungsfenster (/nxm)

    Ein eigenes, flaches Fenster ohne Blizzard-Vorlagen: links die Bereiche, rechts die
    Zeilen des gewaehlten Bereichs. Jede Zeile hat links ihren Namen und rechts genau ein
    Bedienelement, an festen Plaetzen - nichts laeuft ueber.

      Allgemein     Ein/Aus, Verschieben, Einzelziel/Flaeche, Allein/Gruppe, Schadensmodell
      Aussehen      Groesse, Form, Akzentfarbe, Flaeche dahinter, Animationen
      Anzeige       was die Anzeige zeigt (Leuchten, Lage, Abklingzeiten, Check, Text)
      Warnungen     Warnsymbol, Ton, Traenke, Schmuck
      Klasse        die Regeln und Auswahlen der Klasse (aus Classes/*.lua)
      Hilfstasten   Belegung der acht Plaetze, Tasten festlegen
      Werkzeuge     Leisten-Assistent, Erkanntes, Probe, Zuruecksetzen
      Hilfe         wie sich die Anzeige liest

    Bedienelemente: Schalter, Auswahl (Klick weiter, Rechtsklick zurueck), Schrittregler,
    Knopf. Alles gilt je Charakter und wirkt sofort. Gebaut wird beim ersten Oeffnen.
    Das Fenster blendet weich ein, Schalter gleiten, Seiten blenden ueber - alles nur, wenn
    die Einstellung "animations" an ist. Die Akzentfarbe ist die der Anzeige (UI.Accent).
-----------------------------------------------------------------------------]]

local _, NM = ...
local T, Print = NM.T, NM.Print

local Options = {}
NM.Options = Options

local WIDTH, HEIGHT = 720, 500
local SIDEBAR = 180
local ROW_H, ROW_GAP = 30, 2
local PAD = 22
local MAX_ROWS = 12

-- Farben
local C_BG       = { 0.055, 0.060, 0.075, 0.97 }
local C_SIDE     = { 0.035, 0.040, 0.050, 1 }
local C_ROW      = { 1, 1, 1, 0.035 }
local C_ROW_ALT  = { 1, 1, 1, 0.015 }
local C_LINE     = { 1, 1, 1, 0.08 }
local C_ACCENT   = { 0.20, 0.80, 0.55, 1 }
local C_OFF      = { 0.25, 0.27, 0.31, 1 }
local C_CONTROL  = { 1, 1, 1, 0.07 }
local C_HOVER    = { 1, 1, 1, 0.14 }
local C_TEXT     = { 0.92, 0.93, 0.95 }
local C_DIM      = { 0.60, 0.63, 0.68 }

local frame, content, pageTitle, pageHint, brand, stripe
local navButtons, rows = {}, {}
local pages, currentPage
local capturing

local function Tex(parent, layer, color)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    return t
end

local function Label(parent, font, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetTextColor(color[1], color[2], color[3])
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- Flacher Knopf mit Hover
local function FlatButton(parent, width, height)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, height)
    b.bg = Tex(b, "BACKGROUND", C_CONTROL)
    b.bg:SetAllPoints()
    b.text = Label(b, "GameFontHighlightSmall", C_TEXT)
    b.text:SetPoint("LEFT", 8, 0); b.text:SetPoint("RIGHT", -8, 0)
    b.text:SetJustifyH("CENTER")
    b:SetScript("OnEnter", function(s) s.bg:SetColorTexture(C_HOVER[1], C_HOVER[2], C_HOVER[3], C_HOVER[4]) end)
    b:SetScript("OnLeave", function(s) s.bg:SetColorTexture(C_CONTROL[1], C_CONTROL[2], C_CONTROL[3], C_CONTROL[4]) end)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    return b
end

------------------------------------------------------------------------------
-- Texte fuer Auswahlwerte
------------------------------------------------------------------------------

local VALUE_TEXT = {
    auto = T("automatisch", "automatic"), single = T("Einzelziel", "single target"), aoe = T("Fläche", "area"),
    solo = T("allein", "solo"), group = T("Gruppe", "group"), none = T("keiner", "none"),
}

local function ValueText(def, value)
    if def.format then
        local text = def.format(value)
        if text then return text end
    end
    -- Werte, die Zauber der Klasse benennen, in der Clientsprache
    local d = type(value) == "string" and NM.SPELLS[value]
    if d and d.name then return d.name end
    return VALUE_TEXT[value] or tostring(value)
end

------------------------------------------------------------------------------
-- Seiten: Listen von Zeilen
--   { kind = "toggle", key, label }
--   { kind = "choice", key, label, values, format }
--   { kind = "step",   key, label, min, max, step, format }
--   { kind = "color",  key, label }                      (Farbwaehler; Rechtsklick = Vorgabe)
--   { kind = "button", label, text, run }
--   { kind = "info",   label, text = function }          (nur Anzeige)
--   { kind = "bind",   index }                           (Hilfstaste festlegen)
------------------------------------------------------------------------------

local function BuildPages()
    local C = NM.class
    local className = UnitClass("player") or ""

    local classRows = {
        { kind = "info", label = T("Skillung", "Talents"), text = function()
            local S = NM.State
            local specs = C.specs or {}
            return ("%s  (%d/%d/%d)%s"):format(specs[S.spec] or "?", S.points[1], S.points[2], S.points[3],
                S.specKnown and "" or T("  geschätzt", "  guessed"))
        end },
    }
    for _, def in ipairs(C.options or {}) do
        classRows[#classRows + 1] = { kind = "choice", key = def.key, label = def.label, values = def.values, format = def.format }
    end
    local keys = {}
    for k in pairs(C.labels or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return C.labels[a] < C.labels[b] end)
    for _, k in ipairs(keys) do
        classRows[#classRows + 1] = { kind = "toggle", key = k, label = C.labels[k] }
    end

    local keyRows = {
        { kind = "bind", index = 1 },
        { kind = "bind", index = 2 },
    }
    for i = 1, 8 do
        keyRows[#keyRows + 1] = { kind = "info", slot = i, text = function() return "" end }
    end

    pages = {
        { id = "general", name = T("Allgemein", "General"),
          hint = T("Grundlegendes zur Anzeige und zur Lage im Kampf.", "The basics of the display and the combat situation."),
          rows = {
            { kind = "toggle", key = "enabled", label = T("neXtMove eingeschaltet", "neXtMove enabled") },
            { kind = "toggle", key = "locked", invert = true, label = T("Anzeige verschieben (mit der Maus ziehen)", "Move the display (drag it)") },
            { kind = "toggle", key = "onlyCombat", label = T("Moves nur im Kampf zeigen", "Show moves in combat only") },
            { kind = "choice", key = "aoeMode", label = T("Einzelziel oder Fläche", "Single target or area"), values = { "auto", "single", "aoe" } },
            { kind = "choice", key = "groupMode", label = T("Allein oder in der Gruppe", "Solo or in a group"), values = { "auto", "solo", "group" } },
            { kind = "toggle", key = "useParty", label = T("Vorschläge an die Gruppe anpassen (Klassen, Tank, Heiler)", "Adapt suggestions to the group (classes, tank, healer)") },
            { kind = "toggle", key = "useModel", label = T("Rotation nach berechnetem Schaden ordnen", "Order the rotation by calculated damage") },
            { kind = "choice", key = "playStyle", label = T("Umgang mit Mana", "Mana usage"), values = { "auto", "fast", "thrifty" },
              format = function(v)
                  return (v == "fast" and T("schnell töten", "kill fast")) or (v == "thrifty" and T("sparsam", "thrifty")) or "auto"
              end },
            { kind = "toggle", key = "clickIcons", label = T("Move 1 und 2 anklickbar (außerhalb des Kampfes)", "Moves 1 and 2 clickable (out of combat)") },
            { kind = "choice", key = "moveDelay", label = T("Bewegung ändert die Vorschläge erst nach", "Movement changes the suggestions only after"),
              values = { 0.5, 1, 1.5, 2, 3, 5, "never" },
              format = function(v)
                  if v == "never" then return T("nie (Bewegung ignorieren)", "never (ignore movement)") end
                  local n = tostring(v):gsub("%.", T(",", "."))
                  return (T("%s Sekunden Laufen", "%s seconds of moving")):format(n)
              end },
          } },
        { id = "look", name = T("Aussehen", "Appearance"),
          hint = T("Größe, Form und Farbe der Anzeige, und ob sie sich bewegt.", "Size, shape and color of the display, and whether it moves."),
          rows = {
            { kind = "step", key = "scale", label = T("Größe der Anzeige", "Display size"), min = 0.6, max = 2, step = 0.1,
              format = function(v) return ("%d %%"):format(math.floor(v * 100 + 0.5)) end },
            { kind = "choice", key = "shape", label = T("Form der Symbole", "Icon shape"), values = { "round", "square" },
              format = function(v) return v == "square" and T("eckig", "square") or T("abgerundet", "rounded") end },
            { kind = "choice", key = "accent", label = T("Akzentfarbe (Rand und Leuchten von Move 1)", "Accent color (border and glow of move 1)"),
              values = { "class", "green", "blue", "gold", "white" },
              format = function(v)
                  return (v == "green" and T("Grün", "green")) or (v == "blue" and T("Blau", "blue")) or (v == "gold" and "Gold")
                      or (v == "white" and T("Weiß", "white")) or T("Klassenfarbe", "class color")
              end },
            { kind = "toggle", key = "panel", label = T("Dunkle Fläche hinter der Anzeige", "Dark panel behind the display") },
            { kind = "toggle", key = "animations", label = T("Animationen (Wechsel, Leuchten, Pulsieren, Fenster)", "Animations (changes, glow, pulse, window)") },
            { kind = "toggle", key = "flow", label = T("Vorschau steigt zum Move auf, wenn sie an der Reihe ist", "Preview rises to the move when its turn comes") },
            { kind = "color", key = "colHeal", label = T("Randfarbe Heilen (Essen, Verband, Heiltrank)", "Border color healing (food, bandage, healing potion)") },
            { kind = "color", key = "colMana", label = T("Randfarbe Mana (Trinken, Manatrank, Manastein)", "Border color mana (drink, mana potion, mana gem)") },
            { kind = "color", key = "colCraft", label = T("Randfarbe Herstellen (Wasser, Brot, Steine)", "Border color crafting (water, food, stones)") },
            { kind = "color", key = "colBuff", label = T("Randfarbe Buffs (Zauber, Elixiere, Bufffood, Rollen)", "Border color buffs (spells, elixirs, buff food, scrolls)") },
          } },
        { id = "display", name = T("Anzeige", "Display"),
          hint = T("Was neben den zwei Strängen zu sehen ist.", "What is shown next to the two strands."),
          rows = {
            { kind = "toggle", key = "glow", label = T("Knopf von Move 1 leuchtet in der Aktionsleiste", "Highlight the action button of move 1") },
            { kind = "toggle", key = "showCooldowns", label = T("Reihe der großen Abklingzeiten", "Row of major cooldowns") },
            { kind = "toggle", key = "showStatus", label = T("Lage über der Anzeige (Gegner, Gefahr)", "Situation above the display (enemies, danger)") },
            { kind = "toggle", key = "showCheck", label = T("Vor-Kampf-Check (was fehlt)", "Pre-combat check (what is missing)") },
            { kind = "toggle", key = "showReason", label = T("Begründung der Moves als Text", "Explain the moves in text") },
            { kind = "toggle", key = "tooltips", label = T("Tooltip beim Überfahren eines Symbols", "Tooltip when hovering an icon") },
          } },
        { id = "alerts", name = T("Warnungen", "Alerts"),
          hint = T("Reaktionen wie Unterbrechen, Schutz und Heilung.", "Reactions such as interrupt, defense and healing."),
          rows = {
            { kind = "toggle", key = "alerts", label = T("Warnsymbol für Reaktionen", "Alert icon for reactions") },
            { kind = "toggle", key = "sound", label = T("Ton zur Warnung", "Alert sound") },
            { kind = "choice", key = "alertSound", label = T("Welcher Ton", "Which sound"), values = { "warning", "ready", "tell" },
              format = function(v)
                  return (v == "warning" and T("Schlachtzugswarnung", "raid warning")) or (v == "ready" and T("Bereitschaftscheck", "ready check"))
                      or T("Flüstern", "whisper")
              end },
            { kind = "toggle", key = "usePotions", label = T("Tränke und Gesundheitssteine vorschlagen", "Suggest potions and healthstones") },
            { kind = "toggle", key = "useTrinkets", label = T("Schmuckstücke vorschlagen", "Suggest trinkets") },
            { kind = "toggle", key = "useRest", label = T("Essen und Trinken vorschlagen, wenn Gesundheit oder Mana niedrig sind (geschätzt)", "Suggest eating and drinking when health or mana are low (estimated)") },
            { kind = "choice", key = "consumables", label = T("Elixiere, Bufffood, Rollen und Waffensteine vorschlagen", "Suggest elixirs, buff food, scrolls and weapon stones"),
              values = { "always", "hard", "off" },
              format = function(v)
                  return (v == "hard" and T("Gruppe, Instanz, Elite", "group, instance, elite")) or (v == "off" and T("nie", "never"))
                      or T("wenn der Buff fehlt", "when the buff is missing")
              end },
            { kind = "toggle", key = "useRacials", label = T("Volksfähigkeiten vorschlagen", "Suggest racial abilities") },
          } },
        { id = "class", name = className,
          hint = T("Regeln und Auswahlen dieser Klasse.", "Rules and choices of this class."),
          rows = classRows },
        { id = "keys", name = T("Hilfstasten", "Utility keys"),
          hint = T("Zwei feste Tasten mit je vier Plätzen: allein, mit Umschalt (S-), Alt (A-) und Strg (C-).",
                   "Two fixed keys with four slots each: alone, with Shift (S-), Alt (A-) and Ctrl (C-)."),
          rows = keyRows },
        { id = "tools", name = T("Werkzeuge", "Tools"),
          hint = T("Hilfen zum Einrichten und zur Fehlersuche.", "Helpers for setup and troubleshooting."),
          rows = {
            { kind = "button", label = T("Zauber ohne Taste auf freie Leistenplätze legen", "Put spells without a key onto free bar slots"),
              text = T("Leisten-Assistent", "Bar assistant"), run = function() NM.Bars:Assist() end },
            { kind = "button", label = T("Erkannte Skillung, Zauber und Gegenstände in den Chat", "Print detected talents, spells and items"),
              text = T("Zeigen", "Show"), run = function() NM.State:PrintStatus() end },
            { kind = "button", label = T("Erkannte Gruppe (Klassen, Rollen, Tank, Heiler) in den Chat", "Print the detected group (classes, roles, tank, healer)"),
              text = T("Zeigen", "Show"), run = function() NM.Party:Print() end },
            { kind = "button", label = T("Schadensmodell: Waffenwerte und Wert jedes Zaubers in den Chat", "Damage model: weapon values and the value of each spell"),
              text = T("Zeigen", "Show"), run = function() NM.Model:Print() end },
            { kind = "button", label = T("Prüfen, welche Werte der Client herausgibt", "Check which values the client hands out"),
              text = T("Probe", "Probe"), run = function() NM.Probe:Run(true) end },
            { kind = "button", label = T("Alle Einstellungen auf die Vorgaben setzen", "Reset all settings to their defaults"),
              text = T("Zurücksetzen", "Reset"), run = function() NM.ResetSettings(); NM.UI:ApplyLayout() end },
          } },
        { id = "help", name = T("Hilfe", "Help"),
          hint = T("So liest sich die Anzeige.", "How to read the display."),
          rows = {
            { kind = "info", wide = true, label = T("Großes Symbol", "Large icon"),
              text = function() return T("Move 1: die beste Wahl in diesem Moment", "Move 1: the best choice right now") end },
            { kind = "info", wide = true, label = T("Zweites Symbol", "Second icon"),
              text = function() return T("Move 2: die zweitbeste Wahl, als Alternative", "Move 2: the second-best choice, as an alternative") end },
            { kind = "info", wide = true, label = T("Kleine Symbole darunter", "Small icons below"),
              text = function() return T("was nach dem jeweiligen Move am besten folgt", "what follows best after that move") end },
            { kind = "info", wide = true, label = T("Leuchtender Rand", "Glowing border"),
              text = function() return T("Move 1 kann sofort gedrückt werden", "move 1 can be pressed right now") end },
            { kind = "info", wide = true, label = T("Weiße Taste", "White key"),
              text = function() return T("Taste des Zaubers in deinen Aktionsleisten", "the spell's key on your action bars") end },
            { kind = "info", wide = true, label = T("Gelbe Taste", "Yellow key"),
              text = function() return T("eine Hilfstaste: S- Umschalt, A- Alt, C- Strg", "a utility key: S- Shift, A- Alt, C- Ctrl") end },
            { kind = "info", wide = true, label = T("\"Klick\" oder rotes ?", "\"click\" or red ?"),
              text = function() return T("auf einer Leiste ohne Taste / Zauber der Rotation liegt nirgends", "on a bar without a key / a rotation spell placed nowhere") end },
            { kind = "info", wide = true, label = T("Farbiger Rand", "Colored border"),
              text = function() return T("Heilen, Mana, Herstellen, Buff: außerhalb des Kampfes anklicken", "healing, mana, crafting, buff: click it out of combat") end },
            { kind = "info", wide = true, label = T("Abgedunkelt mit Zahl", "Dimmed with a number"),
              text = function() return T("Sekunden, bis die Kraft für den Move reicht", "seconds until you can afford the move") end },
            { kind = "info", wide = true, label = T("Roter Rand, rot getönt", "Red border, red tint"),
              text = function() return T("Ziel ist nicht in Reichweite", "the target is out of range") end },
            { kind = "info", wide = true, label = T("Rotes Symbol links", "Red icon on the left"),
              text = function() return T("Warnung: Unterbrechen, Schutz oder Heilung", "alert: interrupt, defense or healing") end },
          } },
    }
end

------------------------------------------------------------------------------
-- Zeilen
------------------------------------------------------------------------------

local function StopCapture()
    capturing = nil
    if frame then
        frame:EnableKeyboard(false)
        frame:SetScript("OnKeyDown", nil)
    end
end

local MODIFIER_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true, LMETA = true, RMETA = true }

-- Die naechste gedrueckte Taste wird zur Hilfstaste (Esc bricht ab)
local function StartCapture(index)
    if InCombatLockdown() then
        Print(T("Tasten lassen sich im Kampf nicht ändern.", "Keys cannot be changed in combat."))
        return
    end
    capturing = index
    frame:EnableKeyboard(true)
    frame:SetScript("OnKeyDown", function(_, key)
        if MODIFIER_KEYS[key] then return end
        if key ~= "ESCAPE" then NM.Secure:Bind(index, key) end
        StopCapture()
        Options:Refresh()
    end)
    Options:Refresh()
end

local function MakeRow(index)
    local row = CreateFrame("Frame", nil, content)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(index - 1) * (ROW_H + ROW_GAP))
    row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    row.bg = Tex(row, "BACKGROUND", (index % 2 == 1) and C_ROW or C_ROW_ALT)
    row.bg:SetAllPoints()
    row.label = Label(row, "GameFontHighlight", C_TEXT)
    row.label:SetPoint("LEFT", 12, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -190, 0)

    -- Schalter
    local toggle = CreateFrame("Button", nil, row)
    toggle:SetSize(40, 18)
    toggle:SetPoint("RIGHT", -12, 0)
    toggle.track = Tex(toggle, "BACKGROUND", C_OFF)
    toggle.track:SetAllPoints()
    toggle.knob = Tex(toggle, "ARTWORK", { 1, 1, 1, 1 })
    toggle.knob:SetSize(14, 14)
    row.toggle = toggle

    -- Auswahl und Knopf teilen sich einen flachen Knopf
    row.button = FlatButton(row, 170, 22)
    row.button:SetPoint("RIGHT", -12, 0)
    -- Farbfeld (Farbwaehler)
    row.swatch = row.button:CreateTexture(nil, "ARTWORK")
    row.swatch:SetPoint("TOPLEFT", 3, -3); row.swatch:SetPoint("BOTTOMRIGHT", -3, 3)
    row.swatch:Hide()

    -- Schrittregler: [-] Wert [+]
    row.minus = FlatButton(row, 26, 22)
    row.plus = FlatButton(row, 26, 22)
    row.plus:SetPoint("RIGHT", -12, 0)
    row.value = Label(row, "GameFontHighlight", C_TEXT)
    row.value:SetWidth(70)
    row.value:SetJustifyH("CENTER")
    row.value:SetPoint("RIGHT", row.plus, "LEFT", -4, 0)
    row.minus:SetPoint("RIGHT", row.value, "LEFT", -4, 0)
    row.minus.text:SetText("-")
    row.plus.text:SetText("+")

    -- reine Anzeige rechts
    row.info = Label(row, "GameFontHighlight", C_DIM)
    row.info:SetPoint("RIGHT", -12, 0)
    row.info:SetJustifyH("RIGHT")
    return row
end

-- Schalter: Knopf und Farbe folgen t.pos (0 = aus, 1 = an)
local function PlaceKnob(t)
    local p = t.pos or 0
    t.knob:ClearAllPoints()
    t.knob:SetPoint("LEFT", t, "LEFT", 2 + p * 22, 0)
    -- an = dunkler Knopf auf der Akzentfarbe (bleibt auch auf Weiss und Gelb sichtbar)
    local k = 1 - p * 0.93
    t.knob:SetColorTexture(k, k, k, 1)
    t.track:SetColorTexture(C_OFF[1] + (C_ACCENT[1] - C_OFF[1]) * p, C_OFF[2] + (C_ACCENT[2] - C_OFF[2]) * p,
        C_OFF[3] + (C_ACCENT[3] - C_OFF[3]) * p, 1)
end

local function SlideKnob(t, elapsed)
    local d = t.target - t.pos
    local step = (elapsed or 0) / 0.12
    if math.abs(d) <= step then
        t.pos = t.target
        t:SetScript("OnUpdate", nil)
    else
        t.pos = t.pos + (d > 0 and step or -step)
    end
    PlaceKnob(t)
end

-- stellt den Schalter; gleitet nur, wenn dieselbe Zeile umgeschaltet wurde
local function SetToggle(t, on, slide)
    t.target = on and 1 or 0
    if slide and t.pos and t.pos ~= t.target and NM.db.animations ~= false then
        t:SetScript("OnUpdate", SlideKnob)
    else
        t.pos = t.target
        t:SetScript("OnUpdate", nil)
        PlaceKnob(t)
    end
end

local function HideControls(row)
    row.toggle:Hide(); row.button:Hide(); row.minus:Hide(); row.plus:Hide(); row.value:Hide(); row.info:Hide()
    row.swatch:Hide()
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", 12, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -190, 0)
end

local function ApplyChange()
    NM.UI:ApplyLayout()
    Options:Refresh()
end

-- Blizzards Farbwaehler oeffnen; Abbrechen stellt die alte Farbe wieder her
local function PickColor(key)
    local CPF = ColorPickerFrame
    local db = NM.db
    local c = db[key]
    if type(CPF) ~= "table" or type(c) ~= "table" then return end
    local old = { c[1], c[2], c[3] }
    local function set(r, g, b)
        db[key] = { r, g, b }
        ApplyChange()
    end
    local function picked()
        local r, g, b = CPF:GetColorRGB()
        if type(r) == "number" then set(r, g, b) end
    end
    local function cancel() set(old[1], old[2], old[3]) end
    if CPF.SetupColorPickerAndShow then
        CPF:SetupColorPickerAndShow({ r = old[1], g = old[2], b = old[3], hasOpacity = false, swatchFunc = picked, cancelFunc = cancel })
    else
        CPF.hasOpacity = false; CPF.func = picked; CPF.cancelFunc = cancel; CPF.previousValues = old
        CPF:SetColorRGB(old[1], old[2], old[3]); CPF:Hide(); CPF:Show()
    end
    -- das Einstellungsfenster liegt ganz oben: den Farbwaehler davor holen
    if CPF.SetFrameStrata then CPF:SetFrameStrata("FULLSCREEN_DIALOG") end
    if CPF.Raise then CPF:Raise() end
end

local function FillRow(row, def)
    local db = NM.db
    HideControls(row)
    row.label:SetText(def.label or "")
    row.label:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
    if def.kind ~= "toggle" then row.toggle.def = nil end

    if def.kind == "toggle" then
        local on = db[def.key] and true or false
        if def.invert then on = not on end
        local t = row.toggle
        t:Show()
        SetToggle(t, on, t.def == def)
        t.def = def
        t:SetScript("OnClick", function()
            db[def.key] = not db[def.key]
            ApplyChange()
        end)

    elseif def.kind == "choice" then
        local b = row.button
        b:Show()
        b.text:SetText(ValueText(def, db[def.key]))
        b:SetScript("OnClick", function(_, mouse)
            local values, idx = def.values, 1
            for i, v in ipairs(values) do if v == db[def.key] then idx = i end end
            idx = (mouse == "RightButton") and ((idx - 2) % #values + 1) or (idx % #values + 1)
            db[def.key] = values[idx]
            ApplyChange()
        end)

    elseif def.kind == "step" then
        row.minus:Show(); row.plus:Show(); row.value:Show()
        row.value:SetText(def.format and def.format(db[def.key]) or tostring(db[def.key]))
        local function step(dir)
            local v = (db[def.key] or def.min) + dir * def.step
            db[def.key] = math.max(def.min, math.min(def.max, math.floor(v / def.step + 0.5) * def.step))
            ApplyChange()
        end
        row.minus:SetScript("OnClick", function() step(-1) end)
        row.plus:SetScript("OnClick", function() step(1) end)

    elseif def.kind == "color" then
        local b = row.button
        b:Show()
        b.text:SetText("")
        local c = db[def.key]
        if type(c) ~= "table" then c = NM.DEFAULTS[def.key] end
        row.swatch:SetColorTexture(c[1], c[2], c[3], 1)
        row.swatch:Show()
        b:SetScript("OnClick", function(_, mouse)
            if mouse == "RightButton" then
                local d = NM.DEFAULTS[def.key]
                db[def.key] = { d[1], d[2], d[3] }
                ApplyChange()
            else
                PickColor(def.key)
            end
        end)

    elseif def.kind == "button" then
        local b = row.button
        b:Show()
        b.text:SetText(def.text or "")
        b:SetScript("OnClick", function() def.run(); Options:Refresh() end)

    elseif def.kind == "bind" then
        local key = select(def.index, NM.Secure:Keys())
        row.label:SetText((T("Hilfstaste %d", "Utility key %d")):format(def.index))
        local b = row.button
        b:Show()
        if capturing == def.index then
            b.text:SetText(T("Taste drücken ... (Esc)", "Press a key ... (Esc)"))
        else
            b.text:SetText(key and NM.ShortKey(key) or T("festlegen", "set"))
        end
        b:SetScript("OnClick", function() StartCapture(def.index) end)

    elseif def.kind == "info" then
        if def.slot or def.wide then
            -- zweispaltig: links der Kopf (Taste und Kategorie, oder ein Stichwort), rechts der Inhalt
            if def.slot then
                local line = NM.Secure:LayoutLines()[def.slot]
                row.label:SetText(line and line.head or "")
                row.info:SetText(line and line.body or "")
            else
                row.info:SetText(def.text and def.text() or "")
            end
            row.label:ClearAllPoints()
            row.label:SetPoint("LEFT", 12, 0)
            row.label:SetWidth(170)
            row.info:Show()
            row.info:ClearAllPoints()
            row.info:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
            row.info:SetPoint("RIGHT", -12, 0)
            row.info:SetJustifyH("LEFT")
        else
            row.info:Show()
            row.info:ClearAllPoints()
            row.info:SetPoint("RIGHT", -12, 0)
            row.info:SetJustifyH("RIGHT")
            row.info:SetText(def.text and def.text() or "")
        end
    end
end

------------------------------------------------------------------------------
-- Fenster
------------------------------------------------------------------------------

local function PlayOnce(group)
    if not group or NM.db.animations == false then return end
    if group:IsPlaying() then group:Stop() end
    group:Play()
end

local function ShowPage(id)
    if id ~= currentPage and content then PlayOnce(content.fade) end
    currentPage = id
    Options:Refresh()
end

local function Build()
    BuildPages()
    local f = CreateFrame("Frame", "NextMoveOptions", UIParent)
    frame = f
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")    -- auch ueber den Spieleinstellungen
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnHide", StopCapture)
    f:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "NextMoveOptions")

    Tex(f, "BACKGROUND", C_BG):SetAllPoints()
    -- weiches Einblenden beim Oeffnen
    f.fadeIn = f:CreateAnimationGroup()
    local fa = f.fadeIn:CreateAnimation("Alpha")
    fa:SetFromAlpha(0); fa:SetToAlpha(1); fa:SetDuration(0.16)
    if fa.SetSmoothing then fa:SetSmoothing("OUT") end
    local sa = f.fadeIn:CreateAnimation("Scale")
    local setFrom, setTo = sa.SetScaleFrom or sa.SetFromScale, sa.SetScaleTo or sa.SetToScale
    if setFrom then setFrom(sa, 0.97, 0.97) end
    if setTo then setTo(sa, 1, 1) end
    if sa.SetOrigin then sa:SetOrigin("CENTER", 0, 0) end
    sa:SetDuration(0.16)
    if sa.SetSmoothing then sa:SetSmoothing("OUT") end
    f:SetScript("OnShow", function(s) PlayOnce(s.fadeIn) end)
    -- duenner Rahmen
    for _, edge in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
                            { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
        local t = Tex(f, "BORDER", C_LINE)
        t:SetPoint(edge[1]); t:SetPoint(edge[2])
        if edge[3] then t:SetHeight(1) else t:SetWidth(1) end
    end

    -- Seitenleiste
    local side = CreateFrame("Frame", nil, f)
    side:SetPoint("TOPLEFT"); side:SetPoint("BOTTOMLEFT")
    side:SetWidth(SIDEBAR)
    Tex(side, "BACKGROUND", C_SIDE):SetAllPoints()
    -- Akzentstreifen ueber die ganze Breite
    stripe = Tex(f, "ARTWORK", C_ACCENT)
    stripe:SetPoint("TOPLEFT"); stripe:SetPoint("TOPRIGHT")
    stripe:SetHeight(2)
    brand = Label(side, "GameFontNormalLarge", C_ACCENT)
    brand:SetPoint("TOPLEFT", 18, -20)
    brand:SetText("neXtMove")
    local version = Label(side, "GameFontDisableSmall", C_DIM)
    version:SetPoint("TOPLEFT", brand, "BOTTOMLEFT", 0, -4)
    version:SetText("Version " .. NM.version)

    local foot = Label(side, "GameFontDisableSmall", C_DIM)
    foot:SetPoint("BOTTOMLEFT", 18, 16)
    foot:SetPoint("RIGHT", side, "RIGHT", -12, 0)
    foot:SetWordWrap(true)
    foot:SetText(T("Gilt je Charakter und wirkt sofort.", "Per character, applied instantly."))

    for i, page in ipairs(pages) do
        local b = CreateFrame("Button", nil, side)
        b:SetSize(SIDEBAR, 30)
        b:SetPoint("TOPLEFT", 0, -78 - (i - 1) * 32)
        b.bg = Tex(b, "BACKGROUND", { 1, 1, 1, 0 })
        b.bg:SetAllPoints()
        b.bar = Tex(b, "ARTWORK", C_ACCENT)
        b.bar:SetPoint("TOPLEFT"); b.bar:SetPoint("BOTTOMLEFT")
        b.bar:SetWidth(3)
        b.text = Label(b, "GameFontHighlight", C_DIM)
        b.text:SetPoint("LEFT", 18, 0)
        b.text:SetText(page.name)
        b.page = page.id
        b:SetScript("OnClick", function() ShowPage(page.id) end)
        b:SetScript("OnEnter", function(s) if currentPage ~= s.page then s.bg:SetColorTexture(1, 1, 1, 0.05) end end)
        b:SetScript("OnLeave", function(s) if currentPage ~= s.page then s.bg:SetColorTexture(1, 1, 1, 0) end end)
        navButtons[i] = b
    end

    -- Kopf des Inhalts
    pageTitle = Label(f, "GameFontNormalHuge", C_TEXT)
    pageTitle:SetPoint("TOPLEFT", SIDEBAR + PAD, -22)
    pageHint = Label(f, "GameFontHighlightSmall", C_DIM)
    pageHint:SetPoint("TOPLEFT", pageTitle, "BOTTOMLEFT", 0, -6)
    pageHint:SetPoint("RIGHT", f, "RIGHT", -PAD - 30, 0)
    local rule = Tex(f, "ARTWORK", C_LINE)
    rule:SetPoint("TOPLEFT", SIDEBAR + PAD, -72); rule:SetPoint("RIGHT", -PAD, 0)
    rule:SetHeight(1)

    local close = FlatButton(f, 26, 22)
    close:SetPoint("TOPRIGHT", -12, -12)
    close.text:SetText("x")
    close:SetScript("OnClick", function() f:Hide() end)

    content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", SIDEBAR + PAD, -84)
    content:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    for i = 1, MAX_ROWS do rows[i] = MakeRow(i) end
    content.fade = content:CreateAnimationGroup()
    local ca = content.fade:CreateAnimation("Alpha")
    ca:SetFromAlpha(0); ca:SetToAlpha(1); ca:SetDuration(0.14)
    if ca.SetSmoothing then ca:SetSmoothing("OUT") end

    currentPage = pages[1].id
    f:Hide()
end

function Options:Refresh()
    if not frame then return end
    -- die Akzentfarbe der Anzeige gilt auch hier
    if NM.UI and NM.UI.Accent then
        C_ACCENT[1], C_ACCENT[2], C_ACCENT[3] = NM.UI.Accent()
        brand:SetTextColor(C_ACCENT[1], C_ACCENT[2], C_ACCENT[3])
        stripe:SetColorTexture(C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1)
    end
    local page
    for i, p in ipairs(pages) do
        local b = navButtons[i]
        local active = (p.id == currentPage)
        if active then page = p end
        b.bar:SetColorTexture(C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1)
        b.bar:SetShown(active)
        b.bg:SetColorTexture(1, 1, 1, active and 0.07 or 0)
        local c = active and C_TEXT or C_DIM
        b.text:SetTextColor(c[1], c[2], c[3])
    end
    page = page or pages[1]
    pageTitle:SetText(page.name)
    pageHint:SetText(page.hint or "")
    for i = 1, MAX_ROWS do
        local def = page.rows[i]
        if def then
            rows[i]:Show()
            FillRow(rows[i], def)
        else
            rows[i]:Hide()
        end
    end
end

------------------------------------------------------------------------------
-- Eintrag in den Spieleinstellungen (Optionen > AddOns > neXtMove) und im Addon-Menue der
-- Minikarte. Die Seite dort zeigt einen Knopf, der dieses Fenster oeffnet - so gibt es nur
-- EIN Einstellungsfenster, erreichbar ueber /nxm, die Spieleinstellungen und das Menue.
------------------------------------------------------------------------------

function Options:Register()
    if self.category or not (type(Settings) == "table" and type(Settings.RegisterCanvasLayoutCategory) == "function"
            and type(Settings.RegisterAddOnCategory) == "function") then
        return
    end
    local panel = CreateFrame("Frame")
    panel.name = "neXtMove"
    local title = Label(panel, "GameFontNormalHuge", C_TEXT)
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("neXtMove")
    local sub = Label(panel, "GameFontHighlight", C_DIM)
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    sub:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    sub:SetWordWrap(true)
    sub:SetText(T("Rotationshilfe: zeigt die beste und die zweitbeste nächste Wahl mit ihrer Folge und der Taste. Die Einstellungen haben ein eigenes Fenster.",
                  "Rotation helper: shows the best and second-best next move with its follow-up and key. The settings have a window of their own."))
    local open = FlatButton(panel, 260, 28)
    open:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -16)
    open.text:SetText(T("neXtMove-Einstellungen öffnen", "Open the neXtMove settings"))
    open:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel.IsShown and SettingsPanel:IsShown() then pcall(HideUIPanel, SettingsPanel) end
        Options:Open("general")
    end)
    local hint = Label(panel, "GameFontDisableSmall", C_DIM)
    hint:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -12)
    hint:SetText(T("Auch über /nxm und das Addon-Menü an der Minikarte.", "Also via /nxm and the addon menu at the minimap."))

    local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, "neXtMove")
    if ok and category then
        pcall(Settings.RegisterAddOnCategory, category)
        self.category = category
    end
end

-- Addon-Menue der Minikarte (Namen stehen in der .toc)
function _G.NextMove_OnAddonCompartmentClick()
    if NM.active then NM.Options:Toggle() end
end

function _G.NextMove_OnAddonCompartmentEnter(_, button)
    if not (GameTooltip and button) then return end
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:AddLine("neXtMove " .. tostring(NM.version), C_ACCENT[1], C_ACCENT[2], C_ACCENT[3])
    GameTooltip:AddLine(T("Klick: Einstellungen", "Click: settings"), 1, 1, 1)
    GameTooltip:Show()
end

function _G.NextMove_OnAddonCompartmentLeave()
    if GameTooltip then GameTooltip:Hide() end
end

-- Oeffnet das Fenster auf einem Bereich (general, look, display, alerts, class, keys, tools)
function Options:Open(id)
    if not frame then self:Toggle() end
    if not frame then return end
    for _, p in ipairs(pages) do
        if p.id == id then currentPage = id end
    end
    self:Refresh()
    frame:Show()
end

function Options:Toggle()
    if not frame then
        local ok, err = pcall(Build)
        if not ok then
            if frame then frame:Hide() end
            frame = nil
            Print(T("Das Fenster ließ sich nicht bauen: ", "The window could not be built: ") .. tostring(err))
            Print(T("Die Befehle gehen weiter: /nxm help", "The commands still work: /nxm help"))
            return
        end
    end
    if frame:IsShown() then frame:Hide() else self:Refresh(); frame:Show() end
end
