--[[---------------------------------------------------------------------------
    Classes/Rogue.lua - Schurke

    Herkunft der Regeln: mod-playerbots, src/Ai/Class/Rogue/Strategy/
    {Generic,Combat,Assassination}RogueStrategy.cpp. Jede Regel traegt die Prioritaet der
    Bots (ACTION_NORMAL 10, ACTION_HIGH 20, ACTION_INTERRUPT 40 plus Zuschlag):

      Bot-Trigger                          hier
      "combo points 5 available"           cp >= finCP (Meucheln: 4, wie bei den Bots)
      "slice and dice" (Buff fehlt)        Zerhaeckseln fehlt oder laeuft gleich ab
      "target with combo points almost dead"   cp >= 3 und Restlebenszeit <= 3 s
      "rupture" (Lebenszeit >= 6 s)        Blutung fehlt, Ziel blutet, Restlebenszeit >= 12 s
      "expose armor" (cp <= 3, >= 25 s, kein Ruestung zerreissen)   ebenso, nur in der Gruppe
      "kick" (Ziel wirkt)                  Tritt, sonst Nierenhieb, sonst Solarplexus
      "low health" 45 % / "critical" 25 %  Gefahr aus Angreifern, Treffern, Blizzards Warnung
      "light aoe" (2 Gegner in 8 m)        2 Gegner in Nahkampfreichweite -> Klingenwirbel
      "medium threat"                      mehrere Angreifer in der Gruppe -> Verschwinden
      Boost ("adrenaline rush")            lange oder schwere Kaempfe (Elite, Boss, 3+ Gegner)
      Verstohlen: Hinterhalt hinter dem Ziel, sonst Fieser Trick

    Angepasst an WoW Forever (Vanilla-Faehigkeiten, Stufe 60): Vergiften, Hunger nach Blut,
    Moerderische Rage, Dolchfaecher, Schurkenhandel und Mantel der Schatten der Bots gibt es
    hier nicht; dafuer Blutsturz, Geisterhafter Stoss, Kaltbluetigkeit vor dem Ausweiden,
    Konzentration, Vorbereitung, Traenke, Disteltee und Schmuckstuecke.

    Felder einer Klasse (gelten fuer alle Dateien in diesem Ordner):
      spells      [key] = { ref, cost, cp, fin, cd, dur, unit, offgcd, cast, channel, ... }
                  ref     ein beliebiger Rang (gibt den Namen in der Clientsprache)
                  cost    Kraft, falls der Client die Kosten nicht nennt
                  cp/fin  bringt / verbraucht Combopunkte
                  cd/dur  Abklingzeit / Effektdauer in s (Rueckfall)
                  unit    Traeger des Effekts: "player" oder "target"
                  offgcd  loest keine globale Abklingzeit aus
                  cast    Zauberzeit in s (Rueckfall); channel = Dauer einer Kanalisierung
                  interrupts  unterbricht das Ziel; foreign = fremder Effekt, nur der Name
                  always  immer verfuegbar (Angriff); nobar = gehoert nicht auf eine Leiste
                  once    einmalig (Beschwoeren, Herstellen): nicht zweimal in Folge vorschlagen
                  pet     Zauber des Begleiters (alt = weitere Raenge)
      talents     [name] = Zauber-ID des Talents        specs       Namen der drei Baeume
      power       Kraft: 0 Mana, 1 Wut, 3 Energie      gcd         globale Abklingzeit in s
      rangeSpell  Zauber, an denen die Reichweite zum Ziel gemessen wird (target.melee)
      meleeSpell  bei Fernkaempfern: Nahkampfzauber, an denen "Ziel steht an mir" gemessen
                  wird (target.close)
      gcdSpell    Zauber ohne eigene Abklingzeit (an ihnen ist die globale ablesbar)
      rules(S, add)        die Regeln                  slots(S, H)   Belegung der Hilfstasten
      precheck(S, add)     was vor dem Kampf fehlt     cooldowns     Reihe der Abklingzeiten
      snapshot, after, duration, regen, guessSpec, defaults, options   Extras der Klasse
-----------------------------------------------------------------------------]]

