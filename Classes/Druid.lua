--[[---------------------------------------------------------------------------
    Classes/Druid.lua - Druide (Gleichgewicht, Wilder Kampf, Wiederherstellung)

    Herkunft der Regeln: mod-playerbots, src/Ai/Class/Druid/Strategy/:

      Bot (Strategie: Ausloeser -> Aktion, Prioritaet)             hier
      balance: faerie fire 29.5, insect swarm 18, moonfire 17.5,  ebenso (Zauberergestalt oder
               starfire 5.4, wrath 5.3, medium aoe -> hurricane   Mondkingestalt)
               23, medium mana -> innervate 29
      cat:     cat form 28, prowl 29.5, combo 5 -> rip 23.5,      ebenso; Zerfleischen (Mangle),
               ferocious bite 22.5 / execute 24, rake 21.5,       Wildes Bruellen und Tigerfuror
               shred 5.4, claw 5.2, medium threat -> cower 21     gibt es in Forever nicht
      bear:    bear form 28, bash 42, medium health -> frenzied   ebenso
               regeneration 27, lose aggro -> growl 26,
               aoe -> demoralizing roar 24.5, swipe 24,
               lacerate 16, demoralizing roar 15.5, maul 5.2,
               enrage 5.1
      druid:   almost full health -> barkskin 40,                 Baumrinde und Griff der Natur,
               being attacked -> nature's grasp 39                wenn man getroffen wird
      nc:      mark of the wild 14, thorns 10                     ebenso
      resto / healer dps: moonfire, wrath, starfire               Heiler: nur Schaden und Pflege

    Gestalten: Die Regeln folgen der AKTUELLEN Gestalt. Vor dem Kampf (oder ohne Gestalt)
    schlaegt das Addon die Gestalt des Baums vor: Wilder Kampf ab Stufe 20 die Katze, davor
    und als Tank der Baer; sonst die Zauberergestalt (Mondkin, wenn gelernt). Mitten im Kampf
    wird kein Gestaltwechsel verlangt.
    Die Kraft wechselt mit der Gestalt (Mana, Wut, Energie); Energie wird wie beim Schurken
    geschaetzt, Wut und Mana liest das Addon nur an der Benutzbarkeit der Zauber ab.
    Neue Forever-Zauber: Aufschlitzen (Lacerate) ist eingebaut; Urbiss (Primal Bite) nicht,
    seine Wirkung kenne ich nicht (/nxm info primalbite).
-----------------------------------------------------------------------------]]

local _, NM = ...
if select(2, UnitClass("player")) ~= "DRUID" then return end
local T = NM.T
local Common = NM.Common

