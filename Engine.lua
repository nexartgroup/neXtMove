--[[---------------------------------------------------------------------------
    Engine.lua - aus den Regeln der Klasse die zwei besten naechsten Moves

    Wie in mod-playerbots melden Regeln Kandidaten mit einer Prioritaet; genommen wird der
    hoechste, der gerade moeglich ist. Die Regeln selbst stehen je Klasse in Classes/*.lua.

      Move 1   der beste Move jetzt. Laeuft gerade ein eigener Zauber, dann der beste Move
               fuer den Moment, in dem er fertig ist.
      Move 2   die zweitbeste Wahl im selben Moment (eine Alternative zu Move 1).
      Folge    zu jedem der beiden der Move, der danach am besten passt: der Zustand nach
               dem Move (Kraft, Combopunkte, Effekte, Abklingzeiten) wird durchgerechnet und
               darauf dieselbe Logik angewandt. Die Anzeige zeigt die Folge klein und leicht
               durchscheinend unter ihrem Move - zwei Straenge, damit der Fluss klar bleibt.
      Warnung  Reaktionen (Unterbrechen, Schutz, Heilung) sind Kandidaten mit react = true.
               Sie stehen drei Sekunden lang als Move 1 da; wird ihnen nicht gefolgt,
               ruecken sie ins Warnsymbol, und die Rotation laeuft in Move 1 weiter.
               (Im ersten Test stand Entrinnen 36 Sekunden lang als Move 1 und verdeckte
               die Rotation.)

    Ein Kandidat: key, prio, why und wahlweise
      kind   nil = Zauber, "item", "poison", "trinket"   (item, slot dazu)
      consum Verbrauchsgut zum Buffen (Consumables.lua): Gruppe, zu der es gehoert
      react  Reaktion statt Rotation
      pool   Grundzauber: bleibt stehen, auch wenn die Kraft noch laenger fehlt
      fixed  behaelt seinen Platz, auch wenn die Klasse den Zauber nach Wert ordnen laesst
      running  Dauerfeuer (Zauberstab), das schon laeuft: "weiter so" statt "druecken"
    Nach den Regeln ordnet das Schadensmodell (Model.lua) die Zauber der Rotation
    (class.rotation) nach berechnetem Wert; es setzt dabei value und dmg am Kandidaten.
    "Angreifen" und "Automatischer Schuss" sind keine Moves: sie laufen von selbst, sobald
    der Kampf mit einem Zauber oder einem Rechtsklick beginnt.
-----------------------------------------------------------------------------]]

local _, NM = ...
local SP = NM.SPELLS

local Engine = {}
NM.Engine = Engine

local ipairs = ipairs

local function byPrio(a, b) return a.prio > b.prio end

------------------------------------------------------------------------------
-- Gemeinsame Regeln, die jede Klasse aufrufen kann (NM.Common)
------------------------------------------------------------------------------

local T = NM.T
local Common = {}
NM.Common = Common

-- Volksfaehigkeiten: fuer jede Klasse angemeldet (Core.lua), gelernt hat sie nur das Volk
NM.RACIALS = {
    bloodfury  = { ref = 20572, cd = 120, dur = 15, unit = "player", offgcd = true },
    berserking = { ref = 26297, cd = 180, dur = 10, unit = "player", offgcd = true },
    warstomp   = { ref = 20549, cd = 120, cast = 0.5, interrupts = true },
}

-- schwerer oder langer Kampf: lohnt Abklingzeiten ("Boost" der Bots)
function Common.Big(S)
    local t = S.target
    return t.valid and (t.boss or t.elite or t.player or S.aoe >= 3 or (S.ttdMeasured and S.ttd > 30)) or false
end

-- Gesundheitsstein oder Heiltrank, wenn Blizzards Warnung "niedrige Gesundheit" laeuft
function Common.Heal(S, add, prio)
    local items = S.items
    if not (NM.db.usePotions and S.inCombat and S.lowHealth) then return end
    if items.healthstone and not S.used.healthstone and S:itemReady(items.healthstone) then
        add("healthstone", prio, T("Gesundheit niedrig: Gesundheitsstein", "Low health: healthstone"),
            { kind = "item", item = items.healthstone, react = true })
    elseif items.potion and not S.used.potion and S:itemReady(items.potion) then
        add("potion", prio - 0.1, T("Gesundheit niedrig: Heiltrank", "Low health: healing potion"),
            { kind = "item", item = items.potion, react = true })
    end
end

-- Manatrank, wenn der Client fuer den Hauptzauber "zu wenig Mana" meldet
function Common.Mana(S, add, prio)
    local id = S.items.manapotion
    if NM.db.usePotions and S.inCombat and id and not S.used.manapotion and S:itemReady(id) then
        add("manapotion", prio, T("Mana leer: Manatrank", "Out of mana: mana potion"), { kind = "item", item = id })
    end
end

-- Schmuckstuecke mit Benutzen-Effekt in schweren Kaempfen
function Common.Trinkets(S, add, prio)
    if not (NM.db.useTrinkets and S.inCombat and S.gear.trinkets) then return end
    for _, slot in ipairs(S.gear.trinkets) do
        local key = "trinket" .. slot
        if not S.used[key] and S:slotReady(slot) then
            add(key, prio, T("Schwerer Kampf: Schmuckstück benutzen", "Hard fight: use trinket"), { kind = "trinket", slot = slot })
        end
    end
end

-- Volksfaehigkeiten (laufen nach den Regeln jeder Klasse mit)
function Common.Racials(S, add)
    if not (NM.db.useRacials and S.inCombat and S.target.valid) then return end
    local t = S.target
    if Common.Big(S) then
        if S:ready("bloodfury") and not S:has("bloodfury") then
            add("bloodfury", 18.3, T("Schwerer Kampf: Kochendes Blut", "Hard fight: Blood Fury"))
        end
        if S:ready("berserking") and not S:has("berserking") then
            add("berserking", 18.2, T("Schwerer Kampf: Berserker", "Hard fight: Berserking"))
        end
    end
    -- Kriegsdonner: betaeubt alles um einen herum; gegen einen Zauber oder mehrere Angreifer
    local near = (S.isMelee and t.melee == true) or t.close == true or S.near >= 1
    if near and S:ready("warstomp") then
        if t.casting and t.interruptible ~= false then
            add("warstomp", 39, T("Ziel wirkt: Kriegsdonner", "Target is casting: War Stomp"), { react = true })
        elseif S.near >= 3 and S.danger >= 2 then
            add("warstomp", 27.5, T("Viele Angreifer an dir: Kriegsdonner", "Many attackers on you: War Stomp"), { react = true })
        end
    end
end

local function Candidates(S)
    local list = {}
    local function add(key, prio, why, c)
        c = c or {}
        c.key, c.prio, c.why = key, prio, why
        list[#list + 1] = c
    end
    NM.class.rules(S, add)
    Common.Racials(S, add)
    if NM.Consumables then NM.Consumables:Rules(S, add) end
    -- die Rotation nach berechnetem Wert ordnen (Model.lua); der Rest behaelt seine Plaetze
    if NM.Model then NM.Model:Order(S, list) end
    table.sort(list, byPrio)
    return list
end

-- Ist der Kandidat jetzt oder in den naechsten Sekunden moeglich? Setzt c.wait (Sekunden,
-- bis die Kraft reicht; nur bei Energie, wo die Wartezeit absehbar ist).
local function Check(S, c)
    c.wait, c.far = nil, nil
    if c.kind then return true end              -- Gegenstaende hat die Regel schon geprueft
    if c.running then return true end           -- Dauerfeuer, das schon laeuft (Zauberstab)
    if not SP[c.key] or not S:known(c.key) then return false end
    -- das Ziel ist fuer diesen Zauber zu weit weg (oder zu nah): moeglich, aber nachrangig
    if S:inRange(c.key) == false then c.far = true end
    if S:cd(c.key) > S.gcd + 0.15 then return false end
    -- in Bewegung gehen nur Sofortzauber (in der Vorschau steht man wieder)
    if S.moving and not S.sim then
        local d = SP[c.key]
        if d.channel or (d.castTime or d.cast or 0) > 0 then return false end
    end
    -- Die Auskunft des Clients geht vor: "benutzbar" heisst, die Kraft reicht jetzt.
    -- In der Vorschau ist sie unbekannt.
    local usable, noPower = S:usable(c.key)
    if usable == true then return true end
    local need = S:cost(c.key)
    if S.power and S.regen and S.regen > 0 then
        if noPower == true or S.power < need then
            local wait = (need - S.power) / S.regen
            if noPower and wait < 0.3 then wait = 0.3 end
            -- laenger als drei Sekunden wartet nur, wer als Grundzauber gemeldet ist (pool)
            if wait > 3 and not c.pool then return false end
            if wait > 0 then c.wait = wait end
            return true
        end
    elseif noPower == true then
        return false                            -- Mana oder Wut reicht nicht: nicht darauf warten
    elseif S.power and S.power < need then
        return false
    end
    -- aus anderem Grund nicht benutzbar (falsche Waffe, keine Verstohlenheit, kein Ausloeser)
    if usable == false then return false end
    return true
end

-- Der beste moegliche Kandidat. Was das Ziel gerade nicht erreicht, kommt erst dran, wenn
-- sonst nichts geht (die Anzeige faerbt es rot: naeher heran). Jeder Zauber hat seine eigene
-- Reichweite - Feuerschlag reicht kuerzer als Feuerball.
local function First(S, list, skipKey, skipReact)
    local far
    for _, c in ipairs(list) do
        if c.key ~= skipKey and not (skipReact and c.react) and Check(S, c) then
            if not c.far then return c end
            far = far or c
        end
    end
    return far
end

local reactKey, reactStart, reactSeen = nil, 0, 0

-- (fuer Diagnose und Tests)
Engine.Candidates = Candidates

function Engine:Pick(S)
    -- waehrend eines eigenen Zaubers gilt der Zustand nach seinem Ende
    local base = S
    if S.casting then
        base = S:after({ key = S.casting.key, current = true, left = S.casting.left })
    end
    local list = Candidates(base)

    -- die dringendste Reaktion
    local alert = First(base, list, nil, false)
    if alert and (not alert.react or alert.far) then
        alert = nil
        for _, c in ipairs(list) do
            if c.react and Check(base, c) and not c.far then alert = c; break end
        end
    end
    local demoted = false
    if alert then
        local now = S.now
        if reactKey ~= alert.key or now - reactSeen > 1.5 then reactKey, reactStart = alert.key, now end
        reactSeen = now
        demoted = (now - reactStart) > 3
        alert.fresh = (now - reactStart) < 0.3
        alert.demoted = demoted
    end

    -- zwei Straenge: [1] beste Wahl, [2] zweitbeste Wahl im selben Moment; jeder mit seiner
    -- Folge. Ein Strang: { move, state, follow = { move, state } }
    local strands = {}
    local m1 = First(base, list, nil, demoted)
    if not m1 then return strands, alert end
    local d1 = (m1.kind == nil) and SP[m1.key]
    if d1 and d1.fin then NM.State.suggestedFinisher = m1.key end
    -- ein Verbrauchsgut steht als Move 1: es schweigt nach einer Weile (Consumables.lua)
    if m1.consum then NM.Consumables:Shown(m1.consum, S.now) end

    local function Follow(m)
        local after = base:after(m)
        local f = First(after, Candidates(after), nil, true)
        if f then return { move = f, state = after } end
    end
    strands[1] = { move = m1, state = base, follow = Follow(m1) }

    local m2 = First(base, list, m1.key, true)
    if m2 then
        strands[2] = { move = m2, state = base, follow = Follow(m2) }
    end
    return strands, alert
end

