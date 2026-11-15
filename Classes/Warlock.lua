--[[---------------------------------------------------------------------------
    Classes/Warlock.lua - Hexenmeister (Gebrechen, Daemonologie, Zerstoerung)

    Herkunft der Regeln: mod-playerbots, src/Ai/Class/Warlock/Strategy/. Die Bots rechnen
    dort mit eigenen Zahlen (nicht ACTION_*); sie sind hier uebernommen:

      Bot (Strategie: Ausloeser -> Aktion, Prioritaet)             hier
      warlock: low mana -> life tap 95                            Mana reicht nicht mehr fuer
                                                                  den Hauptzauber -> Aderlass
      affli:  corruption 18, unstable affliction 17.5, haunt 16.5 Verderbnis 18, Lebensentzug
              shadow trance -> shadow bolt 16,                    17.5 (statt Instabilem
              target critical health -> drain soul 15.5           Gebrechen), Seelendieb am
                                                                  Kampfende fuer Splitter
      demo:   corruption 18, immolate 17.5, shadow bolt 5.3       ebenso
      destro: immolate 20, conflagrate 19.5,                      ebenso; Schattenbrand am
              target critical health -> shadowburn 18,            Kampfende, Verbrennen ab
              incinerate 5.6, corruption 5.4, shadow bolt 5.2     Stufe 50 als Fueller
      "curse of agony" (affli, demo): 17                          Fluch der Pein (hier "Bane")
      "curse of elements" (destro): 29                            nur in der Gruppe gegen Elite
      aoe: medium aoe (3 Gegner) -> rain of fire 21               ebenso
      nc:  demon armor 27, soul link 28, healthstone 26,          ebenso, dazu der Begleiter
           no pet -> summon 29/30, life tap 23

    Was es in WoW Forever nicht gibt und deshalb entfaellt: Instabiles Gebrechen, Heimsuchung,
    Saat der Verderbnis, Chaosblitz, Metamorphose, Teufelswache, Teufelsruestung, Seele
    brechen, alle Glyphen. Die Bots pruefen bei Flueschen keine Restlebenszeit; hier lohnt ein
    Fluch nur, wenn der Gegner lange genug lebt (gelernte Kampfdauer).

    Mana ist in diesem Client nicht lesbar: "zu wenig Mana" heisst, der Client meldet fuer
    den Hauptzauber "zu wenig Kraft". Die Gesundheit des Ziels ist ebenfalls nicht lesbar:
    "Ziel stirbt gleich" kommt aus der gelernten Kampfdauer.
-----------------------------------------------------------------------------]]

local _, NM = ...
if select(2, UnitClass("player")) ~= "WARLOCK" then return end
local T = NM.T