local SP = {
    -- Gestalten
    bearform     = { ref = 5487,    once = true },
    direbear     = { ref = 9634,    once = true },
    catform      = { ref = 768,     once = true },
    moonkin      = { ref = 24858,   once = true },
    travel       = { ref = 783,     once = true },
    -- Zauberer
    wrath        = { ref = 5177,    cast = 2 },
    starfire     = { ref = 2912,    cast = 3.5 },
    moonfire     = { ref = 8921,    dur = 12, unit = "target", dot = true },
    insectswarm  = { ref = 24974,   dur = 12, unit = "target", dot = true },
    faeriefire   = { ref = 770,     dur = 40, unit = "target" },
    hurricane    = { ref = 16914,   channel = 10, cd = 60, aoe = true },
    entangling   = { ref = 339,     cast = 1.5, dur = 12, unit = "target" },
    hibernate    = { ref = 2637,    cast = 1.5 },
    -- Buffs, Schutz, Mana
    motw         = { ref = 1126,    dur = 1800, unit = "player" },
    gotw         = { ref = 21849,   dur = 3600, unit = "player", foreign = true },
    thorns       = { ref = 467,     dur = 600, unit = "player" },
    naturesgrasp = { ref = 16689,   cd = 60, dur = 45, unit = "player" },
    barkskin     = { ref = 22812,   cd = 60, dur = 15, unit = "player" },
    innervate    = { ref = 29166,   cd = 360, dur = 20, unit = "player" },
    -- Heilung und Pflege
    rejuvenation = { ref = 774,     dur = 12, unit = "player" },
    regrowth     = { ref = 8936,    cast = 2 },
    healingtouch = { ref = 5186,    cast = 3 },
    removecurse  = { ref = 2782 },
    curepoison   = { ref = 8946 },
    abolishpoison = { ref = 2893 },
    -- Baer (Wut)
    maul         = { ref = 6807,    cost = 15, offgcd = true, swing = true },
    swipe        = { ref = 779,     cost = 20, aoe = 3 },
    demoroar     = { ref = 99,      cost = 10, dur = 30, unit = "target" },
    bash         = { ref = 5211,    cost = 10, cd = 60, dur = 3, unit = "target", interrupts = true },
    enrage       = { ref = 5229,    cd = 60, offgcd = true },
    growl        = { ref = 6795,    cd = 10, offgcd = true },
    challengingroar = { ref = 5209, cost = 15, cd = 600 },
    frenziedregen = { ref = 22842,  cd = 180, dur = 10, unit = "player", offgcd = true },
    lacerate     = { ref = 1328616, cost = 15, dur = 15, unit = "target", dot = true },
    feralcharge  = { ref = 1238122, cost = 5, cd = 15, interrupts = true, offgcd = true },
    -- Katze (Energie, Combopunkte)
    claw         = { ref = 1082,    cost = 45, cp = 1 },
    shred        = { ref = 5221,    cost = 60, cp = 1 },
    rake         = { ref = 1822,    cost = 40, cp = 1, dur = 9, unit = "target", dot = true },
    rip          = { ref = 1079,    cost = 30, fin = true, dur = 12, unit = "target" },
    ferociousbite = { ref = 1328618, cost = 35, fin = true },
    primalbite   = { ref = 1238069 },
    prowl        = { ref = 5215,    cd = 10, offgcd = true },
    pounce       = { ref = 9005,    cost = 50, cp = 1, stealth = true, dur = 2, unit = "target" },
    ravage       = { ref = 6785,    cost = 60, cp = 1, stealth = true },
    dash         = { ref = 1850,    cd = 300, dur = 15, unit = "player", offgcd = true },
    cower        = { ref = 8998,    cost = 20, cd = 10 },
}

local TALENT = {
    insectSwarm = 5570, moonkinForm = 24858, feralCharge = 1238122, furor = 17056,
    naturesGrace = 16880, leaderOfThePack = 17007, thickHide = 16929,
}

local BEAR = { bearform = true, direbear = true }

-- welche Gestalt zu Baum und Stufe passt: "cat", "bear" oder "caster"
local function WantedForm(S)
    local db = NM.db
    if db.form ~= "auto" then return db.form end
    if S.spec == 2 then
        if (db.tankMode or not S:known("catform")) and (S:known("bearform") or S:known("direbear")) then return "bear" end
        if S:known("catform") then return "cat" end
    end
    return "caster"
end

local function CurrentForm(S)
    if S.form == "catform" then return "cat" end
    if BEAR[S.form] then return "bear" end
    return "caster"         -- keine Gestalt, Mondkin, Reisegestalt
end

------------------------------------------------------------------------------
-- Regeln je Gestalt
------------------------------------------------------------------------------

