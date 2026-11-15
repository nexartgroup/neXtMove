--[[---------------------------------------------------------------------------
    Core.lua - Grundgeruest von neXtMove

    * sichere Lesehelfer: der Forever-Client (12.x-Engine) gibt manche Werte als "Secrets"
      heraus. Mit einem Secret darf man nicht rechnen und nicht vergleichen (auch nicht mit
      nil), sonst gibt es einen Fehler. Jeder Wert aus dem Spiel geht deshalb durch
      NM.Plain / NM.Get; ein Secret liest sich wie nil (siehe State.lua, was gemessen wurde).
    * Klassen: jede Klasse meldet sich mit NM.RegisterClass an (Ordner Classes). Geladen
      wird nur die Klasse des Charakters; fehlt sie, bleibt das Addon still.
    * Einstellungen fuer alle Charaktere (NextMoveDB.settings, vom Nutzer so gewuenscht;
      bis 0.12.0 je Charakter); Proben, Protokoll und gelernte Kampfdauern fuer das Konto
      (NextMoveDB); gemessene Werte des Charakters (NextMoveCharDB: Waffen, Abklingzeiten)
    * der Takt: Zustand lesen -> Moves waehlen -> Hilfstasten anpassen -> anzeigen
-----------------------------------------------------------------------------]]

local ADDON, NM = ...
_G.NextMove = NM

local pcall, xpcall, type, tostring, tonumber, pairs = pcall, xpcall, type, tostring, tonumber, pairs
local issecret, canaccess = _G.issecretvalue, _G.canaccessvalue

NM.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "?"
NM.SPELLS = {}      -- Zauber der Klasse des Charakters (fuellt die Klassendatei)
NM.classes = {}

local isDE = (GetLocale and GetLocale() == "deDE")
function NM.T(de, en) return isDE and de or en end
local T = NM.T

------------------------------------------------------------------------------
-- Sichere Lesehelfer
------------------------------------------------------------------------------

-- Der Wert selbst, oder nil, wenn der Client ihn nicht lesbar herausgibt
function NM.Plain(v)
    if issecret and issecret(v) then return nil end
    if canaccess and v ~= nil then
        local ok, acc = pcall(canaccess, v)
        if ok and acc == false then return nil end
    end
    return v
end
local Plain = NM.Plain

local function results(ok, ...)
    if ok then return ... end
end

-- Ruft fn(...) geschuetzt auf; alle Rueckgaben (ungeprueft) oder nichts bei einem Fehler
function NM.Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    return results(pcall(fn, ...))
end
local Call = NM.Call

-- Erste Rueckgabe von fn(...), lesbar oder nil
function NM.Get(fn, ...)
    return Plain((Call(fn, ...)))
end

function NM.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99neXtMove|r: " .. tostring(msg))
end
local Print = NM.Print

------------------------------------------------------------------------------
-- Fehlerprotokoll: ein Fehler stoppt nie den Takt und wird nur einmal gemeldet
------------------------------------------------------------------------------

local errorSaid = false
local function onError(err)
    local db = NextMoveDB
    local line = tostring(err)
    if type(db) == "table" then
        db.errors = db.errors or {}
        if db.errors[1] ~= line then table.insert(db.errors, 1, line) end
        while #db.errors > 20 do table.remove(db.errors) end
    end
    if not errorSaid then
        errorSaid = true
        Print(T("Ein Fehler wurde abgefangen. /nxm errors zeigt ihn.",
                "An error was caught. /nxm errors shows it."))
    end
end

function NM.Safe(fn, ...)
    return xpcall(fn, onError, ...)
end

------------------------------------------------------------------------------
-- Ereignisse
------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local handlers = {}

function NM.On(event, fn)
    if not handlers[event] then
        -- Nicht jedes Ereignis gibt es in jedem Client: ein unbekanntes wird uebersprungen
        if not pcall(frame.RegisterEvent, frame, event) then return end
        handlers[event] = {}
    end
    table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
    local hs = handlers[event]
    if not hs then return end
    for i = 1, #hs do NM.Safe(hs[i], ...) end
end)

------------------------------------------------------------------------------
-- Klassen
------------------------------------------------------------------------------