local SP = {
    -- Schaden
    shadowbolt  = { ref = 695,     cast = 2.5 },
    immolate    = { ref = 348,     cast = 2, dur = 15, unit = "target", dot = true },
    corruption  = { ref = 172,     cast = 2, dur = 18, unit = "target", dot = true },
    agony       = { ref = 980,     dur = 24, unit = "target", dot = true },
    doom        = { ref = 603,     dur = 60, cd = 60, unit = "target", dot = true },
    siphon      = { ref = 18879,   dur = 30, unit = "target", dot = true },
    searing     = { ref = 5676,    cast = 1.5 },
    incinerate  = { ref = 1293812, cast = 2.5 },
    conflagrate = { ref = 1293818, cd = 10 },
    shadowburn  = { ref = 18867,   cd = 15 },
    soulfire    = { ref = 6353,    cast = 6, cd = 60 },
    drainsoul   = { ref = 1120,    channel = 15 },
    drainlife   = { ref = 689,     channel = 5 },
    rainoffire  = { ref = 5740,    channel = 8, aoe = true },
    hellfire    = { ref = 1949,    channel = 15 },
    shoot       = { ref = 5019,    nobar = true, once = true, wand = true },
    -- Flueche
    elements    = { ref = 440892,  dur = 300, unit = "target" },
    weakness    = { ref = 702,     dur = 120, unit = "target" },
    recklessness = { ref = 704,    dur = 120, unit = "target" },
    tongues     = { ref = 1714,    dur = 30, unit = "target" },
    exhaustion  = { ref = 18223,   dur = 12, unit = "target", slow = 0.3 },
    amplify     = { ref = 18288,   cd = 180, offgcd = true },
    -- Kontrolle und Schutz
    fear        = { ref = 5782,    cast = 1.5, dur = 10, unit = "target" },
    howl        = { ref = 5484,    cast = 1.5, cd = 40 },
    deathcoil   = { ref = 6789,    cd = 120 },
    banish      = { ref = 710,     cast = 1.5 },
    shadowward  = { ref = 6229,    cd = 30, dur = 30, unit = "player" },
    healthfunnel = { ref = 755,    channel = 10 },
    spelllock   = { ref = 19244,   cd = 24, pet = true, alt = { 19647 }, interrupts = true, offgcd = true },
    -- Mana, Splitter, Steine
    lifetap     = { ref = 1454 },
    createhs    = { ref = 6201, once = true, craft = true,    cast = 3 },
    createss    = { ref = 693, once = true, craft = true,     cast = 3 },
    -- Buffs und Begleiter
    demonskin   = { ref = 696,     dur = 1800, unit = "player" },
    demonarmor  = { ref = 706,     dur = 1800, unit = "player" },
    soullink    = { ref = 19028,   unit = "player", dur = 9999 },
    feldom      = { ref = 18708,   cd = 900, offgcd = true },
    sacrifice   = { ref = 18788 },
    imp         = { ref = 688, once = true,     cast = 10 },
    voidwalker  = { ref = 697, once = true,     cast = 10 },
    succubus    = { ref = 712, once = true,     cast = 10 },
    felhunter   = { ref = 691, once = true,     cast = 10 },
}

local TALENT = {
    improvedCorruption = 17810, nightfall = 18094, siphonLife = 18265, amplifyCurse = 18288,
    felDomination = 18708, soulLink = 19028, ruin = 17959, shadowburn = 17877,
    conflagrate = 1293817, incinerate = 412758, improvedLifeTap = 18182, pandemic = 427712,
}

local SOUL_SHARD = 6265

