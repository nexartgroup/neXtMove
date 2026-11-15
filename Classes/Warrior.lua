--[[---------------------------------------------------------------------------
    Classes/Warrior.lua - Krieger (Waffen, Furor, Schutz)

    Herkunft der Regeln: mod-playerbots, src/Ai/Class/Warrior/Strategy/:

      Bot (Strategie: Ausloeser -> Aktion, Prioritaet)             hier
      arms:  charge 40, battle stance 30, battle shout 29,        ebenso
             rend 28, execute 25, overpower 24, mortal strike 23,
             bloodrage 22, death wish 22, heroic strike 20
      fury:  charge 39 (sonst intercept), berserker stance 29,    ebenso
             battle shout 28, bloodthirst 27, whirlwind 26,
             bloodrage 22, death wish / recklessness 20,
             pummel 40, heroic strike 5.1
      prot:  defensive stance 29, shield block 41, taunt 41,      ebenso; Verwuesten gibt es
             shield bash 40, revenge 22, shield slam 22,          nicht, also Ruestung
             sunder (devastate) 22, thunder clap 21,              zerreissen
             shield wall 20, last stand 93
      aoe:   light aoe (2) -> sweeping strikes 27, thunder clap   ebenso
             25, demoralizing shout 21, cleave 20
      "high rage available" (>= 60) -> heroic strike              Wut ist nicht lesbar: Helden-
                                                                  hafter Stoss, wenn der Haupt-
                                                                  schlag abklingt und die Wut
                                                                  fuer ihn schon reicht

    Was es in WoW Forever nicht gibt und deshalb entfaellt: Klingensturm, Schockwelle,
    Heldenhafter Wurf, Zerschmetternder Wurf, Wuetende Regeneration, Verwuesten,
    Zauberreflexion, Einschreiten, Befehlsruf, Wachsamkeit und die Ausloeser Ploetzlicher Tod,
    Geschmack fuer Blut, Schwert und Schild.

    Haltungen: Die Bots wechseln die Haltung nicht fuer einzelne Zauber, und das Addon auch
    nicht. Vorgeschlagen wird nur, was in der aktuellen Haltung geht (der Client meldet
    Zauber der falschen Haltung als nicht benutzbar). Ob Hinrichten, Ueberwaeltigen, Rache
    oder Siegesrausch gerade moeglich sind, sagt ebenfalls der Client - so verraet Hinrichten,
    dass das Ziel unter 20 % ist, obwohl dessen Gesundheit nicht lesbar ist.
-----------------------------------------------------------------------------]]

local _, NM = ...
if select(2, UnitClass("player")) ~= "WARRIOR" then return end
local T, Get = NM.T, NM.Get
local Common = NM.Common

