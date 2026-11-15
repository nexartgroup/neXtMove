--[[---------------------------------------------------------------------------
    Classes/Paladin.lua - Paladin (Heilig, Schutz, Vergeltung)

    Herkunft der Regeln: mod-playerbots, src/Ai/Class/Paladin/Strategy/:

      Bot (Strategie: Ausloeser -> Aktion, Prioritaet)             hier
      paladin: critical health -> lay on hands 91,                ebenso, ausgeloest durch
               divine shield 90                                   Blizzards Warnung "niedrige
                                                                  Gesundheit"
               hammer of justice interrupt 40                     ebenso
      ret:   seal 20 (kein Siegel aktiv), hammer of wrath 5.6,    ebenso; Richturteil ist das
             judgement 5.5, crusader strike 5.4,                  eine "Judgement" von Forever,
             consecration 5.1 / medium aoe 23,                    Heiliger Stoss ersetzt den
             low mana -> seal of wisdom 25                        Kreuzfahrerstoss
      prot:  righteous fury 28, hammer of the righteous 5.5,      ebenso
             holy shield 24, consecration 24/27,
             hammer of wrath 30
      holy / healer dps: holy shock 5.5, judgement, exorcism      Heiler: nur Schaden und Pflege
      buffs: Segen 11, Aura 10                                    ebenso (nur auf sich selbst)

    Was es in WoW Forever nicht gibt und deshalb entfaellt: Kreuzfahrerstoss, Goettlicher
    Sturm, Schild der Rechtschaffenheit, Schild des Raechers, Zornige Vergeltung, Goettliche
    Bitte, Siegel der Vergeltung / der Verderbnis, Hand der Abrechnung, Flamme des Glaubens.

    Siegel und Richturteil: In Vanilla verbraucht das Richturteil das Siegel, danach wird
    neu gesiegelt. Buffs sind im Kampf nicht lesbar - aber der Client meldet das Richturteil
    nur dann als benutzbar, wenn ein Siegel aktiv ist. Daran liest das Addon das Siegel ab.
    Neue Forever-Zauber: Heiliger Stoss und Hammer der Rechtschaffenen sind eingebaut, ebenso
    Siegel des Furors als Wahl; Lichtwacht nicht (Wirkung unbekannt: /nxm info lightsvigil).
-----------------------------------------------------------------------------]]

local _, NM = ...
if select(2, UnitClass("player")) ~= "PALADIN" then return end
local T = NM.T
local Common = NM.Common

local SP = {
    -- Siegel (immer nur eines aktiv)
    sor          = { ref = 21084,   dur = 30, unit = "player", seal = true },
    sotc         = { ref = 21082,   dur = 30, unit = "player", seal = true },
    sofury       = { ref = 1311649, dur = 30, unit = "player", seal = true },
    justice      = { ref = 20164,   dur = 30, unit = "player", seal = true },
    command      = { ref = 20915,   dur = 30, unit = "player", seal = true },
    light        = { ref = 20165,   dur = 30, unit = "player", seal = true },
    wisdom       = { ref = 20166,   dur = 30, unit = "player", seal = true },
    -- Schaden
    judgement    = { ref = 20271,   cd = 10, offgcd = true },
    holystrike   = { ref = 679,     cd = 6 },
    hammerrighteous = { ref = 407632, cd = 6 },
    consecration = { ref = 26573,   cd = 8, dur = 8, unit = "player", aoe = true, dot = true },
    exorcism     = { ref = 879,     cd = 15 },
    holywrath    = { ref = 2812,    cast = 2, cd = 60 },
    hammerofwrath = { ref = 24275,  cast = 1, cd = 6 },
    holyshock    = { ref = 20473,   cd = 30 },
    lightsvigil  = { ref = 1311590 },
    -- Kontrolle und Schutz
    hoj          = { ref = 853,     cd = 60, dur = 6, unit = "target", interrupts = true },
    repentance   = { ref = 20066,   cd = 60 },
    turnundead   = { ref = 2878,    cast = 1.5, cd = 30 },
    divineshield = { ref = 642,     cd = 300, dur = 12, unit = "player" },
    divineprotection = { ref = 498, cd = 300, dur = 8, unit = "player" },
    layonhands   = { ref = 633,     cd = 3600 },
    bop          = { ref = 1022,    cd = 300 },
    freedom      = { ref = 1044,    cd = 20 },
    holyshield   = { ref = 20927,   cd = 10, dur = 10, unit = "player" },
    divinefavor  = { ref = 20216,   cd = 120, offgcd = true },
    -- Heilung und Pflege
    holylight    = { ref = 635,     cast = 2.5 },
    flashoflight = { ref = 19750,   cast = 1.5 },
    purify       = { ref = 1152 },
    cleanse      = { ref = 4987 },
    -- Buffs
    might        = { ref = 19740,   dur = 300, unit = "player", blessing = true },
    bwisdom      = { ref = 19742,   dur = 300, unit = "player", blessing = true },
    kings        = { ref = 20217,   dur = 300, unit = "player", blessing = true },
    righteousfury = { ref = 25780,  dur = 1800, unit = "player" },
    -- Auren (Haltungsleiste)
    devotion     = { ref = 465,     offgcd = true, once = true },
    retribution  = { ref = 7294,    offgcd = true, once = true },
    concentration = { ref = 19746,  offgcd = true, once = true },
}