local _, NM = ...
if select(2, UnitClass("player")) ~= "ROGUE" then return end
local T, Plain, Call = NM.T, NM.Plain, NM.Call

local SP = {
    -- Aufbau
    sinister    = { ref = 1752,    cost = 45, cp = 1 },
    backstab    = { ref = 53,      cost = 60, cp = 1 },
    mutilate    = { ref = 1241582, cost = 60, cp = 2 },
    hemorrhage  = { ref = 16511,   cost = 35, cp = 1, dur = 15, unit = "target" },
    ghostly     = { ref = 14278,   cost = 40, cp = 1, cd = 20, dur = 7, unit = "player" },
    riposte     = { ref = 14251,   cost = 10, cp = 1, cd = 6 },
    shank       = { ref = 1329283, cost = 0 },
    -- Eroeffnung
    ambush      = { ref = 8676,    cost = 60, cp = 1, stealth = true },
    garrote     = { ref = 703,     cost = 50, cp = 1, stealth = true, dur = 18, unit = "target", dot = true },
    cheapshot   = { ref = 1833,    cost = 60, cp = 2, stealth = true, dur = 4, unit = "target", interrupts = true },
    premed      = { ref = 14183,   cost = 0,  cp = 2, cd = 120, stealth = "keep", offgcd = true },
    -- Finisher
    eviscerate  = { ref = 2098,    cost = 35, fin = true },
    snd         = { ref = 5171,    cost = 25, fin = true, unit = "player" },
    rupture     = { ref = 1943,    cost = 25, fin = true, unit = "target" },
    expose      = { ref = 8647,    cost = 25, fin = true, dur = 30, unit = "target" },
    kidney      = { ref = 408,     cost = 25, fin = true, cd = 20, unit = "target", interrupts = true },
    -- Kontrolle
    kick        = { ref = 1766,    cost = 25, cd = 10, interrupts = true },
    gouge       = { ref = 1776,    cost = 45, cp = 1, cd = 10, dur = 4, unit = "target", interrupts = true },
    blind       = { ref = 2094,    cost = 30, cd = 300 },
    -- Verteidigung und Bewegung
    evasion     = { ref = 5277,    cost = 0,  cd = 300, dur = 15, unit = "player", offgcd = true },
    sprint      = { ref = 2983,    cost = 0,  cd = 300, dur = 15, unit = "player", offgcd = true },
    vanish      = { ref = 1856,    cost = 0,  cd = 300, offgcd = true },
    feint       = { ref = 1966,    cost = 20, cd = 10 },
    stealth     = { ref = 1784,    cost = 0,  cd = 10, offgcd = true },
    -- Abklingzeiten
    bladeflurry = { ref = 13877,   cost = 25, cd = 120, dur = 15, unit = "player" },
    adrenaline  = { ref = 13750,   cost = 0,  cd = 300, dur = 15, unit = "player" },
    coldblood   = { ref = 14177,   cost = 0,  cd = 180, dur = 60, unit = "player", offgcd = true },
    preparation = { ref = 14185,   cost = 0,  cd = 600, offgcd = true },
    deathmark   = { ref = 1325756, cost = 0,  unit = "target" },
    -- nur als Name gebraucht
    sunder      = { ref = 7386,    unit = "target", foreign = true },
}

local TALENT = {
    improvedSnD = 14165, improvedGouge = 13741, vigor = 14983, ruthlessness = 14156,
    sealFate = 14186, relentless = 14179, improvedEvis = 14162, serrated = 14171,
    opportunity = 14057, improvedAmbush = 14079, initiative = 13976,
}

------------------------------------------------------------------------------
-- Eroeffnung aus der Verstohlenheit
------------------------------------------------------------------------------

