--[[---------------------------------------------------------------------------
    Party.lua - die Gruppe: wer dabei ist und was das fuer die Vorschlaege heisst

    Was der Client ueber Mitspieler herausgibt (Stand der Messung steht in der Probe):
      Klasse, Name, zugewiesene Rolle     lesbar erwartet (die Rolle kann geheim sein)
      wen das Ziel angreift               UnitIsUnit("targettarget", Mitspieler)
      Buffs der Mitspieler                nur ausserhalb des Kampfes
      Gesundheit, Kraft                   geheim - "wen heilen" geht deshalb nicht
      Debuffs anderer auf dem Ziel        im Kampf geheim
    Darum entscheiden die Regeln nach der ZUSAMMENSETZUNG ("ein Krieger ist dabei, also
    ueberlasse ich ihm das Ruestung zerreissen"), nicht nach dem, was die anderen gerade tun.

    State:Snapshot ruft Party:Snapshot(S) und bekommt S.party:
      n            Zahl der Mitspieler (ohne einen selbst); 0 = allein
      raid         Schlachtzug
      class[K]     Zahl der Mitspieler je Klasse (fehlende Klasse = 0)
      rolesKnown   in der Gruppe sind Rollen zugewiesen
      myRole       die eigene zugewiesene Rolle ("TANK", "HEALER", "DAMAGER") oder nil
      tank         ein anderer tankt: Rolle Tank, oder das Ziel hat in dieser Sitzung einen
                   Mitspieler angegriffen, dessen Klasse tanken kann
      tankLikely   tank, oder (ohne zugewiesene Rollen) eine Klasse dabei, die tanken kann
      healer       ein anderer heilt: Rolle Heiler, oder (ohne Rollen) eine Klasse, die es kann
      physical     Krieger, Schurken, Jaeger       casters   Magier, Hexenmeister, Priester
      hybrids      Druiden, Paladine, Schamanen    melee     Krieger, Schurken
      mana         Mitspieler mit Mana
      aggro        der Mitspieler, den das Ziel gerade angreift ({ unit, class, role, name })
      aggroSoft    ... und der ist kein Tank (Stoff, Heiler): fuer Tanks ein Grund zu spotten
      threatHigh   man selbst zieht gleich die Aufmerksamkeit, obwohl ein Tank da ist
    Allein, mit "Allein" als Gruppenmodus oder mit abgeschalteter Einstellung useParty ist
    S.party die leere Gruppe SOLO - Regeln koennen die Felder also immer lesen.

    Ausserdem:
      Party:Lacking(keys, want)   Namen der Mitspieler, denen ein Buff fehlt (vor dem Kampf)
      Party:Check(add, label, keys, want)   dasselbe als Zeile fuer den Vor-Kampf-Check
      Party:Probe(add)            was der Client in der Gruppe herausgibt (fuer Probe.lua)
      /nxm group                  die erkannte Gruppe im Chat
    Gewirkte Zauber der Mitspieler werden mitgezaehlt (NextMoveDB.groupCasts), falls der
    Client sie nennt: daran laesst sich spaeter ablesen, ob "der Krieger hat Ruestung
    zerreissen gewirkt" beobachtbar ist.
-----------------------------------------------------------------------------]]

local _, NM = ...
local Plain, Call, Get, T, Print = NM.Plain, NM.Call, NM.Get, NM.T, NM.Print
local SP = NM.SPELLS
local issecret = _G.issecretvalue

local Party = {}
NM.Party = Party

local CAN_TANK = { WARRIOR = true, DRUID = true, PALADIN = true }
local CAN_HEAL = { PRIEST = true, DRUID = true, PALADIN = true, SHAMAN = true }
local PHYSICAL = { WARRIOR = true, ROGUE = true, HUNTER = true }
local MELEE = { WARRIOR = true, ROGUE = true }
local CASTER = { MAGE = true, WARLOCK = true, PRIEST = true }
local HYBRID = { DRUID = true, PALADIN = true, SHAMAN = true }
local NO_MANA = { WARRIOR = true, ROGUE = true }
local TANK_MEMORY = 600         -- so lange gilt ein beobachteter Tank (s)
local ROSTER_AGE = 5            -- so oft wird die Gruppe neu gelesen (s)

local ZERO = { __index = function() return 0 end }
local SOLO = { n = 0, raid = false, class = setmetatable({}, ZERO), rolesKnown = false, tank = false, tankLikely = false,
               healer = false, physical = 0, casters = 0, hybrids = 0, melee = 0, mana = 0, members = {} }
Party.SOLO = SOLO

local roster = SOLO
local rosterAt = 0
local dirty = true
local tankSeen = {}             -- [Name] = Zeit, zu der das Ziel diesen Mitspieler angriff
local castKinds = { unit = "none", spell = "none", seen = 0 }

local RAID, PARTY = {}, {}
for i = 1, 40 do RAID[i] = "raid" .. i end
for i = 1, 4 do PARTY[i] = "party" .. i end

------------------------------------------------------------------------------
-- Gruppe lesen
------------------------------------------------------------------------------

local function ReadRoster(now)
    local raid = Get(IsInRaid) and true or false
    local inGroup = raid or (Get(IsInGroup) and true or false)
    if not inGroup then return SOLO end
    local count = Get(GetNumGroupMembers) or 0
    local tokens = raid and RAID or PARTY
    if not raid then count = count - 1 end
    local r = { n = 0, raid = raid, class = setmetatable({}, ZERO), rolesKnown = false, members = {},
                physical = 0, casters = 0, hybrids = 0, melee = 0, mana = 0, roleTank = 0, roleHealer = 0,
                canTank = 0, canHeal = 0, readAt = now }
    for i = 1, math.min(math.max(count, 0), #tokens) do
        local u = tokens[i]
        if Plain(UnitExists(u)) and not Get(UnitIsUnit, u, "player") then
            local _, token = Call(UnitClass, u)
            token = Plain(token)
            local role = Get(UnitGroupRolesAssigned, u)
            if role == "NONE" then role = nil end
            local m = { unit = u, class = token, role = role, name = Get(UnitName, u) }
            r.members[#r.members + 1] = m
            r.n = r.n + 1
            if role then r.rolesKnown = true end
            if role == "TANK" then r.roleTank = r.roleTank + 1 end
            if role == "HEALER" then r.roleHealer = r.roleHealer + 1 end
            if token then
                r.class[token] = r.class[token] + 1
                if PHYSICAL[token] then r.physical = r.physical + 1 end
                if MELEE[token] then r.melee = r.melee + 1 end
                if CASTER[token] then r.casters = r.casters + 1 end
                if HYBRID[token] then r.hybrids = r.hybrids + 1 end
                if not NO_MANA[token] then r.mana = r.mana + 1 end
                if CAN_TANK[token] then r.canTank = r.canTank + 1 end
                if CAN_HEAL[token] then r.canHeal = r.canHeal + 1 end
            end
        end
    end
    if r.n == 0 then return SOLO end
    local mine = Get(UnitGroupRolesAssigned, "player")
    if mine == "NONE" then mine = nil end
    r.myRole = mine
    if mine then r.rolesKnown = true end
    return r
end

local function Roster(now)
    if dirty or now - rosterAt > ROSTER_AGE then
        roster = ReadRoster(now)
        rosterAt, dirty = now, false
    end
    return roster
end

function Party:Roster() return Roster(GetTime()) end

------------------------------------------------------------------------------
-- Schnappschuss fuer die Regeln
------------------------------------------------------------------------------

function Party:Snapshot(S)
    local db = NM.db
    Party.last = nil
    if db.useParty == false or db.groupMode == "solo" then
        S.party = SOLO
        return
    end
    local now = S.now
    local r = Roster(now)
    if r == SOLO then
        S.party = SOLO
        return
    end
    -- wen greift das Ziel an?
    local aggro
    local t = S.target
    if t and t.valid and not t.player and t.targetingMe ~= true and Plain(UnitExists("targettarget")) then
        for _, m in ipairs(r.members) do
            if Get(UnitIsUnit, "targettarget", m.unit) then
                aggro = m
                break
            end
        end
    end
    if aggro and S.inCombat and aggro.name and (aggro.role == "TANK" or (not aggro.role and CAN_TANK[aggro.class or ""])) then
        tankSeen[aggro.name] = now
    end
    local observed = false
    for _, m in ipairs(r.members) do
        local seen = m.name and tankSeen[m.name]
        if seen and now - seen < TANK_MEMORY then observed = true end
    end
    local P = setmetatable({}, { __index = r })
    P.tank = (r.roleTank > 0) or observed
    P.tankLikely = P.tank or (not r.rolesKnown and r.canTank > 0)
    if r.rolesKnown then P.healer = r.roleHealer > 0 else P.healer = r.canHeal > 0 end
    P.aggro = aggro
    P.aggroSoft = (aggro ~= nil) and aggro.role ~= "TANK" and not (aggro.role == nil and CAN_TANK[aggro.class or ""]) or false
    -- die eigene Bedrohung: gleich oben, obwohl ein anderer tanken soll
    P.threatHigh = (P.tankLikely and r.myRole ~= "TANK" and S.inCombat and t and t.valid and not t.player
        and (S.threatTanking == true or (S.threatPct and S.threatPct >= 85))) and true or false
    S.party = P
    Party.last = P
end

------------------------------------------------------------------------------
-- Buffs der Mitspieler (nur ausserhalb des Kampfes lesbar)
------------------------------------------------------------------------------

local function Reachable(u)
    if Get(UnitIsConnected, u) == false then return false end
    if Get(UnitIsDeadOrGhost, u) == true then return false end
    if Get(UnitInRange, u) == false then return false end
    return true
end

-- Namen der Mitspieler, denen jeder der Buffs keys fehlt; want(m) grenzt ein (z. B. nur
-- Mitspieler mit Mana). Leer im Kampf und wenn der Client die Buffs nicht herausgibt.
function Party:Lacking(keys, want)
    local out = {}
    if Plain(UnitAffectingCombat("player")) or NM.State.aurasRestricted then return out end
    local read = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName
    if not read then return out end
    for _, m in ipairs(Roster(GetTime()).members) do
        if (not want or want(m)) and Reachable(m.unit) then
            local has, readable, asked = false, true, false
            for _, k in ipairs(keys) do
                local name = SP[k] and SP[k].name
                if name then
                    asked = true
                    local ok, a = pcall(read, m.unit, name, "HELPFUL")
                    if not ok or (issecret and issecret(a)) then readable = false
                    elseif a ~= nil then has = true end
                end
            end
            if asked and readable and not has then out[#out + 1] = m.name or m.unit end
        end
    end
    return out
end

-- Zeile fuer den Vor-Kampf-Check: "Arkane Intelligenz: Anna, Bert +2"
function Party:Check(add, label, keys, want)
    local names = self:Lacking(keys, want)
    if #names == 0 then return false end
    local text = table.concat(names, ", ", 1, math.min(3, #names))
    if #names > 3 then text = text .. " +" .. (#names - 3) end
    add(label .. " (" .. text .. ")")
    return true
end

function Party.HasMana(m) return m.class ~= nil and not NO_MANA[m.class] end
function Party.IsPhysical(m) return m.class ~= nil and (PHYSICAL[m.class] or false) end

------------------------------------------------------------------------------
-- Messung und Ausgabe
------------------------------------------------------------------------------

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

-- Was der Client ueber den ersten Mitspieler herausgibt
function Party:Probe(add)
    local raid = Get(IsInRaid) and true or false
    if not (raid or Get(IsInGroup)) then
        add("group", "none")
        return
    end
    local u
    for _, tok in ipairs(raid and RAID or PARTY) do
        if Plain(UnitExists(tok)) and not Get(UnitIsUnit, tok, "player") then u = tok; break end
    end
    add("group", (raid and "raid" or "party") .. tostring(Get(GetNumGroupMembers) or "?"))
    if not u then return end
    do
        local ok, _, token = pcall(UnitClass, u)
        add("g.class", ok and kind(token) or "ERROR")
    end
    add("g.name", first(UnitName, u))
    do
        local role = Call(UnitGroupRolesAssigned, u)
        add("g.role", kind(role) .. ((Plain(role) and (":" .. tostring(role))) or ""))
        local mine = Call(UnitGroupRolesAssigned, "player")
        add("g.myRole", kind(mine) .. ((Plain(mine) and (":" .. tostring(mine))) or ""))
    end
    add("g.health", first(UnitHealth, u))
    add("g.power", first(UnitPower, u))
    add("g.connected", first(UnitIsConnected, u))
    add("g.dead", first(UnitIsDeadOrGhost, u))
    add("g.inRange", first(UnitInRange, u))
    add("g.isUnit", first(UnitIsUnit, "targettarget", u))
    add("g.threat", first(UnitThreatSituation, u, "target"))
    add("g.threatPct", first(function() local _, _, pct = UnitDetailedThreatSituation(u, "target"); return pct end))
    do
        local C = NM.class
        local buff = C.probeBuff and SP[C.probeBuff] and SP[C.probeBuff].name or "?"
        local ok, a = pcall((C_UnitAuras or {}).GetAuraDataBySpellName or error, u, buff, "HELPFUL")
        add("g.buff", ok and ((issecret and issecret(a)) and "SECRET" or type(a)) or "ERROR")
    end
    add("g.casting", first(UnitCastingInfo, u))
    add("g.castEvent", castKinds.unit .. "/" .. castKinds.spell)
    add("g.castsSeen", tostring(castKinds.seen))
    local P = Party.last
    if P and P.n > 0 then
        add("g.read", ("n%d tank=%s likely=%s healer=%s roles=%s aggro=%s"):format(P.n, tostring(P.tank), tostring(P.tankLikely),
            tostring(P.healer), tostring(P.rolesKnown), P.aggro and tostring(P.aggro.class) or "-"))
    end
end

local ROLE_TEXT = { TANK = "Tank", HEALER = T("Heiler", "healer"), DAMAGER = T("Schaden", "damage") }

-- kurze Beschreibung fuer Lage-Zeile und Protokoll, z. B. "Gruppe 5 · Tank · Heiler"
function Party.Describe(P)
    if not P or P.n == 0 then return nil end
    local parts = { (P.raid and T("Schlachtzug ", "raid ") or T("Gruppe ", "group ")) .. (P.n + 1) }
    parts[#parts + 1] = P.tank and "Tank" or (P.tankLikely and T("Tank?", "tank?") or T("kein Tank", "no tank"))
    parts[#parts + 1] = P.healer and T("Heiler", "healer") or T("kein Heiler", "no healer")
    return table.concat(parts, " · ")
end

-- Kurzzeichen fuers Protokoll: G5th = Gruppe mit 5, Tank, Heiler (T = Tank nur vermutet)
function Party.Tag(P)
    if not P or P.n == 0 then return "" end
    return (P.raid and "R" or "G") .. (P.n + 1) .. (P.tank and "t" or (P.tankLikely and "T" or "")) .. (P.healer and "h" or "")
end

function Party:Print()
    dirty = true
    local S = NM.State:Snapshot()
    local P = S.party
    if not P or P.n == 0 then
        Print(T("Keine Gruppe erkannt.", "No group detected.") .. (NM.db.useParty == false
            and T(" (Die Gruppenanpassung ist ausgeschaltet.)", " (Group adaptation is switched off.)") or ""))
        return
    end
    Print(Party.Describe(P))
    for _, m in ipairs(P.members) do
        local seen = m.name and tankSeen[m.name]
        DEFAULT_CHAT_FRAME:AddMessage(("  %s: %s%s%s"):format(tostring(m.name or m.unit), tostring(m.class or "?"),
            m.role and (", " .. T("Rolle ", "role ") .. (ROLE_TEXT[m.role] or m.role)) or "",
            seen and T(", hat getankt", ", has tanked") or ""))
    end
    DEFAULT_CHAT_FRAME:AddMessage(("  %s: %d   %s: %d   %s: %d   %s: %d"):format(T("Nahkampf/Jäger", "physical"), P.physical,
        T("Zauberer", "casters"), P.casters, T("Hybride", "hybrids"), P.hybrids, T("mit Mana", "with mana"), P.mana))
    if P.myRole then DEFAULT_CHAT_FRAME:AddMessage("  " .. T("Deine Rolle: ", "Your role: ") .. (ROLE_TEXT[P.myRole] or P.myRole)) end
end

------------------------------------------------------------------------------
-- Ereignisse
------------------------------------------------------------------------------

-- Zauber der Mitspieler: gibt der Client Einheit und Zauber heraus? Wenn ja, mitzaehlen.
local function OnCast(unit, _, spellID)
    local u = Plain(unit)
    if u == nil then
        if issecret and issecret(unit) then castKinds.unit = "SECRET" end
        return
    end
    if type(u) ~= "string" or not (u:match("^party%d+$") or u:match("^raid%d+$")) then return end
    castKinds.unit = "plain"
    castKinds.seen = castKinds.seen + 1
    local id = Plain(spellID)
    if not id then castKinds.spell = "SECRET"; return end
    castKinds.spell = "plain"
    local db = NM.adb
    if not db then return end
    local _, token = Call(UnitClass, u)
    token = Plain(token) or "?"
    db.groupCasts = db.groupCasts or {}
    local list = db.groupCasts[token]
    if not list then list = {}; db.groupCasts[token] = list end
    local name = Get(C_Spell.GetSpellName, id)
    local key = tostring(name or "?") .. "#" .. tostring(id)
    if list[key] then
        list[key] = list[key] + 1
    else
        local n = 0
        for _ in pairs(list) do n = n + 1 end
        if n < 80 then list[key] = 1 end
    end
end

function Party:Init()
    local function mark() dirty = true end
    NM.On("GROUP_ROSTER_UPDATE", function()
        local before = roster.n
        dirty = true
        -- neu in einer Gruppe: die Probe soll dort noch einmal messen
        if before == 0 and NM.Probe and NM.Probe.Rearm then NM.Probe:Rearm() end
    end)
    NM.On("PLAYER_ROLES_ASSIGNED", mark)
    NM.On("ROLE_CHANGED_INFORM", mark)
    NM.On("PLAYER_ENTERING_WORLD", mark)
    NM.On("UNIT_SPELLCAST_SUCCEEDED", OnCast)
end
