--[[---------------------------------------------------------------------------
    Classes/Shaman.lua - Schamane (Elementar, Verstaerkung, Wiederherstellung)

    Herkunft der Regeln: mod-playerbots, src/Ai/Class/Shaman/Strategy/:

      Bot (Strategie: Ausloeser -> Aktion, Prioritaet)             hier
      ele:  flame shock 5.3 (fehlt), lava burst 5.2,              ebenso; Kettenblitz ab zwei
            lightning bolt 5.0, chain lightning 5.6 (immer),      Gegnern oder in schweren
            earth shock execute 5.5, elemental mastery 29         Kaempfen (er kostet viel Mana)
      enh:  stormstrike 5.5, earth shock 5.3,                     ebenso; Erdschock als Fueller
            flame shock 19, lightning shield 18.5                 ist abschaltbar
      alle: wind shear 23 (Unterbrechen)                          Erdschock unterbricht (Vanilla)
            low health -> stoneclaw totem 40                      mehrere Angreifer allein
      nc:   Waffenverzauberung 22/21, Schild 20/21                ebenso
      Totems: je Element eines, 55; call of the elements 60       je Element eines, wenn der
                                                                  Kampf es lohnt (Einstellung)
      aoe:  medium aoe -> fire nova 23, magma                     ebenso
      resto/healer dps: flame shock, lightning bolt               Heiler: nur Schaden und Pflege

    Was es in WoW Forever nicht gibt und deshalb entfaellt: Windstoss, Donnersturm,
    Lavapeitsche, Wildgeist, Schamanistische Wut, Heldentum/Kampfrausch, Feuerelementar,
    Totem des Ingrimms, Totem des stuermischen Zorns, Erdschild, Geistlaeuterung.
    Waffe des Mahlstroms ist ein Buff mit Stapeln und im Kampf nicht lesbar - sie fehlt.

    Totems: Der Client sagt je Element, ob ein Totem steht (GetTotemInfo); sonst gilt, was
    zuletzt gestellt wurde. Welche Totems gestellt werden, richtet sich nach dem Baum.
-----------------------------------------------------------------------------]]

local _, NM = ...
if select(2, UnitClass("player")) ~= "SHAMAN" then return end
local T, Get, Call, Plain = NM.T, NM.Get, NM.Call, NM.Plain
local Common = NM.Common

local SP = {
    -- Schaden
    lightningbolt  = { ref = 529,     cast = 2.5 },
    chainlightning = { ref = 421,     cast = 2.5, cd = 6, aoe = 3 },
    earthshock     = { ref = 8042,    cd = 6, interrupts = true },
    flameshock     = { ref = 8050,    cd = 6, dur = 12, unit = "target", dot = true },
    frostshock     = { ref = 8056,    cd = 6, dur = 8, unit = "target", slow = 0.5 },
    stormstrike    = { ref = 17364,   cd = 20 },
    lavaburst      = { ref = 408490,  cast = 2, cd = 8 },
    firenova       = { ref = 408341,  cd = 10, aoe = true },
    -- Buffs, Schilde, Waffen
    lightningshield = { ref = 324,    dur = 600, unit = "player" },
    watershield    = { ref = 408510,  dur = 600, unit = "player" },
    rockbiter      = { ref = 8017,    once = true },
    flametongue    = { ref = 8024,    once = true },
    frostbrand     = { ref = 8033,    once = true },
    windfury       = { ref = 8232,    once = true },
    elementalmastery = { ref = 16166, cd = 180, offgcd = true },
    naturesswiftness = { ref = 16188, cd = 180, offgcd = true },
    -- Heilung und Pflege
    healingwave    = { ref = 332,     cast = 3 },
    lesserwave     = { ref = 8004,    cast = 1.5 },
    riptide        = { ref = 1239242, cd = 6 },
    purge          = { ref = 370 },
    curepoison     = { ref = 526 },
    curedisease    = { ref = 2870 },
    ghostwolf      = { ref = 2645,    cast = 3 },
    -- Totems (element: immer nur eines je Element)
    strength       = { ref = 8075,    dur = 120, unit = "player", element = "earth" },
    stoneskin      = { ref = 8071,    dur = 120, unit = "player", element = "earth" },
    stoneclaw      = { ref = 5730,    dur = 15, cd = 30, unit = "player", element = "earth" },
    earthbind      = { ref = 2484,    dur = 45, cd = 15, unit = "player", element = "earth" },
    tremor         = { ref = 8143,    dur = 120, unit = "player", element = "earth" },
    searing        = { ref = 3599,    dur = 40, unit = "player", element = "fire" },
    magma          = { ref = 8190,    dur = 20, unit = "player", element = "fire" },
    flametonguetotem = { ref = 8227,  dur = 120, unit = "player", element = "fire" },
    healingstream  = { ref = 5394,    dur = 60, unit = "player", element = "water" },
    manaspring     = { ref = 5675,    dur = 60, unit = "player", element = "water" },
    manatide       = { ref = 17354,   dur = 12, cd = 300, unit = "player", element = "water" },
    windfurytotem  = { ref = 8512,    dur = 120, unit = "player", element = "air" },
    graceofair     = { ref = 8835,    dur = 120, unit = "player", element = "air" },
    grounding      = { ref = 8177,    dur = 45, cd = 15, unit = "player", element = "air" },
    callofelements = { ref = 66842,   once = true },
    totemicrecall  = { ref = 36936,   once = true },
}

