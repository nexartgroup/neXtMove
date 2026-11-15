--[[---------------------------------------------------------------------------
    Probe.lua - Diagnose: was der Client herausgibt, und was das Addon empfohlen hat

    Probe      welche Werte lesbar sind
                 /nxm probe     sofort, Ergebnis im Chat
                 automatisch    acht Sekunden nach Beginn der ersten Kaempfe einer Sitzung
                                und einmal ausserhalb des Kampfes
               plain = lesbar    SECRET = geheim    nil = kein Wert    ERROR = Aufruf schlug fehl
    Protokoll  eine Zeile, wenn sich Move 1 aendert, und eine je gewirktem Zauber
                 Zeit Lage cpN P~N Gegner/in Reichweite/an dir dGefahr ttdN | Move 1[Taste] > Folge // Move 2 > Folge !Warnung
                 an einem Move: =N berechneter Wert je Sekunde, * laeuft schon (Zauberstab)
                 Lage: C Kampf, S verstohlen, ! Warnung niedrige Gesundheit, M in Bewegung,
                 G5th Gruppe (Zahl, t Tank, T Tank vermutet, h Heiler), ^ Bedrohung hoch,
                 >KLASSE wen das Ziel angreift
    Alles liegt beim Konto in NextMoveDB (probe, log, kills, character je Charakter), damit
    sich die Logik nach dem Spielen gezielt nachschaerfen laesst.
-----------------------------------------------------------------------------]]

local _, NM = ...
local T, Print = NM.T, NM.Print
local SP = NM.SPELLS
local issecret = _G.issecretvalue

local Probe = {}
NM.Probe = Probe

local function kind(v)
    if issecret and issecret(v) then return "SECRET" end
    if v == nil then return "nil" end
    return "plain"
end

local function first(fn, ...)
    if type(fn) ~= "function" then return "n/a" end
    local ok, v = pcall(fn, ...)
    return ok and kind(v) or "ERROR"
end

-- Feld einer zurueckgegebenen Tabelle
local function field(name, fn, ...)
    if type(fn) ~= "function" then return "n/a" end
    local ok, v = pcall(fn, ...)
    if not ok then return "ERROR" end
    if issecret and issecret(v) then return "SECRET(table)" end
    if type(v) ~= "table" then return "nil" end
    local ok2, res = pcall(function() return kind(v[name]) end)
    return ok2 and res or "ERROR"
end

-- ein gelernter Zauber der Klasse zum Abfragen
local function ProbeSpell()
    local list = NM.class.rangeSpell
    if type(list) == "table" then
        for _, k in ipairs(list) do
            if SP[k] and SP[k].id then return SP[k].id end
        end
    end
    for _, d in pairs(SP) do if d.id then return d.id end end
end

