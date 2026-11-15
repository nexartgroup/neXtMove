--[[---------------------------------------------------------------------------
    State.lua - alles, was die Logik ueber Charakter und Kampf wissen muss (alle Klassen)

    Statisch (bei Aenderung neu gelesen):
      * gelernte Zauber: hoechster Rang je Zauber aus dem Zauberbuch, ueber den Namen eines
        Referenz-Rangs gefunden (unabhaengig von der Clientsprache). Was nicht gelernt ist,
        gibt es fuer die Logik nicht - so passt sie zu jeder Stufe.
      * Talente: Rang je Talent-Zauber-ID aus C_Traits, dazu die Punkte je Baum
      * Ausruestung: Waffenarten, Schmuckstuecke mit Benutzen-Effekt
      * Taschen: Traenke, Gesundheitssteine und die Gegenstaende der Klasse

    Je Takt (Snapshot): Kraft (Energie/Mana/Wut), eigene Lage, Ziel, Gegner ueber die
    Namensplaketten, laufender eigener Zauber, Begleiter, dazu die Extras der Klasse.

    Gemessen in WoW Forever 1.60.1 (Proben vom 13.11.2026, offene Welt, Schurke):
      immer geheim      Energie, eigene Gesundheit, Gesundheit des Ziels (auch in Prozent),
                        Schadensbetraege in UNIT_COMBAT
      im Kampf geheim   Start und Dauer von Abklingzeiten, Buffs und Debuffs, Angriffstempo
      immer lesbar      Combopunkte, "Zauber benutzbar" samt "zu wenig Kraft", Reichweite,
                        Kosten, Bedrohung, wen das Ziel angreift, Rang und Art des Gegners,
                        Namensplaketten, GUIDs, Hoechstgesundheit, ob eine Abklingzeit laeuft
                        (isActive; isOnGCD nur waehrend der globalen), Einheit und Zauber-ID
                        der eigenen Zauber, Einheit und Art in UNIT_COMBAT, und ob Blizzards
                        Warnung "niedrige Gesundheit" gezeigt wird
    Das Kampflog gibt es fuer Addons nicht.

    Der Ersatz fuer das Geheime:
      Kraft          ob ein Move JETZT geht, sagt der Client selbst (benutzbar / zu wenig
                     Kraft). Energie wird zusaetzlich geschaetzt und ueber die Benutzbarkeit
                     aller Zauber eingegrenzt; bei Mana gibt es nur diese Grenzen.
      Abklingzeiten  bereit oder nicht ist lesbar; die Restzeit laeuft ab dem Wirken mit
      Buffs/Debuffs  ausserhalb des Kampfes gelesen und gemerkt, im Kampf mitgeschrieben aus
                     den eigenen Zaubern - je Ziel (GUID), damit Mehrfachziele stimmen
      eigene Gesundheit   nicht messbar. Ersatz: Zahl der Angreifer, eingesteckte Treffer je
                     Sekunde und Blizzards Warnung bei niedriger Gesundheit
      Restlebenszeit des Ziels   nicht messbar. Ersatz: die gelernte Kampfdauer gegen Gegner
                     gleichen Rangs und gleicher Stufenlage (NextMoveDB.kills)
-----------------------------------------------------------------------------]]

local _, NM = ...
local Plain, Call, Get, T, Print = NM.Plain, NM.Call, NM.Get, NM.T, NM.Print
local SP = NM.SPELLS

local State = {}
NM.State = State

local GetTime, max, min = GetTime, math.max, math.min
local pairs, ipairs, type, tonumber, wipe = pairs, ipairs, type, tonumber, wipe
local issecret = _G.issecretvalue

local ENERGY = 3
local GCD_SPELL = 61304

-- Gegenstaende aller Klassen, beste Stufe zuerst; die Klasse ergaenzt ihre eigenen
local ITEMS = {
    potion      = { 13446, 3928, 1710, 929, 858, 118 },
    healthstone = { 19013, 19012, 9421, 19011, 19010, 5510, 19009, 19008, 5509, 19007, 19006, 5511, 19005, 19004, 5512 },
    manapotion  = { 13444, 13443, 6149, 3827, 3385, 2455 },
}

-- Arten, die nicht bluten, nach ID und nach Name
local NO_BLEED_ID = { [4] = true, [9] = true, [11] = true }
local NO_BLEED_NAME = { Elemental = true, Mechanical = true, Totem = true, Elementar = true, Mechanisch = true }
local TYPE_BY_NAME = {
    Beast = "beast", Wildtier = "beast", Dragonkin = "dragonkin", Drachkin = "dragonkin",
    Demon = "demon", ["Dämon"] = "demon", Elemental = "elemental", Elementar = "elemental",
    Giant = "giant", Riese = "giant", Undead = "undead", Untoter = "undead",
    Humanoid = "humanoid", Critter = "critter", Kleintier = "critter",
    Mechanical = "mechanical", Mechanisch = "mechanical", Totem = "totem",
}

------------------------------------------------------------------------------
-- Statischer Zustand
------------------------------------------------------------------------------

State.talents = {}          -- [Talent-Zauber-ID] = Rang
State.points = { 0, 0, 0 }  -- Punkte je Baum
State.spec = 1
State.gear = {}
State.items = {}
State.model = {}            -- eigene Effekte: [key] = Ablaufzeit
State.lastCast = {}         -- [key] = Zeit des letzten eigenen Wirkens
State.byId, State.byName = {}, {}
State.est = { e = 100, t = 0 }
State.cpEst = 0

local guidModels = {}       -- Effekte auf Gegnern: [GUID][key] = Ablaufzeit
local dirty = { spells = true, talents = true, gear = true, items = true }

local function TargetModel(create, guid)
    guid = guid or Plain(UnitGUID("target"))
    if not guid then return nil end
    local m = guidModels[guid]
    if not m and create then m = {}; guidModels[guid] = m end
    return m
end

-- Hoechster Rang je Zaubername aus dem Zauberbuch
local top = {}
local function ReadSpellbook()
    wipe(top)
    local SB = C_SpellBook
    if not (SB and SB.GetNumSpellBookSkillLines and SB.GetSpellBookSkillLineInfo and SB.GetSpellBookItemInfo) then return false end
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1
    for line = 1, (Get(SB.GetNumSpellBookSkillLines) or 0) do
        local li = Call(SB.GetSpellBookSkillLineInfo, line)
        if type(li) == "table" and not li.offSpecID and li.itemIndexOffset and li.numSpellBookItems then
            for slot = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
                local lowRank = SB.IsSpellBookItemLowRank and Get(SB.IsSpellBookItemLowRank, slot, bank)
                local passive = SB.IsSpellBookItemPassive and Get(SB.IsSpellBookItemPassive, slot, bank)
                if not lowRank and not passive then
                    local info = Call(SB.GetSpellBookItemInfo, slot, bank)
                    if type(info) == "table" and (info.itemType == nil or info.itemType == spellType)
                       and info.spellID and info.name then
                        top[info.name] = info.spellID
                    end
                end
            end
        end
    end
    return true
end

local function knows(id)
    return (C_SpellBook and C_SpellBook.IsSpellKnown and Get(C_SpellBook.IsSpellKnown, id))
        or (IsPlayerSpell and Get(IsPlayerSpell, id))
end