local function Rules(S, add)
    local db = NM.db
    local t, en, items = S.target, S.enemies, S.items
    local valid, ttd, danger = t.valid, S.ttd, S.danger
    local shards = items.shardCount or 0
    local big = valid and (t.boss or t.elite or t.player or (S.ttdMeasured and ttd > 30)) or false
    -- das Ziel stirbt gleich (aus der gelernten Kampfdauer; die Gesundheit ist nicht lesbar)
    local dying = valid and S.ttdMeasured and ttd <= 5 or false

    local function R(k) return S:ready(k) end
    local function has(k) return S:aura(k) > 0 end

    -- Hauptzauber je Baum und Stufe
    local filler = "shadowbolt"
    if S.spec == 3 and S:known("incinerate") and has("immolate") then filler = "incinerate" end
    if not S:known(filler) then filler = S:known("shadowbolt") and "shadowbolt" or "immolate" end
    -- der Client meldet fuer den Hauptzauber "zu wenig Kraft"
    local _, noMana = S:usable(filler)
    local oom = noMana == true or (S.powerPct and S.powerPct < 15) or false

    -------------------------------------------------------------- vor dem Kampf
    if not S.inCombat then
        local armor = S:known("demonarmor") and "demonarmor" or "demonskin"
        if not has("demonarmor") and not has("demonskin") and S:known(armor) and not S.used[armor] then
            add(armor, 27, T("Rüstung fehlt", "Armor buff is missing"))
        end
        if not S.pet and db.usePet and not S.casting then
            -- allein tankt der Leerwandler; in der Gruppe der Begleiter des Baums
            local order = S.group and ((S.spec == 3) and { "imp" } or { "felhunter", "succubus", "voidwalker", "imp" })
                or { "voidwalker", "imp" }
            if db.pet ~= "auto" then order = { db.pet, "imp" } end
            for _, k in ipairs(order) do
                if S:known(k) and (k == "imp" or shards > 0) and not S.used[k] then
                    add(k, 29, T("Kein Begleiter", "No pet"))
                    break
                end
            end
        end
        if S.pet and S:known("soullink") and not has("soullink") and not S.used.soullink then
            add("soullink", 28, T("Seelenverbindung fehlt", "Soul Link is missing"))
        end
        if db.useHealthstone and not items.healthstone and shards > 0 and S:known("createhs") and not S.used.createhs then
            add("createhs", 26, T("Kein Gesundheitsstein", "No healthstone"))
        end
        if S.powerPct and S.powerPct < 85 and danger == 0 and not S.lowHealth and R("lifetap") and not valid then
            add("lifetap", 23, T("Mana auffüllen", "Refill mana"))
        end
    end

    -------------------------------------------------------------- Notfall (Reaktionen)
    if S.inCombat then
        if db.usePotions and S.lowHealth then
            if items.healthstone and not S.used.healthstone and S:itemReady(items.healthstone) then
                add("healthstone", 60, T("Gesundheit niedrig: Gesundheitsstein", "Low health: healthstone"),
                    { kind = "item", item = items.healthstone, react = true })
            elseif items.potion and not S.used.potion and S:itemReady(items.potion) then
                add("potion", 59, T("Gesundheit niedrig: Heiltrank", "Low health: healing potion"),
                    { kind = "item", item = items.potion, react = true })
            end
        end
        if valid and S.lowHealth and R("deathcoil") then
            add("deathcoil", 58, T("Gesundheit niedrig: Todesmantel", "Low health: Death Coil"), { react = true })
        end
        if en.onMe >= 3 and R("howl") then
            add("howl", 56, T("Viele Angreifer an dir: Schreckensgeheul", "Many attackers on you: Howl of Terror"), { react = true })
        end
    end

    if not valid then return end

    -------------------------------------------------------------- Unterbrechen (Teufelsjaeger)
    if t.casting and t.interruptible ~= false and S.pet and R("spelllock") then
        add("spelllock", 40, T("Ziel wirkt: Zaubersperre", "Target is casting: Spell Lock"), { react = true })
    end

    -------------------------------------------------------------- Mana
    if oom then
        if danger < 2 and not S.lowHealth and R("lifetap") then
            add("lifetap", 95, T("Mana leer: Aderlass", "Out of mana: Life Tap"))
        elseif S.gear.wand and S:known("shoot") and not S.used.shoot then
            add("shoot", 6, T("Mana leer: Zauberstab", "Out of mana: wand"), { running = S:repeating("shoot") or nil })
        end
    end

    -------------------------------------------------------------- Flaeche
    if S.aoe >= 3 and S:known("rainoffire") then
        add("rainoffire", 21, T("Drei oder mehr Gegner: Feuerregen", "Three or more enemies: Rain of Fire"))
    end

    -------------------------------------------------------------- Kampfende
    if dying then
        if R("shadowburn") and shards > 0 then
            add("shadowburn", 18.5, T("Ziel stirbt gleich: Schattenbrand", "Target is about to die: Shadowburn"))
        end
        if shards < db.shards and S:known("drainsoul") and not t.player then
            add("drainsoul", 15.5, T("Ziel stirbt gleich: Seelensplitter holen", "Target is about to die: get a soul shard"))
        end
    end

    -------------------------------------------------------------- Flueche und Verderbnis
    -- lohnen nur, wenn der Gegner lange genug lebt
    local longEnough = function(seconds) return ttd >= seconds end
    if db.curse ~= "none" then
        local curse = db.curse
        if curse == "auto" then
            -- in der Gruppe der Fluch, von dem die meisten etwas haben: viele Nahkaempfer und
            -- Jaeger -> Tollkuehnheit (weniger Ruestung); Magier oder eigene Feuerzauber ->
            -- Elemente; sonst bleibt es beim eigenen Schadensfluch
            local P = S.party
            curse = nil
            if S.group and big then
                if P.n == 0 then
                    curse = S:known("elements") and "elements" or nil
                elseif P.physical >= 2 and P.physical > P.class.MAGE + P.class.WARLOCK and S:known("recklessness") then
                    curse = "recklessness"
                elseif (P.class.MAGE > 0 or S.spec == 3) and S:known("elements") then
                    curse = "elements"
                end
            end
        end
        if curse and S:known(curse) and not has(curse) and longEnough(15) then
            add(curse, 29, T("Fluch fehlt", "Curse is missing"))
        end
    end
    if S.spec == 3 then
        if not has("immolate") and longEnough(6) then
            add("immolate", 20, T("Feuerbrand fehlt", "Immolate is missing"))
        end
        if has("immolate") and R("conflagrate") then
            add("conflagrate", 19.5, T("Feuersbrunst bereit", "Conflagrate ready"))
        end
        if not has("corruption") and longEnough(12) and big then
            add("corruption", 5.4, T("Verderbnis fehlt", "Corruption is missing"))
        end
    else
        if not has("corruption") and longEnough(8) then
            add("corruption", 18, T("Verderbnis fehlt", "Corruption is missing"))
        end
        if S:known("siphon") and not has("siphon") and longEnough(15) then
            add("siphon", 17.6, T("Lebensentzug fehlt", "Siphon Life is missing"))
        end
        if not has("immolate") and longEnough(6) and (S.spec == 2 or not S:known("agony")) then
            add("immolate", 17.5, T("Feuerbrand fehlt", "Immolate is missing"))
        end
        if S:known("agony") and not has("agony") and not has("doom") and longEnough(12) then
            add("agony", 17, T("Fluch der Pein fehlt", "Bane of Agony is missing"))
        end
    end
    if big and t.boss and R("doom") and not has("doom") and not has("agony") and longEnough(60) then
        add("doom", 17.2, T("Langer Kampf: Fluch der Verdammnis", "Long fight: Bane of Doom"))
    end

    -------------------------------------------------------------- Schutz im Kampf
    if danger >= 2 and S:known("drainlife") and not t.player and t.targetingMe ~= false then
        add("drainlife", 14, T("Viele Treffer: Blutsauger", "Many hits: Drain Life"))
    end

    -------------------------------------------------------------- Fueller
    add(filler, 5.3, T("Hauptzauber", "Main spell"))
    if filler ~= "shadowbolt" then add("shadowbolt", 5.2, T("Hauptzauber", "Main spell")) end
    -- der Zauberstab kostet nichts: bei knappem Mana ist er mehr wert als der Hauptzauber (Model.lua)
    if S.gear.wand and S:known("shoot") and not S.used.shoot and not oom then
        add("shoot", 5.0, T("Zauberstab", "Wand"), { running = S:repeating("shoot") or nil })
    end
    -- der Gegner kommt auf dich zu: Fluch der Erschoepfung haelt ihn laenger auf Abstand
    if S.eta and (S.kitePenalty or 0) > 0 and db.curse == "auto" and S:known("exhaustion") and not has("exhaustion")
       and not has("agony") and not has("doom") then
        add("exhaustion", 5.25, T("Ziel kommt auf dich zu: Fluch der Erschöpfung", "Target is coming for you: Curse of Exhaustion"))
    end