-- def: siehe Classes/Rogue.lua fuer die Felder. Die Klassendatei ruft das beim Laden auf;
-- nur die Klasse des Charakters fuellt NM.SPELLS.
function NM.RegisterClass(token, def)
    NM.classes[token] = def
    local _, mine = UnitClass("player")
    if mine == token then
        NM.class = def
        for key, d in pairs(def.spells) do NM.SPELLS[key] = d end
        -- Volksfaehigkeiten gelten fuer jede Klasse (die Klasse darf einen Schluessel selbst belegen)
        for key, d in pairs(NM.RACIALS or {}) do
            if not NM.SPELLS[key] then NM.SPELLS[key] = d end
        end
    end
end

------------------------------------------------------------------------------
-- Einstellungen
------------------------------------------------------------------------------

local DEFAULTS = {
    enabled = true,
    locked = true,
    scale = 1,
    point = { "CENTER", 0, -170 },
    showReason = false,     -- Begruendung der Moves als Text (die Symbole sagen es schon)
    showStatus = true,      -- Statuszeile (Gegner, Restzeit, Gefahr)
    showCooldowns = true,   -- Reihe der grossen Abklingzeiten
    showCheck = true,       -- Vor-Kampf-Check
    tooltips = true,        -- Tooltip beim Ueberfahren eines Symbols
    onlyCombat = false,     -- Moves nur im Kampf zeigen
    glow = true,            -- Knopf von Move 1 in der Aktionsleiste hervorheben
    alerts = true,          -- Warnsymbol fuer Reaktionen (Unterbrechen, Schutz, Heilung)
    sound = true,           -- Ton zur Warnung
    alertSound = "warning", -- warning | ready | tell
    useRacials = true,      -- Volksfaehigkeiten vorschlagen
    aoeMode = "auto",       -- auto | single | aoe
    groupMode = "auto",     -- auto | solo | group
    lowHealth = 45,
    critHealth = 25,
    usePotions = true,
    useTrinkets = true,
    consumables = "always", -- Elixiere, Bufffood, Rollen, Waffensteine: always | hard | off
    useRest = true,         -- ausserhalb des Kampfes Essen und Trinken vorschlagen (geschaetzt)
    useModel = true,        -- Rotation nach berechnetem Schaden ordnen (Model.lua)
    playStyle = "auto",     -- Mana-Einsatz: auto | fast | thrifty
    clickIcons = true,      -- Symbole von Move 1 und 2 ausserhalb des Kampfes anklickbar
    animations = true,      -- Bewegung in Anzeige und Einstellungsfenster
    flow = true,            -- die Vorschau steigt zum Move auf, wenn sie an der Reihe ist
    shape = "round",        -- Form der Symbole: round | square
    accent = "class",       -- Akzentfarbe: class | green | blue | gold | white
    panel = false,          -- dunkle Flaeche hinter der Anzeige
    useParty = true,        -- Vorschlaege an die Zusammensetzung der Gruppe anpassen (Party.lua)
    moveDelay = 1.5,        -- so lange am Stueck laufen, bis Bewegung die Vorschlaege aendert (Sekunden oder "never")
    -- Randfarben je Art des Moves (frei waehlbar)
    colHeal = { 0.30, 0.85, 0.40 },     -- Essen, Verband, Heiltrank, Gesundheitsstein
    colMana = { 0.30, 0.60, 1.00 },     -- Trinken, Manatrank, Manastein
    colCraft = { 1.00, 0.82, 0.10 },    -- Herstellen (Wasser, Brot, Steine)
    colBuff = { 1.00, 1.00, 1.00 },     -- Buffzauber, Elixiere, Bufffood, Rollen, Waffensteine
}
NM.DEFAULTS = DEFAULTS

local function copyDefault(v)
    return (type(v) == "table") and { v[1], v[2], v[3] } or v
end

local function initDB()
    if type(NextMoveDB) ~= "table" then NextMoveDB = {} end
    if type(NextMoveCharDB) ~= "table" then NextMoveCharDB = {} end
    local adb, cdb = NextMoveDB, NextMoveCharDB
    -- Einstellungen gelten fuer alle Charaktere
    if type(adb.settings) ~= "table" then adb.settings = {} end
    local db = adb.settings
    local classDefaults = NM.class and NM.class.defaults or {}
    for _, source in ipairs({ DEFAULTS, classDefaults }) do
        for k, v in pairs(source) do
            if db[k] == nil then
                -- Umzug: bis 0.12.0 lagen die Einstellungen beim Charakter. Was der erste
                -- Charakter nach dem Update eingestellt hatte, gilt nun fuer alle.
                if cdb[k] ~= nil and type(cdb[k]) == type(v) then db[k] = copyDefault(cdb[k]) else db[k] = copyDefault(v) end
            end
        end
    end
    if db.settingsVersion == nil then db.settingsVersion = cdb.settingsVersion end
    -- Stand der Einstellungen: aeltere bekommen geaenderte Vorgaben einmalig nachgezogen
    if (db.settingsVersion or 1) < 2 then
        db.showReason = false       -- 0.5.3: die Begruendung als Text ist von Haus aus aus
        db.settingsVersion = 2
    end
    NM.db, NM.adb, NM.cdb = db, adb, cdb