local function ReadSpells()
    local haveBook = ReadSpellbook()
    wipe(State.byId); wipe(State.byName)
    local missingNames = false
    for key, d in pairs(SP) do
        d.name = Get(C_Spell.GetSpellName, d.ref) or d.name
        d.id = nil
        if not d.name then
            missingNames = true
        elseif d.foreign then
            -- kein eigener Zauber, nur der Name zaehlt
        elseif d.always then
            d.id = d.ref
        elseif d.pet then
            -- Zauber des Begleiters: gelernt, wenn der gerufene Begleiter ihn hat
            local petBank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Pet or 1
            local function petKnows(id)
                return (C_SpellBook and C_SpellBook.IsSpellKnown and Get(C_SpellBook.IsSpellKnown, id, petBank))
                    or (IsSpellKnown and Get(IsSpellKnown, id, true))
            end
            if petKnows(d.ref) then d.id = d.ref end
            for _, alt in ipairs(d.alt or {}) do
                if petKnows(alt) then d.id = alt end
            end
        else
            d.id = top[d.name]
            if not d.id then
                -- Rueckfall, falls das Zauberbuch den Zauber nicht zeigt: die Suche ueber den Namen
                -- findet nur gelernte Zauber, danach die Abfrage auf den Referenz-Rang
                local info = Plain((Call(C_Spell.GetSpellInfo, d.name)))
                local sid = type(info) == "table" and Plain(info.spellID)
                if sid and (haveBook == false or knows(sid)) then d.id = sid
                elseif knows(d.ref) then d.id = d.ref end
            end
        end
        if d.id then
            State.byId[d.id] = key
            State.byId[d.ref] = key
            State.byName[d.name] = key
            -- Kosten, Abklingzeit und Zauberzeit, wie der Client sie nennt (Talente eingerechnet)
            -- (jeder Zauber kostet eine Kraftart; beim Druiden wechselt sie mit der Gestalt)
            d.costNow, d.costType = nil, nil
            local costs = Plain((Call(C_Spell.GetSpellPowerCost, d.id)))
            if type(costs) == "table" then
                for _, c in ipairs(costs) do
                    local ty, co = Plain(c.type), Plain(c.cost)
                    -- Mana 0, Wut 1, Energie 3 (Combopunkte und anderes zaehlen hier nicht)
                    if (ty == 0 or ty == 1 or ty == 3) and co and co > 0 and not d.costNow then
                        d.costNow, d.costType = co, ty
                    end
                end
            end
            d.cdBase = State.BaseCooldown(d.id)
            local info = Plain((Call(C_Spell.GetSpellInfo, d.id)))
            local ct = type(info) == "table" and Plain(info.castTime)
            if type(ct) == "number" then d.castTime = ct / 1000 end
        end
    end
    -- Zauberdaten koennen kurz nach dem Login noch fehlen: dann spaeter noch einmal
    return not missingNames
end

local function ReadTalents()
    local talents = State.talents
    wipe(talents)
    local CT, TR = C_ClassTalents, C_Traits
    if CT and CT.GetActiveConfigID and TR and TR.GetConfigInfo and TR.GetTreeNodes and TR.GetNodeInfo then
        local configID = Get(CT.GetActiveConfigID)
        local ci = configID and Call(TR.GetConfigInfo, configID)
        if type(ci) == "table" and type(ci.treeIDs) == "table" then
            for _, treeID in ipairs(ci.treeIDs) do
                local nodes = Call(TR.GetTreeNodes, treeID)
                if type(nodes) == "table" then
                    for _, nodeID in ipairs(nodes) do
                        local ni = Call(TR.GetNodeInfo, configID, nodeID)
                        if type(ni) == "table" then
                            local rank = tonumber(ni.currentRank or ni.ranksPurchased or ni.activeRank) or 0
                            local entryID = ni.activeEntry
                            if type(entryID) == "table" then entryID = entryID.entryID end
                            if not entryID and type(ni.entryIDs) == "table" then entryID = ni.entryIDs[1] end
                            if rank > 0 and entryID then
                                local ei = Call(TR.GetEntryInfo, configID, entryID)
                                local di = type(ei) == "table" and ei.definitionID and Call(TR.GetDefinitionInfo, ei.definitionID)
                                local sid = type(di) == "table" and (di.spellID or di.overriddenSpellID)
                                if sid then talents[sid] = rank end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Punkte je Baum: GetSpecializationInfo (Forever fuellt pointsSpent), sonst der gewaehlte
    -- Baum, zuletzt ein Schluss der Klasse aus ihren Schluesselzaubern
    local points, known = State.points, false
    local SI = C_SpecializationInfo
    for i = 1, 3 do
        points[i] = 0
        if SI and SI.GetSpecializationInfo then
            local ok, specId, _, _, _, _, _, spent = pcall(SI.GetSpecializationInfo, i)
            if ok and Plain(specId) then points[i] = tonumber(Plain(spent)) or 0 end
        end
        if points[i] > 0 then known = true end
    end
    local spec
    if known then
        spec = 1
        for i = 2, 3 do if points[i] > points[spec] then spec = i end end
    elseif SI and SI.GetSpecialization then
        local sel = Get(SI.GetSpecialization)
        if type(sel) == "number" and sel >= 1 and sel <= 3 then spec = sel end
    end
    if not known and NM.class.guessSpec then spec = NM.class.guessSpec(SP, spec) or spec end
    State.spec = spec or NM.class.defaultSpec or 1
    State.specKnown = known
end

local function WeaponInfo(slot)
    local id = Get(GetInventoryItemID, "player", slot)
    if not id then return nil end
    local _, _, _, _, _, classID, subID = Call(C_Item.GetItemInfoInstant, id)
    classID, subID = Plain(classID), Plain(subID)
    return id, classID == 2, (classID == 2 and subID == 15), (classID == 2 and subID == 19)
end

