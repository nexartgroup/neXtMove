--[[---------------------------------------------------------------------------
    Consumables.lua - Elixiere, Flaeschchen, Bufffood, Rollen und Waffensteine als Move

    Vor dem Kampf zeigt die Anzeige auch Verbrauchsgueter, deren Buff gerade fehlt. Eine feste
    Liste gibt es nicht (welche Gegenstaende Forever kennt, ist offen): die Taschen werden
    gelesen, und was ein Gegenstand tut, steht im Text seines Benutzen-Zaubers.

      Art        woran erkannt                                    wann aktiv
      food       Text nennt "satt" / "well fed"                   Effekt "Satt" laeuft
      weapon     Text nennt die Waffe, Dauer in Minuten            Waffenhand ist verzaubert
      flask      Unterart 3 oder "Fläschchen"/"Flask" im Namen     Effekt mit dem Namen des
      scroll     Unterart 4 oder "Rolle"/"Scroll" im Namen         Benutzen-Zaubers laeuft
      elixir     Unterart 2, sonst: Dauer in Minuten und ein Wert

    Der Text nennt auch die Werte (Beweglichkeit, Intelligenz, ...). Was der Klasse nichts
    bringt, wird nicht vorgeschlagen; von mehreren Gegenstaenden mit denselben Werten zaehlt
    der beste, und laeuft einer davon, ist die Gruppe erledigt.

    Auren sind nur ausserhalb des Kampfes lesbar - dort wird ohnehin gebufft. Ist der Name
    eines Effekts nicht der des Benutzen-Zaubers, wuerde der Vorschlag nie verschwinden:
    darum gilt ein Gegenstand nach dem Benutzen fuer seine Dauer als aktiv, bis sein Effekt
    einmal gesehen wurde (danach zaehlt nur noch der gelesene Effekt).

    Damit die Anzeige nicht draengelt: ein Vorschlag steht hoechstens SHOW Sekunden als
    Move 1 und schweigt dann QUIET Sekunden; im Vor-Kampf-Check bleibt er stehen.

    Rast: Ist das Mana oder die Gesundheit niedrig, wird ausserhalb des Kampfes Trinken oder
    Essen (ersatzweise ein Verband) vorgeschlagen. Beide Werte gibt der Client nicht heraus,
    also wird geschaetzt:
      Mana        eigene Zauber ziehen ihre Kosten ab, die Zeit fuellt auf; der Client sagt je
                  Zauber, ob das Mana reicht - das begrenzt die Schaetzung nach oben und unten
      Gesundheit  jeder eingesteckte Treffer zieht einen Anteil ab (je Charakter gelernt),
                  die Zeit fuellt auf; Blizzards Warnung "niedrige Gesundheit" eicht den Wert

    Zum Auswerten: NextMoveDB.consumables.seen (was in den Taschen erkannt wurde, mit Text)
    und .auras (Namen der eigenen Effekte ausserhalb des Kampfes).
-----------------------------------------------------------------------------]]

local _, NM = ...
local T, Plain, Get, Call = NM.T, NM.Plain, NM.Get, NM.Call

local Cons = {}
NM.Consumables = Cons

local SHOW, QUIET = 20, 300
local QUIET_REST = 90           -- Essen und Trinken melden sich frueher wieder
local EAT_BELOW, DRINK_BELOW = 60, 40      -- geschaetzte Prozent, unter denen gerastet wird
local WARN_AT = 30              -- angenommene Schwelle von Blizzards Warnung "niedrige Gesundheit"
local MIN_BUFF = 300            -- kuerzere Effekte sind Traenke, keine Buffs

-- Werte, die ein Text nennen kann (Reihenfolge = Reihenfolge im Gruppenschluessel)
local STATS = {
    { "agi",   "beweglichkeit", "agility" },
    { "str",   "%f[%a]stärke", "strength" },
    { "ap",    "angriffskraft", "attack power", "körperlichen schaden", "physical damage" },
    { "crit",  "kritisch", "critical" },
    { "haste", "tempo", "haste" },
    { "int",   "intelligenz", "intellect" },
    { "sp",    "zauberschaden", "zaubermacht", "spell damage", "spell power", "heilzauber", "healing done",
               "fire damage", "frost damage", "shadow damage", "arcane damage", "nature damage" },
    { "spi",   "willenskraft", "spirit" },
    { "mana",  "mana" },
    { "sta",   "ausdauer", "stamina" },
    { "armor", "rüstung", "armor" },
    { "hp",    "gesundheit", "health" },
    { "res",   "widerstand", "resistance" },
    { "def",   "verteidigung", "defense" },
}
local PHYSICAL = { agi = true, str = true, ap = true, crit = true, haste = true }
local CASTER = { int = true, sp = true, spi = true, mana = true, crit = true, haste = true }
local ANYONE = { sta = true, armor = true, hp = true, res = true, def = true }
local WANTS = {
    WARRIOR = { PHYSICAL }, ROGUE = { PHYSICAL }, HUNTER = { PHYSICAL },
    MAGE = { CASTER }, WARLOCK = { CASTER }, PRIEST = { CASTER },
    PALADIN = { PHYSICAL, CASTER }, SHAMAN = { PHYSICAL, CASTER }, DRUID = { PHYSICAL, CASTER },
}

