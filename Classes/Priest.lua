--[[---------------------------------------------------------------------------
    Classes/Priest.lua - Priester (Disziplin, Heilig, Schatten)

    Herkunft der Regeln: mod-playerbots, src/Ai/Class/Priest/Strategy/:

      Bot (Strategie: Ausloeser -> Aktion, Prioritaet)             hier
      priest: being attacked -> power word: shield 21             ebenso (Geschwaechte Seele
              medium threat -> fade 55                            wird mitgeschrieben)
              critical health -> desperate prayer 25              bei Blizzards Warnung
      shadow: shadowform 20, silence 41,                          ebenso
              mind blast 5.3, mind flay 5.2,
              shadow word: death 5.1, shoot 5.0
      shadow debuff: devouring plague 22,                         ebenso (Vampirberuehrung gibt
              shadow word: pain 21 (Lebenszeit >= 8 s)            es nicht)
      holy dps / healer dps: holy fire 19, smite 5.2              Heiler: nur Schaden und Pflege
      boost:  power infusion 41                                   in schweren Kaempfen
      nc:     inner fire 10, Seelenstaerke 11                     ebenso

    Was es in WoW Forever nicht gibt und deshalb entfaellt: Vampirberuehrung, Gedankenexplosion,
    Dispersion, Schattengeist, Hymne der Hoffnung.

    Zauberstab: "Schiessen" laeuft wie ein automatischer Angriff weiter, sobald man es einmal
    startet. Vorgeschlagen wird es nur, solange es NICHT laeuft - wenn das Mana leer ist oder
    (Einstellung) als sparsamer Fueller gegen gewoehnliche Gegner.
    Heilen in Schattengestalt geht nicht: der Client meldet die Heilzauber dann als nicht
    benutzbar, also werden sie nicht vorgeschlagen.
-----------------------------------------------------------------------------]]

local _, NM = ...
if select(2, UnitClass("player")) ~= "PRIEST" then return end
local T = NM.T
local Common = NM.Common

local SP = {
    -- Schaden
    swp          = { ref = 589,     dur = 18, unit = "target", dot = true },
    mindblast    = { ref = 8092,    cast = 1.5, cd = 8 },
    mindflay     = { ref = 17311,   channel = 3, slow = 0.5, slowDur = 3 },
    smite        = { ref = 591,     cast = 2.5 },
    holyfire     = { ref = 14914,   cast = 3.5, dur = 10, unit = "target", dot = true },
    devouring    = { ref = 2944,    cd = 180, dur = 24, unit = "target", dot = true },
    swd          = { ref = 1309595, cd = 12 },
    vampiricembrace = { ref = 15286, dur = 60, unit = "target" },
    penance      = { ref = 1240720, channel = 2, cd = 12 },
    holynova     = { ref = 15430, aoe = true },
    manaburn     = { ref = 8129,    cast = 3 },
    starshards   = { ref = 10797,   channel = 6 },
    shoot        = { ref = 5019,    nobar = true, once = true, wand = true },
    -- Schutz und Kontrolle
    pws          = { ref = 17,      cd = 4, dur = 30, unit = "player" },
    weakened     = { ref = 6788,    dur = 15, unit = "player", foreign = true, harmful = true },
    fade         = { ref = 586,     cd = 30 },
    psychicscream = { ref = 8122,   cd = 30 },
    silence      = { ref = 15487,   cd = 45, interrupts = true, offgcd = true },
    desperateprayer = { ref = 13908, cd = 600 },
    shackle      = { ref = 9484,    cast = 1.5 },
    -- Heilung und Pflege
    renew        = { ref = 139,     dur = 15, unit = "player" },
    lesserheal   = { ref = 2052,    cast = 2.5 },
    heal         = { ref = 2054,    cast = 3 },
    flashheal    = { ref = 2061,    cast = 1.5 },
    dispel       = { ref = 527 },
    curedisease  = { ref = 528 },
    abolish      = { ref = 552 },
    -- Buffs und Abklingzeiten
    shadowform   = { ref = 15473,   once = true },
    innerfire    = { ref = 588,     dur = 600, unit = "player" },
    fortitude    = { ref = 1243,    dur = 1800, unit = "player" },
    prayerfort   = { ref = 21562,   dur = 3600, unit = "player", foreign = true },
    divinespirit = { ref = 14752,   dur = 1800, unit = "player" },
    innerfocus   = { ref = 14751,   cd = 180, offgcd = true },
    powerinfusion = { ref = 10060,  cd = 180, dur = 15, unit = "player", offgcd = true },
}