local function ChooseOpener(S, big)
    local db, t, g = NM.db, S.target, S.gear
    local canAmbush = S:known("ambush") and g.mhDagger
    local canCheap = S:known("cheapshot") and t.stunnable
    local canGarrote = S:known("garrote") and t.bleedable

    if db.opener == "ambush" and canAmbush then return "ambush", T("Eröffnung nach Wahl", "Chosen opener") end
    if db.opener == "cheapshot" and canCheap then return "cheapshot", T("Eröffnung nach Wahl", "Chosen opener") end
    if db.opener == "garrote" and canGarrote then return "garrote", T("Eröffnung nach Wahl", "Chosen opener") end

    if t.casting and canCheap then
        return "cheapshot", T("Ziel wirkt: mit der Betäubung unterbrechen", "Target is casting: interrupt with the stun")
    end
    -- Kontrolle zuerst, wenn der Kampf gefaehrlich wird oder man nicht hinter das Ziel kommt
    local higher = t.level and t.level > 0 and t.level > S.level + 2
    local risky = t.elite or S.enemies.n >= 2 or higher or S.notBehind
    if canCheap and risky then
        return "cheapshot", T("Gefährlicher Kampf: erst betäuben", "Dangerous fight: stun first")
    end
    if canAmbush and not S.notBehind then
        return "ambush", T("Höchster Schaden aus der Verstohlenheit", "Highest damage from stealth")
    end
    if canGarrote and big then
        return "garrote", T("Langer Kampf: Blutung zum Auftakt", "Long fight: open with the bleed")
    end
    if canCheap then return "cheapshot", T("Betäuben und zwei Combopunkte", "Stun and two combo points") end
    if canGarrote then return "garrote", T("Blutung zum Auftakt", "Open with the bleed") end
    if S:known("backstab") and g.mhDagger and not S.notBehind then
        return "backstab", T("Meucheln aus der Verstohlenheit", "Backstab from stealth")
    end
    return "sinister", T("Angriff aus der Verstohlenheit", "Attack from stealth")
end

------------------------------------------------------------------------------
-- Regeln
------------------------------------------------------------------------------

