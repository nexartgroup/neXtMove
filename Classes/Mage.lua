--[[---------------------------------------------------------------------------
    Classes/Mage.lua - Magier (Arkan, Feuer, Frost)

    Herkunft der Regeln: mod-playerbots, src/Ai/Class/Mage/Strategy/. Prioritaeten wie dort
    (ACTION_DEFAULT 5, ACTION_NORMAL 10, ACTION_HIGH 20, ACTION_INTERRUPT 40, EMERGENCY 90):

      Bot (Strategie: Ausloeser -> Aktion, Prioritaet)             hier
      mage:   critical health -> ice block 90                      Blizzards Warnung "niedrige
              low health -> mana shield 85                         Gesundheit" -> Eisblock,
                                                                  viele Treffer -> Manaschild
              enemy is close -> frost nova 50, blink back 35       Gegner schlaegt zu -> Frostnova
              high mana (unter 65 %) -> mana gem 90                Mana reicht nicht mehr fuer
              low mana (unter 15 %) -> evocation 90                den Hauptzauber -> Manastein,
                                                                  Hervorrufung, sonst Zauberstab
              counterspell (bei den Bots nur gegen Heiler) 40      gegen jeden Zauber des Ziels
      arcane: arcane blast 5.6, arcane missiles 5.5,               ebenso; nach vier Arkanschlaegen
              fire blast 5.3, frostbolt 5.2                        Arkane Geschosse
      fire:   improved scorch -> scorch 19, fireball 5.3,          ebenso; Pyroschlag als
              fire blast 5.1; blast wave 40 wenn Gegner nah        Eroeffnung vor dem Kampf
      frost:  frostbolt 5.4, ice lance 5.3, fire blast 5.2;        ebenso; Eislanze auf
              being attacked -> ice barrier 29;                    eingefrorene Ziele (nach
              frost nova on target -> (deep freeze) frostbolt      eigener Frostnova)
      aoe:    medium aoe (3 Gegner) -> flamestrike 23, blizzard 22,   ebenso, dazu Arkane
              light aoe (2) -> cone of cold 21 (Frost)             Explosion, wenn sie an dir sind
      boost:  arcane power 29, combustion 18, cold snap 28        ebenso in schweren Kaempfen
      nc:     arcane intellect 21, Ruestung 19, mana gem 20        ebenso, dazu Wasser und Brot

    Was es in WoW Forever nicht gibt und deshalb entfaellt: Arkanbeschuss, Lebende Bombe,
    Drachenodem, Tiefes Gefrieren, Spiegelbild, Unsichtbarkeit, Eisige Adern, Zauberraub,
    Geschmolzene Ruestung, Wasserelementar. Ausloeser wie Heisse Straehne oder Finger des
    Frosts sind Buffs und im Kampf nicht lesbar - sie fehlen deshalb.

    Mana ist in diesem Client nicht lesbar: "zu wenig Mana" heisst, der Client meldet fuer
    den Hauptzauber "zu wenig Kraft".
-----------------------------------------------------------------------------]]

local _, NM = ...
if select(2, UnitClass("player")) ~= "MAGE" then return end
local T = NM.T