-- Waffenarten (Unterart der Waffe): scharf oder stumpf, fuer Wetz- und Gewichtssteine
local SHARP = { [0] = true, [1] = true, [6] = true, [7] = true, [8] = true, [15] = true }
local BLUNT = { [4] = true, [5] = true, [10] = true, [13] = true }

-- Namen des Essens-Buffs und des Essens selbst (deutsch, englisch); dazu die Namen, die der
-- Client fuer bekannte Zauber nennt
local FED_NAMES = { "Satt", "Well Fed", "Wohlgenährt" }
local FED_SPELLS = { 19705, 19706, 19708, 19709, 19710, 19711, 24799, 25661 }
local EATING = { "Essen", "Food" }
local DRINKING = { "Trinken", "Drink" }
local BANDAGED = { "Kürzlich bandagiert", "Recently Bandaged" }
-- Anteil der Gesundheit, den ein Treffer etwa kostet (Startwert; wird je Charakter gelernt)
local HIT = { MAGE = 5, WARLOCK = 5, PRIEST = 5, ROGUE = 4, DRUID = 4, HUNTER = 3.5, SHAMAN = 3.5, WARRIOR = 3, PALADIN = 3 }

local PRIO = { weapon = 17.9, flask = 17.8, elixir = 17.7, scroll = 17.5, food = 17.3 }
local LABEL = {
    weapon = T("Waffe nicht verstärkt", "Weapon not enhanced"), flask = T("Fläschchen fehlt", "Flask is missing"),
    elixir = T("Elixier fehlt", "Elixir is missing"), scroll = T("Rolle fehlt", "Scroll buff is missing"),
    food = T("Essens-Buff fehlt", "Food buff is missing"),
}

local info = {}                 -- je Gegenstand: was er ist (false = kein Buff-Verbrauchsgut)
local groups = {}               -- Gruppenschluessel -> { kind, key, best, list }
local order = {}                -- Gruppen in fester Reihenfolge
local dirty, pendingUntil = true, 0
local counts = {}               -- Gegenstand -> Vorrat beim letzten Lesen
local usedAt = {}               -- Gruppenschluessel -> wann zuletzt benutzt
local restItems = {}            -- Essen, Trinken, Verbaende in den Taschen
local lastRest = {}             -- "eat" / "drink" -> der zuletzt benutzte Gegenstand
local est = { hp = 100 }        -- Schaetzung: hp (Prozent), mana (absolut), t (zuletzt gerechnet)
local shown = {}                -- Gruppenschluessel -> { sum, last, quietUntil }
local db

------------------------------------------------------------------------------
-- Text lesen
------------------------------------------------------------------------------

-- laengste Dauer, die der Text nennt, in Sekunden (nur Minuten und Stunden zaehlen)
local function DurationOf(text)
    local best = 0
    for n, unit in text:gmatch("(%d+)%s*([%a]+)") do
        local s
        if unit:find("^min") then s = tonumber(n) * 60
        elseif unit:find("^std") or unit:find("^stunde") or unit:find("^hour") or unit:find("^hr") then s = tonumber(n) * 3600 end
        if s and s > best then best = s end
    end
    return best
end