local TALENT = {
    sealOfCommand = 20375, holyShield = 20925, holyShock = 1311606, repentance = 20066,
    divineFavor = 20216, improvedRighteousFury = 20468, improvedJudgement = 25956,
}

local SEALS = { "sor", "sotc", "sofury", "justice", "command", "light", "wisdom" }
local BLESSINGS = { "might", "bwisdom", "kings" }

local function Rules(S, add)
    local db = NM.db
    local t, en = S.target, S.enemies
    local valid, ttd, danger = t.valid, S.ttd, S.danger
    local big = Common.Big(S)
    -- Tank: von Hand gewaehlt, als Rolle zugewiesen, oder Schutz-Baum ohne andere Rolle
    local tank = db.tankMode or S.party.myRole == "TANK" or (S.spec == 2 and S.party.myRole == nil)
    local evil = valid and (t.type == "undead" or t.type == "demon")

    local function R(k) return S:ready(k) end
    local function has(k) return S:aura(k) > 0 end

    -- der Client meldet fuer das Hauptsiegel "zu wenig Kraft"
    local _, noMana = S:usable("sor")
    local oom = noMana == true or false

    -- Siegel: gewuenscht nach Baum; bei leerem Mana Weisheit
    local want = db.seal
    if want == "auto" then
        want = (S.spec == 3 and S:known("command") and "command")
            or (S.spec == 1 and S:known("wisdom") and "wisdom") or "sor"
    end
    if not S:known(want) then want = "sor" end
    if oom and S:known("wisdom") then want = "wisdom" end
    local sealed = S.sealActive

    -------------------------------------------------------------- vor dem Kampf und Pflege
    -- Aura (Haltungsleiste)
    if not S.form then
        local order = (S.spec == 3 and { "retribution", "devotion" }) or (S.spec == 1 and { "concentration", "devotion" })
            or { "devotion", "retribution" }
        for _, k in ipairs(order) do
            -- (liegt die Aura schon von einem zweiten Paladin auf einem, nimmt man die naechste)
            if S:known(k) and not S.used[k] and not (S.party.class.PALADIN > 0 and has(k)) then
                add(k, 10, T("Keine Aura aktiv", "No aura active")); break
            end
        end
    end
    -- Segen auf sich selbst
    if db.selfBlessing then
        local any = false
        for _, k in ipairs(BLESSINGS) do if has(k) then any = true end end
        if not any then
            local order = (S.spec == 1) and { "bwisdom", "kings", "might" } or { "might", "kings", "bwisdom" }
            for _, k in ipairs(order) do
                if S:known(k) and not S.used[k] then
                    add(k, S.inCombat and 9 or 11, T("Kein Segen aktiv", "No blessing active"))
                    break
                end
            end
        end
    end
    if tank and S.group and S:known("righteousfury") and not has("righteousfury") and not S.used.righteousfury then
        add("righteousfury", 28, T("Zorn der Gerechtigkeit fehlt", "Righteous Fury is missing"))
    end

    -------------------------------------------------------------- Notfall (Reaktionen)
    if S.inCombat then
        Common.Heal(S, add, 94)
        if S.lowHealth then
            if R("divineshield") and not has("divineshield") then
                add("divineshield", 92, T("Gesundheit niedrig: Gottesschild", "Low health: Divine Shield"), { react = true })
            elseif R("divineprotection") and not has("divineprotection") and not has("divineshield") then
                add("divineprotection", 91.5, T("Gesundheit niedrig: Göttlicher Schutz", "Low health: Divine Protection"), { react = true })
            end
            if R("layonhands") and not has("divineshield") then
                add("layonhands", 91, T("Gesundheit niedrig: Handauflegung", "Low health: Lay on Hands"), { react = true })
            end
            if not S.moving then
                local heal = S:known("flashoflight") and "flashoflight" or "holylight"
                if S:known(heal) then
                    add(heal, has("divineshield") and 93 or 90, T("Gesundheit niedrig: dich heilen", "Low health: heal yourself"), { react = true })
                end
            end
        end
    end

    if not valid then return end

    -------------------------------------------------------------- Unterbrechen
    if t.casting and t.interruptible ~= false and t.stunnable and R("hoj") then
        add("hoj", 40, T("Ziel wirkt: Hammer der Gerechtigkeit", "Target is casting: Hammer of Justice"), { react = true })
    end
    if danger >= 2 and not S.dangerGuessed and t.stunnable and t.targetingMe ~= false and not has("hoj") and R("hoj") then
        add("hoj", 26, T("Hoher eingehender Schaden: Ziel betäuben", "High incoming damage: stun the target"), { react = true })
    end

    -------------------------------------------------------------- Mana
    if oom then Common.Mana(S, add, 24.5) end

    -------------------------------------------------------------- Siegel und Richturteil
    local fighting = S.inCombat or t.melee == true
    if fighting and not sealed and not S.used[want] then
        add(want, 20, oom and T("Mana leer: Siegel der Weisheit", "Out of mana: Seal of Wisdom") or T("Kein Siegel aktiv", "No seal active"))
    end
    if sealed and R("judgement") and db.useJudgement then
        add("judgement", 5.5, T("Richturteil bereit", "Judgement ready"))
    end

    -------------------------------------------------------------- Abklingzeiten
    if big and S.inCombat then
        if S.spec == 1 and R("divinefavor") then add("divinefavor", 21, T("Schwerer Kampf: Göttliche Gunst", "Hard fight: Divine Favor")) end
        Common.Trinkets(S, add, 18.6)
    end

    -------------------------------------------------------------- Rotation
    -- Hammer des Zorns geht nur unter 20 % - das meldet der Client
    if R("hammerofwrath") and S:usable("hammerofwrath") == true and not S.moving then
        add("hammerofwrath", tank and 30 or 5.6, T("Ziel unter 20 %: Hammer des Zorns", "Target below 20%: Hammer of Wrath"))
    end
    if tank and S.inCombat and R("holyshield") and not has("holyshield") then
        add("holyshield", 24, T("Heiliger Schild bereit", "Holy Shield ready"))
    end
    if S.near >= 3 or (tank and S.group and S.near >= 1) then
        if R("consecration") and not has("consecration") then
            add("consecration", S.near >= 3 and 23 or 24, T("Gegner an dir: Weihe", "Enemies on you: Consecration"))
        end
        if evil and S.near >= 2 and R("holywrath") then
            add("holywrath", 22.5, T("Untote oder Dämonen: Heiliger Zorn", "Undead or demons: Holy Wrath"))
        end
    end
    if R("hammerrighteous") then
        add("hammerrighteous", 5.5, T("Hammer der Rechtschaffenen bereit", "Hammer of the Righteous ready"))
    end
    if R("holystrike") then
        add("holystrike", 5.4, T("Heiliger Stoß bereit", "Holy Strike ready"))
    end
    if evil and R("exorcism") then
        add("exorcism", 5.2, T("Untoter oder Dämon: Exorzismus", "Undead or demon: Exorcism"))
    end
    if S.spec == 1 and R("holyshock") and big then
        add("holyshock", 5.5, T("Heiliger Schock bereit", "Holy Shock ready"))
    end