local SP = {
    -- Schaden
    frostbolt   = { ref = 116,     cast = 2.5, dur = 5, unit = "target", slow = 0.4 },
    fireball    = { ref = 143,     cast = 3 },
    fireblast   = { ref = 2136,    cd = 8 },
    scorch      = { ref = 2948,    cast = 1.5 },
    pyroblast   = { ref = 12505, once = true,   cast = 6 },
    arcanemissiles = { ref = 5143, channel = 5 },
    arcaneblast = { ref = 1239696, cast = 2.5 },
    icelance    = { ref = 400640 },
    frostfire   = { ref = 401502,  cast = 3, slow = 0.4 },
    shoot       = { ref = 5019,    nobar = true, once = true, wand = true },
    -- Flaeche
    arcaneexplosion = { ref = 1449, aoe = true },
    flamestrike = { ref = 2120,    cast = 3, dur = 8, unit = "player", aoe = true },
    blizzard    = { ref = 10,      channel = 8, aoe = true },
    coneofcold  = { ref = 120,     cd = 10, aoe = true, slow = 0.5, slowDur = 8 },
    blastwave   = { ref = 13018,   cd = 45, aoe = true },
    -- Kontrolle und Schutz
    frostnova   = { ref = 122,     cd = 25, dur = 8, unit = "target" },
    polymorph   = { ref = 118,     cast = 1.5 },
    counterspell = { ref = 2139,   cd = 30, interrupts = true, offgcd = true },
    blink       = { ref = 1953,    cd = 15 },
    iceblock    = { ref = 11958,   cd = 300, dur = 10, unit = "player" },
    icebarrier  = { ref = 13031,   cd = 30, dur = 60, unit = "player" },
    manashield  = { ref = 1463,    dur = 60, unit = "player" },
    fireward    = { ref = 543,     cd = 30 },
    frostward   = { ref = 6143,    cd = 30 },
    removecurse = { ref = 475 },
    -- Abklingzeiten und Mana
    evocation   = { ref = 12051,   cd = 480, channel = 8 },
    arcanepower = { ref = 12042,   cd = 180, dur = 15, unit = "player", offgcd = true },
    pom         = { ref = 12043,   cd = 180, dur = 30, unit = "player", offgcd = true },
    combustion  = { ref = 11129,   cd = 180, dur = 60, unit = "player", offgcd = true },
    coldsnap    = { ref = 12472,   cd = 600, offgcd = true },
    -- Buffs und Herbeizaubern
    intellect   = { ref = 1459,    dur = 1800, unit = "player" },
    brilliance  = { ref = 23028,   dur = 3600, unit = "player" },
    frostarmor  = { ref = 7300,    dur = 1800, unit = "player" },
    icearmor    = { ref = 7302,    dur = 1800, unit = "player" },
    magearmor   = { ref = 6117,    dur = 1800, unit = "player" },
    conjurewater = { ref = 5504, once = true, craft = true,   cast = 3 },
    conjurefood = { ref = 587, once = true, craft = true,     cast = 3 },
    gemruby     = { ref = 10054, once = true, craft = true,   cast = 3 },
    gemcitrine  = { ref = 10053, once = true, craft = true,   cast = 3 },
    gemjade     = { ref = 3552, once = true, craft = true,    cast = 3 },
    gemagate    = { ref = 759, once = true, craft = true,     cast = 3 },
    -- nur als Name gebraucht
    improvedscorch = { ref = 22959, unit = "target", foreign = true },
}

local TALENT = {
    improvedScorch = 11095, shatter = 11170, fingersOfFrost = 400647, missileBarrage = 400588,
    arcaneBlast = 400574, iceLance = 1312002, heatingUp = 400624, winterChill = 11180,
}

local GEMS = { "gemruby", "gemcitrine", "gemjade", "gemagate" }

-- Arkanschlag-Stapel: als Effekt im Kampf nicht lesbar, also mitgezaehlt
local blastStacks, blastUntil = 0, 0

