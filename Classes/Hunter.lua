--[[---------------------------------------------------------------------------
    Classes/Hunter.lua - Jaeger (Tierherrschaft, Treffsicherheit, Ueberleben)

    Herkunft der Regeln: mod-playerbots, src/Ai/Class/Hunter/Strategy/. Die Bots rechnen dort
    mit eigenen Zahlen; sie sind hier uebernommen:

      Bot (Strategie: Ausloeser -> Aktion, Prioritaet)             hier
      hunter: hunter's mark 29.5                                  Mal des Jaegers, wenn der
                                                                  Gegner lange genug lebt
              rapid fire 29 (Boost)                               in schweren Kaempfen
              has aggro -> concussive shot 20                     Ziel greift dich an und ist
                                                                  noch nicht bei dir
              low health -> deterrence 35                         Blizzards Warnung "niedrige
              medium threat -> feign death 35                     Gesundheit" oder mehrere
                                                                  Angreifer -> Abschreckung,
                                                                  Totstellen
              pet medium/low health -> mend pet 22/21             Gesundheit des Begleiters ist
                                                                  nicht lesbar: Tier heilen, wenn
                                                                  es einen starken Gegner tankt
              enemy within melee -> explosive trap 37,            Ziel steht an dir: Falle,
                mongoose bite 22 (sonst raptor strike),           Mungobiss, Gegenangriff,
                wing clip 21                                      Raptorstoss, Zurechtstutzen
                                                                  (nur unter dem Mindestabstand;
                                                                  sonst wird weiter geschossen)
      bm:     bestial wrath 19, intimidation 40                   ebenso
      alle:   no stings -> serpent sting 17 (Lebenszeit >= 8 s)   ebenso
              aimed shot 5.4, arcane shot 5.3                     ebenso (die Bots wirken den
                                                                  Arkanen Schuss durch einen
                                                                  Fehler nie; hier schon)
      aoe:    medium aoe (3) -> volley 22, light aoe (2) ->       ebenso; Mehrfachschuss in
              multi-shot 21                                       Treffsicherheit auch allein
      bdps:   aspect of the hawk 20 (sonst monkey)                ebenso
      pet:    no pet -> call pet 60, dead -> revive pet 60        ebenso
      nc:     trueshot aura                                       ebenso

    Was es in WoW Forever nicht gibt und deshalb entfaellt: Toetungsbefehl, Toedlicher
    Schuss, Zuverlaessiger Schuss, Schimaerenschuss, Explosivschuss, Schwarzer Pfeil,
    Unterdrueckender Schuss, Bereitschaft, Irrefuehrung, Aspekt der Viper / des Drachenfalken.

    "Automatischer Schuss" ist kein Move: er laeuft von selbst. Die Stiche des Begleiters
    ebenso. Besaenftigender Schuss braucht einen Wutanfall des Gegners - der ist als Effekt
    nicht lesbar, also liegt der Schuss nur auf einer Hilfstaste.
    Neue Forever-Zauber: Scharfschuetzenschuss und Falke rufen sind eingebaut, ihre genaue
    Wirkung kenne ich nicht (/nxm info sniper, /nxm info summonhawk); Schreiter-Tritt nicht.
-----------------------------------------------------------------------------]]

local _, NM = ...
if select(2, UnitClass("player")) ~= "HUNTER" then return end
local T, Get = NM.T, NM.Get