local function ReadGear()
    local g = State.gear
    g.mhID, g.mhWeapon, g.mhDagger = WeaponInfo(16)
    g.ohID, g.ohWeapon, g.ohDagger = WeaponInfo(17)
    local _, rangedWeapon, _, wand = WeaponInfo(18)
    g.wand = rangedWeapon and wand or false
    g.trinkets = g.trinkets or {}
    wipe(g.trinkets)
    for slot = 13, 14 do
        local id = Get(GetInventoryItemID, "player", slot)
        -- nur Schmuck mit Benutzen-Effekt
        if id and Get(C_Item.GetItemSpell, id) then g.trinkets[#g.trinkets + 1] = slot end
    end
end

-- Abklingzeiten von Gegenstaenden sind im Kampf nicht lesbar. Ersatz: sinkt der Vorrat einer
-- Art um eins, wurde sie eben benutzt. Traenke teilen sich ihre Abklingzeit.
local ITEM_CD = { potion = 120, manapotion = 120, healthstone = 120, managem = 120, tea = 300 }
local ITEM_SHARED = { potion = "manapotion", manapotion = "potion" }
State.itemUsed = {}
local lastCount = {}

-- Grundabklingzeit eines Zaubers in s, wie der Client sie nennt (ohne Talente). Die Funktion
-- ist global; eine Fassung in C_Spell gibt es in diesem Client nicht.
function State.BaseCooldown(id)
    local ms = Get(_G.GetSpellBaseCooldown, id)
    if ms == nil and C_Spell and C_Spell.GetSpellBaseCooldown then ms = Get(C_Spell.GetSpellBaseCooldown, id) end
    if type(ms) == "number" and ms > 0 then return ms / 1000 end
end

-- Abklingzeit, mit der gerechnet wird: zuerst die am Charakter beobachtete (Talente sind dann
-- eingerechnet), dann die des Clients, dann die aus der Tabelle der Klasse
function State.CooldownLength(key)
    local d = SP[key]
    if not d then return nil end
    local seen = NM.cdb and NM.cdb.cdSeen and NM.cdb.cdSeen[key]
    if seen then return seen, "seen" end
    if d.cdBase then return d.cdBase, "client" end
    if d.cd then return d.cd, "table" end
end

local function ReadItems()
    local items = State.items
    for kind in pairs(ITEM_CD) do lastCount[kind] = items[kind .. "Count"] or 0 end
    wipe(items)
    for _, source in ipairs({ ITEMS, NM.class.items or {} }) do
        for kind, list in pairs(source) do
            for _, id in ipairs(list) do
                local n = Get(C_Item.GetItemCount, id)
                if n and n > 0 then
                    if not items[kind] then items[kind] = id end
                    items[kind .. "Count"] = (items[kind .. "Count"] or 0) + n
                end
            end
        end
    end
    local now = GetTime()
    for kind in pairs(ITEM_CD) do
        if (items[kind .. "Count"] or 0) == lastCount[kind] - 1 then
            State.itemUsed[kind] = now
            if ITEM_SHARED[kind] then State.itemUsed[ITEM_SHARED[kind]] = now end
        end
    end
end

local function Refresh()
    if dirty.spells then dirty.spells = not ReadSpells() end
    if dirty.talents then dirty.talents = false; ReadTalents() end
    if dirty.gear then dirty.gear = false; ReadGear() end
    if dirty.items then dirty.items = false; ReadItems() end
end
State.Refresh = Refresh

------------------------------------------------------------------------------
-- Dauer eines eigenen Effekts (fuer das Modell und die Vorschau auf Move 2)
------------------------------------------------------------------------------

function State.Duration(key, cp)
    local fn = NM.class.duration
    local dur = fn and fn(key, max(1, cp or 1), State)
    if dur then return dur end
    local d = SP[key]
    return d and d.dur
end

------------------------------------------------------------------------------
-- Abklingzeiten
------------------------------------------------------------------------------

-- Restzeit in s, wenn der Client sie nennt. Im Kampf sind Start und Dauer geheim; lesbar
-- bleiben zwei Wahrheitswerte: laeuft etwas (isActive), und ist es nur die globale
-- Abklingzeit (isOnGCD; fehlt ausserhalb der globalen).
local function CooldownOf(id, now)
    local info = Plain((Call(C_Spell.GetSpellCooldown, id)))
    if type(info) ~= "table" then return nil end
    local st, du = Plain(info.startTime), Plain(info.duration)
    if st and du then
        if du <= 0 then return 0 end
        return max(0, st + du - now), nil, nil, du
    end
    return nil, Plain(info.isActive), Plain(info.isOnGCD)
end

-- Ein eigener Zauber wurde gewirkt: Effektdauer, Abklingzeit und Kraft mitschreiben
local function ApplyCast(key, now, cp, viaCooldown, guid)
    local d = SP[key]
    if not d then return end
    State.lastCast[key] = now
    local dur = d.unit and State.Duration(key, cp)
    if dur then
        if d.unit == "target" then
            local m = TargetModel(true, guid)
            if m then m[key] = now + dur end
        else
            State.model[key] = now + dur
        end
    end
    if viaCooldown then return end       -- nur am Start der Abklingzeit erkannt: Rest schon verbucht
    if not d.offgcd then State.lastGCD = now end
    State.est.e = max(0, State.est.e - (d.costNow or d.cost or 0))
    if d.fin then State.cpEst = 0 elseif d.cp then State.cpEst = min(5, State.cpEst + d.cp) end
    if NM.class.onCast then NM.class.onCast(key, now, State) end
end

function State:ReadCooldown(key, now)
    local d = SP[key]
    if not (d and d.id) then return 0 end
    local cd, active, onGCD, full = CooldownOf(d.id, now)
    if cd then
        -- Ausserhalb des Kampfes ist die volle Dauer lesbar: merken, denn sie enthaelt Talente.
        -- Nur glauben, was zur bekannten Abklingzeit passt (keine Zaubersperren, nicht die globale).
        if full and full > 2 and NM.db then
            local ref = d.cdBase or d.cd
            if not ref or (full >= ref * 0.4 and full <= ref * 1.2) then
                NM.cdb.cdSeen = NM.cdb.cdSeen or {}
                NM.cdb.cdSeen[key] = math.floor(full * 10 + 0.5) / 10
            end
        end
        return cd
    end
    local last, base = self.lastCast[key], State.CooldownLength(key)
    local left = (last and base) and max(0, last + base - now) or 0
    if active == false or (active and onGCD) then return 0 end
    if active then
        -- Laeuft, die Restzeit ist geheim. Laeuft gerade die globale Abklingzeit (am
        -- Bezugszauber abgelesen) und ist vom Zauber kein eigenes Wirken bekannt, dann ist
        -- es nur die globale.
        if left <= 0 then
            if self.gcdRunning then return 0 end
            ApplyCast(key, now, self.cpRecent or 0, true)
            return base or 30
        end
        return left
    end
    return left
end

-- Globale Abklingzeit: lesbar, oder daran, ob beim Bezugszauber (ohne eigene Abklingzeit)
-- etwas laeuft
local gcdRunning, gcdStart = false, 0
local function ReadGCD(now, gcdLen)
    State.gcdRunning = false
    local cd = CooldownOf(GCD_SPELL, now)
    if cd then State.gcdRunning = cd > 0; return cd end
    local id
    for _, k in ipairs(State.gcdSpells or NM.class.gcdSpell or {}) do
        if SP[k] and SP[k].id then id = SP[k].id; break end
    end
    if id then
        local left, active = CooldownOf(id, now)
        if left then State.gcdRunning = left > 0; return left end
        if active ~= nil then
            local running = active and true or false
            if running and not gcdRunning then gcdStart = now end
            gcdRunning = running
            State.gcdRunning = running
            return running and max(0.1, gcdStart + gcdLen - now) or 0
        end
    end
    local last = State.lastGCD
    return last and max(0, last + gcdLen - now) or 0
end

------------------------------------------------------------------------------
-- Effekte (Buffs und Debuffs)
------------------------------------------------------------------------------

-- Restdauer eines Effekts in s (0 = nicht vorhanden). Ausserhalb des Kampfes liest der
-- Client und das Modell merkt es sich; im Kampf zaehlt nur das Modell.
function State:ReadAura(key, now)
    local d = SP[key]
    local name = d and d.name
    if not name then return 0 end
    local unit = d.unit or "player"
    local onTarget = (unit == "target")
    if onTarget and not Plain(UnitExists("target")) then return 0 end
    if not self.aurasRestricted and C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
        -- (harmful: ein Debuff auf einem selbst, etwa Geschwaechte Seele)
        local filter = onTarget and (d.foreign and "HARMFUL" or "HARMFUL|PLAYER") or (d.harmful and "HARMFUL" or "HELPFUL")
        local ok, a = pcall(C_UnitAuras.GetAuraDataBySpellName, unit, name, filter)
        if ok and not (issecret and issecret(a)) then
            if a == nil then
                local m = onTarget and TargetModel(false) or self.model
                if m then m[key] = nil end
                return 0
            end
            if type(a) == "table" then
                local exp = Plain(a.expirationTime)
                if exp then
                    local left = (exp == 0) and 9999 or max(0, exp - now)
                    local m = onTarget and TargetModel(true) or self.model
                    if m then m[key] = now + left end
                    return left
                end
            end
        end
    end
    local m = onTarget and TargetModel(false) or self.model
    local e = m and m[key]
    return e and max(0, e - now) or 0
end

------------------------------------------------------------------------------
-- Kraft eingrenzen, wenn sie geheim ist: der Client sagt je Zauber, ob die Kraft reicht.
-- Jeder benutzbare Zauber gibt eine Untergrenze (seine Kosten), jeder mit "zu wenig Kraft"
-- eine Obergrenze.
------------------------------------------------------------------------------

local function PowerBounds(powerMax, powerType)
    local lo, hi = 0, powerMax
    for _, d in pairs(SP) do
        local cost = d.id and not d.always and (d.costNow or d.cost)
        -- nur Zauber der aktuellen Kraftart sagen etwas ueber sie aus
        if cost and cost > 0 and (d.costType == nil or d.costType == powerType) then
            local usable, noPower = Call(C_Spell.IsSpellUsable, d.id)
            usable, noPower = Plain(usable), Plain(noPower)
            if noPower == true then
                if not hi or cost - 1 < hi then hi = cost - 1 end
            elseif usable == true then
                if cost > lo then lo = cost end
            end
        end
    end
    if hi and lo > hi then hi = powerMax end
    return lo, hi
end

------------------------------------------------------------------------------
-- Eigene Lage: Treffer zaehlen, Blizzards Warnung lesen
------------------------------------------------------------------------------

-- Gemessen: Einheit und Art des Ereignisses sind lesbar, der Betrag nicht. Also zaehlen die
-- Treffer, die man einsteckt - als Mass fuer den eingehenden Schaden.
local hitsTaken = {}
local function OnUnitCombat(unit, action, _, amount)
    unit, action, amount = Plain(unit), Plain(action), Plain(amount)
    State.combatEvent = (unit and "u" or "U") .. (action and "a" or "A") .. (type(amount) == "number" and "n" or "N")
    if unit == "player" and action == "WOUND" then
        hitsTaken[#hitsTaken + 1] = GetTime()
        if NM.Model then NM.Model:OnHit() end
    end
end

local function HitRate(now)
    while hitsTaken[1] and hitsTaken[1] < now - 5 do table.remove(hitsTaken, 1) end
    return #hitsTaken / 5
end

-- Blizzards eigene Warnung bei niedriger Gesundheit (der rote Bildschirmrand): ob sie
-- gezeigt wird, ist lesbar - das einzige direkte Zeichen fuer die eigene Gesundheit
local function LowHealthWarning()
    local f = _G.LowHealthFrame
    if not (f and f.IsShown) then return false end
    return Get(f.IsShown, f) and true or false
end

-- lesbarer Wert oder nichts (in Forever bisher nie lesbar)
local function HealthOf(unit)
    local hp, hpMax = Get(UnitHealth, unit), Get(UnitHealthMax, unit)
    if hp and hpMax and hpMax > 0 then return hp, hpMax end
end

------------------------------------------------------------------------------
-- Gelernte Kampfdauer: die Gesundheit des Ziels ist geheim, also merkt sich das Addon, wie
-- lange Kaempfe gegen Gegner dieser Art dauern, und schaetzt daraus die Restlebenszeit
------------------------------------------------------------------------------

local engage = {}

local function KillKey(t, level, group)
    local rank = t.boss and "boss" or (t.elite and "elite") or (t.player and "player") or "normal"
    local diff = "even"
    if t.level and t.level > 0 then
        if t.level >= level + 3 then diff = "high" elseif t.level <= level - 3 then diff = "low" end
    end
    return rank .. "-" .. diff .. (group and "-group" or "-solo")
end

local function LearnKill(now)
    if not (engage.start and engage.key) then return end
    local dur = now - engage.start
    engage.start = nil
    local id = (NM.classToken or "?") .. ":" .. engage.key
    -- was der Gegner an verbuchtem Schaden ausgehalten hat (auch kurze Kaempfe zaehlen)
    if NM.Model and dur >= 1.5 and dur <= 600 then NM.Model:OnKill(id, engage.guid) end
    if dur < 3 or dur > 600 then return end
    local kills = NM.adb.kills
    if type(kills) ~= "table" then kills = {}; NM.adb.kills = kills end
    local k = kills[id]
    if not k then
        kills[id] = { avg = dur, n = 1 }
    else
        k.avg = k.avg * 0.7 + dur * 0.3
        k.n = k.n + 1
    end
end

-- Restlebenszeit aus der gelernten Dauer; nil, solange zu wenig Kaempfe gesehen wurden.
-- Vor dem Kampf (key gegeben) die ganze gelernte Dauer.
local function LearnedTTD(now, key)
    local kills = NM.adb.kills
    key = key or engage.key
    local k = type(kills) == "table" and key and kills[(NM.classToken or "?") .. ":" .. key]
    if not (k and k.n >= 2) then return nil end
    if not engage.start then return k.avg end
    return max(k.avg - (now - engage.start), max(2, k.avg * 0.15))
end

------------------------------------------------------------------------------
-- Gegner ueber die Namensplaketten
------------------------------------------------------------------------------

local PLATES, PLATE_TARGETS = {}, {}
for i = 1, 40 do PLATES[i] = "nameplate" .. i; PLATE_TARGETS[i] = "nameplate" .. i .. "target" end

local enemies = { n = 0, melee = 0, onMe = 0, far = 0, plates = 0, t = 0 }

local function ScanEnemies(now, rangeSpell)
    if now - enemies.t < 0.25 then return enemies end
    enemies.t = now
    local n, inRange, onMe, far, plates = 0, 0, 0, 0, 0
    for i = 1, 40 do
        local u = PLATES[i]
        if Plain(UnitExists(u)) then
            plates = plates + 1
            if Plain(UnitCanAttack("player", u)) and not Plain(UnitIsDead(u)) then
                local fighting = Plain(UnitAffectingCombat(u))
                local threat = Get(UnitThreatSituation, "player", u)
                local onPlayer = Get(UnitIsUnit, PLATE_TARGETS[i], "player")
                if fighting or threat or onPlayer then
                    n = n + 1
                    local r = rangeSpell and Get(C_Spell.IsSpellInRange, rangeSpell, u)
                    if r == true then inRange = inRange + 1 elseif r == false then far = far + 1 end
                    if onPlayer or (threat and threat >= 2) then onMe = onMe + 1 end
                end
            end
        end
    end
    enemies.n, enemies.melee, enemies.onMe, enemies.far, enemies.plates = n, inRange, onMe, far, plates
    return enemies
end

------------------------------------------------------------------------------
-- Snapshot
------------------------------------------------------------------------------

local Snap = {}
Snap.__index = Snap

function Snap:known(k) local d = SP[k]; return (d and d.id) ~= nil end
function Snap:id(k) local d = SP[k]; return d and d.id end
function Snap:name(k) local d = SP[k]; return d and d.name end
function Snap:cost(k) local d = SP[k]; return d and (d.costNow or d.cost) or 0 end
function Snap:talent(name)
    local id = NM.class.talents and NM.class.talents[name]
    return id and State.talents[id] or 0
end

function Snap:cd(k)
    local ov = self.cdOv[k]
    if ov then return ov end
    local c = self.cdCache[k]
    if c == nil then c = State:ReadCooldown(k, self.now); self.cdCache[k] = c end
    return max(0, c - self.shift)
end

-- gelernt und bis zum Ende der globalen Abklingzeit bereit
function Snap:ready(k)
    return self:known(k) and not self.used[k] and self:cd(k) <= self.gcd + 0.15
end

-- benutzbar, zu wenig Kraft; nil = unbekannt (auch in der Vorschau)
function Snap:usable(k)
    if self.sim then return nil end
    local d = SP[k]
    if not (d and d.id) then return false end
    local u, noPower = Call(C_Spell.IsSpellUsable, d.id)
    return Plain(u), Plain(noPower)
end

function Snap:aura(k)
    local ov = self.auraOv[k]
    if ov then return ov end
    local a = self.auraCache[k]
    if a == nil then a = State:ReadAura(k, self.now); self.auraCache[k] = a end
    return max(0, a - self.shift)
end
function Snap:has(k) return self:aura(k) > 0 end

-- Laeuft der Zauber gerade als Dauerfeuer (Zauberstab "Schiessen")? Dann muss man ihn nicht
-- noch einmal druecken.
function Snap:repeating(k)
    if self.sim then return false end
    local d = SP[k]
    if not (d and d.id) then return false end
    local on = (C_Spell and C_Spell.IsAutoRepeatSpell and Get(C_Spell.IsAutoRepeatSpell, d.id))
    if on == nil and IsAutoRepeatSpell then on = Get(IsAutoRepeatSpell, d.name) end
    return on and true or false
end

-- Hat man mindestens n der Kraft? Gelesen oder geschaetzt, sonst die Untergrenze aus den
-- benutzbaren Zaubern (in der Vorschau unbekannt: nein)
function Snap:atLeast(n)
    if self.power then return self.power >= n end
    return (self.powerLo or 0) >= n
end

-- Ist das Ziel fuer diesen Zauber in Reichweite? true / false, oder nil, wenn der Zauber
-- kein Ziel braucht oder der Client nichts sagt. Gilt fuer den Takt (auch in der Vorschau:
-- der Abstand aendert sich durch einen Zauber nicht).
function Snap:inRange(k)
    local cache = self.rangeCache
    if not cache then return nil end
    local r = cache[k]
    if r == nil then
        local d = SP[k]
        r = "?"
        if d and d.id and d.unit ~= "player" and self.target and self.target.valid then
            local ok = Get(C_Spell.IsSpellInRange, d.id, "target")
            if ok == true or ok == 1 then r = true elseif ok == false or ok == 0 then r = false end
        end
        cache[k] = r
    end
    if r == "?" then return nil end
    return r
end

function Snap:itemReady(id)
    if not id then return false end
    local st, du = Call(C_Item.GetItemCooldown, id)
    st, du = Plain(st), Plain(du)
    if st and du then
        if du > 0 then return (st + du - self.now) <= 0.2 end
        return true
    end
    -- nicht lesbar (im Kampf): nach dem eigenen Verbrauch
    for kind, len in pairs(ITEM_CD) do
        local used = State.itemUsed[kind]
        if used and self.items[kind] == id and self.now - used < len then return false end
    end
    return true
end

function Snap:slotReady(slot)
    local st, du = Call(GetInventoryItemCooldown, "player", slot)
    st, du = Plain(st), Plain(du)
    if st and du and du > 0 then return (st + du - self.now) <= 0.2 end
    return true
end

-- Zeit, die ein Zauber belegt: Zauberzeit oder Kanalisierung, mindestens die globale
function Snap:castLen(k)
    local d = SP[k]
    if not d then return self.gcdLen end
    local ct = d.channel or d.castTime or d.cast or 0
    if d.offgcd then return ct end
    return max(self.gcdLen, ct)
end

-- Der Zustand nach einem Move: Grundlage fuer Move 2 (und fuer den laufenden Zauber)
function Snap:after(c)
    local S2 = setmetatable({}, { __index = self })
    local d = (c.kind == nil) and SP[c.key] or nil
    local dt = c.wait or 0
    if c.current then dt = c.left or 0
    elseif c.kind == "poison" then dt = dt + 3
    elseif d then dt = dt + self:castLen(c.key) end
    S2.sim = true
    S2.shift = self.shift + dt
    S2.gcd = 0
    S2.casting = false
    S2.auraOv = setmetatable({}, { __index = self.auraOv })
    S2.cdOv = setmetatable({}, { __index = self.cdOv })
    S2.used = setmetatable({}, { __index = self.used })
    -- Gegenstaende und einmalige Zauber (Beschwoeren, Herstellen) nicht zweimal vorschlagen
    if c.kind or (d and d.once) then S2.used[c.key] = true end

    if self.power then
        local p = self.power - ((d and not c.current) and self:cost(c.key) or 0) + (self.regen or 0) * dt
        S2.power = max(0, min(self.powerMax or p, p))
    end

    local cp = self.cp
    if d then
        if d.fin then
            if d.unit then S2.auraOv[c.key] = State.Duration(c.key, cp) or 10 end
            cp = 0
        else
            if d.cp and cp then cp = min(5, cp + d.cp) end
            if d.unit and (d.dur or NM.class.duration) then
                local dur = State.Duration(c.key, cp)
                if dur then S2.auraOv[c.key] = dur end
            end
        end
        local base = State.CooldownLength(c.key)
        if base and not c.current then S2.cdOv[c.key] = max(0, base - dt) end
        if self.stealthed and d.stealth ~= "keep" and c.key ~= "stealth" then
            S2.stealthed = false
            S2.inCombat = true
        end
        if d.interrupts then
            S2.target = setmetatable({ casting = false }, { __index = self.target })
        end
    end
    S2.cp = cp
    if NM.class.after then NM.class.after(S2, c, d, self) end
    return S2
end

local function Danger(S)
    local db, hp, onMe = NM.db, S.hp, S.enemies.onMe
    local d = 0
    if hp then
        if hp <= db.critHealth then d = 3 elseif hp <= db.lowHealth then d = 2 elseif hp <= 65 then d = 1 end
    end
    if onMe >= 3 then d = max(d, 2) elseif onMe >= 2 then d = max(d, 1) end
    -- eingesteckte Treffer je Sekunde: ein Gegner schlaegt etwa alle zwei Sekunden zu
    local hits = S.hitRate or 0
    if hits >= 1.6 then d = max(d, 2) elseif hits >= 0.9 then d = max(d, 1) end
    if S.lowHealth then d = 3 end
    local eliteOnMe = S.target.elite and S.target.targetingMe and not S.group
    if eliteOnMe then d = max(d, 1) end
    -- die eigene Gesundheit ist nicht lesbar: dann entscheidet die Lage allein, und sie wird
    -- vorsichtiger gelesen
    if not hp and S.inCombat and (onMe >= 2 or eliteOnMe) and d < 2 then
        return 2, true      -- geraten, nicht gemessen
    end
    return d, false
end

local EMPTY = {}
local cpPrev = 0
local outOfRangeSince

function State:Snapshot()
    Refresh()
    local C, db = NM.class, NM.db
    local now = GetTime()
    local S = setmetatable({}, Snap)
    S.now, S.shift, S.sim = now, 0, false
    S.cdCache, S.auraCache, S.rangeCache = {}, {}, {}
    S.cdOv, S.auraOv, S.used = EMPTY, EMPTY, EMPTY
    S.spec, S.gear, S.items = self.spec, self.gear, self.items
    S.level = Get(UnitLevel, "player") or 1

    -- Gestalt, Haltung oder Aura: der Schluessel des aktiven Zaubers der Haltungsleiste
    for i = 1, (Get(GetNumShapeshiftForms) or 0) do
        local _, active, _, spellID = Call(GetShapeshiftFormInfo, i)
        if Plain(active) then
            spellID = Plain(spellID)
            local key = spellID and State.byId[spellID]
            if not key and spellID then
                local name = Get(C_Spell.GetSpellName, spellID)
                key = name and State.byName[name]
            end
            S.form = key or true
            break
        end
    end
    -- Kraftart: fest je Klasse, beim Druiden nach Gestalt
    local powerType = C.power
    if C.dynamicPower then powerType = Get(UnitPowerType, "player") or C.power end
    S.powerType = powerType
    local gcdLen = C.gcd or 1.5
    if type(gcdLen) == "function" then gcdLen = gcdLen(S) or 1.5 end
    S.gcdLen = gcdLen
    -- Nahkaempfer? Reichweiten- und Bezugszauber? Beim Druiden haengt das an der Gestalt:
    -- die Klasse darf dafuer Funktionen statt fester Werte angeben.
    local function resolve(v) if type(v) == "function" then return v(S) end return v end
    S.isMelee = resolve(C.melee) and true or false
    local rangeSpells = resolve(C.rangeSpell) or EMPTY
    State.gcdSpells = resolve(C.gcdSpell)

    -- ob Effekte gerade geheim sind (dann zaehlt nur das Modell)
    self.aurasRestricted = C_Secrets and C_Secrets.ShouldAurasBeSecret and Get(C_Secrets.ShouldAurasBeSecret) or false

    S.inCombat = Plain(UnitAffectingCombat("player")) and true or false
    S.stealthed = Get(IsStealthed) and true or false
    if db.groupMode == "group" then S.group = true
    elseif db.groupMode == "solo" then S.group = false
    else S.group = Get(IsInGroup) and true or false end
    S.gcd = ReadGCD(now, S.gcdLen)
    S.pet = (Plain(UnitExists("pet")) and not Plain(UnitIsDead("pet"))) and true or false
    S.petDead = (Plain(UnitExists("pet")) and Plain(UnitIsDead("pet"))) and true or false
    -- in Bewegung (seit einer halben Sekunde): Zauber mit Zauberzeit gehen dann nicht
    -- (die Geschwindigkeit ist im Kampf geheim; dann zaehlen die Ereignisse "laeuft los" und
    -- "bleibt stehen")
    local speed = Get(GetUnitSpeed, "player")
    local moving
    if speed ~= nil then moving = speed > 0 else moving = self.movingEvent and true or false end
    if moving then
        self.movingSince = self.movingSince or now
        S.moving = (now - self.movingSince) > 0.5
    else
        self.movingSince = nil
        S.moving = false
    end

    -- laufender eigener Zauber: Move 1 ist dann, was danach kommt
    local cur = self.cur
    if cur then
        local left = cur.len and max(0, cur.t + cur.len - now) or 0.5
        if left <= 0 and now - cur.t > (cur.len or 0) + 1.5 then
            self.cur = nil
        else
            S.casting = { key = cur.key, left = left, channel = cur.channel }
            S.gcd = max(S.gcd, left)
        end
    end

    -- Kraft: gelesen; sonst Energie geschaetzt; sonst nur die Grenzen aus der Benutzbarkeit
    S.powerMax = Get(UnitPowerMax, "player", powerType)
    local p = Get(UnitPower, "player", powerType)
    if p then
        S.power, S.powerRead = p, true
        self.est.e = p
    else
        local lo, hi = PowerBounds(S.powerMax, powerType)
        S.powerLo, S.powerHi = lo, hi
        if powerType == ENERGY then
            local est = self.est
            S.regen = C.regen and C.regen(S) or 10
            local pmax = S.powerMax or 100
            est.e = min(pmax, est.e + S.regen * max(0, now - (est.t > 0 and est.t or now)))
            est.e = max(lo, min(hi or pmax, est.e))
            S.power = est.e
            S.powerMax = pmax
        end
    end
    self.est.t = now
    if S.power and not S.regen then S.regen = (powerType == ENERGY) and 10 or 0 end
    if S.power and S.powerMax and S.powerMax > 0 then S.powerPct = S.power / S.powerMax * 100 end
    -- Obergrenze der Kraft in Prozent, wenn nur Grenzen bekannt sind
    if not S.powerPct and S.powerHi and S.powerMax and S.powerMax > 0 then
        S.powerHiPct = S.powerHi / S.powerMax * 100
    end

    -- Combopunkte (Klassen mit Combopunkten)
    if C.combo then
        local cp = GetComboPoints and Get(GetComboPoints, "player", "target")
        if cp == nil then cp = Get(UnitPower, "player", 4) end
        if cp == nil then cp = self.cpEst else self.cpEst = cp end
        S.cp = cp
        self.cpRecent = max(cp, cpPrev)
        if cp > 0 then self.cpLast, self.cpLastT = cp, now end
        -- Combopunkte fallen im Kampf auf 0, ohne dass ein Zauberereignis den Finisher nannte:
        -- dann war es der zuletzt empfohlene (nur solange die Zauber-IDs geheim ankommen)
        if cpPrev > 0 and cp == 0 and S.inCombat and self.castSecret ~= false and not self.targetChanged
           and now - (self.lastFinisher or 0) > 1.2
           and Plain(UnitExists("target")) and not Plain(UnitIsDeadOrGhost("target")) then
            local key = self.suggestedFinisher
            if key then
                ApplyCast(key, now, cpPrev)
                self.lastFinisher = now
            end
        end
        cpPrev = cp
    else
        S.cp = 0
    end
    self.targetChanged = false

    -- eigene Lage
    S.hitRate = HitRate(now)
    S.lowHealth = LowHealthWarning()
    local hp, hpMax = HealthOf("player")
    if hp then S.hp, S.hpRead = hp / hpMax * 100, true end

    -- Ziel
    local t = {}
    S.target = t
    t.exists = Plain(UnitExists("target")) and true or false
    if t.exists then
        t.attackable = Plain(UnitCanAttack("player", "target")) and true or false
        t.dead = Plain(UnitIsDeadOrGhost("target")) and true or false
        t.valid = t.attackable and not t.dead
        if t.dead then LearnKill(now) end
    end
    local rangeSpell
    for _, k in ipairs(rangeSpells) do
        if SP[k] and SP[k].id then rangeSpell = SP[k].id; break end
    end
    if t.valid then
        local class = Get(UnitClassification, "target") or "normal"
        t.class = class
        t.level = Get(UnitLevel, "target")
        t.boss = (class == "worldboss") or (t.level == -1)
        t.elite = t.boss or class == "elite" or class == "rareelite"
        t.player = Plain(UnitIsPlayer("target")) and true or false
        local ctName, ctID = Call(UnitCreatureType, "target")
        ctName, ctID = Plain(ctName), Plain(ctID)
        t.type = ctName and TYPE_BY_NAME[ctName] or "other"
        t.bleedable = not ((type(ctID) == "number" and NO_BLEED_ID[ctID]) or (ctName and NO_BLEED_NAME[ctName]))
        t.stunnable = not t.boss
        t.guid = Plain(UnitGUID("target"))
        if Plain(UnitExists("targettarget")) then
            t.targetingMe = Get(UnitIsUnit, "targettarget", "player")   -- true, false oder nil (unbekannt)
        else
            t.targetingMe = false
        end
        t.onPet = S.pet and Get(UnitIsUnit, "targettarget", "pet") or false
        local th, tm = HealthOf("target")
        if th then t.hp = th / tm * 100 end
        -- wirkt das Ziel etwas, und ist es unterbrechbar (ein geheimer Name heisst: es wird
        -- etwas gewirkt; erst auf Secret pruefen, dann vergleichen)
        local castName, _, _, _, _, _, _, notInt = UnitCastingInfo("target")
        local casting = (issecret and issecret(castName)) or castName ~= nil
        if not casting then
            castName, _, _, _, _, _, notInt = UnitChannelInfo("target")
            casting = (issecret and issecret(castName)) or castName ~= nil
        end
        if casting then
            t.casting = true
            t.interruptible = (Plain(notInt) ~= true)
        end
        t.melee = rangeSpell and Get(C_Spell.IsSpellInRange, rangeSpell, "target")
        -- Fernkaempfer mit Nahkampfzaubern (Jaeger): steht das Ziel in Nahkampfreichweite?
        for _, k in ipairs(resolve(C.meleeSpell) or EMPTY) do
            if SP[k] and SP[k].id then
                t.close = Get(C_Spell.IsSpellInRange, SP[k].id, "target")
                break
            end
        end
        if t.melee == false and S.inCombat then
            outOfRangeSince = outOfRangeSince or now
            t.farFor = now - outOfRangeSince
        else
            outOfRangeSince = nil
        end
        local tanking, _, pct = Call(UnitDetailedThreatSituation, "player", "target")
        S.threatTanking, S.threatPct = Plain(tanking), Plain(pct)

        -- Restlebenszeit: gelernt, sonst nach Rang des Gegners geschaetzt
        if S.inCombat and not engage.start then
            engage.start, engage.key, engage.guid = now, KillKey(t, S.level, S.group), t.guid
        end
        local killKey = (S.inCombat and engage.key) or KillKey(t, S.level, S.group)
        S.killId = (NM.classToken or "?") .. ":" .. killKey
        local ttd
        if S.inCombat then ttd = LearnedTTD(now) else ttd = LearnedTTD(now, killKey) end
        if ttd then
            -- genauer: was Gegner dieser Art aushalten, minus was dieses Ziel schon bekommen hat
            local kills = NM.adb.kills
            local k = type(kills) == "table" and kills[S.killId]
            local byDamage = NM.Model and k and NM.Model:TTD(S.killId, S.inCombat and t.guid or nil,
                S.inCombat and engage.start and (now - engage.start) or nil, k.avg)
            if byDamage then ttd = (ttd + byDamage) / 2; S.ttdByDamage = byDamage end
            S.ttd, S.ttdMeasured, S.ttdLearned = ttd, true, true
        else
            local guess = t.boss and 180 or (t.elite and (S.group and 25 or 45)) or (t.player and 25) or 10
            S.ttd = guess
        end
        S.fightTime = engage.start and (now - engage.start) or 0
    else
        outOfRangeSince = nil
    end

    -- Gegner
    local en = ScanEnemies(now, rangeSpell)
    local view = { n = en.n, melee = en.melee, onMe = en.onMe, far = en.far, plates = en.plates }
    if t.valid and S.inCombat then
        -- das Ziel zaehlt immer, auch ohne Namensplaketten
        view.n = max(view.n, 1)
        if t.melee == true then view.melee = max(view.melee, 1) end
        if t.targetingMe then view.onMe = max(view.onMe, 1) end
    end
    S.enemies = view
    -- Flaeche: wie viele Gegner fuer Flaechenzauber zaehlen (Umschalter: auto, single, aoe)
    if db.aoeMode == "single" then
        S.aoe, S.near = min(view.n, 1), min(view.onMe, 1)
    elseif db.aoeMode == "aoe" then
        S.aoe, S.near = max(view.n, 3), max(view.onMe, 3)
    else
        S.aoe, S.near = view.n, max(view.onMe, S.isMelee and view.melee or 0)
    end
    S.notBehind = (self.notBehindUntil or 0) > now
    S.danger, S.dangerGuessed = Danger(S)

    -- die Gruppe: Klassen, Tank, Heiler, wen das Ziel angreift (Party.lua)
    if NM.Party then NM.Party:Snapshot(S) else S.party = EMPTY end
    if NM.Model then NM.Model:Snapshot(S) end
    if C.snapshot then C.snapshot(S, self, now) end

    -- sind Effekte geheim, verraet nur der Start der Abklingzeit, dass einer laeuft
    if self.aurasRestricted and C.cooldownBuffs then
        for _, k in ipairs(C.cooldownBuffs) do
            if SP[k] and SP[k].id then S:cd(k) end
        end
    end

    self.busy = S.inCombat or t.valid or S.stealthed or S.casting
    return S
end

------------------------------------------------------------------------------
-- Mitschreiben der eigenen Zauber (Modell)
------------------------------------------------------------------------------

local function KeyOf(spellID)
    local key = State.byId[spellID]
    if not key then
        local name = Get(C_Spell.GetSpellName, spellID)
        key = name and State.byName[name]
    end
    return key
end

local function OnCast(unit, _, spellID)
    local u = Plain(unit)
    if u ~= nil and u ~= "player" then return end
    spellID = Plain(spellID)
    -- fuer die Probe: kam das Ereignis lesbar an (u/s) oder geheim (U/S)
    State.castEvent = (u and "u" or "U") .. (spellID and "s" or "S")
    State.castSecret = (spellID == nil)
    if not (u and spellID) then return end
    local key = KeyOf(spellID)
    if not key then return end
    local now = GetTime()
    -- die Combopunkte von kurz vor dem Wirken (das Ereignis kann nach ihrem Verbrauch kommen)
    local cp = (State.cpLastT and now - State.cpLastT < 1.5) and State.cpLast or State.cpRecent or 0
    local cur = State.cur
    local guid = (cur and cur.key == key) and cur.guid or nil
    ApplyCast(key, now, cp, false, guid)
    if NM.Model then NM.Model:OnCast(key, cp, guid) end
    State.castsSeen = (State.castsSeen or 0) + 1
    if SP[key].fin then State.lastFinisher = now end
    if cur and cur.key == key and not cur.channel then State.cur = nil end
    if NM.Probe then NM.Probe:Log("  cast " .. key .. (NM.class.combo and (" cp" .. cp) or "")) end
end

local function OnCastStart(channel)
    return function(unit, _, spellID)
        if Plain(unit) ~= "player" then return end
        spellID = Plain(spellID)
        local key = spellID and KeyOf(spellID)
        if not key then State.cur = nil; return end
        local d = SP[key]
        local len = channel and (type(d.channel) == "number" and d.channel or 3) or (d.castTime or d.cast)
        State.cur = { key = key, t = GetTime(), len = len, channel = channel, guid = Plain(UnitGUID("target")) }
    end
end

local function OnCastEnd(unit)
    if Plain(unit) == "player" then State.cur = nil end
end

function State:Init()
    NM.classToken = select(2, UnitClass("player"))
    local function mark(what) return function() dirty[what] = true end end
    NM.On("SPELLS_CHANGED", mark("spells"))
    NM.On("LEARNED_SPELL_IN_SKILL_LINE", mark("spells"))
    NM.On("PLAYER_LEVEL_UP", mark("spells"))
    for _, ev in ipairs({ "TRAIT_CONFIG_UPDATED", "PLAYER_TALENT_UPDATE", "ACTIVE_TALENT_GROUP_CHANGED", "TRAIT_TREE_CHANGED" }) do
        NM.On(ev, function() dirty.talents = true; dirty.spells = true end)
    end
    NM.On("UNIT_PET", mark("spells"))
    NM.On("PLAYER_EQUIPMENT_CHANGED", mark("gear"))
    NM.On("BAG_UPDATE_DELAYED", mark("items"))
    NM.On("UNIT_SPELLCAST_SUCCEEDED", OnCast)
    NM.On("UNIT_SPELLCAST_START", OnCastStart(false))
    NM.On("UNIT_SPELLCAST_CHANNEL_START", OnCastStart(true))
    for _, ev in ipairs({ "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_STOP" }) do
        NM.On(ev, OnCastEnd)
    end
    NM.On("UNIT_COMBAT", OnUnitCombat)
    NM.On("PLAYER_STARTED_MOVING", function() State.movingEvent = true end)
    NM.On("PLAYER_STOPPED_MOVING", function() State.movingEvent = false end)
    NM.On("PLAYER_TARGET_CHANGED", function()
        -- ein Ziel, das im Kampf verschwindet, ist in aller Regel gestorben
        if Plain(UnitAffectingCombat("player")) then LearnKill(GetTime()) end
        engage.start = nil
        State.cpEst = 0
        State.targetChanged = true
    end)
    NM.On("PLAYER_REGEN_ENABLED", function()
        LearnKill(GetTime())
        wipe(hitsTaken); wipe(guidModels)
        engage.start = nil
    end)
    NM.On("UI_ERROR_MESSAGE", function(_, msg)
        msg = Plain(msg)
        if msg and msg == SPELL_FAILED_NOT_BEHIND then State.notBehindUntil = GetTime() + 4 end
    end)
    -- Zauber- und Talentdaten sind beim Login nicht sofort vollstaendig
    for _, delay in ipairs({ 2, 6, 15 }) do
        C_Timer.After(delay, function() dirty.spells, dirty.talents, dirty.gear, dirty.items = true, true, true, true end)
    end
end

------------------------------------------------------------------------------
-- Ausgaben fuer /nxm status und /nxm info
------------------------------------------------------------------------------

function State:PrintStatus()
    dirty.spells, dirty.talents, dirty.gear, dirty.items = true, true, true, true
    Refresh()
    local C, p, g = NM.class, self.points, self.gear
    local trees = C.specs or { "1", "2", "3" }
    Print(("%s: %s (%d/%d/%d)%s"):format(T("Skillung", "Talents"), trees[self.spec] or "?", p[1], p[2], p[3],
        self.specKnown and "" or T(" - geschätzt, keine Punkte lesbar", " - guessed, no points readable")))
    local function weapon(isWeapon, isDagger)
        if not isWeapon then return T("keine Waffe", "no weapon") end
        return isDagger and T("Dolch", "dagger") or T("kein Dolch", "not a dagger")
    end
    Print(("%s: %s / %s, %s: %d"):format(T("Waffen", "Weapons"), weapon(g.mhWeapon, g.mhDagger), weapon(g.ohWeapon, g.ohDagger),
        T("Schmuck mit Benutzen-Effekt", "on-use trinkets"), #(g.trinkets or EMPTY)))
    local known, missing = {}, {}
    for _, d in pairs(SP) do
        if not d.foreign and not d.always and d.name then
            if d.id then known[#known + 1] = d.name else missing[#missing + 1] = d.name end
        end
    end
    table.sort(known); table.sort(missing)
    Print(T("Gelernt: ", "Known: ") .. table.concat(known, ", "))
    Print(T("Nicht gelernt: ", "Not known: ") .. table.concat(missing, ", "))
    local tal = {}
    for name, sid in pairs(C.talents or EMPTY) do
        local r = self.talents[sid]
        if r then tal[#tal + 1] = (Get(C_Spell.GetSpellName, sid) or name) .. " " .. r end
    end
    table.sort(tal)
    Print(T("Talente in der Logik: ", "Talents used by the logic: ") .. (#tal > 0 and table.concat(tal, ", ") or "-"))
    local it = {}
    for kind, id in pairs(self.items) do
        if type(id) == "number" and not kind:find("Count$") then
            it[#it + 1] = (Get(C_Item.GetItemNameByID, id) or kind)
        end
    end
    table.sort(it)
    Print(T("Gegenstände: ", "Items: ") .. (#it > 0 and table.concat(it, ", ") or "-"))
    if NM.Consumables then NM.Consumables:Print() end
    NM.Secure:PrintKeys()
end

-- /nxm info <Schluessel | Name | ID | Zauberlink>: was Client und Addon ueber einen Zauber wissen
function State:PrintSpellInfo(query)
    query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local say = function(text) DEFAULT_CHAT_FRAME:AddMessage("  " .. text) end
    -- Link (|Hspell:ID...|h[Name]|h) oder blanke ID
    local id = tonumber(query:match("|[Hh]spell:(%d+)")) or tonumber(query)
    local name = query:match("|h%[(.-)%]|h") or query
    local key
    if id then
        key = State.byId[id]
        if not key then
            for k, def in pairs(SP) do if def.ref == id then key = k; break end end
        end
        local n = Get(C_Spell.GetSpellName, id)
        if not key and n then key = State.byName[n] end
        name = n or name
    else
        local low = name:lower()
        if SP[low] then key = low end
        if not key then
            for k, def in pairs(SP) do
                if def.name and def.name:lower() == low then key = k; break end
            end
        end
        if not key then
            -- ein Zauber ausserhalb der Tabelle: der Client kennt ihn vielleicht beim Namen
            local info = Plain((Call(C_Spell.GetSpellInfo, name)))
            id = type(info) == "table" and Plain(info.spellID) or nil
            if id then name = Plain(info.name) or name end
        end
    end
    local d = key and SP[key]
    if not d and not id then
        local keys = {}
        for k in pairs(SP) do keys[#keys + 1] = k end
        table.sort(keys)
        Print(T("Unbekannt. Möglich sind Zauberlink (Umschalt-Klick), Name, ID oder ein Schlüssel: ",
            "Unknown. Use a spell link (shift-click), a name, an ID or a key: ") .. table.concat(keys, ", "))
        return
    end
    if d then id = (id and not d.id) and id or (d.id or d.ref); name = d.name or name end
    local known = d and d.id and true or (not d and IsPlayerSpell and Get(IsPlayerSpell, id)) or false
    Print(("%s (ID %d)%s"):format(name or "?", id, known and "" or T(" - nicht gelernt", " - not known")))
    local desc = Get(C_Spell.GetSpellDescription, id)
    if desc and desc ~= "" then say(desc) end

    -- Kosten und Zauberzeit
    local cost = d and (d.costNow or d.cost)
    local castTime = d and (d.castTime or d.cast)
    if not d then
        local costs = Plain((Call(C_Spell.GetSpellPowerCost, id)))
        if type(costs) == "table" and type(costs[1]) == "table" then cost = Plain(costs[1].cost) end
        local info = Plain((Call(C_Spell.GetSpellInfo, id)))
        local ct = type(info) == "table" and Plain(info.castTime)
        if type(ct) == "number" then castTime = ct / 1000 end
    end
    -- Abklingzeit: was der Client nennt, was am Charakter beobachtet wurde, was die Tabelle sagt
    local client = State.BaseCooldown(id)
    local parts = {}
    local function fmt(sec) return (sec % 1 == 0) and ("%d s"):format(sec) or ("%.1f s"):format(sec) end
    if client then parts[#parts + 1] = fmt(client) .. T(" (Client)", " (client)") end
    local seen = key and NM.cdb and NM.cdb.cdSeen and NM.cdb.cdSeen[key]
    if seen then parts[#parts + 1] = fmt(seen) .. T(" (beobachtet)", " (observed)") end
    if d and d.cd then parts[#parts + 1] = fmt(d.cd) .. T(" (Tabelle)", " (table)") end
    if #parts == 0 then parts[1] = T("keine", "none") end
    say(("%s: %s, %s: %s s, %s: %s"):format(T("Kosten", "Cost"), tostring(cost or 0),
        T("Zauberzeit", "Cast time"), tostring(castTime or 0), T("Abklingzeit", "Cooldown"), table.concat(parts, ", ")))

    if not d then
        say(T("neXtMove verwendet diesen Zauber nicht.", "neXtMove does not use this spell."))
        return
    end
    -- was das Schadensmodell aus dem Text liest und daraus rechnet
    if NM.Model then
        local read = NM.Model:ProfileText(key)
        if read then
            local value = d.id and NM.Model:ValueText(self:Snapshot(), key)
            say(T("Schaden laut Text: ", "Damage per text: ") .. read .. (value and ("  " .. value) or ""))
        end
    end
    -- was das Addon daraus macht
    local line = T("Schlüssel: ", "Key: ") .. key
    local use = State.CooldownLength(key)
    if use then line = line .. T(", gerechnet wird mit ", ", calculated with ") .. fmt(use) end
    if d.id then
        local left = self:ReadCooldown(key, GetTime())
        line = line .. ", " .. ((left and left > 0.05) and (T("noch ", "remaining ") .. fmt(math.floor(left * 10 + 0.5) / 10)) or T("bereit", "ready"))
    end
    say(line)
    if d.id and NM.Bars then
        local e = NM.Bars:ForSpell(d.id)
        say(e and (T("Leiste: Taste ", "Bar: key ") .. (e.key or T("keine (nur Klick)", "none (click only)")))
            or T("Liegt auf keiner Leiste.", "Not on any bar."))
    end
end