local function Rules(S, add)
    local db = NM.db
    local t, en, items = S.target, S.enemies, S.items
    local valid, ttd, danger = t.valid, S.ttd, S.danger
    local big = valid and (t.boss or t.elite or t.player or S.aoe >= 3 or (S.ttdMeasured and ttd > 30)) or false
    local dying = valid and S.ttdMeasured and ttd <= 3 or false

    local function R(k) return S:ready(k) end
    local function has(k) return S:aura(k) > 0 end

    -- Hauptzauber je Baum; ohne Talente Frost, wie bei den Bots
    local filler
    if S.spec == 1 then
        filler = S:known("arcaneblast") and "arcaneblast" or (S:known("arcanemissiles") and "arcanemissiles")
    elseif S.spec == 2 then
        filler = S:known("fireball") and "fireball"
    end
    filler = filler or (S:known("frostbolt") and "frostbolt") or "fireball"
    -- der Client meldet fuer den Hauptzauber "zu wenig Kraft"
    local _, noMana = S:usable(filler)
    local oom = noMana == true or (S.powerPct and S.powerPct < 15) or false
    -- der Gegner schlaegt im Nahkampf auf dich ein
    local meleed = S.inCombat and (S.hitRate or 0) >= 0.2 and en.onMe >= 1

    -------------------------------------------------------------- vor dem Kampf
    if not S.inCombat then
        if not has("intellect") and not has("brilliance") and S:known("intellect") and not S.used.intellect then
            add("intellect", 21, T("Arkane Intelligenz fehlt", "Arcane Intellect is missing"))
        end
        if not (has("magearmor") or has("icearmor") or has("frostarmor")) then
            -- allein die Eisruestung (verlangsamt Nahkaempfer), in der Gruppe die Magische Ruestung
            local order = S.group and { "magearmor", "icearmor", "frostarmor" } or { "icearmor", "frostarmor", "magearmor" }
            for _, k in ipairs(order) do
                if S:known(k) and not S.used[k] then add(k, 19, T("Rüstung fehlt", "Armor buff is missing")); break end
            end
        end
        if db.conjure and not valid then
            if not items.managem then
                for _, k in ipairs(GEMS) do
                    if S:known(k) and not S.used[k] then add(k, 20, T("Kein Manastein", "No mana gem")); break end
                end
            end
            if not items.water and S:known("conjurewater") and not S.used.conjurewater then
                add("conjurewater", 18, T("Kein Wasser", "No water"))
            end
            if not items.food and S:known("conjurefood") and not S.used.conjurefood then
                add("conjurefood", 17, T("Kein Brot", "No food"))
            end
        end
        -- Eroeffnung: der lange Pyroschlag lohnt nur vor dem Kampf
        if valid and S:known("pyroblast") and not S.used.pyroblast and t.melee ~= false then
            add("pyroblast", 26, T("Eröffnung aus der Ferne: Pyroschlag", "Opener from range: Pyroblast"))
        end
    end

    -------------------------------------------------------------- Notfall (Reaktionen)
    if S.inCombat then
        if S.lowHealth and R("iceblock") and not has("iceblock") then
            add("iceblock", 90, T("Gesundheit niedrig: Eisblock", "Low health: Ice Block"), { react = true })
        end
        if db.usePotions and S.lowHealth then
            if items.healthstone and not S.used.healthstone and S:itemReady(items.healthstone) then
                add("healthstone", 88, T("Gesundheit niedrig: Gesundheitsstein", "Low health: healthstone"),
                    { kind = "item", item = items.healthstone, react = true })
            elseif items.potion and not S.used.potion and S:itemReady(items.potion) then
                add("potion", 87, T("Gesundheit niedrig: Heiltrank", "Low health: healing potion"),
                    { kind = "item", item = items.potion, react = true })
            end
        end
        if meleed and R("frostnova") and not has("frostnova") then
            add("frostnova", 50, T("Gegner an dir: Frostnova, dann Abstand", "Enemy on you: Frost Nova, then step away"), { react = true })
        end
        -- (keine Reaktion mit Warnton: allein greift das Ziel einen in jedem Kampf an)
        if (danger >= 1 or en.onMe >= 1) and R("icebarrier") and not has("icebarrier") then
            add("icebarrier", 29, T("Du wirst angegriffen: Eisbarriere", "You are under attack: Ice Barrier"))
        elseif danger >= 2 and not S:known("icebarrier") and S:known("manashield") and not has("manashield") and not oom then
            add("manashield", 28, T("Viele Treffer: Manaschild", "Many hits: Mana Shield"), { react = true })
        end
    end

    if not valid then return end

    -------------------------------------------------------------- Unterbrechen
    if t.casting and t.interruptible ~= false and R("counterspell") then
        add("counterspell", 42, T("Ziel wirkt: Gegenzauber", "Target is casting: Counterspell"), { react = true })
    end

    -------------------------------------------------------------- Mana
    if oom then
        if items.managem and not S.used.managem and S:itemReady(items.managem) then
            add("managem", 91, T("Mana leer: Manastein", "Out of mana: mana gem"), { kind = "item", item = items.managem })
        elseif R("evocation") and danger < 2 then
            add("evocation", 90, T("Mana leer: Hervorrufung", "Out of mana: Evocation"))
        elseif db.usePotions and items.manapotion and not S.used.manapotion and S:itemReady(items.manapotion) then
            add("manapotion", 89, T("Mana leer: Manatrank", "Out of mana: mana potion"), { kind = "item", item = items.manapotion })
        elseif S.gear.wand and S:known("shoot") and not S.used.shoot then
            add("shoot", 6, T("Mana leer: Zauberstab", "Out of mana: wand"), { running = S:repeating("shoot") or nil })
        end
    end

    -------------------------------------------------------------- Flaeche
    if S.near >= 3 and S:known("arcaneexplosion") then
        add("arcaneexplosion", 23.5, T("Mehrere Gegner an dir: Arkane Explosion", "Several enemies on you: Arcane Explosion"))
    end
    if S.near >= 1 and meleed and R("blastwave") then
        add("blastwave", 40, T("Gegner an dir: Druckwelle", "Enemy on you: Blast Wave"))
    end
    if S.aoe >= 3 then
        if S:known("flamestrike") and not has("flamestrike") then
            add("flamestrike", 23, T("Drei oder mehr Gegner: Flammenstoß", "Three or more enemies: Flamestrike"))
        end
        if S:known("blizzard") then
            add("blizzard", 22, T("Drei oder mehr Gegner: Blizzard", "Three or more enemies: Blizzard"))
        end
    end
    if S.near >= 2 and R("coneofcold") then
        add("coneofcold", 21, T("Zwei Gegner an dir: Kältekegel", "Two enemies on you: Cone of Cold"))
    end

    -------------------------------------------------------------- Abklingzeiten
    if big and not dying then
        if R("arcanepower") and not has("arcanepower") then add("arcanepower", 29, T("Schwerer Kampf: Arkane Macht", "Hard fight: Arcane Power")) end
        if R("combustion") and not has("combustion") then add("combustion", 18, T("Schwerer Kampf: Verbrennung", "Hard fight: Combustion")) end
        if R("pom") and not has("pom") then add("pom", 17.8, T("Schwerer Kampf: Geistesgegenwart", "Hard fight: Presence of Mind")) end
        if db.useTrinkets and S.gear.trinkets then
            for _, slot in ipairs(S.gear.trinkets) do
                local key = "trinket" .. slot
                if not S.used[key] and S:slotReady(slot) then
                    add(key, 17.5, T("Schwerer Kampf: Schmuckstück benutzen", "Hard fight: use trinket"), { kind = "trinket", slot = slot })
                end
            end
        end
    end
    if R("coldsnap") and S:known("frostnova") and S:cd("frostnova") > 10 and (meleed or S:cd("icebarrier") > 15) then
        add("coldsnap", 28, T("Frostzauber zurücksetzen", "Reset frost spells"))
    end

    -------------------------------------------------------------- Rotation
    -- eingefrorenes Ziel (eigene Frostnova laeuft): Eislanze trifft dann dreifach
    if has("frostnova") and R("icelance") then
        add("icelance", 19, T("Ziel eingefroren: Eislanze", "Target frozen: Ice Lance"))
    end
    -- Verbessertes Versengen auf dem Ziel halten (Feuer, lange Kaempfe)
    if S.spec == 2 and S:talent("improvedScorch") > 0 and big and ttd >= 15
       and S:known("scorch") and not has("improvedscorch") then
        add("scorch", 19, T("Feuerverwundbarkeit fehlt: Versengen", "Fire vulnerability is missing: Scorch"))
    end
    -- nach vier Arkanschlaegen die Arkanen Geschosse
    if S.spec == 1 and S:known("arcaneblast") and S:known("arcanemissiles") then
        local stacks = (S.blastStacks or 0)
        if stacks >= 4 then
            add("arcanemissiles", 15, T("Vier Arkanschläge: Arkane Geschosse", "Four Arcane Blasts: Arcane Missiles"))
        end
    end
    -- Ziel stirbt gleich oder du laeufst: der schnelle Zauber
    if (dying or S.moving) and R("fireblast") then
        add("fireblast", 14, dying and T("Ziel stirbt gleich: Feuerschlag", "Target is about to die: Fire Blast")
            or T("In Bewegung: Feuerschlag", "Moving: Fire Blast"))
    end
    if S.moving and R("icelance") then
        add("icelance", 13.5, T("In Bewegung: Eislanze", "Moving: Ice Lance"))
    end

    add(filler, 5.6, T("Hauptzauber", "Main spell"))
    if filler ~= "arcanemissiles" and S.spec == 1 then add("arcanemissiles", 5.5, T("Hauptzauber", "Main spell")) end
    if S.spec == 3 or filler == "frostbolt" then add("icelance", 5.3, T("Schneller Zauber", "Quick spell")) end
    if filler ~= "frostbolt" then add("frostbolt", 5.2, T("Ersatz für den Hauptzauber", "Fallback for the main spell")) end
    add("fireblast", 5.1, T("Schneller Zauber", "Quick spell"))
    if filler ~= "fireball" then add("fireball", 5.05, T("Ersatz für den Hauptzauber", "Fallback for the main spell")) end
    -- der Zauberstab kostet nichts: bei knappem Mana ist er mehr wert als der Hauptzauber (Model.lua)
    if S.gear.wand and S:known("shoot") and not S.used.shoot and not oom then
        add("shoot", 5.0, T("Zauberstab", "Wand"), { running = S:repeating("shoot") or nil })
    end