local function CasterRules(S, add, ctx)
    local t, en = S.target, S.enemies
    local ttd, danger, big = S.ttd, S.danger, ctx.big
    local R, has = ctx.R, ctx.has
    local _, noMana = S:usable("wrath")
    local oom = noMana == true or false

    if S.inCombat then
        if S.lowHealth and not S.moving then
            for _, k in ipairs({ "regrowth", "healingtouch", "rejuvenation" }) do
                if S:known(k) then
                    add(k, 60, T("Gesundheit niedrig: dich heilen", "Low health: heal yourself"), { react = true })
                    break
                end
            end
        end
        if oom then
            if R("innervate") and not has("innervate") then add("innervate", 29, T("Mana leer: Anregen", "Out of mana: Innervate")) end
            Common.Mana(S, add, 24.5)
        end
    end
    if not t.valid then return end

    local meleed = S.inCombat and (S.hitRate or 0) >= 0.2 and en.onMe >= 1
    if meleed and R("naturesgrasp") and not has("naturesgrasp") then
        add("naturesgrasp", 39, T("Gegner an dir: Griff der Natur", "Enemy on you: Nature's Grasp"))
    end
    if S.aoe >= 3 and R("hurricane") then
        add("hurricane", 23, T("Drei oder mehr Gegner: Hurrikan", "Three or more enemies: Hurricane"))
    end
    if S:known("faeriefire") and not has("faeriefire") and (S.group and big) and ttd >= 25 then
        add("faeriefire", 29.5, T("Feenfeuer fehlt", "Faerie Fire is missing"))
    end
    if S:known("insectswarm") and not has("insectswarm") and ttd >= 8 then
        add("insectswarm", 18, T("Insektenschwarm fehlt", "Insect Swarm is missing"))
    end
    if S:known("moonfire") and not has("moonfire") and ttd >= 8 then
        add("moonfire", 17.5, T("Mondfeuer fehlt", "Moonfire is missing"))
    end
    -- Sternenfeuer lohnt seine lange Zauberzeit gegen starke Gegner und als Eroeffnung
    if S:known("starfire") and (big or not S.inCombat or ttd >= 14) then
        add("starfire", 5.4, T("Hauptzauber", "Main spell"))
    end
    if S:known("wrath") then add("wrath", 5.3, T("Hauptzauber", "Main spell")) end
    -- in Bewegung: Mondfeuer auch, wenn es noch laeuft
    if S.moving and S:known("moonfire") then
        add("moonfire", 5.2, T("In Bewegung: Mondfeuer", "Moving: Moonfire"))
    end
end

local function BearRules(S, add, ctx)
    local db = NM.db
    local t = S.target
    local ttd, danger, big = S.ttd, S.danger, ctx.big
    local R, has = ctx.R, ctx.has
    -- Tank: von Hand gewaehlt, als Rolle zugewiesen, oder in der Gruppe, solange kein anderer tankt
    local P = S.party
    local tank = db.tankMode or P.myRole == "TANK" or (S.group and P.myRole == nil and not P.tank)

    if S.inCombat and (S.lowHealth or danger >= 2) and R("frenziedregen") and not has("frenziedregen") then
        add("frenziedregen", 60, T("Viele Treffer: Rasende Regeneration", "Many hits: Frenzied Regeneration"), { react = true })
    end
    if not t.valid then return end

    if t.casting and t.interruptible ~= false then
        if t.melee == false and R("feralcharge") then
            add("feralcharge", 42, T("Ziel wirkt: Wilde Attacke unterbricht", "Target is casting: Feral Charge interrupts"), { react = true })
        elseif t.stunnable and R("bash") then
            add("bash", 42, T("Ziel wirkt: Hieb betäubt", "Target is casting: Bash stuns"), { react = true })
        end
    end
    if S.inCombat and t.melee == false and R("feralcharge") then
        add("feralcharge", 18, T("Ziel nicht in Reichweite: Wilde Attacke", "Target out of reach: Feral Charge"))
    end
    -- (einem zweiten Tank nimmt man das Ziel nicht weg)
    if tank and S.group and S.inCombat and t.targetingMe == false and not (P.aggro and not P.aggroSoft) and not t.player and R("growl") then
        add("growl", 26, T("Ziel greift jemand anderen an: Knurren", "Target attacks someone else: Growl"), { react = true })
    end
    if (S.inCombat or t.melee == true) and not S:atLeast(10) and R("enrage") and danger < 2 then
        add("enrage", 22, T("Wut fehlt: Wutanfall", "No rage: Enrage"))
    end
    if S.near >= 2 then
        if S:known("demoroar") and not has("demoroar") then
            add("demoroar", 24.5, T("Mehrere Gegner: Demoralisierendes Gebrüll", "Several enemies: Demoralizing Roar"))
        end
        if S:known("swipe") then add("swipe", 24, T("Mehrere Gegner: Prankenhieb", "Several enemies: Swipe")) end
    end
    if S:known("lacerate") and ((S.lacerateStacks or 0) < 5 or S:aura("lacerate") < 6) and ttd >= 8 then
        add("lacerate", 16, T("Aufschlitzen aufbauen", "Stack Lacerate"))
    end
    if S:known("demoroar") and not has("demoroar") and ttd >= 10 and (big or tank) then
        add("demoroar", 15.5, T("Demoralisierendes Gebrüll fehlt", "Demoralizing Roar is missing"))
    end
    -- Zermalmen: Wut abbauen (der Client sagt, ob sie reicht)
    if S:known("maul") then add("maul", 5.2, T("Wut übrig: Zermalmen", "Spare rage: Maul")) end