end

local function Slots(S, H)
    local items = S.items
    local L = {}
    L.interrupt = { H.spell(H.known("hoj") and "hoj" or nil) }
    L.stun = { H.spell(H.pick({ "repentance", "turnundead", "hoj" })) }
    L.buff = { H.spell(H.pick({ "divinefavor", "freedom", "might", "kings" })) }
    L.debuff = { H.spell(H.pick({ "cleanse", "purify", "exorcism" })) }
    L.heal = { H.item(items.healthstone or items.potion) or H.spell(H.pick({ "flashoflight", "holylight" })) }
    L.escape = { H.spell(H.pick({ "freedom", "divineprotection", "bop" })) }
    L.trinket = { H.trinket() or H.item(items.manapotion) }
    L.defense = { H.spell(H.pick({ "divineshield", "divineprotection", "layonhands", "bop" })) }
    return L
end

local function Precheck(S, add)
    if not S.form and (S:known("devotion") or S:known("retribution")) then add(T("Aura", "aura")) end
    if NM.db.selfBlessing and S:known("might") then
        local any = false
        for _, k in ipairs(BLESSINGS) do if S:has(k) then any = true end end
        if not any then add(T("Segen", "blessing")) end
    end
    -- Gruppe: wer noch gar keinen Segen hat
    if S.party.n > 0 and S:known("might") then NM.Party:Check(add, T("Segen", "blessing"), BLESSINGS) end