local SP = {
    -- Haltungen
    battlestance = { ref = 2457,   offgcd = true, once = true },
    defstance    = { ref = 71,     offgcd = true, once = true },
    zerkstance   = { ref = 2458,   offgcd = true, once = true },
    -- Schlaege
    heroicstrike = { ref = 284,    cost = 15, offgcd = true, swing = true },
    cleave       = { ref = 845,    cost = 20, offgcd = true, swing = true, aoe = 2 },
    rend         = { ref = 772,    cost = 10, dur = 15, unit = "target", dot = true },
    mortalstrike = { ref = 21551,  cost = 30, cd = 6 },
    bloodthirst  = { ref = 23892,  cost = 30, cd = 6 },
    shieldslam   = { ref = 23923,  cost = 20, cd = 6 },
    whirlwind    = { ref = 1680,   cost = 25, cd = 10, aoe = 4 },
    execute      = { ref = 5308,   cost = 15 },
    overpower    = { ref = 7384,   cost = 5, cd = 5 },
    revenge      = { ref = 6572,   cost = 5, cd = 5 },
    victoryrush  = { ref = 402927, cost = 0 },
    slam         = { ref = 1464,   cost = 15, cast = 1.5 },
    sunder       = { ref = 7386,   cost = 15, dur = 30, unit = "target" },
    hamstring    = { ref = 1715,   cost = 10, dur = 15, unit = "target" },
    -- Rufe und Flaeche
    battleshout  = { ref = 6673,   cost = 10, dur = 120, unit = "player" },
    demoshout    = { ref = 1160,   cost = 10, dur = 30, unit = "target" },
    thunderclap  = { ref = 6343,   cost = 20, cd = 4, dur = 30, unit = "target", aoe = 4 },
    sweeping     = { ref = 12292,  cost = 30, cd = 30, dur = 20, unit = "player" },
    piercinghowl = { ref = 12323,  cost = 10 },
    intimidating = { ref = 5246,   cost = 25, cd = 180 },
    challenging  = { ref = 1161,   cost = 5, cd = 600 },
    -- Bewegung, Unterbrechen, Kontrolle
    charge       = { ref = 100,    cd = 15, offgcd = true },
    intercept    = { ref = 20252,  cost = 10, cd = 30, offgcd = true },
    pummel       = { ref = 6552,   cost = 10, cd = 10, interrupts = true, offgcd = true },
    shieldbash   = { ref = 72,     cost = 10, cd = 12, interrupts = true, offgcd = true },
    concussion   = { ref = 12809,  cost = 15, cd = 45, interrupts = true },
    taunt        = { ref = 355,    cd = 10, offgcd = true },
    mockingblow  = { ref = 694,    cost = 10, cd = 120 },
    disarm       = { ref = 676,    cost = 20, cd = 60 },
    -- Wut und Abklingzeiten
    bloodrage    = { ref = 2687,   cd = 60, offgcd = true },
    berserkerrage = { ref = 18499, cd = 30, offgcd = true },
    deathwish    = { ref = 12328,  cost = 10, cd = 180, dur = 30, unit = "player" },
    recklessness = { ref = 1719,   cd = 1800, dur = 15, unit = "player", offgcd = true },
    retaliation  = { ref = 20230,  cd = 1800, dur = 15, unit = "player", offgcd = true },
    shieldwall   = { ref = 871,    cd = 1800, dur = 10, unit = "player", offgcd = true },
    shieldblock  = { ref = 2565,   cost = 10, cd = 5, dur = 5, unit = "player", offgcd = true },
    laststand    = { ref = 12975,  cd = 600, dur = 20, unit = "player", offgcd = true },
}

local TALENT = {
    mortalStrike = 12294, bloodthirst = 23881, shieldSlam = 23922, sweepingStrikes = 12292,
    deathWish = 12328, piercingHowl = 12323, lastStand = 12975, concussionBlow = 12809,
    tacticalMastery = 12295, improvedRend = 12286,
}

local STANCES = { battlestance = true, defstance = true, zerkstance = true }

-- Ruestung zerreissen stapelt bis fuenf: als Effekt im Kampf nicht lesbar, also mitgezaehlt
local sunderCount, sunderUntil, sunderGuid = 0, 0, nil