local TALENT = {
    shadowform = 15473, mindFlay = 15407, silence = 15487, vampiricEmbrace = 15286,
    innerFocus = 14751, powerInfusion = 10060, wandSpec = 14524, spiritTap = 15270,
}

local function Rules(S, add)
    local db = NM.db
    local t, en = S.target, S.enemies
    local valid, ttd, danger = t.valid, S.ttd, S.danger
    local big = Common.Big(S)
    local dying = valid and S.ttdMeasured and ttd <= 3 or false
    local shadow = (S.form == "shadowform")

    local function R(k) return S:ready(k) end
    local function has(k) return S:aura(k) > 0 end

    -- Fueller je Gestalt und Talenten
    local filler = (S:known("mindflay") and (shadow or S.spec == 3)) and "mindflay" or (S:known("smite") and "smite") or nil
    local probe = S:known("mindblast") and "mindblast" or (S:known("smite") and "smite") or "swp"
    local _, noMana = S:usable(probe)
    local oom = noMana == true or false
    local wand = S.gear.wand and S:known("shoot") and not S.used.shoot
    local wandRuns = wand and S:repeating("shoot") or nil

    -------------------------------------------------------------- vor dem Kampf
    if not S.inCombat then
        if S:known("innerfire") and not has("innerfire") and not S.used.innerfire then
            add("innerfire", 18, T("Inneres Feuer fehlt", "Inner Fire is missing"))
        end
        if S:known("fortitude") and not has("fortitude") and not has("prayerfort") and not S.used.fortitude then
            add("fortitude", 17, T("Seelenstärke fehlt", "Fortitude is missing"))
        end
        if S:known("divinespirit") and not has("divinespirit") and not S.used.divinespirit then
            add("divinespirit", 16, T("Göttlicher Willen fehlt", "Divine Spirit is missing"))
        end
    end
    -- Schattengestalt: vor dem Kampf oder gleich zu Beginn
    if db.useShadowform and S:known("shadowform") and not shadow and not S.used.shadowform
       and (valid or S.inCombat) and (not S.inCombat or (S.fightTime or 0) < 3) then
        add("shadowform", 23, T("Schattengestalt fehlt", "Shadowform is missing"))
    end

    -------------------------------------------------------------- Notfall (Reaktionen)
    if S.inCombat then
        Common.Heal(S, add, 62)
        if S.lowHealth then
            if R("desperateprayer") then
                add("desperateprayer", 61, T("Gesundheit niedrig: Verzweifeltes Gebet", "Low health: Desperate Prayer"), { react = true })
            end
            if not S.moving then
                for _, k in ipairs({ "flashheal", "heal", "lesserheal" }) do
                    -- (in Schattengestalt meldet der Client Heilzauber als nicht benutzbar)
                    if S:known(k) and S:usable(k) ~= false then
                        add(k, 60, T("Gesundheit niedrig: dich heilen", "Low health: heal yourself"), { react = true })
                        break
                    end
                end
            end
        end
        if (en.onMe >= 2 or (danger >= 2 and not S.dangerGuessed)) and R("psychicscream") then
            add("psychicscream", 56, T("Mehrere Angreifer an dir: Psychischer Schrei", "Several attackers on you: Psychic Scream"), { react = true })
        end
        -- (Verblassen gibt die Gegner ab: das lohnt nur, wenn jemand tankt)
        local handOver = S.party.n == 0 or S.party.tankLikely
        if S.group and handOver and en.onMe >= 1 and valid and not t.player and R("fade") then
            add("fade", 55, T("Gegner greifen dich an: Verblassen", "Enemies attack you: Fade"), { react = true })
        elseif S.party.threatHigh and valid and R("fade") then
            add("fade", 55, T("Zu viel Bedrohung: Verblassen", "Too much threat: Fade"), { react = true })
        end
        -- Schild, wenn man angegriffen wird (Geschwaechte Seele sperrt ihn 15 Sekunden)
        if (en.onMe >= 1 or danger >= 1) and S:known("pws") and not has("pws") and not has("weakened") and R("pws") then
            add("pws", 21.5, T("Du wirst angegriffen: Machtwort: Schild", "You are under attack: Power Word: Shield"))
        end
    end

    if not valid then return end

    -- Schild schon vor dem Kampf, wenn man allein eroeffnet
    if not S.inCombat and not S.group and db.shieldOpener and S:known("pws") and not has("pws") and not has("weakened") and R("pws") then
        add("pws", 21.5, T("Vor dem Kampf: Machtwort: Schild", "Before the fight: Power Word: Shield"))
    end

    -------------------------------------------------------------- Unterbrechen
    if t.casting and t.interruptible ~= false and R("silence") then
        add("silence", 41, T("Ziel wirkt: Stille", "Target is casting: Silence"), { react = true })
    end

    -------------------------------------------------------------- Mana
    if oom then
        Common.Mana(S, add, 24.5)
        if wand then add("shoot", 6, T("Mana leer: Zauberstab", "Out of mana: wand"), { running = wandRuns }) end
    end

    -------------------------------------------------------------- Abklingzeiten
    if big and S.inCombat and not dying then
        if R("powerinfusion") and not has("powerinfusion") then add("powerinfusion", 29, T("Schwerer Kampf: Seele der Macht", "Hard fight: Power Infusion")) end
        if R("innerfocus") and R("mindblast") then add("innerfocus", 21, T("Innerer Fokus vor dem Gedankenschlag", "Inner Focus before Mind Blast")) end
        Common.Trinkets(S, add, 18.6)
    end

    -------------------------------------------------------------- Flaeche
    if S.near >= 3 and not shadow and S:known("holynova") then
        add("holynova", 24, T("Mehrere Gegner an dir: Heilige Nova", "Several enemies on you: Holy Nova"))
    end

    -------------------------------------------------------------- Schadenseffekte (lohnen nur, wenn das Ziel lange genug lebt)
    if R("devouring") and not has("devouring") and ttd >= 12 then
        add("devouring", 22, T("Verschlingende Seuche bereit", "Devouring Plague ready"))
    end
    if S:known("swp") and not has("swp") and ttd >= 8 then
        add("swp", 21, T("Schattenwort: Schmerz fehlt", "Shadow Word: Pain is missing"))
    end
    if S:known("vampiricembrace") and not has("vampiricembrace") and ttd >= 15 and (shadow or S.spec == 3) then
        add("vampiricembrace", 16, T("Vampirumarmung fehlt", "Vampiric Embrace is missing"))
    end
    if not shadow and S:known("holyfire") and not has("holyfire") and S:usable("holyfire") ~= false
       and (not S.inCombat or ttd >= 10) then
        add("holyfire", 19, T("Heiliges Feuer fehlt", "Holy Fire is missing"))
    end

    -------------------------------------------------------------- Rotation
    if R("mindblast") then add("mindblast", 5.3, T("Gedankenschlag bereit", "Mind Blast ready")) end
    if (dying or S.moving) and not S.lowHealth and R("swd") then
        add("swd", 5.25, dying and T("Ziel stirbt gleich: Schattenwort: Tod", "Target is about to die: Shadow Word: Death")
            or T("In Bewegung: Schattenwort: Tod", "Moving: Shadow Word: Death"))
    end
    -- Fueller: gegen gewoehnliche Gegner spart der Zauberstab Mana
    -- (mit Schadensmodell entscheidet der berechnete Wert: bei knappem Mana gewinnt der Stab)
    local thrifty = db.wandFiller and not db.useModel and S.gear.wand and S:known("shoot") and not big and not S.group
    if filler and not thrifty then
        add(filler, 5.2, T("Hauptzauber", "Main spell"))
    end
    if filler ~= "smite" and not shadow and not thrifty and S:known("smite") then
        add("smite", 5.15, T("Ersatz für den Hauptzauber", "Fallback for the main spell"))
    end
    if wand and not oom then add("shoot", 5.0, T("Zauberstab", "Wand"), { running = wandRuns }) end