local function Rules(S, add)
    local db = NM.db
    local t, en, g, items = S.target, S.enemies, S.gear, S.items
    local cp, e, ttd = S.cp, S.power, S.ttd
    local valid = t.valid
    local danger = S.danger
    local finCP = (db.finisherCP > 0 and db.finisherCP) or (S.spec == 1 and 4 or 5)
    -- schwerer oder langer Kampf: lohnt Abklingzeiten ("Boost" der Bots)
    local big = valid and (t.boss or t.elite or t.player or S.aoe >= 3 or (S.ttdMeasured and ttd > 25)) or false
    -- das Ziel stirbt gleich und es ist das einzige
    local dying = valid and S.ttdMeasured and ttd < 6 and en.n <= 1 or false

    local function R(k) return S:ready(k) end
    local function has(k) return S:aura(k) > 0 end

    -------------------------------------------------------------- vor dem Kampf
    if not S.inCombat and not S.stealthed then
        if db.usePoisons then
            if g.mhWeapon and not S.mhPoison and items.poisonInstant and not S.used.poison_mh then
                add("poison_mh", 20, T("Kein Gift auf der Waffenhand", "No poison on the main hand"),
                    { kind = "poison", item = items.poisonInstant, slot = 16 })
            end
            local oh = items.poisonDeadly or items.poisonInstant
            if g.ohWeapon and not S.ohPoison and oh and not S.used.poison_oh then
                add("poison_oh", 19, T("Kein Gift auf der Schildhand", "No poison on the off hand"),
                    { kind = "poison", item = oh, slot = 17 })
            end
        end
        if valid and db.autoStealth and R("stealth") then
            add("stealth", 40, T("Vor dem Kampf in die Verstohlenheit", "Stealth before the fight"))
        end
    end

    -------------------------------------------------------------- verstohlen
    if S.stealthed then
        if not valid then return end
        if R("premed") and cp <= 3 then
            add("premed", 45, T("Zwei Combopunkte vor der Eröffnung", "Two combo points before the opener"))
        end
        local opener, why = ChooseOpener(S, big)
        add(opener, 30, why)
        -- Ersatz, falls die Eroeffnung nicht geht (Waffe, Energie)
        if opener ~= "cheapshot" and t.stunnable then add("cheapshot", 12, T("Ersatz-Eröffnung", "Fallback opener")) end
        if opener ~= "garrote" and t.bleedable then add("garrote", 11.5, T("Ersatz-Eröffnung", "Fallback opener")) end
        if opener ~= "sinister" then add("sinister", 11, T("Ersatz-Eröffnung", "Fallback opener")) end
        return
    end

    -------------------------------------------------------------- Notfall (Reaktionen)
    if S.inCombat then
        local attacked = en.onMe > 0 or t.targetingMe == true
        if danger >= 2 and attacked and not has("evasion") and R("evasion") then
            add("evasion", 29, T("Mehrere Angreifer oder viele Treffer: Entrinnen", "Several attackers or many hits: Evasion"), { react = true })
        end
        if db.usePotions and S.lowHealth then
            if items.healthstone and not S.used.healthstone and S:itemReady(items.healthstone) then
                add("healthstone", 28.6, T("Gesundheit niedrig: Gesundheitsstein", "Low health: healthstone"),
                    { kind = "item", item = items.healthstone, react = true })
            elseif items.potion and not S.used.potion and S:itemReady(items.potion) then
                add("potion", 28.5, T("Gesundheit niedrig: Heiltrank", "Low health: healing potion"),
                    { kind = "item", item = items.potion, react = true })
            end
        end
        -- (Finte und Verschwinden geben die Gegner ab: das lohnt nur, wenn jemand tankt)
        local handOver = S.party.n == 0 or S.party.tankLikely
        if S.group and handOver and valid and not t.player and R("feint")
           and (S.threatTanking or (S.threatPct and S.threatPct >= 85)) then
            add("feint", 28, T("Zu viel Bedrohung: Finte", "Too much threat: Feint"), { react = true })
        end
        if R("vanish") and ((S.group and handOver and en.onMe >= 2)
           or (db.useVanish and danger >= 3 and not has("evasion"))) then
            add("vanish", 27, T("Mehrere Angreifer: Verschwinden", "Several attackers: Vanish"), { react = true })
        end
    end

    if not valid then return end

    -------------------------------------------------------------- Unterbrechen
    if t.casting and t.interruptible ~= false then
        if R("kick") then
            add("kick", 42, T("Ziel wirkt: unterbrechen", "Target is casting: interrupt"), { react = true })
        elseif cp >= 1 and t.stunnable and R("kidney") then
            add("kidney", 41.5, T("Ziel wirkt: mit Betäubung unterbrechen", "Target is casting: interrupt with a stun"), { react = true })
        elseif R("gouge") then
            add("gouge", 41, T("Ziel wirkt: mit Solarplexus unterbrechen", "Target is casting: interrupt with Gouge"), { react = true })
        end
    end

    -- Betaeubung als Schutz (nur bei gemessener Gefahr: geraten wuerde der Nierenhieb
    -- staendig Zerhaeckseln verdraengen)
    local stunned = has("cheapshot") or has("kidney") or has("gouge")
    if danger >= 2 and not S.dangerGuessed and cp >= 2 and t.stunnable and t.targetingMe ~= false
       and not stunned and R("kidney") then
        add("kidney", 26.5, T("Hoher eingehender Schaden: Ziel betäuben", "High incoming damage: stun the target"), { react = true })
    end

    -------------------------------------------------------------- nicht erreichbar
    if S.inCombat and t.melee == false and (t.farFor or 0) > 1.5 and not has("sprint") and R("sprint") then
        add("sprint", 22.2, T("Ziel nicht erreichbar: Sprinten", "Target out of reach: Sprint"))
    end

    -------------------------------------------------------------- Abklingzeiten
    if not dying then
        if not has("bladeflurry") and t.melee ~= false and R("bladeflurry") then
            if S.near >= 2 then
                add("bladeflurry", 24.5, T("Mehrere Gegner in Reichweite: Klingenwirbel", "Several enemies in reach: Blade Flurry"))
            elseif big and not (S.ttdMeasured and ttd < 10) then
                add("bladeflurry", 24.5, T("Schwerer Kampf: Klingenwirbel", "Hard fight: Blade Flurry"))
            end
        end
        if big and e <= 60 and not has("adrenaline") and R("adrenaline") then
            add("adrenaline", 22.4, T("Schwerer Kampf, Energie knapp: Adrenalinrausch", "Hard fight, low energy: Adrenaline Rush"))
        end
        if db.useDeathMark and (big or ttd > 10) and not has("deathmark") and R("deathmark") then
            add("deathmark", 22.6, T("Todesmal bereit", "Death Mark ready"))
        end
        if db.useTrinkets and big and g.trinkets then
            for _, slot in ipairs(g.trinkets) do
                local key = "trinket" .. slot
                if not S.used[key] and S:slotReady(slot) then
                    add(key, 21.8, T("Schwerer Kampf: Schmuckstück benutzen", "Hard fight: use trinket"), { kind = "trinket", slot = slot })
                end
            end
        end
        if db.usePotions and big and e <= 25 and items.tea and not S.used.tea and S:itemReady(items.tea) then
            add("tea", 12.5, T("Energie leer: Disteltee", "Out of energy: Thistle Tea"), { kind = "item", item = items.tea })
        end
    end
    if (danger >= 1 or big) and S:known("evasion") and S:cd("evasion") > 60 and R("preparation") then
        add("preparation", 10.5, T("Abklingzeiten zurücksetzen", "Reset cooldowns"))
    end

    -------------------------------------------------------------- Riposte
    if R("riposte") and S:usable("riposte") == true then
        add("riposte", 24, T("Nach Parade: Riposte", "After a parry: Riposte"))
    end

    -------------------------------------------------------------- Finisher
    -- Zerhaeckseln lohnt nur, wenn der Kampf noch eine Weile dauert (gelernte Kampfdauer)
    -- Gerechnet (Model.lua): Zerhaeckseln bringt seinen Tempozuwachs mal den Schaden der
    -- automatischen Angriffe, so lange es haelt und der Gegner lebt. Ausweiden bringt, was sein
    -- Text fuer die Combopunkte nennt. Das Groessere gewinnt.
    local M = NM.Model
    local evisDmg = db.useModel and cp >= 1 and S:known("eviscerate") and M:Damage(S, "eviscerate") or nil
    local white = db.useModel and S.model and S.model.meleeDPS or nil
    local sndGain
    if white and cp >= 1 and S:known("snd") then
        sndGain = white * ((M:Percent("snd") or 20) / 100) * math.min(NM.State.Duration("snd", cp) or 9, ttd)
    end
    local sndLeft = S:aura("snd")
    if S:known("snd") and cp >= 1 and sndLeft <= 1.5 then
        local worth
        if sndGain and evisDmg then worth = sndGain > evisDmg
        else worth = not dying and not (S.ttdMeasured and ttd < 8) end
        if worth then add("snd", 25, T("Zerhäckseln fehlt", "Slice and Dice is missing")) end
    end
    -- (ein Krieger in der Gruppe zerreisst die Ruestung selbst: dann bleiben die Punkte fuer Schaden)
    if db.useExposeArmor and S.group and S.party.class.WARRIOR == 0 and t.elite and ttd >= 25 and cp >= 1 and cp <= 3
       and S:known("expose") and not has("expose") and not has("sunder") then
        add("expose", 23, T("Rüstung des Ziels ist nicht gesenkt", "Target's armor is not reduced"))
    end
    if S:known("eviscerate") then
        if S.ttdMeasured and cp >= 3 and ttd <= 3 then
            add("eviscerate", 22, T("Ziel stirbt gleich: Combopunkte verbrauchen", "Target is about to die: spend combo points"))
        elseif cp >= finCP then
            if not dying and not has("coldblood") and (sndLeft > 1.5 or not S:known("snd")) and R("coldblood") then
                add("coldblood", 26, T("Kaltblütigkeit vor dem Ausweiden", "Cold Blood before Eviscerate"))
            end
            add("eviscerate", 20, T("Combopunkte voll: Ausweiden", "Combo points full: Eviscerate"))
        end
    end
    if cp >= finCP and S:known("rupture") and t.bleedable and not has("rupture") then
        local ruptureDmg = db.useModel and M:Damage(S, "rupture") or nil
        local worth
        if ruptureDmg and evisDmg then worth = ruptureDmg > evisDmg else worth = ttd >= 12 end
        if worth then add("rupture", 21, T("Ziel lebt lange genug: Blutung", "Target lives long enough: Rupture")) end
    end

    -------------------------------------------------------------- Aufbau
    if cp < 5 then
        -- hinter dem Ziel steht man nur, wenn es einen nicht angreift oder betaeubt ist
        local canBehind = not S.notBehind and (t.targetingMe == false or stunned)
        -- Alle Aufbauzauber, die gerade gehen. Ohne Schadensmodell gilt diese Reihenfolge; mit
        -- ihm entscheidet der Schaden je Energie (class.rotation).
        -- (pool: der Aufbauzauber bleibt stehen, auch wenn die Energie noch laenger fehlt -
        -- der automatische Angriff laeuft ohnehin und ist kein eigener Move)
        local n = 0
        local function build(key, why)
            add(key, 13 - n * 0.02, why, { pool = true })
            n = n + 1
        end
        if S:known("mutilate") and g.mhDagger and g.ohDagger and not S.notBehind then
            build("mutilate", T("Combopunkte aufbauen (zwei Dolche)", "Build combo points (two daggers)"))
        end
        if S:known("backstab") and g.mhDagger and canBehind then
            build("backstab", T("Hinter dem Ziel: Meucheln", "Behind the target: Backstab"))
        end
        if S:known("hemorrhage") then build("hemorrhage", T("Combopunkte aufbauen", "Build combo points")) end
        build("sinister", T("Combopunkte aufbauen", "Build combo points"))
        if t.targetingMe ~= false and not has("ghostly") and R("ghostly") then
            add("ghostly", 13.5, T("Ziel greift dich an: Geisterhafter Stoß", "Target attacks you: Ghostly Strike"))
        end
        if db.useShank and R("shank") then
            add("shank", 12.8, T("Stich bereit", "Shank ready"))
        end
    end