local function Rules(S, add)
    local db = NM.db
    local t, en = S.target, S.enemies
    local valid, ttd, danger = t.valid, S.ttd, S.danger
    local big = Common.Big(S)
    local dying = valid and S.ttdMeasured and ttd <= 4 or false
    -- Tank: von Hand gewaehlt, als Rolle zugewiesen, oder Schutz-Baum ohne andere Rolle
    local P = S.party
    local tank = db.tankMode or P.myRole == "TANK" or (S.spec == 3 and P.myRole == nil)
    local stance = STANCES[S.form] and S.form or nil

    local function R(k) return S:ready(k) end
    local function has(k) return S:aura(k) > 0 end
    -- vom Client bestaetigt: geht jetzt (Ausloeser-Zauber wie Hinrichten oder Ueberwaeltigen)
    local function procs(k) return R(k) and S:usable(k) == true end

    -------------------------------------------------------------- Haltung
    -- gewechselt wird vor dem Kampf oder solange noch kaum Wut da ist (sie geht dabei verloren)
    local want = db.stance
    if want == "auto" then
        want = (tank and S:known("defstance") and "defstance")
            or (S.spec == 2 and S:known("zerkstance") and "zerkstance") or "battlestance"
    end
    if want ~= "none" and stance ~= want and S:known(want) and not S.used[want]
       and (not S.inCombat or not S:atLeast(20)) then
        add(want, 30, T("Haltung für diesen Baum", "Stance for this spec"))
    end

    -------------------------------------------------------------- Notfall (Reaktionen)
    if S.inCombat then
        Common.Heal(S, add, 94)
        if S.lowHealth then
            if R("laststand") and not has("laststand") then
                add("laststand", 93, T("Gesundheit niedrig: Letztes Gefecht", "Low health: Last Stand"), { react = true })
            end
            if procs("shieldwall") and not has("shieldwall") then
                add("shieldwall", 92, T("Gesundheit niedrig: Schildwall", "Low health: Shield Wall"), { react = true })
            end
            if not S.group and en.onMe >= 2 and R("intimidating") then
                add("intimidating", 90, T("Gesundheit niedrig: Drohruf", "Low health: Intimidating Shout"), { react = true })
            end
        end
        if en.onMe >= 2 and danger >= 2 and procs("retaliation") and not has("retaliation") then
            add("retaliation", 91, T("Mehrere Angreifer: Gegenschlag", "Several attackers: Retaliation"), { react = true })
        end
    end

    if not valid then return end

    -------------------------------------------------------------- Unterbrechen
    if t.casting and t.interruptible ~= false then
        if procs("pummel") then
            add("pummel", 40, T("Ziel wirkt: Zuschlagen", "Target is casting: Pummel"), { react = true })
        elseif procs("shieldbash") then
            add("shieldbash", 40, T("Ziel wirkt: Schildhieb", "Target is casting: Shield Bash"), { react = true })
        elseif R("concussion") then
            add("concussion", 39.5, T("Ziel wirkt: Erschütternder Schlag", "Target is casting: Concussion Blow"), { react = true })
        end
    end

    -------------------------------------------------------------- Herankommen
    if t.melee == false then
        if not S.inCombat and procs("charge") and S.chargeInRange then
            add("charge", 40, T("Eröffnung: Sturmangriff", "Opener: Charge"))
        elseif S.inCombat and procs("intercept") and S.interceptInRange then
            add("intercept", 39, T("Ziel nicht in Reichweite: Abfangen", "Target out of reach: Intercept"))
        end
    end

    -------------------------------------------------------------- Tank
    if tank and S.group and S.inCombat then
        -- (einem zweiten Tank nimmt man das Ziel nicht weg)
        local onOtherTank = P.aggro and not P.aggroSoft
        if t.targetingMe == false and not onOtherTank and not t.player and R("taunt") and S:usable("taunt") ~= false then
            add("taunt", 41, P.aggro and (T("Ziel greift %s an: Spott", "Target attacks %s: Taunt")):format(tostring(P.aggro.name or "?"))
                or T("Ziel greift jemand anderen an: Spott", "Target attacks someone else: Taunt"), { react = true })
        end
        if danger >= 1 and procs("shieldblock") and not has("shieldblock") then
            add("shieldblock", 25.5, T("Viele Treffer: Schildblock", "Many hits: Shield Block"))
        end
    end

    -------------------------------------------------------------- Wut und Rufe
    if (S.inCombat or t.melee == true) and not S.lowHealth and danger < 2 and not S:atLeast(20) and R("bloodrage") then
        add("bloodrage", 22, T("Wut fehlt: Blutrausch", "No rage: Bloodrage"))
    end
    if S:known("battleshout") and not has("battleshout") and (S.inCombat or t.melee == true) then
        add("battleshout", 29, T("Schlachtruf fehlt", "Battle Shout is missing"))
    end

    -------------------------------------------------------------- Abklingzeiten
    if big and S.inCombat and not dying then
        if R("deathwish") and not has("deathwish") then add("deathwish", 22.2, T("Schwerer Kampf: Todeswunsch", "Hard fight: Death Wish")) end
        if procs("recklessness") and not has("recklessness") and t.boss then
            add("recklessness", 20.5, T("Bosskampf: Tollkühnheit", "Boss fight: Recklessness"))
        end
        Common.Trinkets(S, add, 18.6)
    end

    -------------------------------------------------------------- Ausloeser
    if procs("victoryrush") then add("victoryrush", 26, T("Nach dem Sieg: Siegesrausch", "After a kill: Victory Rush")) end
    if procs("execute") then add("execute", 25, T("Ziel unter 20 %: Hinrichten", "Target below 20%: Execute")) end
    if procs("overpower") then add("overpower", 24, T("Ziel ist ausgewichen: Überwältigen", "Target dodged: Overpower")) end
    if procs("revenge") then add("revenge", 22.5, T("Nach Block oder Parade: Rache", "After a block or parry: Revenge")) end

    -------------------------------------------------------------- Flaeche
    if S.near >= 2 then
        if R("sweeping") and not has("sweeping") then
            add("sweeping", 27, T("Mehrere Gegner: Weitreichende Stöße", "Several enemies: Sweeping Strikes"))
        end
        if R("whirlwind") then add("whirlwind", 26.5, T("Mehrere Gegner: Wirbelwind", "Several enemies: Whirlwind")) end
        if S:known("thunderclap") and R("thunderclap") and not has("thunderclap") then
            add("thunderclap", 25, T("Mehrere Gegner: Donnerknall", "Several enemies: Thunder Clap"))
        end
        if (danger >= 1 or tank) and S:known("demoshout") and not has("demoshout") then
            add("demoshout", 21, T("Mehrere Gegner: Demoralisierender Ruf", "Several enemies: Demoralizing Shout"))
        end
    end

    -------------------------------------------------------------- Rotation
    -- der Hauptschlag des Baums
    local main = (S:known("mortalstrike") and "mortalstrike") or (S:known("bloodthirst") and "bloodthirst")
        or (S:known("shieldslam") and "shieldslam") or nil
    if main and R(main) then
        add(main, main == "bloodthirst" and 27 or 23, T("Hauptschlag bereit", "Main strike ready"))
    end
    if S.spec == 2 and R("whirlwind") then add("whirlwind", 26, T("Wirbelwind bereit", "Whirlwind ready")) end

    -- Verwunden: blutet und lebt lange genug (nicht mehr, wenn Hinrichten schon geht)
    if S:known("rend") and not has("rend") and t.bleedable and ttd >= 9 and not dying and not procs("execute") then
        add("rend", tank and 11 or 28, T("Verwunden fehlt", "Rend is missing"))
    end
    -- Ruestung zerreissen: als Tank immer, sonst gegen starke Gegner
    -- (tankt ein anderer Krieger, baut der die Ruestung ab)
    local otherSunders = not tank and P.tank and P.class.WARRIOR > 0
    if S:known("sunder") and not otherSunders and (tank or (big and ttd >= 20)) then
        local stacks = (S.sunderStacks or 0)
        if stacks < 5 or S:aura("sunder") < 6 then
            add("sunder", tank and 22 or 5.3, T("Rüstung zerreißen aufbauen", "Stack Sunder Armor"))
        end
    end
    if tank and S:known("thunderclap") and R("thunderclap") and not has("thunderclap") and ttd >= 8 then
        add("thunderclap", 21, T("Donnerknall fehlt", "Thunder Clap is missing"))
    end
    if tank and S:known("demoshout") and not has("demoshout") and ttd >= 10 and big then
        add("demoshout", 5.1, T("Demoralisierender Ruf fehlt", "Demoralizing Shout is missing"))
    end

    -- Wut abbauen: Heldenhafter Stoss (Spalten bei mehreren Gegnern), wenn der Hauptschlag
    -- abklingt und die Wut fuer ihn schon reicht - oder, ohne Hauptschlag, wenn Wut uebrig ist
    local dump = (S.near >= 2 and S:known("cleave")) and "cleave" or "heroicstrike"
    if S:known(dump) then
        local spare
        if main then spare = S:cd(main) > 2 and S:atLeast(S:cost(main))
        else spare = S:atLeast(20) or S.level < 6 end
        if spare then add(dump, 20, T("Wut übrig: abbauen", "Spare rage: spend it")) end
    end