end

local function CatRules(S, add, ctx)
    local db = NM.db
    local t = S.target
    local ttd, big = S.ttd, ctx.big
    local R, has = ctx.R, ctx.has
    local cp = S.cp
    local dying = t.valid and S.ttdMeasured and ttd <= 3 or false

    if not t.valid then return end

    -- verstohlen: Eroeffnung
    if S.stealthed then
        local opener
        if S:known("pounce") and t.stunnable and (t.elite or S.enemies.n >= 2 or S.notBehind or not S:known("ravage")) then
            opener = "pounce"
        elseif S:known("ravage") and not S.notBehind then
            opener = "ravage"
        elseif S:known("pounce") and t.stunnable then
            opener = "pounce"
        else
            opener = (S:known("shred") and not S.notBehind) and "shred" or "claw"
        end
        add(opener, 30, T("Eröffnung aus der Verstohlenheit", "Opener from stealth"))
        if opener ~= "claw" then add("claw", 11, T("Ersatz-Eröffnung", "Fallback opener")) end
        return
    end
    if not S.inCombat and db.autoProwl and R("prowl") then
        add("prowl", 29.5, T("Vor dem Kampf schleichen", "Prowl before the fight"))
    end

    if S.inCombat and t.melee == false and (t.farFor or 0) > 1.5 and not has("dash") and R("dash") then
        add("dash", 28, T("Ziel nicht erreichbar: Spurt", "Target out of reach: Dash"))
    end
    if S.group and (S.party.n == 0 or S.party.tankLikely) and S.inCombat and not t.player and R("cower") and (S.threatTanking or (S.threatPct and S.threatPct >= 85)) then
        add("cower", 21, T("Zu viel Bedrohung: Ducken", "Too much threat: Cower"), { react = true })
    end

    -- Finisher
    if S:known("ferociousbite") and cp >= 3 and dying then
        add("ferociousbite", 24, T("Ziel stirbt gleich: Wilder Biss", "Target is about to die: Ferocious Bite"))
    end
    if cp >= 5 then
        if S:known("rip") and t.bleedable and not has("rip") and ttd >= 12 then
            add("rip", 23.5, T("Combopunkte voll: Zerfetzen", "Combo points full: Rip"))
        end
        if S:known("ferociousbite") then
            add("ferociousbite", 22.5, T("Combopunkte voll: Wilder Biss", "Combo points full: Ferocious Bite"))
        elseif S:known("rip") and t.bleedable then
            add("rip", 22.4, T("Combopunkte voll: Zerfetzen", "Combo points full: Rip"))
        end
    end
    -- Aufbau
    if cp < 5 then
        if S:known("rake") and t.bleedable and not has("rake") and ttd >= 6 then
            add("rake", 21.5, T("Krallenhieb fehlt", "Rake is missing"))
        end
        -- hinter dem Ziel steht man nur, wenn es einen nicht angreift
        local canBehind = not S.notBehind and t.targetingMe == false
        if S:known("shred") and canBehind then
            add("shred", 5.4, T("Hinter dem Ziel: Schreddern", "Behind the target: Shred"), { pool = true })
        end
        if S:known("claw") then
            add("claw", 5.2, T("Combopunkte aufbauen", "Build combo points"), { pool = true })
        elseif S:known("rake") then
            add("rake", 5.1, T("Combopunkte aufbauen", "Build combo points"), { pool = true })
        end
    end
end