local SP = {
    -- Fernkampf
    autoshot    = { ref = 75,      always = true, nobar = true },     -- nur zum Messen der Reichweite
    serpent     = { ref = 1978,    dur = 15, unit = "target", dot = true },
    arcane      = { ref = 3044,    cd = 6 },
    aimed       = { ref = 19434,   cast = 3, cd = 6, weapon = "ranged" },
    multishot   = { ref = 2643,    cd = 10, weapon = "ranged", aoe = 3 },
    sniper      = { ref = 1310785, cast = 3 },
    concussive  = { ref = 5116,    cd = 12, dur = 4, unit = "target", slow = 0.5 },
    scorpid     = { ref = 3043,    dur = 20, unit = "target" },
    viper       = { ref = 3034,    dur = 8, unit = "target" },
    distracting = { ref = 20736,   cd = 8 },
    tranq       = { ref = 19801,   cd = 20 },
    scatter     = { ref = 19503,   cd = 30, dur = 4, unit = "target", interrupts = true },
    volley      = { ref = 1510,    channel = 6, cd = 60, aoe = true },
    mark        = { ref = 1130,    dur = 120, unit = "target" },
    -- Nahkampf
    raptor      = { ref = 14260,   cd = 6, offgcd = true, swing = true },
    mongoose    = { ref = 1495,    cd = 5 },
    counterattack = { ref = 20909, cd = 5 },
    wingclip    = { ref = 2974,    dur = 10, unit = "target", slow = 0.5 },
    disengage   = { ref = 781,     cd = 5 },
    -- Fallen
    immolationtrap = { ref = 13795, cd = 15 },
    explosivetrap  = { ref = 13813, cd = 15 },
    freezingtrap   = { ref = 1499,  cd = 15 },
    frosttrap      = { ref = 13809, cd = 15 },
    -- Schutz und Abklingzeiten
    feign       = { ref = 5384,    cd = 30, offgcd = true },
    deterrence  = { ref = 19263,   cd = 300, dur = 10, unit = "player", offgcd = true },
    rapidfire   = { ref = 3045,    cd = 300, dur = 15, unit = "player", offgcd = true },
    bestialwrath = { ref = 19574,  cd = 120, dur = 18, unit = "player", offgcd = true },
    intimidation = { ref = 19577,  cd = 60, interrupts = true, offgcd = true },
    summonhawk  = { ref = 1293525, once = true },
    scarebeast  = { ref = 1513,    cast = 1.5 },
    -- Aspekte (immer nur einer aktiv)
    hawk        = { ref = 13165,   dur = 9999, unit = "player", aspect = true },
    monkey      = { ref = 13163,   dur = 9999, unit = "player", aspect = true },
    cheetah     = { ref = 5118,    dur = 9999, unit = "player", aspect = true },
    pack        = { ref = 13159,   dur = 9999, unit = "player", aspect = true },
    wild        = { ref = 20043,   dur = 9999, unit = "player", aspect = true },
    beast       = { ref = 13161,   dur = 9999, unit = "player", aspect = true },
    trueshot    = { ref = 1299348, dur = 1800, unit = "player" },
    -- Begleiter
    callpet     = { ref = 883,     once = true },
    revivepet   = { ref = 982,     cast = 10, once = true },
    mendpet     = { ref = 136,     channel = 5, dur = 15, unit = "player" },
}

local TALENT = {
    intimidation = 19577, bestialWrath = 19574, scatterShot = 19503, trueshotAura = 1299346,
    sniperShot = 1310687, deterrence = 19263, counterattack = 19306, loneWolf = 415370,
    improvedConcussive = 19407, summonHawk = 1293241,
}

local ASPECTS = { "hawk", "monkey", "cheetah", "pack", "wild", "beast" }

-- Nahkampf oder Fernkampf? Gerechnet aus den Waffen (Model.lua): Schaden der automatischen
-- Angriffe plus die Dauerleistung der zugehoerigen Zauber. Ein schlechter Bogen mit einer
-- guten Nahkampfwaffe heisst: in den Nahkampf. Gilt, bis sich die Ausruestung aendert.
local function Mode(S)
    if S.hunterMode ~= nil then return S.hunterMode or nil end
    local M, st = NM.Model, S.model
    local mode = false
    -- (nur entscheiden, wenn der Client beide Seiten nennt: sonst hiesse "unbekannt" faelschlich "schwach")
    if NM.db.useModel and st and st.meleeDPS and st.rangedKnown then
        local melee = (st.meleeDPS or 0) + M:Rate(S, "raptor")
        local ranged = 0
        if st.rangedDPS then
            ranged = st.rangedDPS + M:Rate(S, "arcane") + M:Rate(S, "serpent") + M:Rate(S, "aimed") + M:Rate(S, "multishot")
        end
        mode = { melee = melee, ranged = ranged, preferMelee = melee > ranged * 1.15 }
    end
    S.hunterMode = mode
    return mode or nil
end