local TALENT = {
    stormstrike = 17364, waterShield = 408510, maelstrom = 408498, manaTide = 16190,
    riptide = 408521, naturesSwiftness = 16188, elementalFocus = 16164,
}

local ELEMENTS = { "fire", "earth", "water", "air" }        -- Reihenfolge der Totemplaetze des Clients
local SLOT_OF = { fire = 1, earth = 2, water = 3, air = 4 }

-- Totems je Baum und Element, das erste gelernte gewinnt
local TOTEM_SET = {
    [1] = { earth = { "stoneskin", "strength" }, fire = { "searing" }, water = { "manaspring", "healingstream" } },
    [2] = { earth = { "strength", "stoneskin" }, fire = { "searing" }, water = { "manaspring", "healingstream" },
            air = { "windfurytotem", "graceofair" } },
    [3] = { earth = { "stoneskin", "strength" }, fire = { "searing" }, water = { "manaspring", "healingstream" } },
}

-- Totems nach Gruppe: Nahkaempfer (Krieger, Schurken, man selbst als Verstaerker) bekommen
-- Staerke der Erde und Windzorn, sonst zaehlt Steinhaut; Jaeger allein die Anmut der Luft.
local partySets = {}
local function TotemSet(S)
    local base = TOTEM_SET[S.spec] or TOTEM_SET[1]
    local P = S.party
    if P.n == 0 then return base end
    local melee = P.melee > 0 or S.spec == 2
    local hunters = P.class.HUNTER > 0
    local sig = S.spec .. (melee and "m" or "") .. (hunters and "h" or "")
    local set = partySets[sig]
    if not set then
        set = { fire = base.fire, water = base.water }
        set.earth = melee and { "strength", "stoneskin" } or { "stoneskin", "strength" }
        if melee then set.air = { "windfurytotem", "graceofair" }
        elseif hunters then set.air = { "graceofair" }
        else set.air = base.air end
        partySets[sig] = set
    end
    return set
end