end

local function Slots(S, H)
    local L = {}
    L.interrupt = { H.spell(H.pick({ "pummel", "shieldbash" })) }
    L.stun = { H.spell(H.pick({ "concussion", "intimidating", "hamstring", "piercinghowl" })) }
    L.buff = { H.spell(H.pick({ "deathwish", "recklessness", "sweeping", "berserkerrage", "bloodrage" })) }
    L.debuff = { H.spell(H.pick({ "demoshout", "thunderclap", "disarm", "hamstring", "sunder" })) }
    L.heal = { H.item(S.items.healthstone or S.items.potion) }
    L.escape = { H.spell(H.pick({ "intimidating", "piercinghowl", "hamstring", "intercept" })) }
    L.trinket = { H.trinket() }
    L.defense = { H.spell(H.pick({ "laststand", "shieldwall", "retaliation", "shieldblock" })) }
    return L
end

local function Precheck(S, add)
    if not S.form and S:known("battlestance") then add(T("Haltung", "stance")) end
end

NM.RegisterClass("WARRIOR", {
    spells = SP,
    talents = TALENT,
    specs = { T("Waffen", "Arms"), T("Furor", "Fury"), T("Schutz", "Protection") },
    defaultSpec = 1,
    power = 1,
    gcd = 1.5,
    melee = true,
    rangeSpell = { "rend", "hamstring", "sunder", "heroicstrike" },
    gcdSpell = { "rend", "hamstring", "sunder", "battleshout", "demoshout" },
    probeBuff = "battleshout",
    defaults = {
        stance = "auto",        -- auto | battlestance | defstance | zerkstance | none
        tankMode = false,       -- als Tank spielen, auch ohne Schutz-Baum
    },
    options = {
        { key = "stance", label = T("Haltung", "Stance"), values = { "auto", "battlestance", "defstance", "zerkstance", "none" } },
    },
    labels = {
        tankMode = T("Als Tank spielen (auch ohne Schutz-Baum)", "Play as a tank (even without Protection)"),
    },
    cooldowns = { "charge", "intercept", "bloodrage", "pummel", "shieldbash", "mortalstrike", "bloodthirst", "shieldslam",
                  "whirlwind", "deathwish", "recklessness", "retaliation", "shieldwall", "laststand" },
    cooldownBuffs = { "deathwish", "recklessness", "retaliation", "shieldwall", "laststand", "sweeping" },

    guessSpec = function(spells, selected)
        if selected then return selected end
        if spells.shieldslam.id or spells.laststand.id or spells.concussion.id then return 3 end
        if spells.bloodthirst.id or spells.deathwish.id or spells.piercinghowl.id then return 2 end
        return 1
    end,

    onCast = function(key, now, State)
        if key == "sunder" then
            local guid = NM.Plain(UnitGUID("target"))
            if guid ~= sunderGuid or now > sunderUntil then sunderCount = 0 end
            sunderGuid = guid
            sunderCount = math.min(5, sunderCount + 1)
            sunderUntil = now + 30
        end
    end,

    snapshot = function(S, _, now)
        local guid = S.target.guid
        S.sunderStacks = (guid and guid == sunderGuid and now <= sunderUntil) and sunderCount or 0
        -- Sturmangriff und Abfangen haben eine eigene Reichweite (8 bis 25 Meter)
        local c, i = SP.charge.id, SP.intercept.id
        S.chargeInRange = c and Get(C_Spell.IsSpellInRange, c, "target") == true
        S.interceptInRange = i and Get(C_Spell.IsSpellInRange, i, "target") == true
    end,

    after = function(S2, c, _, S)
        if STANCES[c.key] then S2.form = c.key end
        if c.key == "sunder" then S2.sunderStacks = math.min(5, (S.sunderStacks or 0) + 1) end
        if c.key == "charge" or c.key == "intercept" then
            S2.target = setmetatable({ melee = true }, { __index = S.target })
            S2.inCombat = true
        end
    end,

    -- nach Schaden je Wut und Zeit geordnet (Model.lua); Ausloeser wie Hinrichten behalten ihren Platz
    rotation = { { "mortalstrike", "bloodthirst", "shieldslam", "whirlwind", "slam", "rend", "heroicstrike", "cleave" } },
    rules = Rules,
    slots = Slots,
    precheck = Precheck,
})