end

local function Slots(S, H)
    local items = S.items
    local L = {}
    L.interrupt = { H.spell(H.known("silence") and "silence" or nil) }
    L.stun = { H.spell(H.pick({ "psychicscream", "shackle" })) }
    L.buff = { H.spell(H.pick({ "powerinfusion", "innerfocus", "innerfire", "fortitude" })) }
    L.debuff = { H.spell(H.pick({ "dispel", "abolish", "curedisease", "manaburn" })) }
    L.heal = { H.item(items.healthstone or items.potion) or H.spell(H.pick({ "flashheal", "heal", "lesserheal", "renew" })) }
    L.escape = { H.spell(H.pick({ "fade", "psychicscream" })) }
    L.trinket = { H.trinket() or H.item(items.manapotion) }
    L.defense = { H.spell(H.pick({ "pws", "desperateprayer", "renew" })) }
    return L
end

local function Precheck(S, add)
    if S:known("innerfire") and not S:has("innerfire") then add(T("Inneres Feuer", "Inner Fire")) end
    if S:known("fortitude") and not S:has("fortitude") and not S:has("prayerfort") then add(T("Seelenstärke", "Fortitude")) end
    -- Gruppe: Seelenstaerke fuer alle, Willenskraft fuer Mitspieler mit Mana
    if S.party.n > 0 then
        if S:known("fortitude") then NM.Party:Check(add, T("Seelenstärke", "Fortitude"), { "fortitude", "prayerfort" }) end
        if S:known("divinespirit") then
            NM.Party:Check(add, T("Göttlicher Wille", "Divine Spirit"), { "divinespirit" }, NM.Party.HasMana)
        end
    end
    if NM.db.useShadowform and S:known("shadowform") and S.form ~= "shadowform" then add(T("Schattengestalt", "Shadowform")) end