local function Rules(S, add)
    local db = NM.db
    local t, en, g = S.target, S.enemies, S.gear
    local valid, ttd, danger = t.valid, S.ttd, S.danger
    local big = Common.Big(S)
    local dying = valid and S.ttdMeasured and ttd <= 3 or false
    local melee = (S.spec == 2)

    local function R(k) return S:ready(k) end
    local function has(k) return S:aura(k) > 0 end

    local _, noMana = S:usable("lightningbolt")
    local oom = noMana == true or false

    -------------------------------------------------------------- vor dem Kampf
    if not S.inCombat then
        -- Waffenverzauberung nach Baum
        if g.mhWeapon and not S.mhImbue then
            local order = melee and { "windfury", "flametongue", "rockbiter" } or { "flametongue", "rockbiter" }
            for _, k in ipairs(order) do
                if S:known(k) and not S.used[k] then add(k, 22, T("Waffe ist nicht verzaubert", "Weapon has no imbue")); break end
            end
        end
        if S.totemsOut and not valid and db.useRecall and S:known("totemicrecall") and not S.used.totemicrecall then
            add("totemicrecall", 12, T("Totems zurückrufen (Mana zurück)", "Recall the totems (mana back)"))
        end
    end
    -- Schild: Wasserschild fuer Zauberer und Heiler, sonst Blitzschlagschild
    local shield = (not melee and S:known("watershield")) and "watershield" or "lightningshield"
    if S:known(shield) and not has("watershield") and not has("lightningshield") and not S.used[shield] then
        add(shield, S.inCombat and 18.5 or 20, T("Schild fehlt", "Shield is missing"))
    end

    -------------------------------------------------------------- Notfall (Reaktionen)
    if S.inCombat then
        Common.Heal(S, add, 62)
        if S.lowHealth and not S.moving then
            local heal = S:known("lesserwave") and "lesserwave" or "healingwave"
            if S:known(heal) then
                add(heal, 61, T("Gesundheit niedrig: dich heilen", "Low health: heal yourself"), { react = true })
            end
        end
        -- (in einer Gruppe ohne Tank lenkt das Totem genauso ab wie allein)
        if (not S.group or (S.party.n > 0 and not S.party.tankLikely)) and (en.onMe >= 2 or danger >= 2)
           and not S.totems.earthIsStoneclaw and R("stoneclaw") then
            add("stoneclaw", 40, T("Mehrere Angreifer: Steinklauentotem lenkt sie ab", "Several attackers: Stoneclaw Totem distracts them"), { react = true })
        end
    end

    if not valid then return end

    -------------------------------------------------------------- Unterbrechen
    if t.casting and t.interruptible ~= false and R("earthshock") then
        add("earthshock", 42, T("Ziel wirkt: Erdschock unterbricht", "Target is casting: Earth Shock interrupts"), { react = true })
    end

    -------------------------------------------------------------- Mana
    if oom then
        if R("manatide") then add("manatide", 25, T("Mana leer: Totem der Manaflut", "Out of mana: Mana Tide Totem")) end
        Common.Mana(S, add, 24.5)
    end

    -------------------------------------------------------------- Totems
    local worth = db.totems == "always" or (db.totems == "auto" and (S.group or big or ttd >= 20))
    if worth and S.inCombat and not S.moving then
        local set = TotemSet(S)
        local missing, first = 0, nil
        for _, el in ipairs(ELEMENTS) do
            if S.totems[el] == false and set[el] then
                for _, k in ipairs(set[el]) do
                    if S:known(k) and not S.used[k] then
                        missing = missing + 1
                        first = first or k
                        break
                    end
                end
            end
        end
        if missing >= 2 and S:known("callofelements") and not S.used.callofelements then
            add("callofelements", 25, T("Mehrere Totems fehlen: Ruf der Elemente", "Several totems are missing: Call of the Elements"))
        elseif first then
            add(first, 24, T("Totem fehlt", "A totem is missing"))
        end
    end
    -- Flaeche: Magmatotem und Feuernova, wenn die Gegner an einem stehen
    if S.near >= 3 then
        if S:known("magma") and not has("magma") and not S.used.magma then
            add("magma", 23.5, T("Mehrere Gegner an dir: Totem der glühenden Magma", "Several enemies on you: Magma Totem"))
        end
        if S.totems.fire and R("firenova") then
            add("firenova", 23, T("Mehrere Gegner an dir: Feuernova", "Several enemies on you: Fire Nova"))
        end
    end

    -------------------------------------------------------------- Abklingzeiten
    if big and S.inCombat then
        if R("elementalmastery") then add("elementalmastery", 29, T("Schwerer Kampf: Elementarbeherrschung", "Hard fight: Elemental Mastery")) end
        Common.Trinkets(S, add, 18.6)
    end

    -------------------------------------------------------------- Rotation
    if S:known("flameshock") and not has("flameshock") and ttd >= 8 and R("flameshock") then
        add("flameshock", melee and 19 or 5.3, T("Flammenschock fehlt", "Flame Shock is missing"))
    end
    if melee then
        if R("stormstrike") then add("stormstrike", 5.5, T("Sturmschlag bereit", "Stormstrike ready")) end
        -- Erdschock als Fueller kostet viel Mana: erst mit Sturmschlag oder in schweren Kaempfen
        if db.shockFiller and (S:known("stormstrike") or big) and R("earthshock") then
            add("earthshock", 5.3, T("Erdschock als Füller", "Earth Shock as a filler"))
        end
        -- Eroeffnung aus der Ferne, solange der Gegner nicht bei einem ist
        if not S.inCombat and t.close ~= true and S:known("lightningbolt") then
            add("lightningbolt", 5.2, T("Eröffnung aus der Ferne: Blitzschlag", "Opener from range: Lightning Bolt"))
        end
    else
        if R("chainlightning") and (S.aoe >= 2 or big) then
            add("chainlightning", S.aoe >= 2 and 22 or 5.6, T("Kettenblitz bereit", "Chain Lightning ready"))
        end
        if has("flameshock") and R("lavaburst") then
            add("lavaburst", 5.2, T("Flammenschock läuft: Lavaeruption", "Flame Shock is up: Lava Burst"))
        end
        add("lightningbolt", 5.0, T("Hauptzauber", "Main spell"))
        -- der Gegner kommt auf dich zu: Frostschock haelt ihn laenger auf Abstand (Wert: Model.lua)
        if S.eta and (S.kitePenalty or 0) > 0 and not has("frostshock") and R("frostshock") then
            add("frostshock", 5.1, T("Ziel kommt auf dich zu: Frostschock", "Target is coming for you: Frost Shock"))
        end
        if (dying or S.moving) and R("earthshock") then
            add("earthshock", 5.5, dying and T("Ziel stirbt gleich: Erdschock", "Target is about to die: Earth Shock")
                or T("In Bewegung: Erdschock", "Moving: Earth Shock"))
        end
    end