end

------------------------------------------------------------------------------
-- Hilfstasten, Vor-Kampf-Check, Extras
------------------------------------------------------------------------------

local function Slots(S, H)
    local g, items = S.gear, S.items
    local L = {}
    L.interrupt = { H.spell(H.pick({ "kick", "gouge" })) }
    L.stun = { H.known("cheapshot") and H.spell("cheapshot", "stealth") or nil,
               H.spell(H.pick({ "kidney", "gouge", "blind" }), H.known("cheapshot") and "nostealth" or nil) }
    -- Buff: ausserhalb des Kampfes zuerst das fehlende Waffengift
    local poison
    if NM.db.usePoisons then
        if g.mhWeapon and not S.mhPoison and items.poisonInstant then
            poison = { kind = "poison", item = items.poisonInstant, slot = 16, cond = "nocombat" }
        elseif g.ohWeapon and not S.ohPoison and (items.poisonDeadly or items.poisonInstant) then
            poison = { kind = "poison", item = items.poisonDeadly or items.poisonInstant, slot = 17, cond = "nocombat" }
        end
    end
    L.buff = { poison, H.spell(H.pick({ "bladeflurry", "adrenaline", "coldblood", "snd" })) }
    L.debuff = { H.known("garrote") and H.spell("garrote", "stealth") or nil,
                 H.spell(H.pick({ "expose", "rupture", "hemorrhage" }), H.known("garrote") and "nostealth" or nil) }
    L.heal = { H.item(items.healthstone or items.potion) }
    L.escape = { H.spell(H.pick({ "vanish", "sprint" })) }
    L.trinket = { H.trinket() or H.item(items.tea) }
    L.defense = { H.spell(H.pick({ "evasion", "feint" })) }
    return L