end

local function Slots(S, H)
    local items = S.items
    local L = {}
    L.interrupt = { H.spell(H.known("spelllock") and "spelllock" or nil) }
    L.stun = { H.spell(H.pick({ "fear", "deathcoil" })) }
    L.buff = { H.spell(H.pick({ "amplify", "feldom", "sacrifice", "demonarmor", "demonskin" })) }
    L.debuff = { H.spell(H.pick({ "elements", "weakness", "tongues", "recklessness", "exhaustion" })) }
    L.heal = { H.item(items.healthstone or items.potion) }
    L.escape = { H.spell(H.pick({ "howl", "deathcoil", "fear" })) }
    L.trinket = { H.trinket() or H.item(items.manapotion) }
    L.defense = { H.spell(H.pick({ "shadowward", "drainlife", "healthfunnel" })) }
    return L
end

local function Precheck(S, add)
    local db, items = NM.db, S.items
    local shards = items.shardCount or 0
    if S.level >= 10 and shards == 0 then add(T("Seelensplitter (0)", "soul shards (0)")) end
    if db.usePet and not S.pet then add(T("Begleiter", "pet")) end
    if S:known("demonskin") and not S:has("demonarmor") and not S:has("demonskin") then add(T("Dämonenrüstung", "Demon Armor")) end
    if db.useHealthstone and S:known("createhs") and not items.healthstone then add(T("Gesundheitsstein", "healthstone")) end
    if S.group and S:known("createss") and not items.soulstone then add(T("Seelenstein", "soulstone")) end