-- Gibt es einen Mindestabstand fuer Schuesse? Der Client nennt ihn bei der Reichweite.
local function DeadZone()
    for _, k in ipairs({ "autoshot", "arcane", "serpent" }) do
        local d = SP[k]
        if d and d.id and d.minRange then return d.minRange > 0 end
    end
    return nil
end

local function Rules(S, add)
    local db = NM.db
    local t, en, items = S.target, S.enemies, S.items
    local valid, ttd, danger = t.valid, S.ttd, S.danger
    local big = valid and (t.boss or t.elite or t.player or S.aoe >= 3 or (S.ttdMeasured and ttd > 30)) or false

    local function R(k) return S:ready(k) end
    local function has(k) return S:aura(k) > 0 end

    local aspect
    for _, k in ipairs(ASPECTS) do if has(k) then aspect = k; break end end

    -------------------------------------------------------------- vor dem Kampf
    if not S.inCombat then
        if db.usePet and not S.pet then
            -- kein Begleiter: rufen; ist er tot, wiederbeleben (beides steht dann zur Wahl)
            if S.petDead then
                if S:known("revivepet") and not S.used.revivepet then add("revivepet", 61, T("Begleiter ist tot", "Pet is dead")) end
            else
                if S:known("callpet") and not S.used.callpet then add("callpet", 60, T("Kein Begleiter", "No pet")) end
                if S:known("revivepet") and not S.used.revivepet then add("revivepet", 59, T("Falls der Begleiter tot ist", "If the pet is dead")) end
            end
        end
        if S:known("trueshot") and not has("trueshot") and not S.used.trueshot then
            add("trueshot", 19, T("Aura des Volltreffers fehlt", "Trueshot Aura is missing"))
        end
    end
    -- Aspekt: Falke (sonst Affe). Gepard und Rudel machen im Kampf benommen.
    local want = S:known("hawk") and "hawk" or "monkey"
    if S:known(want) and not S.used[want] then
        if not aspect then
            add(want, 20, T("Kein Aspekt aktiv", "No aspect active"))
        elseif (aspect == "cheetah" or aspect == "pack") and (S.inCombat or valid) then
            add(want, 20, T("Zum Kampf den Aspekt wechseln", "Switch the aspect for combat"))
        end
    end

    -------------------------------------------------------------- Notfall (Reaktionen)
    if S.inCombat then
        if db.usePotions and S.lowHealth then
            if items.healthstone and not S.used.healthstone and S:itemReady(items.healthstone) then
                add("healthstone", 62, T("Gesundheit niedrig: Gesundheitsstein", "Low health: healthstone"),
                    { kind = "item", item = items.healthstone, react = true })
            elseif items.potion and not S.used.potion and S:itemReady(items.potion) then
                add("potion", 61.5, T("Gesundheit niedrig: Heiltrank", "Low health: healing potion"),
                    { kind = "item", item = items.potion, react = true })
            end
        end
        -- Totstellen: mit Begleiter gibt man ihm die Gegner zurueck
        if R("feign") and ((S.group and en.onMe >= 2) or (S.lowHealth and S.pet) or (danger >= 2 and S.pet and en.onMe >= 2)) then
            add("feign", 35.5, T("Zu viele Angreifer an dir: Totstellen", "Too many attackers on you: Feign Death"), { react = true })
        elseif R("feign") and S.party.threatHigh then
            -- ein Tank ist da, und das Ziel dreht sich gleich um
            add("feign", 35.5, T("Zu viel Bedrohung: Totstellen", "Too much threat: Feign Death"), { react = true })
        end
        if (S.lowHealth or (danger >= 2 and t.close == true)) and not has("deterrence") and R("deterrence") then
            add("deterrence", 35, T("Du wirst im Nahkampf getroffen: Abschreckung", "You are being hit in melee: Deterrence"), { react = true })
        end
    end

    if not valid then return end

    -------------------------------------------------------------- Unterbrechen
    if t.casting and t.interruptible ~= false then
        if R("scatter") and t.close ~= true then
            add("scatter", 41, T("Ziel wirkt: Streuschuss", "Target is casting: Scatter Shot"), { react = true })
        elseif S.pet and R("intimidation") then
            add("intimidation", 40, T("Ziel wirkt: Einschüchterung", "Target is casting: Intimidation"), { react = true })
        end
    end

    -------------------------------------------------------------- Begleiter heilen
    -- Seine Gesundheit ist nicht lesbar: geheilt wird, wenn er einen starken Gegner schon
    -- eine Weile tankt (hoechstens alle 15 Sekunden)
    if db.useMendPet and S.pet and S.inCombat and t.onPet and (big or (S.fightTime or 0) > 8)
       and (S.fightTime or 0) > 5 and not has("mendpet") and S:known("mendpet") then
        add("mendpet", 22, T("Begleiter tankt schon länger: Tier heilen", "Pet has been tanking for a while: Mend Pet"))
    end

    -------------------------------------------------------------- Ziel steht an dir
    -- Ob im Nahkampf noch geschossen werden kann, sagt der Client selbst: die Reichweite der
    -- Schuesse (t.melee) ist dann weiter erfuellt. Nur wenn sie verneint wird (Mindestabstand),
    -- bleibt allein der Nahkampf. Schuesse machen mehr Schaden und gehen deshalb vor.
    if t.close == true then
        local onMe = t.targetingMe ~= false
        local mode = Mode(S)
        -- geschossen wird im Nahkampf nur, wenn die Schuesse reichen UND der Fernkampf mehr bringt
        local shots = t.melee == true and not (mode and mode.preferMelee)
        for _, trap in ipairs({ "explosivetrap", "immolationtrap" }) do
            if R(trap) and S:usable(trap) == true and onMe then
                add(trap, 37, T("Gegner an dir: Falle legen", "Enemy on you: lay a trap"))
                break
            end
        end
        if R("counterattack") and S:usable("counterattack") == true then
            add("counterattack", 22.5, T("Nach Parade: Gegenangriff", "After a parry: Counterattack"))
        end
        if R("mongoose") and S:usable("mongoose") == true then
            add("mongoose", 22, T("Nach Ausweichen: Mungobiss", "After a dodge: Mongoose Bite"))
        end
        if not shots then
            if R("raptor") then
                add("raptor", 21.5, (mode and mode.preferMelee) and T("Nahkampf bringt mehr: Raptorstoß", "Melee is stronger: Raptor Strike")
                    or T("Zu nah zum Schießen: Raptorstoß", "Too close to shoot: Raptor Strike"), { fixed = true })
            end
            if S:known("wingclip") and not has("wingclip") then
                add("wingclip", 21, T("Zurechtstutzen, dann Abstand gewinnen", "Wing Clip, then get distance"))
            end
            return      -- unter dem Mindestabstand gehen keine Schuesse
        end
        -- Schuesse gehen weiter: der Raptorstoss fuellt nur die Luecken (fest ganz hinten: er
        -- braucht einen Nahkampfschlag, und der faellt nicht, solange man schiesst)
        if R("raptor") then
            add("raptor", 5.2, T("Zwischen den Schüssen: Raptorstoß", "Between shots: Raptor Strike"), { fixed = true })
        end
    end

    -------------------------------------------------------------- Abklingzeiten
    if big and S.inCombat then
        if R("rapidfire") and not has("rapidfire") then add("rapidfire", 29, T("Schwerer Kampf: Schnellfeuer", "Hard fight: Rapid Fire")) end
        if S.pet and R("bestialwrath") and not has("bestialwrath") then
            add("bestialwrath", 19, T("Schwerer Kampf: Zorn des Wildtiers", "Hard fight: Bestial Wrath"))
        end
        if db.useSummonHawk and R("summonhawk") and not S.used.summonhawk and S:usable("summonhawk") ~= false then
            add("summonhawk", 18.8, T("Schwerer Kampf: Falke rufen", "Hard fight: Summon Hawk"))
        end
        if db.useTrinkets and S.gear.trinkets then
            for _, slot in ipairs(S.gear.trinkets) do
                local key = "trinket" .. slot
                if not S.used[key] and S:slotReady(slot) then
                    add(key, 18.5, T("Schwerer Kampf: Schmuckstück benutzen", "Hard fight: use trinket"), { kind = "trinket", slot = slot })
                end
            end
        end
    end

    -------------------------------------------------------------- Vorbereitung am Ziel
    -- Mal des Jaegers lohnt nur, wenn der Gegner lange genug lebt
    if S:known("mark") and not has("mark") and (big or ttd >= 12) then
        add("mark", 29.5, T("Mal des Jägers fehlt", "Hunter's Mark is missing"))
    end
    -- der Gegner kommt auf dich zu: verlangsamen (steht er schon an dir, bringt es nichts mehr)
    -- Mit Schadensmodell: nur, wenn Abstand etwas wert ist (Mindestabstand des Bogens, Fernkampf
    -- staerker als Nahkampf); sein Platz in der Rotation ergibt sich aus der gewonnenen Zeit.
    if S.inCombat and t.targetingMe == true and t.close ~= true and R("concussive") and not has("concussive") and not has("wingclip")
       and (S.kitePenalty == nil or S.kitePenalty > 0) then
        add("concussive", 20, T("Ziel kommt auf dich zu: Erschütternder Schuss", "Target is coming for you: Concussive Shot"))
    end

    -------------------------------------------------------------- Flaeche
    if S.aoe >= 3 and R("volley") and S.pet then
        add("volley", 22, T("Drei oder mehr Gegner: Salve", "Three or more enemies: Volley"))
    end
    if S.aoe >= 2 and R("multishot") then
        add("multishot", 21, T("Mehrere Gegner: Mehrfachschuss", "Several enemies: Multi-Shot"))
    end

    -------------------------------------------------------------- Rotation
    if S:known("serpent") and not has("serpent") and not has("scorpid") and not has("viper") and ttd >= 8
       and t.type ~= "mechanical" and t.type ~= "elemental" then
        add("serpent", 17, T("Schlangenbiss fehlt", "Serpent Sting is missing"))
    end
    if db.useSniperShot and R("sniper") then
        add("sniper", 5.45, T("Scharfschützenschuss bereit", "Sniper Shot ready"))
    end
    if R("aimed") then
        add("aimed", 5.4, T("Gezielter Schuss bereit", "Aimed Shot ready"))
    end
    -- Treffsicherheit schiesst den Mehrfachschuss auch auf ein einzelnes Ziel
    if S.spec == 2 and S.aoe < 2 and R("multishot") and db.multiSingle then
        add("multishot", 5.35, T("Mehrfachschuss bereit", "Multi-Shot ready"))
    end
    if db.arcaneFiller and R("arcane") then
        add("arcane", 5.3, T("Arkaner Schuss bereit", "Arcane Shot ready"))
    end