end

NM.RegisterClass("PRIEST", {
    spells = SP,
    talents = TALENT,
    specs = { T("Disziplin", "Discipline"), T("Heilig", "Holy"), T("Schatten", "Shadow") },
    defaultSpec = 3,
    power = 0,
    gcd = 1.5,
    melee = false,
    rangeSpell = { "swp", "smite", "mindblast" },
    gcdSpell = { "swp", "smite", "renew", "lesserheal" },
    probeBuff = "innerfire",
    defaults = {
        useShadowform = true,
        shieldOpener = true,    -- Machtwort: Schild schon vor dem Kampf (allein)
        wandFiller = true,      -- gegen gewoehnliche Gegner der Zauberstab statt des Fuellers
    },
    labels = {
        useShadowform = T("Schattengestalt", "Shadowform"),
        shieldOpener = T("Schild schon vor dem Kampf (allein)", "Shield before the fight (solo)"),
        wandFiller = T("Zauberstab statt Füller gegen gewöhnliche Gegner", "Wand instead of filler against ordinary enemies"),
    },
    cooldowns = { "mindblast", "pws", "psychicscream", "fade", "silence", "devouring", "swd", "powerinfusion", "innerfocus", "desperateprayer" },
    cooldownBuffs = { "powerinfusion" },

    guessSpec = function(spells, selected)
        if selected then return selected end
        if spells.shadowform.id or spells.mindflay.id or spells.vampiricembrace.id then return 3 end
        if spells.powerinfusion.id or spells.innerfocus.id or spells.penance.id then return 1 end
        if spells.holynova.id then return 2 end
        return 3
    end,

    -- der Schild hinterlaesst Geschwaechte Seele (15 Sekunden kein neuer Schild)
    onCast = function(key, now, State)
        if key == "pws" then State.model.weakened = now + 15 end
    end,

    after = function(S2, c)
        if c.key == "shadowform" then S2.form = "shadowform" end
        if c.key == "pws" then S2.auraOv.weakened = 15 end
    end,

    -- nach berechnetem Wert geordnet (Model.lua)
    rotation = { { "swp", "mindblast", "mindflay", "smite", "holyfire", "devouring", "swd", "starshards", "holynova", "shoot" } },
    kite = function(S, M) return M.CasterKite(S, M) end,
    rules = Rules,
    slots = Slots,
    precheck = Precheck,
})