local function Rules(S, add)
    local db = NM.db
    local t = S.target
    local danger = S.danger
    local ctx = {
        big = Common.Big(S),
        R = function(k) return S:ready(k) end,
        has = function(k) return S:aura(k) > 0 end,
    }
    local has = ctx.has
    local form, want = CurrentForm(S), WantedForm(S)

    -------------------------------------------------------------- Pflege (nur ohne Tiergestalt wirkbar)
    if not S.inCombat and form == "caster" then
        if S:known("motw") and not has("motw") and not has("gotw") and not S.used.motw then
            add("motw", 21, T("Mal der Wildnis fehlt", "Mark of the Wild is missing"))
        end
        if S:known("thorns") and not has("thorns") and not S.used.thorns then
            add("thorns", 20, T("Dornen fehlen", "Thorns is missing"))
        end
    end

    -------------------------------------------------------------- Gestalt des Baums
    -- vor dem Kampf, oder im Kampf nur aus der Zauberergestalt heraus (Wilder Kampf)
    if form ~= want and (t.valid or S.inCombat) and (not S.inCombat or form == "caster") then
        local key
        if want == "cat" then key = "catform"
        elseif want == "bear" then key = S:known("direbear") and "direbear" or "bearform"
        elseif want == "caster" and S:known("moonkin") and S.form ~= "moonkin" and not S.inCombat then key = "moonkin" end
        if key and S:known(key) and not S.used[key] then
            add(key, 28, T("Gestalt für diesen Baum", "Form for this spec"))
        end
    elseif want == "caster" and S.spec == 1 and S:known("moonkin") and S.form ~= "moonkin" and not S.inCombat
       and t.valid and not S.used.moonkin then
        add("moonkin", 28, T("Mondkingestalt", "Moonkin Form"))
    end

    -------------------------------------------------------------- Notfall (Reaktionen)
    if S.inCombat then
        Common.Heal(S, add, 62)
        if (S.lowHealth or danger >= 2) and S:ready("barkskin") and not has("barkskin") then
            add("barkskin", 40, T("Viele Treffer: Baumrinde", "Many hits: Barkskin"), { react = true })
        end
    end

    if form == "cat" then CatRules(S, add, ctx)
    elseif form == "bear" then BearRules(S, add, ctx)
    else CasterRules(S, add, ctx) end

    if ctx.big and S.inCombat then Common.Trinkets(S, add, 18.6) end
end

local function Slots(S, H)
    local items = S.items
    local L = {}
    L.interrupt = { H.spell(H.pick({ "bash", "feralcharge" })) }
    L.stun = { H.known("pounce") and H.spell("pounce", "stealth") or nil,
               H.spell(H.pick({ "bash", "entangling", "hibernate" }), H.known("pounce") and "nostealth" or nil) }
    L.buff = { H.spell(H.pick({ "innervate", "enrage", "motw", "thorns" })) }
    L.debuff = { H.spell(H.pick({ "faeriefire", "demoroar", "removecurse", "abolishpoison", "curepoison" })) }
    L.heal = { H.item(items.healthstone or items.potion) or H.spell(H.pick({ "regrowth", "healingtouch", "rejuvenation" })) }
    L.escape = { H.spell(H.pick({ "dash", "travel", "entangling" })) }
    L.trinket = { H.trinket() or H.item(items.manapotion) }
    L.defense = { H.spell(H.pick({ "barkskin", "frenziedregen", "naturesgrasp", "rejuvenation" })) }
    return L
end

local function Precheck(S, add)
    if S:known("motw") and not S:has("motw") and not S:has("gotw") then add(T("Mal der Wildnis", "Mark of the Wild")) end
    if S:known("thorns") and not S:has("thorns") then add(T("Dornen", "Thorns")) end
    -- Gruppe: wem das Mal fehlt, und Dornen fuer den Tank
    if S.party.n > 0 then
        if S:known("motw") then NM.Party:Check(add, T("Mal der Wildnis", "Mark of the Wild"), { "motw", "gotw" }) end
        if S:known("thorns") then
            NM.Party:Check(add, T("Dornen für den Tank", "Thorns for the tank"), { "thorns" }, function(m) return m.role == "TANK" end)
        end
    end
end