end

local function Slots(S, H)
    local items = S.items
    local L = {}
    L.interrupt = { H.spell(H.pick({ "scatter", "intimidation" })) }
    L.stun = { H.spell(H.pick({ "intimidation", "scatter", "freezingtrap", "wingclip", "concussive" })) }
    L.buff = { H.spell(H.pick({ "rapidfire", "bestialwrath", "summonhawk", "trueshot" })) }
    L.debuff = { H.spell(H.pick({ "tranq", "scorpid", "viper", "distracting", "mark" })) }
    L.heal = { H.item(items.healthstone or items.potion) or H.spell(H.known("mendpet") and "mendpet" or nil) }
    L.escape = { H.spell(H.pick({ "feign", "disengage", "cheetah" })) }
    L.trinket = { H.trinket() or H.item(items.manapotion) }
    L.defense = { H.spell(H.pick({ "deterrence", "feign", "monkey", "mendpet" })) }
    return L
end

local function Precheck(S, add)
    local db = NM.db
    if db.usePet and S.level >= 10 and S:known("callpet") and not S.pet then add(T("Begleiter", "pet")) end
    local aspect
    for _, k in ipairs(ASPECTS) do if S:has(k) then aspect = k; break end end
    if not aspect and (S:known("hawk") or S:known("monkey")) then add(T("Aspekt", "aspect")) end
    if S:known("trueshot") and not S:has("trueshot") then add(T("Aura des Volltreffers", "Trueshot Aura")) end
    -- Nahkampfwaffe staerker als die Fernkampfwaffe: sagen, denn die Symbole zeigen es erst im Kampf
    local mode = Mode(S)
    if mode and mode.preferMelee then
        add((T("Nahkampf stärker als Fernkampf (%s gegen %s Schaden/s)", "melee beats ranged (%s vs %s damage/s)")):format(
            NM.Model.Num(mode.melee), NM.Model.Num(mode.ranged)))
    end
    -- Munition, falls der Client das Munitionsfach kennt
    local ammo = Get(GetInventoryItemCount, "player", 0)
    if ammo and ammo > 1 and ammo < 200 then add((T("Munition knapp (%d)", "low on ammo (%d)")):format(ammo)) end
    -- Zufriedenheit des Begleiters (1 unzufrieden, 2 zufrieden, 3 gluecklich)
    local happy = S.pet and GetPetHappiness and Get(GetPetHappiness)
    if happy and happy < 3 then add(T("Begleiter füttern", "feed the pet")) end