end

function NM.ResetSettings()
    local db = NM.db
    for _, source in ipairs({ DEFAULTS, NM.class and NM.class.defaults or {} }) do
        for k, v in pairs(source) do db[k] = copyDefault(v) end
    end
end

------------------------------------------------------------------------------
-- Takt
------------------------------------------------------------------------------

local acc = 0
local function tick()
    local S = NM.State:Snapshot()
    local strands, alert = NM.Engine:Pick(S)
    NM.Secure:Update(S)
    NM.UI:Show(S, strands, alert)
    if NM.Probe then NM.Probe:Trace(S, strands, alert) end
end
NM.Tick = tick

local function onUpdate(_, elapsed)
    acc = acc + elapsed
    -- im Kampf und mit Ziel zehnmal je Sekunde, sonst gemaechlich
    local interval = NM.State.busy and 0.1 or 0.4
    if acc < interval then return end
    acc = 0
    if NM.db.enabled then NM.Safe(tick) end
end

------------------------------------------------------------------------------
-- Start
------------------------------------------------------------------------------

NM.On("ADDON_LOADED", function(name)
    if name == ADDON then initDB() end
end)

NM.On("PLAYER_LOGIN", function()
    if not NM.db then initDB() end
    if not NM.class then
        NM.inactive = true
        return
    end
    NM.active = true
    NM.State:Init()
    NM.Model:Init()
    NM.Party:Init()
    NM.Consumables:Init()
    NM.Secure:Init()
    NM.Click:Init()
    NM.Bars:Init()
    NM.UI:Init()
    NM.Safe(NM.Options.Register, NM.Options)
    if NM.Probe then NM.Probe:Init() end
    frame:SetScript("OnUpdate", onUpdate)
end)

------------------------------------------------------------------------------
-- Slash-Befehle (das Wichtigste steht auch im Fenster: /nxm)
------------------------------------------------------------------------------

local function help()
    Print(T("Befehle:", "Commands:"))
    local lines = {
        T("/nxm - Einstellungsfenster", "/nxm - settings window"),
        T("/nxm lock | unlock - Anzeige sperren oder verschieben", "/nxm lock | unlock - lock or move the display"),
        T("/nxm scale 0.6-2 - Größe", "/nxm scale 0.6-2 - size"),
        T("/nxm bind 1|2 TASTE - die zwei Hilfstasten festlegen (z. B. /nxm bind 1 F)", "/nxm bind 1|2 KEY - set the two utility keys (e.g. /nxm bind 1 F)"),
        T("/nxm keys - Belegung der Hilfstasten zeigen", "/nxm keys - show the utility key layout"),
        T("/nxm bars - Zauber ohne Taste auf freie Leistenplätze legen", "/nxm bars - put spells without a key onto free action bar slots"),
        T("/nxm aoe auto|single|aoe - Einzelziel oder Fläche", "/nxm aoe auto|single|aoe - single target or area"),
        T("/nxm group auto|solo|group - allein oder in der Gruppe", "/nxm group auto|solo|group - alone or in a group"),
        T("/nxm toggle <name> - eine Einstellung an/aus (Namen: /nxm toggle)", "/nxm toggle <name> - switch a setting (names: /nxm toggle)"),
        T("/nxm status - was erkannt wurde (Skillung, Waffen, Zauber, Gegenstände)", "/nxm status - what was detected (talents, weapons, spells, items)"),
        T("/nxm model - Schadensmodell: Waffenwerte und Wert jedes Zaubers", "/nxm model - damage model: weapon values and the value of each spell"),
        T("/nxm info <zauber> - Daten eines Zaubers (Zauberlink per Umschalt-Klick, Name, ID oder Schlüssel)", "/nxm info <spell> - data of a spell (shift-click link, name, ID or key)"),
        T("/nxm group - die erkannte Gruppe: Klassen, Rollen, Tank, Heiler", "/nxm group - the detected group: classes, roles, tank, healer"),
        T("/nxm probe - prüft, welche Werte der Client herausgibt", "/nxm probe - checks which values the client hands out"),
        T("/nxm log [n] - die letzten Zeilen des Protokolls der Empfehlungen", "/nxm log [n] - the last lines of the recommendation log"),
        T("/nxm on | off | reset | errors", "/nxm on | off | reset | errors"),
    }
    for _, l in ipairs(lines) do DEFAULT_CHAT_FRAME:AddMessage("  " .. l) end