end

local function Precheck(S, add)
    local g, items = S.gear, S.items
    if not NM.db.usePoisons or S.level < 20 then return end
    if g.mhWeapon and not S.mhPoison then
        add(items.poisonInstant and T("Gift auf der Waffenhand", "main hand poison") or T("Waffengift (keins in den Taschen)", "weapon poison (none in bags)"))
    end
    if g.ohWeapon and not S.ohPoison and (items.poisonDeadly or items.poisonInstant) then
        add(T("Gift auf der Schildhand", "off hand poison"))
    end
end

NM.RegisterClass("ROGUE", {
    spells = SP,
    talents = TALENT,
    specs = { T("Meucheln", "Assassination"), T("Kampf", "Combat"), T("Täuschung", "Subtlety") },
    defaultSpec = 2,
    power = 3,
    gcd = 1.0,
    melee = true,
    combo = true,
    stealthBar = true,      -- die Hauptleiste wechselt in der Verstohlenheit die Seite
    rangeSpell = { "sinister", "eviscerate", "backstab" },
    gcdSpell = { "sinister", "eviscerate", "backstab" },
    probeBuff = "snd",
    items = {
        poisonInstant = { 8928, 8927, 8926, 6950, 6949, 6947 },
        poisonDeadly  = { 20844, 8985, 8984, 2893, 2892 },
        tea           = { 7676 },
    },
    defaults = {
        autoStealth = true,     -- vor dem Kampf Verstohlenheit empfehlen
        opener = "auto",        -- auto | ambush | cheapshot | garrote
        finisherCP = 0,         -- 0 = nach Talentbaum (Meucheln 4, sonst 5)
        usePoisons = true,
        useExposeArmor = true,
        useVanish = false,      -- Verschwinden als Notfall solo
        useDeathMark = true,
        useShank = false,       -- Wirkung im Client pruefen: /nxm info shank
    },
    options = {
        { key = "opener", label = T("Eröffnung", "Opener"), values = { "auto", "ambush", "cheapshot", "garrote" } },
        { key = "finisherCP", label = T("Combopunkte für Finisher", "Combo points for finishers"), values = { 0, 3, 4, 5 },
          format = function(v) if v == 0 then return T("automatisch", "automatic") end end },
    },
    labels = {
        autoStealth = T("Verstohlenheit vor dem Kampf empfehlen", "Suggest stealth before the fight"),
        usePoisons = T("Waffengifte", "Weapon poisons"),
        useExposeArmor = T("Rüstung schwächen (Gruppe)", "Expose Armor (group)"),
        useVanish = T("Verschwinden als Notfall allein", "Vanish as a solo emergency"),
        useDeathMark = T("Todesmal", "Death Mark"),
        useShank = T("Stich", "Shank"),
    },
    cooldowns = { "bladeflurry", "adrenaline", "coldblood", "evasion", "sprint", "vanish", "kick", "preparation" },
    cooldownBuffs = { "bladeflurry", "adrenaline", "evasion", "sprint", "coldblood", "ghostly" },

    guessSpec = function(spells, selected)
        if selected then return selected end
        if spells.adrenaline.id or spells.bladeflurry.id then return 2 end
        if spells.hemorrhage.id or spells.premed.id then return 3 end
        if spells.mutilate.id or spells.coldblood.id then return 1 end
        return 2
    end,

    duration = function(key, cp, State)
        local tal = State.talents
        if key == "snd" then return (6 + 3 * cp) * (1 + 0.15 * (tal[TALENT.improvedSnD] or 0)) end
        if key == "rupture" then return 6 + 2 * cp end
        if key == "kidney" then return 1 + cp end
        if key == "gouge" then return 4 + 0.5 * (tal[TALENT.improvedGouge] or 0) end
    end,

    regen = function(S) return (S:aura("adrenaline") > 0) and 20 or 10 end,

    snapshot = function(S)
        local hasMH, _, _, _, hasOH = Call(GetWeaponEnchantInfo)
        S.mhPoison, S.ohPoison = Plain(hasMH) and true or false, Plain(hasOH) and true or false
    end,

    after = function(S2, c)
        if c.key == "stealth" or c.key == "vanish" then S2.stealthed = true end
        if c.key == "adrenaline" then S2.regen = 20 end
        if c.key == "tea" and S2.power then S2.power = math.min(S2.powerMax or 100, S2.power + 100) end
        if c.key == "poison_mh" then S2.mhPoison = true end
        if c.key == "poison_oh" then S2.ohPoison = true end
    end,

    -- nach Schaden je Energie geordnet (Model.lua)
    rotation = { { "mutilate", "backstab", "hemorrhage", "sinister" } },
    rules = Rules,
    slots = Slots,
    precheck = Precheck,
})