end

NM.RegisterClass("HUNTER", {
    spells = SP,
    talents = TALENT,
    specs = { T("Tierherrschaft", "Beast Mastery"), T("Treffsicherheit", "Marksmanship"), T("Überleben", "Survival") },
    defaultSpec = 1,
    power = 0,
    gcd = 1.5,
    melee = false,
    rangeSpell = { "autoshot", "serpent", "arcane" },
    meleeSpell = { "raptor", "wingclip", "mongoose" },
    gcdSpell = { "serpent", "arcane", "mark", "hawk", "monkey" },
    probeBuff = "hawk",
    defaults = {
        usePet = true,
        useMendPet = true,
        arcaneFiller = true,    -- Arkaner Schuss als Fueller (kostet Mana)
        multiSingle = true,     -- Mehrfachschuss auch auf ein einzelnes Ziel (Treffsicherheit)
        useSniperShot = true,
        useSummonHawk = true,
    },
    labels = {
        usePet = T("Begleiter rufen und wiederbeleben", "Call and revive the pet"),
        useMendPet = T("Tier heilen, wenn der Begleiter tankt", "Mend Pet while the pet is tanking"),
        arcaneFiller = T("Arkaner Schuss als Füller", "Arcane Shot as a filler"),
        multiSingle = T("Mehrfachschuss auch auf Einzelziele", "Multi-Shot on single targets too"),
        useSniperShot = T("Scharfschützenschuss", "Sniper Shot"),
        useSummonHawk = T("Falke rufen", "Summon Hawk"),
    },
    cooldowns = { "rapidfire", "bestialwrath", "intimidation", "scatter", "feign", "deterrence", "concussive", "multishot", "aimed", "volley" },
    cooldownBuffs = { "rapidfire", "bestialwrath", "deterrence" },

    guessSpec = function(spells, selected)
        if selected then return selected end
        if spells.bestialwrath.id or spells.intimidation.id or spells.summonhawk.id then return 1 end
        if spells.sniper.id or spells.scatter.id or spells.trueshot.id then return 2 end
        if spells.counterattack.id or spells.deterrence.id then return 3 end
        return 1
    end,

    -- ein neuer Aspekt loest den alten ab
    onCast = function(key, now, State)
        if SP[key] and SP[key].aspect then
            for _, k in ipairs(ASPECTS) do
                if k ~= key then State.model[k] = nil end
            end
        end
    end,

    after = function(S2, c)
        local k = c.key
        if k == "callpet" or k == "revivepet" then S2.pet = true; S2.petDead = false end
        if SP[k] and SP[k].aspect then
            for _, other in ipairs(ASPECTS) do
                if other ~= k then S2.auraOv[other] = 0 end
            end
        end
    end,

    -- nach berechnetem Wert geordnet (Model.lua)
    rotation = { { "serpent", "arcane", "aimed", "multishot", "sniper", "concussive", "volley", "raptor" } },
    autoShot = true,        -- waehrend einer Zauberzeit fallen die automatischen Schuesse aus
    -- Was kostet es je Sekunde, wenn der Gegner an einem steht statt auf Abstand?
    kite = function(S)
        local mode = Mode(S)
        if not mode or mode.preferMelee then return 0 end
        local loss = NM.Model:Hurt(S, true) * mode.ranged           -- Treffer, die man einsteckt
        if DeadZone() ~= false and S.target.melee ~= true then      -- unter dem Mindestabstand nur Nahkampf
            loss = loss + math.max(0, mode.ranged - mode.melee)
        end
        return loss
    end,
    rules = Rules,
    slots = Slots,
    precheck = Precheck,
})