end

local function Slots(S, H)
    local items = S.items
    local L = {}
    L.interrupt = { H.spell(H.known("counterspell") and "counterspell" or nil) }
    L.stun = { H.spell(H.pick({ "polymorph", "frostnova" })) }
    L.buff = { H.spell(H.pick({ "arcanepower", "combustion", "pom", "coldsnap", "evocation" })) }
    L.debuff = { H.spell(H.pick({ "frostnova", "coneofcold", "removecurse" })) }
    L.heal = { H.item(items.healthstone or items.potion) }
    L.escape = { H.spell(H.pick({ "blink", "frostnova" })) }
    L.trinket = { H.trinket() or H.item(items.managem or items.manapotion) }
    L.defense = { H.spell(H.pick({ "iceblock", "icebarrier", "manashield" })) }
    return L
end

local function Precheck(S, add)
    local db, items = NM.db, S.items
    if S:known("intellect") and not S:has("intellect") and not S:has("brilliance") then add(T("Arkane Intelligenz", "Arcane Intellect")) end
    -- Gruppe: Intelligenz nur fuer Mitspieler mit Mana
    if S.party.n > 0 and S:known("intellect") then
        NM.Party:Check(add, T("Arkane Intelligenz", "Arcane Intellect"), { "intellect", "brilliance" }, NM.Party.HasMana)
    end
    if (S:known("frostarmor") or S:known("icearmor") or S:known("magearmor"))
       and not (S:has("magearmor") or S:has("icearmor") or S:has("frostarmor")) then
        add(T("Rüstung", "armor"))
    end
    if db.conjure then
        local knowsGem = false
        for _, k in ipairs(GEMS) do if S:known(k) then knowsGem = true end end
        if knowsGem and not items.managem then add(T("Manastein", "mana gem")) end
        if S:known("conjurewater") and not items.water then add(T("Wasser", "water")) end
        if S:known("conjurefood") and not items.food then add(T("Brot", "food")) end
    end