end

-- Schalter, die sich mit /nxm toggle umlegen lassen: jede Einstellung mit Ja/Nein-Wert
local function toggleNames()
    local names = {}
    for k, v in pairs(NM.db) do
        if type(v) == "boolean" and k ~= "enabled" and k ~= "locked" then names[#names + 1] = k end
    end
    table.sort(names)
    return names
end

local MODES = {
    aoe = { key = "aoeMode", values = { auto = true, single = true, aoe = true } },
    group = { key = "groupMode", values = { auto = true, solo = true, group = true } },
}

SLASH_NEXTMOVE1, SLASH_NEXTMOVE2 = "/nextmove", "/nxm"
SlashCmdList.NEXTMOVE = function(input)
    local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    local db = NM.db
    if not db then return end
    if NM.inactive then
        Print(T("Für diese Klasse gibt es keine Logik.", "There is no logic for this class."))
        return
    end
    if cmd == "" or cmd == "options" or cmd == "config" then
        NM.Options:Toggle()
    elseif cmd == "help" or cmd == "?" then
        help()
    elseif cmd == "lock" or cmd == "unlock" then
        db.locked = (cmd == "lock")
        NM.UI:ApplyLayout()
        Print(db.locked and T("Anzeige gesperrt.", "Display locked.")
            or T("Anzeige entsperrt: mit der Maus ziehen, dann /nxm lock.", "Display unlocked: drag it, then /nxm lock."))
    elseif cmd == "scale" then
        local s = tonumber(rest)
        if s and s >= 0.6 and s <= 2 then db.scale = s; NM.UI:ApplyLayout() else help() end
    elseif cmd == "bind" then
        local idx, key = rest:match("^(%d)%s+(%S+)$")
        NM.Secure:Bind(tonumber(idx), key and key:upper())
    elseif MODES[cmd] and not (cmd == "group" and rest == "") then
        local mode, value = MODES[cmd], rest:lower()
        if mode.values[value] then
            db[mode.key] = value
            Print(cmd .. ": " .. value)
        else help() end
    elseif cmd == "toggle" then
        local want = rest:lower()
        for _, k in ipairs(toggleNames()) do
            if k:lower() == want then
                db[k] = not db[k]
                Print(k .. ": " .. (db[k] and T("an", "on") or T("aus", "off")))
                NM.UI:ApplyLayout()
                return
            end
        end
        Print(T("Schalter: ", "Switches: ") .. table.concat(toggleNames(), ", "))
    elseif cmd == "on" or cmd == "off" then
        db.enabled = (cmd == "on")
        NM.UI:ApplyLayout()
        Print(db.enabled and T("eingeschaltet", "enabled") or T("ausgeschaltet", "disabled"))
    elseif cmd == "reset" then
        NM.ResetSettings()
        NM.UI:ApplyLayout()
        Print(T("Einstellungen zurückgesetzt.", "Settings reset."))
    elseif cmd == "errors" then
        local e = NM.adb.errors
        if not e or #e == 0 then Print(T("Keine Fehler protokolliert.", "No errors logged.")); return end
        for i = 1, math.min(#e, 5) do DEFAULT_CHAT_FRAME:AddMessage("  " .. e[i]) end
    elseif cmd == "log" then
        local log = NM.adb.log or {}
        local n = math.min(#log, tonumber(rest) or 15)
        Print((T("Protokoll, die letzten %d Zeilen:", "Log, the last %d lines:")):format(n))
        for i = #log - n + 1, #log do DEFAULT_CHAT_FRAME:AddMessage("  " .. log[i]) end
    elseif cmd == "keys" then
        NM.Secure:PrintKeys()
    elseif cmd == "bars" then
        NM.Bars:Assist(rest:lower() == "go")
    elseif cmd == "status" then
        NM.State:PrintStatus()
    elseif cmd == "info" then
        NM.State:PrintSpellInfo(rest)
    elseif cmd == "group" and rest == "" then
        NM.Party:Print()
    elseif cmd == "model" then
        NM.Model:Print()
    elseif cmd == "probe" then
        if NM.Probe then NM.Probe:Run(true) end
    else
        help()
    end
end