end

NM.RegisterClass("PALADIN", {
    spells = SP,
    talents = TALENT,
    specs = { T("Heilig", "Holy"), T("Schutz", "Protection"), T("Vergeltung", "Retribution") },
    defaultSpec = 3,        -- wie die Bots ohne Talente
    power = 0,
    gcd = 1.5,
    melee = true,
    rangeSpell = { "holystrike", "hammerrighteous", "judgement" },
    gcdSpell = { "sor", "holylight", "might", "purify" },
    probeBuff = "sor",
    defaults = {
        seal = "auto",          -- auto | sor | command | sotc | sofury | wisdom | light | justice
        useJudgement = true,
        selfBlessing = true,
        tankMode = false,
    },
    options = {
        { key = "seal", label = T("Siegel", "Seal"), values = { "auto", "sor", "command", "sotc", "sofury", "wisdom", "light", "justice" } },
    },
    labels = {
        useJudgement = T("Richturteil in der Rotation", "Judgement in the rotation"),
        selfBlessing = T("Segen auf sich selbst halten", "Keep a blessing on yourself"),
        tankMode = T("Als Tank spielen (auch ohne Schutz-Baum)", "Play as a tank (even without Protection)"),
    },
    cooldowns = { "judgement", "hoj", "holystrike", "hammerrighteous", "consecration", "exorcism", "holyshock",
                  "divineshield", "divineprotection", "layonhands", "repentance" },
    cooldownBuffs = { "divineshield", "divineprotection", "holyshield" },

    guessSpec = function(spells, selected)
        if selected then return selected end
        if spells.holyshield.id then return 2 end
        if spells.holyshock.id or spells.divinefavor.id then return 1 end
        return 3
    end,

    -- ein neues Siegel loest das alte ab; das Richturteil verbraucht es
    onCast = function(key, now, State)
        local d = SP[key]
        if d and d.seal then
            for _, k in ipairs(SEALS) do
                if k ~= key then State.model[k] = nil end
            end
        elseif key == "judgement" then
            for _, k in ipairs(SEALS) do State.model[k] = nil end
        elseif d and d.blessing then
            for _, k in ipairs(BLESSINGS) do
                if k ~= key then State.model[k] = nil end
            end
        end
    end,

    snapshot = function(S)
        -- Siegel aktiv? Das Richturteil ist nur mit Siegel benutzbar - das sagt der Client auch
        -- im Kampf. Ohne Richturteil (unter Stufe 4) oder bei unklarer Auskunft zaehlt das Modell.
        local model = false
        for _, k in ipairs(SEALS) do if S:aura(k) > 0 then model = true end end
        local usable, noPower = S:usable("judgement")
        if S:known("judgement") and usable ~= nil and noPower ~= true and S:cd("judgement") <= 0.2 then
            S.sealActive = usable
        else
            S.sealActive = model
        end
    end,

    after = function(S2, c, d)
        if d and d.seal then S2.sealActive = true end
        if c.key == "judgement" then S2.sealActive = false end
        if c.key == "devotion" or c.key == "retribution" or c.key == "concentration" then S2.form = c.key end
    end,

    -- nach berechnetem Wert geordnet (Model.lua)
    rotation = { { "holystrike", "hammerrighteous", "exorcism", "holyshock", "consecration", "judgement" } },
    rules = Rules,
    slots = Slots,
    precheck = Precheck,
})