local function StatsOf(text)
    local found, n = {}, 0
    for _, s in ipairs(STATS) do
        for i = 2, #s do
            if text:find(s[i]) then found[#found + 1] = s[1]; n = n + 1; break end
        end
    end
    return found, n
end

-- Bringt der Gegenstand der Klasse etwas? Ohne erkannten Wert: ja (er liegt in der Tasche).
local function Useful(stats)
    if #stats == 0 then return true end
    local wants = WANTS[Cons.class or ""] or { PHYSICAL, CASTER }
    for _, s in ipairs(stats) do
        if ANYONE[s] then return true end
        for _, set in ipairs(wants) do if set[s] then return true end end
    end
    return false
end

-- Zahl vor einem der Woerter ("552 Gesundheit"); 1, wenn nur das Wort dasteht; nil ohne Wort
local function Amount(text, ...)
    for i = 1, select("#", ...) do
        local word = select(i, ...)
        if text:find(word) then
            local n = text:match("([%d%.,]+)%s*" .. word)
            n = n and tonumber((n:gsub("[%.,]", "")))
            return (n and n > 0) and n or 1
        end
    end
end

-- Buff-Verbrauchsgut? Setzt kind, stats und bei Waffensteinen edge.
local function Classify(e, text, lname, classID, subID)
    local fed = text:find("%f[%a]satt%f[%A]") or text:find("well fed")
    -- Waffensteine und -oele nennen die Waffe und eine Dauer in Minuten
    local weapon = e.dur >= MIN_BUFF and subID ~= 2 and subID ~= 3 and (text:find("waffe") or text:find("weapon"))
    if fed then
        e.kind = "food"
        e.stats = StatsOf(text:sub(fed))
    elseif weapon then
        e.kind = "weapon"
        e.stats = StatsOf(text)
        if #e.stats == 0 then e.stats = { "ap" } end       -- "erhoeht den Schaden der Waffe"
        if text:find("scharf") or text:find("sharp") or text:find("klinge") or text:find("blade") or text:find("edged") then e.edge = SHARP
        elseif text:find("stumpf") or text:find("blunt") then e.edge = BLUNT end
    elseif classID ~= 0 or subID == 1 or subID == 7 or e.dur < MIN_BUFF then
        return false                                        -- Handwerksware, Trank, Verband, kurzer Effekt
    else
        e.stats = StatsOf(text)
        if subID == 3 or lname:find("fläschchen") or lname:find("flask") then e.kind = "flask"
        elseif subID == 4 or lname:find("^rolle") or lname:find("scroll") then e.kind = "scroll"
        elseif subID == 2 or #e.stats > 0 then e.kind = "elixir"
        else return false end
    end
    return true
end

-- Was ist der Gegenstand? Rueckgabe: Eintrag, false (weder Buff noch Rast) oder nil (Text
-- noch nicht geladen, spaeter noch einmal)
local function Describe(id)
    local _, _, _, _, _, classID, subID = Call(C_Item.GetItemInfoInstant, id)
    classID, subID = Plain(classID), Plain(subID)
    if classID ~= 0 and classID ~= 7 and classID ~= 8 then return false end
    local spellName, spellID = Call(C_Item.GetItemSpell, id)
    spellName, spellID = Plain(spellName), Plain(spellID)
    if not (spellName and spellID) then return false end
    local raw = Get(C_Spell.GetSpellDescription, spellID)
    if type(raw) ~= "string" or raw == "" then return nil end
    local name = Get(C_Item.GetItemNameByID, id)
    if type(name) ~= "string" then return nil end
    local text, lname = raw:lower(), name:lower()
    local _, _, _, itemLevel, minLevel = Call(C_Item.GetItemInfo, id)
    local e = { id = id, name = name, spell = spellName, spellID = spellID, class = classID, sub = subID,
                minLevel = tonumber(Plain(minLevel)) or 0,
                rank = (tonumber(Plain(minLevel)) or 0) * 1000 + (tonumber(Plain(itemLevel)) or 0) }
    e.dur = DurationOf(text)

    -- Rast: Essen und Trinken (im Sitzen) stellen Gesundheit oder Mana wieder her, Verbaende heilen
    if classID == 0 then
        e.restDur = tonumber(text:match("(%d+)%s*sek") or text:match("(%d+)%s*sec"))
        if subID == 7 or lname:find("verband") or lname:find("bandage") then
            e.bandage = Amount(text, "schaden", "damage", "gesundheit", "health") or 1
        elseif subID == 5 or text:find("sitzen") or text:find("seated") then
            e.eat = Amount(text, "gesundheit", "health")
            e.drink = Amount(text, "mana")
        end
    end

    if Classify(e, text, lname, classID, subID) then
        e.useful = Useful(e.stats)
        -- Gruppe: Art und Werte; Gegenstaende derselben Gruppe ersetzen einander
        e.group = (e.kind == "food" or e.kind == "weapon") and e.kind
            or (e.kind .. ":" .. (#e.stats > 0 and table.concat(e.stats, "+") or e.spell))
    end
    if not (e.kind or e.eat or e.drink or e.bandage) then return false, e, raw end
    return e, e, raw
end

-- fuer die Auswertung festhalten, was erkannt wurde
local function Remember(id, e, raw)
    if not (db and e) then return end
    local n = 0
    for _ in pairs(db.seen) do n = n + 1 end
    if n >= 60 and not db.seen[id] then return end
    local rest = (e.eat and (" essen=" .. e.eat) or "") .. (e.drink and (" trinken=" .. e.drink) or "")
        .. (e.bandage and (" verband=" .. e.bandage) or "")
    db.seen[id] = ("%s | %s/%s | %s#%s | %ds | %s%s | %s%s | %s"):format(e.name, tostring(e.class), tostring(e.sub),
        e.spell, tostring(e.spellID), e.dur or 0, e.kind or "-", rest, e.stats and table.concat(e.stats, "+") or "-",
        e.kind and (e.useful and "" or " (nichts für die Klasse)") or "", (raw or ""):sub(1, 160))
end

------------------------------------------------------------------------------
-- Taschen lesen
------------------------------------------------------------------------------

local inFight = false

-- ein Gegenstand wurde benutzt: seine Gruppe und, bei Essen und Trinken, die Rast
function Cons.MarkUsed(e, now)
    if e.group then usedAt[e.group] = now; shown[e.group] = nil end
    for _, what in ipairs({ "eat", "drink", "bandage" }) do
        if e[what] then
            usedAt["rest:" .. what] = now; shown["rest:" .. what] = nil
            lastRest[what] = e
        end
    end
end

local function Scan(now)
    dirty = false
    for k in pairs(groups) do groups[k] = nil end
    for i = #order, 1, -1 do order[i] = nil end
    for i = #restItems, 1, -1 do restItems[i] = nil end
    local C = C_Container
    if not (C and C.GetContainerNumSlots and C.GetContainerItemID) then return end
    local pending = false
    local have = {}
    for bag = 0, 4 do
        local slots = tonumber(Get(C.GetContainerNumSlots, bag)) or 0
        for slot = 1, slots do
            local id = Get(C.GetContainerItemID, bag, slot)
            if type(id) == "number" and not have[id] then
                have[id] = true
                local e = info[id]
                if e == nil then
                    local raw, rec
                    e, rec, raw = Describe(id)
                    if e == nil then pending = true else info[id] = e; Remember(id, rec, raw) end
                end
                if e and (e.eat or e.drink or e.bandage) then restItems[#restItems + 1] = e end
                if e and e.useful then
                    local g = groups[e.group]
                    if not g then
                        g = { key = e.group, kind = e.kind, list = {} }
                        groups[e.group] = g; order[#order + 1] = g
                    end
                    g.list[#g.list + 1] = e
                    if not g.best or e.rank > g.best.rank or (e.rank == g.best.rank and e.id > g.best.id) then g.best = e end
                end
            end
        end
    end
    table.sort(order, function(a, b)
        if PRIO[a.kind] ~= PRIO[b.kind] then return PRIO[a.kind] > PRIO[b.kind] end
        return a.key < b.key
    end)
    -- Der Vorrat ist um eins gesunken: benutzt (der Zauber dazu wird nicht immer gemeldet)
    for id, e in pairs(info) do
        if e then
            local n = have[id] and (tonumber(Get(C_Item.GetItemCount, id)) or 0) or 0
            if counts[id] and n == counts[id] - 1 and not inFight then Cons.MarkUsed(e, now) end
            counts[id] = n
        end
    end
    -- Texte, die der Client noch laedt: bald noch einmal lesen
    if pending then dirty, pendingUntil = true, now + 2 end
end

------------------------------------------------------------------------------
-- Laeuft der Buff schon?
------------------------------------------------------------------------------

-- Effekt auf einem selbst: true / false, oder nil, wenn nicht lesbar (im Kampf)
local function HasAura(name, filter)
    if not (name and C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then return nil end
    local ok, a = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", name, filter or "HELPFUL")
    if not ok or (issecret and issecret(a)) then return nil end
    return a ~= nil
end

local fedNames
local function FedNames()
    if fedNames then return fedNames end
    fedNames = {}
    local have = {}
    local function put(n) if type(n) == "string" and n ~= "" and not have[n] then have[n] = true; fedNames[#fedNames + 1] = n end end
    if db and db.fed then put(db.fed) end
    for _, n in ipairs(FED_NAMES) do put(n) end
    for _, id in ipairs(FED_SPELLS) do put(Get(C_Spell.GetSpellName, id)) end
    return fedNames
end

local function AnyAura(names, filter)
    local readable = false
    for _, n in ipairs(names) do
        local has = HasAura(n, filter)
        if has then return true, n end
        if has == false then readable = true end
    end
    if readable then return false end
    return nil
end

-- Ist die Gruppe erledigt? Gelesener Effekt, sonst (solange der Effekt nie gesehen wurde)
-- die Zeit seit dem Benutzen.
local function Active(S, g)
    local now = S.now
    local seen
    if g.kind == "weapon" then
        local has = Plain((Call(GetWeaponEnchantInfo)))
        if has then return true end
        seen = (has ~= nil)
    elseif g.kind == "food" then
        local has, name = AnyAura(FedNames())
        if has then
            if db and usedAt.food and not db.fedSeen then db.fedSeen, db.fed = true, name end
            return true
        end
        if has == nil then return true end                  -- nicht lesbar: nichts vorschlagen
        seen = db and db.fedSeen
        if AnyAura(EATING) then return true end             -- isst gerade
    else
        local readable = false
        for _, e in ipairs(g.list) do
            local has = HasAura(e.spell)
            if has then
                if db then db.auraSeen[e.spell] = true end
                return true
            end
            if has == false then readable = true end
        end
        if not readable then return true end
        seen = db and db.auraSeen[g.best.spell]
    end
    local used = usedAt[g.key]
    if used and not seen then
        local dur = (g.best.dur and g.best.dur > 0) and g.best.dur or 1800
        if now - used < dur then return true end
    elseif used and now - used < 12 then
        return true                                         -- eben benutzt (Essen dauert zehn Sekunden)
    end
    return false
end

-- Der beste Waffenstein, der zur Waffe in der Waffenhand passt (scharf, stumpf oder beliebig)
local function WeaponItem(S, g)
    local gear = S.gear
    if not (gear and gear.mhWeapon and gear.mhID) then return nil end
    local _, _, _, _, _, _, subID = Call(C_Item.GetItemInfoInstant, gear.mhID)
    subID = Plain(subID) or -1
    local best
    for _, e in ipairs(g.list) do
        if (not e.edge or e.edge[subID]) and (not best or e.rank > best.rank or (e.rank == best.rank and e.id > best.id)) then best = e end
    end
    return best
end

------------------------------------------------------------------------------
-- "Ein mächtigerer Zauber ist bereits aktiv"
--
-- Manche Buffs schliessen einander aus (im Spiel gemessen: ein Elixier wurde vorgeschlagen,
-- der Client lehnte es mit dieser Meldung ab). Welche das sind, sagt der Client vorher nicht.
-- Deshalb lernt das Addon aus der Meldung: es merkt sich, welche Effekte in dem Moment
-- liefen, und schlaegt den Gegenstand nicht mehr vor, solange sie alle laufen. Kommt die
-- Meldung spaeter noch einmal, bleibt nur uebrig, was beide Male lief - bis der wahre
-- Verursacher feststeht.
------------------------------------------------------------------------------

local bouncedUntil = {}         -- [Gruppe] = Zeit: gesperrt, wenn sich nichts merken liess
local try = {}                  -- letzter Versuch, ein Verbrauchsgut zu benutzen: e, t, how
local bounceAt                  -- Meldung kam, der Versuch dazu ist noch nicht bekannt

local function Contains(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

-- laufende eigene Effekte: alle, und die mit einem Wert, den auch der Gegenstand gibt
local function Blockers(e)
    local all, near, nAll, nNear = {}, {}, 0, 0
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return all, near, 0, 0 end
    for i = 1, 40 do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok or type(a) ~= "table" or (issecret and issecret(a)) then break end
        local name, id, dur = Plain(a.name), Plain(a.spellId), tonumber(Plain(a.duration))
        -- kurze Effekte (Essen, Trinken, Ausloeser) sperren keinen Buff von einer halben Stunde
        if type(name) == "string" and name ~= e.spell and not (dur and dur > 0 and dur < 60) then
            if not all[name] then all[name] = true; nAll = nAll + 1 end
            local text = id and Get(C_Spell.GetSpellDescription, id)
            if type(text) == "string" and e.stats and not near[name] then
                for _, st in ipairs(StatsOf(text:lower())) do
                    if Contains(e.stats, st) then near[name] = true; nNear = nNear + 1; break end
                end
            end
        end
    end
    return all, near, nAll, nNear
end

local function Learn(e, how)
    local now = GetTime()
    try.e, bounceAt = nil, nil
    if not (db and e.group) then return end
    local all, near, nAll, nNear = Blockers(e)
    local set
    local old = db.bounce[e.spell]
    if old then
        -- was beim letzten Mal lief und jetzt wieder
        local n = 0
        set = {}
        for name in pairs(old) do if all[name] then set[name] = true; n = n + 1 end end
        if n == 0 then set = nil end
    end
    if not set then
        if nNear > 0 then set = near elseif nAll > 0 then set = all end
    end
    if set then
        local n = 0
        for _ in pairs(db.bounce) do n = n + 1 end
        if n < 60 or old then db.bounce[e.spell] = set end
    end
    -- fuer diese Sitzung in jedem Fall Ruhe, bis sich an den Effekten etwas aendern konnte
    bouncedUntil[e.group] = now + (set and 60 or 1800)
    local names = {}
    for name in pairs(set or {}) do names[#names + 1] = name end
    table.sort(names)
    db.bounceLog = db.bounceLog or {}
    table.insert(db.bounceLog, 1, ("%s (%s): %s"):format(e.name, how or "?", #names > 0 and table.concat(names, ", ") or "-"))
    db.bounceLog[9] = nil
    shown[e.group] = nil
    missingAt = -1
end

-- gilt die Sperre gerade? (alle gemerkten Effekte laufen)
local function Bounced(S, g, e)
    local u = bouncedUntil[g.key]
    if u then
        if S.now < u then return true end
        bouncedUntil[g.key] = nil
    end
    local set = db and db.bounce and e and db.bounce[e.spell]
    if not set then return false end
    local n = 0
    for name in pairs(set) do
        if HasAura(name) ~= true then return false end
        n = n + 1
    end
    return n > 0
end

-- jemand versucht, einen Gegenstand zu benutzen (Klick auf das Symbol, Tasche, Leiste)
function Cons.Tried(itemID, how)
    local e = itemID and info[itemID]
    if not (e and e.group) then return end
    try.e, try.t, try.how = e, GetTime(), how
    if bounceAt and try.t - bounceAt < 1 then Learn(e, how) end
end

-- ein eigener Zauber schlug fehl: war es der Benutzen-Zauber eines Verbrauchsguts?
local function OnFail(unit, _, spellID)
    if Plain(unit) ~= "player" then return end
    spellID = Plain(spellID)
    if not spellID then return end
    for _, e in pairs(info) do
        if e and e.group and e.spellID == spellID then Cons.Tried(e.id, "fail"); return end
    end
    try.e = nil                                             -- ein anderer Zauber: nicht unser Fall
end

-- die Meldung des Clients
local function OnError(_, message)
    message = Plain(message)
    if type(message) ~= "string" or message ~= SPELL_FAILED_AURA_BOUNCED then return end
    local now = GetTime()
    if try.e and now - (try.t or 0) < 3 then Learn(try.e, try.how) else bounceAt = now end
end

------------------------------------------------------------------------------
-- Regeln
------------------------------------------------------------------------------

local function Mode() return NM.db and NM.db.consumables or "always" end

-- Lage, in der ueberhaupt gebufft wird
local function Calm(S)
    if S.inCombat or S.stealthed then return false end
    if Get(IsMounted) or Get(UnitOnTaxi, "player") or Get(UnitIsDeadOrGhost, "player") then return false end
    return true
end

-- schwere Lage: Gruppe, Instanz oder ein Elite- oder Bossgegner im Ziel
local function Hard(S)
    local t = S.target
    if S.group or (S.party and S.party.n and S.party.n > 0) then return true end
    if Get(IsInInstance) then return true end
    return t and t.valid and (t.elite or t.boss) and true or false
end

-- ruft fn(g, e) fuer jede Gruppe, deren Buff jetzt sinnvoll waere. Die Vorschau der Engine
-- fragt im selben Takt mehrmals: das Ergebnis gilt fuer den Takt.
local missing, missingAt = {}, -1
local function Each(S, fn)
    if S.now == missingAt then
        for i = 1, #missing do fn(missing[i], missing[i].pick) end
        return
    end
    missingAt = S.now
    for i = #missing, 1, -1 do missing[i] = nil end
    if Mode() == "off" or not Calm(S) then return end
    if dirty and S.now >= pendingUntil then Scan(S.now) end
    if #order == 0 then return end
    local mode, hard = Mode(), nil
    for _, g in ipairs(order) do
        local e = g.best
        local ok = true
        -- Flaeschchen nur fuer Schweres; im sparsamen Modus alles ausser Essen
        if g.kind == "flask" or (mode == "hard" and g.kind ~= "food") then
            if hard == nil then hard = Hard(S) end
            ok = hard
        end
        if ok and g.kind == "weapon" then
            -- Schurken vergiften ihre Waffen; Steine nur, wenn sie zur Waffe passen
            e = Cons.class ~= "ROGUE" and WeaponItem(S, g) or nil
            ok = e ~= nil
        end
        if ok and not Active(S, g) and not Bounced(S, g, e) then g.pick = e; missing[#missing + 1] = g; fn(g, e) end
    end
end

------------------------------------------------------------------------------
-- Rast: Mana und Gesundheit schaetzen, Essen und Trinken vorschlagen
------------------------------------------------------------------------------

-- Isst, trinkt oder verbindet man gerade? Gelesener Effekt; solange der nie gesehen wurde,
-- die Zeit seit dem Benutzen.
local REST_AURA = { eat = EATING, drink = DRINKING }
local function Busy(what, now, inCombat)
    local used = usedAt["rest:" .. what]
    if used and now - used < 2.5 then return true end
    local names = REST_AURA[what]
    if names and not inCombat then
        local has = AnyAura(names)
        if has then
            if db and used then db.restSeen[what] = true end
            return true
        end
        if has == false and db and db.restSeen[what] then return false end
    end
    local e = lastRest[what]
    return used and now - used < (e and e.restDur or 20) or false
end

-- Die Schaetzung fortschreiben (jeder Takt, auch im Kampf)
local function Tick(S)
    local now = S.now
    local dt = est.t and math.max(0, now - est.t) or 0
    est.t = now
    local t = S.target
    est.rank = (t and t.valid and ((t.boss and 3) or (t.elite and 2))) or 1

    -- Gesundheit
    if S.hpRead and S.hp then
        est.hp = S.hp
    else
        local rate = 0
        if not S.inCombat then
            rate = 0.6
            if Busy("eat", now) or Busy("bandage", now) then
                local e = lastRest.eat or lastRest.bandage
                local hpMax = tonumber(Get(UnitHealthMax, "player"))
                local amount = e and (e.eat or e.bandage)
                rate = (amount and amount > 1 and hpMax and hpMax > 0 and e.restDur and e.restDur > 0)
                    and (amount / e.restDur / hpMax * 100) or 4
            end
        end
        est.hp = math.min(100, est.hp + rate * dt)
        -- Blizzards Warnung eicht: sie steht, also ist die Gesundheit niedrig; sie steht nicht,
        -- also ist sie es nicht. Lag die Schaetzung weit daneben, lernt der Anteil je Treffer.
        if S.lowHealth then
            if not est.warned and db and est.hp > WARN_AT + 25 then db.hitPct = math.min(15, db.hitPct * 1.25) end
            est.warned = true
            if est.hp > WARN_AT then est.hp = WARN_AT end
        else
            if est.warned == false and est.hp < WARN_AT - 10 and db and not est.eased then
                db.hitPct = math.max(1, db.hitPct * 0.85); est.eased = true
            end
            est.warned = false
            if est.hp < WARN_AT + 1 then est.hp = WARN_AT + 1 end
        end
        if not S.inCombat then est.eased = nil end
    end

    -- Mana
    local pmax = S.powerMax
    if S.powerType == 0 and pmax and pmax > 0 then
        if S.powerRead and S.power then
            est.mana = S.power
        else
            local mana = est.mana or pmax
            local rate
            if not S.inCombat and Busy("drink", now) then
                local e = lastRest.drink
                rate = (e and e.drink and e.drink > 1 and e.restDur and e.restDur > 0) and (e.drink / e.restDur) or pmax / 25
            else
                local base, casting = Call(_G.GetManaRegen)
                base, casting = tonumber(Plain(base)), tonumber(Plain(casting))
                if db and not db.regenRead then db.regenRead = base and ("lesbar %.1f/%.1f"):format(base, casting or 0) or "nicht lesbar" end
                if S.inCombat or (est.lastCast and now - est.lastCast < 5) then rate = casting or 0
                else rate = (base and base > 0) and base or pmax * 0.008 end
            end
            mana = mana + rate * dt
            local lo, hi = S.powerLo or 0, S.powerHi or pmax
            est.mana = math.max(lo, math.min(hi, math.min(pmax, mana)))
        end
        est.manaPct = est.mana / pmax * 100
    else
        est.manaPct = nil                                   -- (Druide in Tiergestalt: Mana gerade nicht zu sehen)
    end
end

-- bestes Essen, Getraenk oder Verband, das die Stufe erlaubt
local function RestItem(S, what, allowBuffFood)
    local level = S.level or 1
    local best
    for _, e in ipairs(restItems) do
        local amount = e[what]
        if amount and e.minLevel <= level and (allowBuffFood or e.kind ~= "food")
           and Get(C_Item.IsUsableItem, e.id) ~= false and S:itemReady(e.id) then
            if not best or amount > best[what] or (amount == best[what] and e.rank > best.rank) then best = e end
        end
    end
    return best
end

-- ruft fn(what, e, why) fuer Essen und Trinken, die jetzt sinnvoll waeren
local function Rest(S, fn)
    if NM.db.useRest == false or not Calm(S) then return end
    if dirty and S.now >= pendingUntil then Scan(S.now) end
    if #restItems == 0 then return end
    local now = S.now
    if (S.lowHealth or est.hp < EAT_BELOW) and not Busy("eat", now) and not Busy("bandage", now) then
        -- Bufffood nur, wenn sein Buff ohnehin fehlt (dann erledigt ein Essen beides)
        local fed = groups.food
        local e = (fed and not Active(S, fed) and fed.best.eat and fed.best) or RestItem(S, "eat")
        local what = "eat"
        if not e and AnyAura(BANDAGED, "HARMFUL") ~= true then e, what = RestItem(S, "bandage"), "bandage" end
        if e then
            fn(what, e, S.lowHealth and T("Gesundheit niedrig", "Low health")
                or T("Gesundheit geschätzt bei ", "Health estimated at ") .. math.floor(est.hp) .. " %")
        end
    end
    if est.manaPct and est.manaPct < DRINK_BELOW and not Busy("drink", now) then
        local e = RestItem(S, "drink", true)
        if e then fn("drink", e, T("Mana geschätzt bei ", "Mana estimated at ") .. math.floor(est.manaPct) .. " %") end
    end
end

local REST_PRIO = { eat = 18.6, bandage = 18.6, drink = 18.5 }

-- Kandidaten fuer die Engine (laeuft nach den Regeln der Klasse)
function Cons:Rules(S, add)
    if not S.sim then Tick(S) end
    Rest(S, function(what, e, why)
        local key = "rest:" .. what
        if S.used[key] then return end
        local st = shown[key]
        if st and st.quietUntil and S.now < st.quietUntil then return end
        add(key, REST_PRIO[what], why .. ": " .. e.name, { kind = "item", item = e.id, consum = key })
    end)
    Each(S, function(g, e)
        local key = "use:" .. g.key
        if S.used[key] or not S:itemReady(e.id) then return end
        if Get(C_Item.IsUsableItem, e.id) == false then return end
        local st = shown[g.key]
        if st and st.quietUntil and S.now < st.quietUntil then return end
        local c = { kind = (g.kind == "weapon") and "poison" or "item", item = e.id, consum = g.key }
        if g.kind == "weapon" then c.slot = 16 end
        add(key, PRIO[g.kind], LABEL[g.kind] .. ": " .. e.name, c)
    end)
end

-- Vor-Kampf-Check: nennt auch, was gerade schweigt
function Cons:Check(S, add)
    Rest(S, function(_, e) add(e.name) end)
    Each(S, function(_, e) add(e.name) end)
end

-- Die Engine meldet, dass ein Verbrauchsgut als Move 1 steht: nach SHOW Sekunden schweigt es
function Cons:Shown(key, now)
    local st = shown[key]
    if not st then st = { sum = 0, last = now }; shown[key] = st end
    if now - st.last < 1.5 then st.sum = st.sum + (now - st.last) end
    st.last = now
    if st.sum >= SHOW then st.sum, st.quietUntil = 0, now + (key:find("^rest:") and QUIET_REST or QUIET) end
end

function Cons:Wake()
    for k in pairs(shown) do shown[k] = nil end
    missingAt = -1
end

------------------------------------------------------------------------------
-- Ereignisse, Auswertung
------------------------------------------------------------------------------

-- ein eigener Zauber: war es der Benutzen-Zauber eines Verbrauchsguts?
local function OnCast(unit, _, spellID)
    if Plain(unit) ~= "player" then return end
    spellID = Plain(spellID)
    if not spellID then return end
    local now = GetTime()
    for _, e in pairs(info) do
        if e and e.spellID == spellID and (counts[e.id] or 0) > 0 then Cons.MarkUsed(e, now); missingAt = -1; return end
    end
    -- ein eigener Zauber kostet Mana (fuer die Schaetzung)
    local key = NM.State.byId and NM.State.byId[spellID]
    local d = key and NM.SPELLS[key]
    if d and est.mana and (d.costType == nil or d.costType == 0) and not d.wand then
        est.mana = math.max(0, est.mana - (d.costNow or d.cost or 0))
    end
    est.lastCast = now
end

-- eingesteckte Treffer und Heilungen (Betraege sind geheim, gezaehlt wird das Ereignis)
local function OnCombat(unit, action)
    if Plain(unit) ~= "player" then return end
    action = Plain(action)
    if action == "WOUND" then
        est.hp = math.max(1, est.hp - (db and db.hitPct or 4) * (est.rank or 1))
        est.hits = (est.hits or 0) + 1
    elseif action == "HEAL" then
        est.hp = math.min(100, est.hp + 6)
    end
end

-- Namen der eigenen Effekte ausserhalb des Kampfes (zum Nachschaerfen der Erkennung)
function Cons:NoteAuras()
    if not (db and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
    for i = 1, 40 do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok or a == nil or (issecret and issecret(a)) or type(a) ~= "table" then break end
        local name, id = Plain(a.name), Plain(a.spellId)
        if type(name) == "string" then
            local n = 0
            for _ in pairs(db.auras) do n = n + 1 end
            if n < 60 or db.auras[name] then db.auras[name] = tonumber(id) or 0 end
        end
    end
end

function Cons:Print()
    local S = NM.State:Snapshot()
    if dirty then Scan(S.now) end
    local names = {}
    for _, g in ipairs(order) do
        local e = g.kind == "weapon" and WeaponItem(S, g) or g.best
        local state = Active(S, g) and T("aktiv", "active")
            or (Bounced(S, g, e) and T("stärkerer Buff aktiv", "stronger buff active")) or T("fehlt", "missing")
        names[#names + 1] = ("%s (%s)"):format(e.name, state)
    end
    NM.Print(T("Verbrauchsgüter zum Buffen: ", "Buff consumables: ") .. (#names > 0 and table.concat(names, ", ") or "-"))
end

function Cons:Init()
    NextMoveDB.consumables = NextMoveDB.consumables or {}
    db = NextMoveDB.consumables
    db.seen, db.auras, db.auraSeen = db.seen or {}, db.auras or {}, db.auraSeen or {}
    db.restSeen = db.restSeen or {}
    db.bounce = db.bounce or {}
    local _, token = UnitClass("player")
    Cons.class = token
    db.hitPct = tonumber(db.hitPct) or HIT[token or ""] or 4
    NM.On("UNIT_COMBAT", OnCombat)
    local function mark() dirty = true; missingAt = -1 end
    NM.On("PLAYER_REGEN_DISABLED", function() inFight = true end)
    -- der Tod nimmt die Buffs: was nur gemerkt war, gilt nicht mehr
    NM.On("PLAYER_DEAD", function() for k in pairs(usedAt) do usedAt[k] = nil end end)
    -- wiederbelebt: Gesundheit und Mana sind niedrig
    NM.On("PLAYER_UNGHOST", function() est.hp = 50; if est.mana then est.mana = est.mana * 0.5 end end)
    NM.On("BAG_UPDATE_DELAYED", mark)
    NM.On("PLAYER_ENTERING_WORLD", function() dirty = true; Cons:Wake() end)
    NM.On("PLAYER_EQUIPMENT_CHANGED", mark)
    NM.On("GROUP_ROSTER_UPDATE", function() Cons:Wake() end)
    NM.On("PLAYER_REGEN_ENABLED", function()
        inFight = false
        if C_Timer then C_Timer.After(2, function() Cons:NoteAuras() end) end
    end)
    NM.On("UNIT_SPELLCAST_SUCCEEDED", OnCast)
    -- "Ein mächtigerer Zauber ist bereits aktiv": welcher Gegenstand war es?
    NM.On("UI_ERROR_MESSAGE", OnError)
    NM.On("UNIT_SPELLCAST_FAILED", OnFail)
    NM.On("UNIT_SPELLCAST_FAILED_QUIET", OnFail)
    if hooksecurefunc then
        -- aus der Tasche oder von einer Leiste benutzt (nur mitlesen, nichts aendern)
        if C_Container and C_Container.UseContainerItem then
            pcall(hooksecurefunc, C_Container, "UseContainerItem", function(bag, slot)
                local id = Get(C_Container.GetContainerItemID, bag, slot)
                if type(id) == "number" then Cons.Tried(id, "bag") end
            end)
        end
        if UseAction and GetActionInfo then
            pcall(hooksecurefunc, "UseAction", function(slot)
                local kind, id = Call(GetActionInfo, slot)
                if Plain(kind) == "item" and type(Plain(id)) == "number" then Cons.Tried(Plain(id), "bar") end
            end)
        end
    end
end

-- (fuer Tests)
Cons.Describe = Describe
function Cons.Reset()
    for k in pairs(info) do info[k] = nil end
    for k in pairs(usedAt) do usedAt[k] = nil end
    for k in pairs(counts) do counts[k] = nil end
    for k in pairs(lastRest) do lastRest[k] = nil end
    est.hp, est.mana, est.t, est.lastCast, est.warned = 100, nil, nil, nil, nil
    for k in pairs(bouncedUntil) do bouncedUntil[k] = nil end
    try.e, bounceAt = nil, nil
    Cons:Wake(); dirty, pendingUntil, fedNames = true, 0, nil
end
Cons.est = est
function Cons.Use(key, now) usedAt[key] = now; missingAt = -1 end
function Cons.Dirty() dirty = true; missingAt = -1 end