end

NM.RegisterClass("MAGE", {
    spells = SP,
    talents = TALENT,
    specs = { T("Arkan", "Arcane"), T("Feuer", "Fire"), T("Frost", "Frost") },
    defaultSpec = 3,        -- wie die Bots ohne Talente
    power = 0,
    gcd = 1.5,
    melee = false,
    rangeSpell = { "frostbolt", "fireball", "fireblast" },
    gcdSpell = { "frostbolt", "fireball", "arcaneexplosion", "scorch" },
    probeBuff = "intellect",
    items = {
        managem = { 8008, 8007, 5513, 5514 },
        water   = { 8079, 8078, 8077, 3772, 2136, 2288, 5350 },
        food    = { 22895, 8076, 8075, 1487, 1114, 1113, 5349 },
    },
    defaults = {
        conjure = true,         -- Manastein, Wasser und Brot herbeizaubern
    },
    labels = {
        conjure = T("Manastein, Wasser und Brot herbeizaubern", "Conjure mana gem, water and food"),
    },
    cooldowns = { "counterspell", "frostnova", "blink", "iceblock", "icebarrier", "evocation", "arcanepower", "combustion", "pom", "coldsnap" },
    cooldownBuffs = { "icebarrier", "iceblock", "arcanepower", "combustion", "pom" },

    guessSpec = function(spells, selected)
        if selected then return selected end
        if spells.arcaneblast.id or spells.arcanepower.id or spells.pom.id then return 1 end
        if spells.pyroblast.id or spells.blastwave.id or spells.combustion.id then return 2 end
        return 3
    end,

    -- Arkanschlag-Stapel mitzaehlen (verfallen nach acht Sekunden, Geschosse verbrauchen sie)
    onCast = function(key, now)
        if key == "arcaneblast" then
            if now > blastUntil then blastStacks = 0 end
            blastStacks = math.min(4, blastStacks + 1)
            blastUntil = now + 8
        elseif key == "arcanemissiles" then
            blastStacks = 0
        end
    end,

    snapshot = function(S, _, now)
        S.blastStacks = (now <= blastUntil) and blastStacks or 0
    end,

    after = function(S2, c, _, S)
        if c.key == "arcaneblast" then S2.blastStacks = math.min(4, (S.blastStacks or 0) + 1)
        elseif c.key == "arcanemissiles" then S2.blastStacks = 0 end
    end,

    -- nach berechnetem Wert geordnet (Model.lua); der Frostblitz bekommt gutgeschrieben, dass er
    -- einen Gegner, der auf einen zukommt, laenger auf Abstand haelt
    rotation = { { "fireball", "frostbolt", "scorch", "fireblast", "arcanemissiles", "arcaneblast", "frostfire",
                   "arcaneexplosion", "flamestrike", "blizzard", "coneofcold", "blastwave", "shoot" } },
    kite = function(S, M) return M.CasterKite(S, M) end,
    rules = Rules,
    slots = Slots,
    precheck = Precheck,
})