-- Aufschlitzen stapelt bis fuenf: mitgezaehlt wie Ruestung zerreissen beim Krieger
local lacCount, lacUntil, lacGuid = 0, 0, nil

NM.RegisterClass("DRUID", {
    spells = SP,
    talents = TALENT,
    specs = { T("Gleichgewicht", "Balance"), T("Wilder Kampf", "Feral Combat"), T("Wiederherstellung", "Restoration") },
    defaultSpec = 1,        -- wie die Bots ohne Talente
    power = 0,
    dynamicPower = true,    -- Mana, Wut oder Energie je nach Gestalt
    combo = true,
    stealthBar = false,
    gcd = function(S) return S.form == "catform" and 1.0 or 1.5 end,
    melee = function(S) return S.form == "catform" or BEAR[S.form] or false end,
    rangeSpell = function(S)
        if S.form == "catform" then return { "claw", "rake", "shred" } end
        if BEAR[S.form] then return { "maul", "swipe", "bash" } end
        return { "wrath", "moonfire" }
    end,
    gcdSpell = function(S)
        if S.form == "catform" then return { "claw", "rake", "shred" } end
        if BEAR[S.form] then return { "swipe", "demoroar", "lacerate" } end
        return { "wrath", "moonfire", "rejuvenation", "motw" }
    end,
    probeBuff = "motw",
    defaults = {
        form = "auto",          -- auto | caster | cat | bear
        tankMode = false,       -- Wilder Kampf als Baer
        autoProwl = true,       -- als Katze vor dem Kampf schleichen
    },
    options = {
        { key = "form", label = T("Gestalt", "Form"), values = { "auto", "caster", "cat", "bear" },
          format = function(v)
              return (v == "auto" and T("nach Baum", "by spec")) or (v == "caster" and T("Zauberer", "caster"))
                  or (v == "cat" and T("Katze", "cat")) or T("Bär", "bear")
          end },
    },
    labels = {
        tankMode = T("Wilder Kampf als Bär (Tank)", "Feral as a bear (tank)"),
        autoProwl = T("Als Katze vor dem Kampf schleichen", "Prowl before the fight as a cat"),
    },
    cooldowns = { "bash", "feralcharge", "enrage", "frenziedregen", "barkskin", "naturesgrasp", "innervate", "dash", "hurricane", "growl" },
    cooldownBuffs = { "barkskin", "frenziedregen", "naturesgrasp", "dash", "innervate" },

    guessSpec = function(spells, selected)
        if selected then return selected end
        if spells.feralcharge.id or spells.lacerate.id then return 2 end
        if spells.moonkin.id or spells.insectswarm.id then return 1 end
        return 1
    end,

    duration = function(key, cp)
        if key == "rip" then return 12 end
    end,

    onCast = function(key, now)
        if key == "lacerate" then
            local guid = NM.Plain(UnitGUID("target"))
            if guid ~= lacGuid or now > lacUntil then lacCount = 0 end
            lacGuid = guid
            lacCount = math.min(5, lacCount + 1)
            lacUntil = now + 15
        end
    end,

    snapshot = function(S, _, now)
        local guid = S.target.guid
        S.lacerateStacks = (guid and guid == lacGuid and now <= lacUntil) and lacCount or 0
    end,

    after = function(S2, c, _, S)
        local k = c.key
        if k == "catform" or k == "bearform" or k == "direbear" or k == "moonkin" then S2.form = k end
        if k == "prowl" then S2.stealthed = true end
        if k == "lacerate" then S2.lacerateStacks = math.min(5, (S.lacerateStacks or 0) + 1) end
    end,

    -- nach berechnetem Wert geordnet (Model.lua): je Gestalt eine Gruppe
    rotation = { { "wrath", "starfire", "moonfire", "insectswarm", "hurricane" }, { "shred", "claw", "rake" }, { "maul", "swipe", "lacerate" } },
    kite = function(S, M)
        if S.form == "catform" or S.form == "bearform" or S.form == "direbear" then return nil end
        return M.CasterKite(S, M)
    end,
    rules = Rules,
    slots = Slots,
    precheck = Precheck,
})