end

local function Slots(S, H)
    local items = S.items
    local L = {}
    L.interrupt = { H.spell(H.known("earthshock") and "earthshock" or nil) }
    L.stun = { H.spell(H.pick({ "earthbind", "frostshock", "stoneclaw" })) }
    L.buff = { H.spell(H.pick({ "elementalmastery", "naturesswiftness", "callofelements", "lightningshield" })) }
    L.debuff = { H.spell(H.pick({ "purge", "frostshock", "flameshock" })) }
    L.heal = { H.item(items.healthstone or items.potion) or H.spell(H.pick({ "lesserwave", "healingwave" })) }
    L.escape = { H.spell(H.pick({ "ghostwolf", "earthbind", "frostshock" })) }
    L.trinket = { H.trinket() or H.item(items.manapotion) }
    L.defense = { H.spell(H.pick({ "stoneclaw", "grounding", "curepoison", "curedisease", "healingwave" })) }
    return L
end

local function Precheck(S, add)
    if S.gear.mhWeapon and not S.mhImbue and (S:known("rockbiter") or S:known("flametongue")) then
        add(T("Waffenverzauberung", "weapon imbue"))
    end
    if (S:known("lightningshield") or S:known("watershield")) and not S:has("lightningshield") and not S:has("watershield") then
        add(T("Schild", "shield"))
    end
end