end

NM.RegisterClass("WARLOCK", {
    spells = SP,
    talents = TALENT,
    specs = { T("Gebrechen", "Affliction"), T("Dämonologie", "Demonology"), T("Zerstörung", "Destruction") },
    defaultSpec = 2,        -- wie die Bots ohne Talente
    power = 0,
    gcd = 1.5,
    melee = false,
    rangeSpell = { "shadowbolt", "immolate", "corruption" },
    gcdSpell = { "agony", "lifetap", "corruption", "immolate", "shadowbolt" },
    probeBuff = "demonarmor",
    items = {
        shard     = { SOUL_SHARD },
        soulstone = { 16896, 16895, 16893, 16892, 5232 },
    },
    defaults = {
        usePet = true,
        pet = "auto",           -- auto | imp | voidwalker | succubus | felhunter
        curse = "auto",         -- auto | none | elements | weakness | recklessness | tongues
        shards = 3,             -- so viele Seelensplitter haelt Seelendieb vor
        useHealthstone = true,
    },
    options = {
        { key = "pet", label = T("Begleiter", "Pet"), values = { "auto", "imp", "voidwalker", "succubus", "felhunter" } },
        { key = "curse", label = T("Fluch", "Curse"), values = { "auto", "none", "elements", "weakness", "recklessness", "tongues" } },
        { key = "shards", label = T("Seelensplitter vorhalten", "Soul shards to keep"), values = { 0, 1, 3, 5, 10 } },
    },
    labels = {
        usePet = T("Begleiter beschwören", "Summon pet"),
        useHealthstone = T("Gesundheitsstein herstellen", "Create healthstone"),
    },
    cooldowns = { "deathcoil", "howl", "conflagrate", "shadowburn", "soulfire", "amplify", "feldom", "spelllock" },

    guessSpec = function(spells, selected)
        if selected then return selected end
        if spells.conflagrate.id or spells.shadowburn.id then return 3 end
        if spells.siphon.id then return 1 end
        if spells.soullink.id or spells.feldom.id then return 2 end
        return 2
    end,

    duration = function(key, _, State)
        -- Verderbnis haelt je nach Rang 12, 15 oder 18 Sekunden
        if key == "corruption" then
            local level = NM.Get(UnitLevel, "player") or 60
            return (level < 14 and 12) or (level < 24 and 15) or 18
        end
    end,

    after = function(S2, c)
        local k = c.key
        if k == "imp" or k == "voidwalker" or k == "succubus" or k == "felhunter" then S2.pet = true end
    end,

    -- nach berechnetem Wert geordnet (Model.lua)
    rotation = { { "shadowbolt", "immolate", "corruption", "agony", "siphon", "doom", "searing", "incinerate", "conflagrate",
                   "soulfire", "rainoffire", "exhaustion", "shoot" } },
    kite = function(S, M) return M.CasterKite(S, M) end,
    rules = Rules,
    slots = Slots,
    precheck = Precheck,
})