function Probe:Collect()
    local C, S = NM.class, NM.State
    local spell = ProbeSpell() or 0
    local buff = C.probeBuff and SP[C.probeBuff] and SP[C.probeBuff].name or "?"
    local CS, CU, SEC = C_Spell or {}, C_UnitAuras or {}, C_Secrets or {}
    local out = {}
    local function add(label, value) out[#out + 1] = label .. "=" .. value end
    add("class", NM.classToken or "?")
    add("power", first(UnitPower, "player", C.power))
    add("powerMax", first(UnitPowerMax, "player", C.power))
    if C.combo then add("combo", first(GetComboPoints or UnitPower, "player", GetComboPoints and "target" or 4)) end
    add("health", first(UnitHealth, "player"))
    add("healthMax", first(UnitHealthMax, "player"))
    add("targetHealth", first(UnitHealth, "target"))
    add("petHealth", first(UnitHealth, "pet"))
    add("speed", first(GetUnitSpeed, "player"))
    add("cd.start", field("startTime", CS.GetSpellCooldown, spell))
    add("cd.isActive", field("isActive", CS.GetSpellCooldown, spell))
    add("cd.isOnGCD", field("isOnGCD", CS.GetSpellCooldown, spell))
    add("usable", first(CS.IsSpellUsable, spell))
    do
        local ok, _, noPower = pcall(CS.IsSpellUsable or error, spell)
        add("usable.noPower", ok and kind(noPower) or "ERROR")
    end
    add("range", first(CS.IsSpellInRange, spell, "target"))
    add("cost", first(CS.GetSpellPowerCost, spell))
    add("castTime", field("castTime", CS.GetSpellInfo, spell))
    do
        local ok, a = pcall(CU.GetAuraDataBySpellName or error, "player", buff, "HELPFUL")
        add("buff", ok and ((issecret and issecret(a)) and "SECRET" or type(a)) or "ERROR")
        local m = C.probeBuff and S.model[C.probeBuff]
        add("buffModel", (m and m > GetTime()) and "active" or "none")
    end
    add("casting", first(UnitCastingInfo, "target"))
    add("ownCast", first(UnitCastingInfo, "player"))
    add("threat", first(UnitThreatSituation, "player", "target"))
    add("targetOnMe", first(UnitIsUnit, "targettarget", "player"))
    add("creatureType", first(UnitCreatureType, "target"))
    add("guid", first(UnitGUID, "target"))
    add("plate1", first(UnitExists, "nameplate1"))
    add("aurasSecret", SEC.ShouldAurasBeSecret and tostring(NM.Get(SEC.ShouldAurasBeSecret)) or "n/a")
    add("cooldownsSecret", SEC.ShouldCooldownsBeSecret and tostring(NM.Get(SEC.ShouldCooldownsBeSecret)) or "n/a")
    -- Ereignisse: klein = lesbar, gross = geheim (u Einheit, s Zauber-ID, a Art, n Betrag)
    add("castEvent", S.castEvent or "none")
    add("castsSeen", tostring(S.castsSeen or 0))
    add("combatEvent", S.combatEvent or "none")
    add("powerEst", tostring(math.floor(S.est.e or -1)))
    -- Werte fuer das Schadensmodell
    add("unitDamage", first(UnitDamage, "player"))
    add("rangedDamage", first(UnitRangedDamage, "player"))
    add("attackSpeed", first(UnitAttackSpeed, "player"))
    add("critChance", first(GetCritChance))
    add("spellPower", first(GetSpellBonusDamage, 3))
    add("description", first(CS.GetSpellDescription, spell))
    add("maxRange", field("maxRange", CS.GetSpellInfo, spell))
    add("swings", tostring(NM.Model and NM.Model.swings or 0))
    add("lowHealthFrame", (LowHealthFrame and LowHealthFrame.IsShown) and first(LowHealthFrame.IsShown, LowHealthFrame) or "n/a")
    -- in der Gruppe: was der Client ueber Mitspieler herausgibt
    if NM.Party then NM.Party:Probe(add) end
    return out
end

function Probe:Run(say)
    local db = NM.adb
    local combat = NM.Plain(UnitAffectingCombat("player")) and true or false
    local lines = self:Collect()
    db.probe = db.probe or {}
    table.insert(db.probe, 1, {
        time = date and date("%Y-%m-%d %H:%M:%S") or "",
        version = NM.version,
        combat = combat,
        instance = NM.Get(IsInInstance) and true or false,
        values = table.concat(lines, " "),
    })
    while #db.probe > 14 do table.remove(db.probe) end
    if say then
        Print(T("Probe ", "Probe ") .. (combat and T("(im Kampf)", "(in combat)") or T("(außerhalb des Kampfes)", "(out of combat)")))
        local row = {}
        for i, l in ipairs(lines) do
            row[#row + 1] = l
            if #row == 4 or i == #lines then
                DEFAULT_CHAT_FRAME:AddMessage("  " .. table.concat(row, "  "))
                wipe(row)
            end
        end
    end
end

------------------------------------------------------------------------------
-- Protokoll der Empfehlungen (die letzten 500 Zeilen)
------------------------------------------------------------------------------

local lastSig

function Probe:Log(line)
    local db = NM.adb
    if not db then return end
    db.log = db.log or {}
    local log = db.log
    log[#log + 1] = (date and date("%H:%M:%S ") or "") .. line
    if #log > 500 then
        for _ = 1, #log - 500 do table.remove(log, 1) end
    end
end

local function describe(S, m)
    if not m then return "-" end
    local key = NM.Secure:KeyFor(S, m)
    return m.key .. (m.running and "*" or "") .. ((m.wait and m.wait > 0.2) and ("~%.1f"):format(m.wait) or "")
        .. (m.value and ("=" .. NM.Model.Num(m.value)) or "") .. "[" .. (key or "?") .. "]"
end

local function strandText(strand)
    if not strand then return "-" end
    local text = describe(strand.state, strand.move)
    if strand.follow then text = text .. " > " .. describe(strand.follow.state, strand.follow.move) end
    return text
end

function Probe:Trace(S, strands, alert)
    local s1, s2 = strands[1], strands[2]
    if not (S.inCombat or S.stealthed or s1) then lastSig = nil; return end
    local sig = (s1 and s1.move.key or "-") .. "/" .. (s2 and s2.move.key or "-") .. (S.inCombat and "C" or "")
        .. (alert and alert.key or "")
    if sig == lastSig then return end
    lastSig = sig
    local en = S.enemies
    local flags = (S.inCombat and "C" or "") .. (S.stealthed and "S" or "") .. (S.lowHealth and "!" or "") .. (S.moving and "M" or "")
    -- Gruppe: G5th = fuenf Leute, Tank, Heiler; ^ = eigene Bedrohung hoch; >KLASSE = wen das Ziel angreift
    local P = S.party
    if P and P.n and P.n > 0 then
        flags = flags .. " " .. NM.Party.Tag(P) .. (P.threatHigh and "^" or "") .. (P.aggro and (">" .. tostring(P.aggro.class or "?")) or "")
    end
    local power = S.power and (" P~" .. math.floor(S.power)) or ""
    local cp = NM.class.combo and (" cp" .. S.cp) or ""
    local casting = S.casting and (" cast:" .. S.casting.key) or ""
    self:Log(("%s%s%s %d/%d/%d d%d ttd%s%s | %s // %s%s"):format(flags ~= "" and flags or ".", cp, power,
        en.n, en.melee, en.onMe, S.danger, S.ttd and tostring(math.floor(S.ttd)) or "?", casting,
        strandText(s1), strandText(s2), alert and (" !" .. alert.key .. (alert.demoted and "(demoted)" or "")) or ""))
end

local autoRuns = 0

-- neu in einer Gruppe: noch einmal messen (gleich, und in den naechsten Kaempfen)
function Probe:Rearm()
    autoRuns = 0
    C_Timer.After(5, function()
        if not NM.Plain(UnitAffectingCombat("player")) then NM.Safe(Probe.Run, Probe, false) end
    end)
end

function Probe:Init()
    -- acht Sekunden nach Kampfbeginn: dann sind schon Zauber gewirkt und Schaden gefallen
    NM.On("PLAYER_REGEN_DISABLED", function()
        if autoRuns >= 4 then return end
        C_Timer.After(8, function()
            if autoRuns < 4 and NM.Plain(UnitAffectingCombat("player")) then
                autoRuns = autoRuns + 1
                NM.Safe(Probe.Run, Probe, false)
            end
        end)
    end)
    -- einmal ausserhalb des Kampfes zum Vergleich
    C_Timer.After(12, function()
        if not NM.Plain(UnitAffectingCombat("player")) then NM.Safe(Probe.Run, Probe, false) end
    end)
    -- beim Ausloggen festhalten, was erkannt wurde (je Charakter)
    NM.On("PLAYER_LOGOUT", function()
        local db, S = NM.adb, NM.State
        if not (db and NM.active) then return end
        local known = {}
        for key, d in pairs(SP) do if d.id and not d.foreign and not d.always then known[#known + 1] = key end end
        table.sort(known)
        local k1, k2 = NM.Secure:Keys()
        db.characters = db.characters or {}
        local name = (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
        db.characters[name] = {
            class = NM.classToken, level = NM.Get(UnitLevel, "player"), spec = S.spec,
            points = table.concat(S.points, "/"), specKnown = S.specKnown and true or false,
            known = table.concat(known, " "),
            mhDagger = S.gear.mhDagger and true or false, ohWeapon = S.gear.ohWeapon and true or false,
            wand = S.gear.wand and true or false, key1 = k1 or "-", key2 = k2 or "-",
            version = NM.version, time = date and date("%Y-%m-%d %H:%M") or "",
        }
        -- Schadensmodell: Werte, Zaubertexte und was daraus gelesen wurde (zum Nachschaerfen)
        if NM.Model then
            db.model = db.model or {}
            db.model[name] = NM.Model:Dump()
        end
    end)
end