NM.RegisterClass("SHAMAN", {
    spells = SP,
    talents = TALENT,
    specs = { T("Elementar", "Elemental"), T("Verstärkung", "Enhancement"), T("Wiederherstellung", "Restoration") },
    defaultSpec = 2,        -- wie die Bots ohne Talente
    power = 0,
    gcd = 1.5,
    melee = false,
    rangeSpell = { "earthshock", "lightningbolt" },
    meleeSpell = { "stormstrike" },
    gcdSpell = { "lightningbolt", "lightningshield", "healingwave", "rockbiter" },
    probeBuff = "lightningshield",
    defaults = {
        totems = "auto",        -- auto | always | never
        shockFiller = true,     -- Erdschock als Fueller (Verstaerkung)
        useRecall = true,       -- Totems nach dem Kampf zurueckrufen
    },
    options = {
        { key = "totems", label = T("Totems stellen", "Place totems"), values = { "auto", "always", "never" },
          format = function(v)
              return (v == "auto" and T("wenn es lohnt", "when worth it")) or (v == "always" and T("immer", "always")) or T("nie", "never")
          end },
    },
    labels = {
        shockFiller = T("Erdschock als Füller (Verstärkung)", "Earth Shock as a filler (Enhancement)"),
        useRecall = T("Totems nach dem Kampf zurückrufen", "Recall totems after combat"),
    },
    cooldowns = { "earthshock", "stormstrike", "chainlightning", "elementalmastery", "naturesswiftness", "stoneclaw", "grounding", "manatide" },

    guessSpec = function(spells, selected)
        if selected then return selected end
        if spells.stormstrike.id then return 2 end
        if spells.watershield.id or spells.manatide.id or spells.riptide.id then return 3 end
        if spells.elementalmastery.id or spells.lavaburst.id then return 1 end
        return 2
    end,

    -- ein neues Totem loest das alte desselben Elements ab
    onCast = function(key, now, State)
        local d = SP[key]
        if d and d.element then
            for k, other in pairs(SP) do
                if k ~= key and other.element == d.element then State.model[k] = nil end
            end
        elseif key == "totemicrecall" then
            for k, other in pairs(SP) do
                if other.element then State.model[k] = nil end
            end
        end
    end,

    snapshot = function(S, State, now)
        local hasMH, _, _, _, hasOH = Call(GetWeaponEnchantInfo)
        S.mhImbue, S.ohImbue = Plain(hasMH) and true or false, Plain(hasOH) and true or false
        -- je Element: steht ein Totem? Der Client sagt es; sonst das zuletzt gestellte
        local totems, out = {}, false
        for _, el in ipairs(ELEMENTS) do
            local have = Get(GetTotemInfo, SLOT_OF[el])
            if have == nil then
                have = false
                for k, d in pairs(SP) do
                    if d.element == el and (State.model[k] or 0) > now then have = true end
                end
            end
            totems[el] = have and true or false
            if totems[el] then out = true end
        end
        totems.earthIsStoneclaw = (State.model.stoneclaw or 0) > now
        S.totems, S.totemsOut = totems, out
    end,

    after = function(S2, c, d, S)
        if d and d.element then
            S2.totems = setmetatable({ [d.element] = true }, { __index = S.totems })
        elseif c.key == "callofelements" then
            S2.totems = { fire = true, earth = true, water = true, air = true }
        elseif c.key == "totemicrecall" then
            S2.totems = { fire = false, earth = false, water = false, air = false }
            S2.totemsOut = false
        end
        if c.key == "rockbiter" or c.key == "flametongue" or c.key == "windfury" or c.key == "frostbrand" then S2.mhImbue = true end
    end,

    -- nach berechnetem Wert geordnet (Model.lua)
    rotation = { { "lightningbolt", "chainlightning", "earthshock", "flameshock", "frostshock", "stormstrike", "lavaburst" } },
    kite = function(S, M)
        if S.spec == 2 then return nil end          -- Verstaerker will in den Nahkampf
        return M.CasterKite(S, M)
    end,
    rules = Rules,
    slots = Slots,
    precheck = Precheck,
})
