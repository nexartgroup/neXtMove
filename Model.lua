--[[---------------------------------------------------------------------------
    Model.lua - Schadensmodell: was ein Move bringt, gemessen an dem, was er kostet

    Die Regeln der Klasse (Classes/*.lua) sagen, WANN ein Zauber in Frage kommt. Dieses
    Modell sagt, WIE VIEL er bringt, und ordnet danach die Rotation. Das Prinzip hinter
    jeder Rotation ist dasselbe:

        Wert = erwarteter Schaden / (Zeit, die der Move belegt + Zeit, die seine Kosten wert sind)

      Schaden   aus dem Zaubertext des Clients (die Zahlen stehen dort fertig gerechnet) und
                aus den Werten des Charakters: Waffenschaden und -tempo, kritische Treffer.
                Schaden ueber Zeit zaehlt nur so weit, wie der Gegner noch lebt. Flaechen-
                zauber zaehlen je Gegner.
      Zeit      Zauberzeit oder globale Abklingzeit. Ein Schlag "beim naechsten Angriff"
                (Heldenhafter Stoss, Raptorstoss) belegt keine Zeit. Wer nebenher von selbst
                schiesst (Jaeger), verliert waehrend einer Zauberzeit diese Schuesse.
      Kosten    Energie und Wut: so lange, wie sie zum Nachwachsen brauchen. Mana: so lange,
                wie man dafuer trinken muss (ein voller Vorrat etwa 25 Sekunden). Darum
                schlaegt der Zauberstab oft den Hauptzauber, solange einen niemand angreift.
      Beschuss  Jede Sekunde, in der man Treffer einsteckt, kostet zusaetzlich die Zeit, die
                man danach zum Erholen braucht. Wer angegriffen wird, will deshalb schnell
                toeten: dann gewinnt der teure, starke Zauber gegen den sparsamen.
      Abstand   Kommt der Gegner auf einen zu, ist jede Sekunde auf Abstand etwas wert (kein
                Zurueckwerfen beim Zaubern, kein Mindestabstand des Bogens, weniger Treffer).
                Ein Verlangsamen bekommt diesen Gewinn gutgeschrieben.

    Was das Addon dafuer sammelt:
      vor dem Kampf   Waffenschaden, Angriffstempo, Angriffskraft, kritische Treffer,
                      Zaubermacht (im Kampf teils geheim: der letzte Stand bleibt stehen),
                      Zaubertexte, Kosten, Zauberzeiten, Reichweiten
      im Kampf        eigene Zauber und Schlaege (PLAYER_SWING) -> verbuchter Schaden je Ziel;
                      Entfernung des Ziels aus den Reichweiten der eigenen Zauber
      nach dem Kampf  wie viel verbuchter Schaden ein Gegner dieser Art aushaelt (daraus die
                      Restlebenszeit), wie viel Mana ein Kampf kostet, wie viele Treffer er
                      einbringt

    Fehlt dem Modell etwas (Text nicht lesbar, Waffe unbekannt), bleibt fuer diesen Zauber
    die feste Reihenfolge der Klasse bestehen.
-----------------------------------------------------------------------------]]

local _, NM = ...
local SP = NM.SPELLS
local Plain, Call, Get, T = NM.Plain, NM.Call, NM.Get, NM.T
local max, min, floor = math.max, math.min, math.floor
local GetTime = GetTime

local Model = { stats = {} }
NM.Model = Model

local EMPTY = {}
local MOB_SPEED = 7             -- Meter je Sekunde, die ein Gegner laeuft
local REST_TIME = 25            -- Sekunden, um Mana oder Gesundheit einmal ganz aufzufuellen

------------------------------------------------------------------------------
-- Werte des Charakters
------------------------------------------------------------------------------

local lastStats = 0

local function avg(a, b)
    if type(a) == "number" and type(b) == "number" and b > 0 then return (a + b) / 2 end
end

-- Liest, was lesbar ist; im Kampf Geheimes bleibt auf dem letzten Stand.
function Model:ReadStats()
    local st = self.stats
    local lo, hi, olo, ohi = Call(UnitDamage, "player")
    local mhAvg, ohAvg = avg(Plain(lo), Plain(hi)), avg(Plain(olo), Plain(ohi))
    local mhS, ohS, rS = Call(UnitAttackSpeed, "player")
    mhS, ohS, rS = Plain(mhS), Plain(ohS), Plain(rS)
    local speed, rlo, rhi = Call(UnitRangedDamage, "player")
    speed = Plain(speed)
    local rAvg = avg(Plain(rlo), Plain(rhi))
    if type(speed) ~= "number" or speed <= 0 then speed = (type(rS) == "number" and rS > 0) and rS or nil end

    -- Das Angriffstempo ist im Kampf geheim: dann gilt das zuletzt gelesene, zur Not ein
    -- uebliches Tempo, bis es ausserhalb des Kampfes gelesen ist.
    local function tempo(read, known, usual)
        if type(read) == "number" and read > 0 then return read end
        return known or usual
    end
    if mhAvg then st.mhAvg, st.mhSpeed = mhAvg, tempo(mhS, st.mhSpeed, 2.4) end
    if ohAvg and NM.State.gear.ohWeapon then
        st.ohAvg, st.ohSpeed = ohAvg, tempo(ohS, st.ohSpeed, 2.0)
    elseif mhAvg then
        st.ohAvg, st.ohSpeed = nil, nil
    end
    if rAvg then
        st.rAvg, st.rSpeed = rAvg, tempo(speed, st.rSpeed, NM.State.gear.wand and 1.6 or 2.6)
    elseif rlo ~= nil and Plain(rlo) ~= nil and not rAvg then
        st.rAvg, st.rSpeed = nil, nil               -- lesbar, aber keine Fernkampfwaffe
    end
    -- nur wenn der Client den Fernkampfschaden wirklich nennt, darf "kein Bogen" etwas heissen
    if rAvg or Plain(rlo) ~= nil then st.rangedKnown = true end

    local function pct(fn, ...)
        local v = Get(fn, ...)
        if type(v) == "number" and v >= 0 and v <= 100 then return v / 100 end
    end
    st.critMelee = pct(GetCritChance) or st.critMelee
    st.critRanged = pct(GetRangedCritChance) or st.critRanged
    st.critSpell = pct(GetSpellCritChance) or pct(GetSpellCritChance, 3) or st.critSpell
    local sp
    for school = 2, 7 do
        local v = Get(GetSpellBonusDamage, school)
        if type(v) == "number" and (not sp or v > sp) then sp = v end
    end
    st.spellPower = sp or st.spellPower

    -- Schaden je Sekunde aus den automatischen Angriffen
    st.meleeDPS = st.mhAvg and (st.mhAvg / st.mhSpeed + (st.ohAvg and st.ohAvg / st.ohSpeed or 0)) * (1 + (st.critMelee or 0)) or nil
    st.rangedDPS = st.rAvg and st.rAvg / st.rSpeed * (1 + (st.critRanged or 0)) or nil
    st.wand = NM.State.gear.wand and true or false
    if NM.cdb then NM.cdb.stats = st end
end

------------------------------------------------------------------------------
-- Zaubertexte lesen
------------------------------------------------------------------------------

local function Normalize(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("[\r\n]+", " ")
    text = text:gsub("(%d)[%.,](%d%d%d)%f[%D]", "%1%2")     -- Tausenderzeichen
    text = text:gsub("(%d),(%d)", "%1.%2")                  -- deutsches Komma
    return text:lower()
end

local function tail(s, n) return s:sub(-n) end

-- Aus einem Zaubertext die Zahlen, die fuer den Schaden zaehlen. hint ist der Eintrag der
-- Klassentabelle (dot, dur, channel). Ergebnis nil, wenn der Text keinen Schaden nennt.
--   direct       sofortiger Schaden (Mittel aus "x bis y")
--   dot, dotDur  Schaden ueber Zeit, gesamt, und seine Dauer
--   weapon       Waffenschaden gehoert dazu; weaponPct (z. B. 150), weaponBonus ("plus 15")
--   swingBonus   "erhoeht den Nahkampfschaden um x" (Schlag beim naechsten Angriff)
--   rangedBonus  "erhoeht den Distanzschaden um x"
--   perCP[n]     Finishing-Move: Schaden je Combopunkt; perCPDur[n] seine Dauer
function Model.Parse(raw, hint)
    if type(raw) ~= "string" or raw == "" then return nil end
    hint = hint or EMPTY
    local text = Normalize(raw)
    local p = {}

    -- Finishing-Moves: "1 Punkt: 6-10 Schaden", "2 points: 14-22 damage", "1 Punkt: 40 Schaden ueber 8 Sek."
    local first = text:find("%d%s+p[uo][ni][kn]te?s?%s*:")
    if first then
        local tbl = text:sub(first)
        local ROW = "(%d)%s+p[uo][ni][kn]te?s?%s*:%s*(%d+)%s*%-?%s*(%d*)"
        local at = 1
        while true do
            local s, e, n, a, b = tbl:find(ROW, at)
            if not s then break end
            n, a, b = tonumber(n), tonumber(a), tonumber(b)
            p.perCP = p.perCP or {}
            p.perCP[n] = b and (a + b) / 2 or a
            -- der Rest der Zeile bis zur naechsten: "Schaden ueber 8 Sek."
            local rest = tbl:sub(e + 1, (tbl:find(ROW, e + 1) or (#tbl + 1)) - 1)
            local dur = rest:match("(%d+)%s*sek") or rest:match("(%d+)%s*sec")
            if dur then
                p.perCPDur = p.perCPDur or {}
                p.perCPDur[n] = tonumber(dur)
            end
            at = e + 1
        end
        text = text:sub(1, first - 1)
    end

    local amounts, durs, percents = {}, {}, {}
    local pos = 1
    while true do
        local s, e, num = text:find("(%d+%.?%d*)", pos)
        if not s then break end
        local val = tonumber(num) or tonumber((num:gsub("%.$", ""))) or 0
        local after = text:sub(e + 1, e + 48)
        local before = text:sub(max(1, s - 48), s - 1)
        local consumed = e
        if after:find("^%s*%%") then
            percents[#percents + 1] = { val = val, after = after }
        elseif after:find("^%s*sek") or after:find("^%s*sec") or after:find("^%s*min") then
            if after:find("^%s*min") then val = val * 60 end
            local b = tail(before, 18)
            local kind = "plain"
            if b:find("ber%s*$") or b:find("verlauf von%s*$") or b:find("over%s*$") or b:find("innerhalb von%s*$")
               or b:find("within%s*$") or b:find("laufe von%s*$") then
                kind = "over"
            elseif b:find("alle%s*$") or b:find("every%s*$") then
                kind = "tick"
            end
            durs[#durs + 1] = { s = s, e = e, val = val, kind = kind }
        else
            local _, r2, hiTxt = after:find("^%s*bis%s*(%d+)")
            if not r2 then _, r2, hiTxt = after:find("^%s*to%s*(%d+)") end
            if not r2 then _, r2, hiTxt = after:find("^%s*%-%s*(%d+)") end
            if r2 then
                val = (val + tonumber(hiTxt)) / 2
                consumed = e + r2
                after = text:sub(consumed + 1, consumed + 48)
            end
            -- ein Betrag ist Schaden, wenn das Wort gleich darauf folgt ("6 Punkt(e) Schaden",
            -- "20 Nature damage"), nicht bei "8 Metern ... Waffenschaden" oder "48 Schaden absorbiert"
            local nextDigit = after:find("%d") or (#after + 1)
            local seg = after:sub(1, min(nextDigit - 1, 22))
            if (seg:find("schaden") or seg:find("damage")) and not seg:find("^%s*meter") and not seg:find("^%s*yard") then
                if not tail(before, 28):find("absorb") and not after:sub(1, 40):find("absorb") then
                    amounts[#amounts + 1] = { s = s, e = consumed, val = val }
                end
            else
                local b = tail(before, 6)
                if b:find("um%s*$") or b:find("by%s*$") or b:find("plus%s*$") then
                    if before:find("nahkampfschaden") or before:find("melee damage") then
                        p.swingBonus = val
                    elseif before:find("distanzschaden") or before:find("fernkampfschaden") or before:find("ranged damage") then
                        p.rangedBonus = val
                    elseif before:find("waffenschaden") or before:find("weapon damage") then
                        p.weaponBonus = val
                    end
                end
            end
        end
        pos = consumed + 1
    end

    if text:find("waffenschaden") or text:find("weapon damage") then p.weapon = true end
    for _, pc in ipairs(percents) do
        local a = pc.after:sub(1, 30)
        if a:find("waffenschaden") or a:find("weapon damage") then p.weaponPct = pc.val end
    end

    -- Dauern den Betraegen zuordnen: "x Schaden ueber y Sek." in beiden Reihenfolgen
    local function gap(a, d)
        if a.e < d.s then return d.s - a.e end
        return a.s - d.e
    end
    for _, d in ipairs(durs) do
        if d.kind == "over" then
            local best, bestGap
            for _, a in ipairs(amounts) do
                local g = gap(a, d)
                if not a.dot and g <= 60 and (not bestGap or g < bestGap) then best, bestGap = a, g end
            end
            if best then best.dot = d.val end
        end
    end
    -- "x Schaden alle 3 Sek." mit nachfolgender Gesamtdauer
    for i, d in ipairs(durs) do
        if d.kind == "tick" and d.val > 0 then
            for _, a in ipairs(amounts) do
                if not a.dot and a.e < d.s and d.s - a.e <= 30 then
                    local total = hint.channel or hint.dur
                    local nxt = durs[i + 1]
                    if nxt and nxt.s - d.e <= 45 then total = nxt.val end
                    if total then a.val, a.dot = a.val * total / d.val, total end
                end
            end
        end
    end
    -- "jede Sekunde x Schaden, y Sek. lang"
    if text:find("jede sek") or text:find("each sec") or text:find("every sec") or text:find("pro sek") or text:find("per sec") then
        local a = amounts[1]
        if a and not a.dot then
            local total = hint.channel
            for _, d in ipairs(durs) do if d.s > a.s then total = total or d.val; break end end
            if total then a.val, a.dot = a.val * total, total end
        end
    end

    for _, a in ipairs(amounts) do
        if a.dot then
            if not p.dot then p.dot, p.dotDur = a.val, a.dot end
        elseif not p.direct then
            p.direct = a.val
        elseif hint.dot and not p.dot then
            p.dot, p.dotDur = a.val, hint.dur            -- zweiter Betrag eines Zaubers mit Schaden ueber Zeit
        end
    end
    -- laut Tabelle Schaden ueber Zeit, der Text nennt die Dauer anders ("blutet 9 Sek. lang")
    if (hint.dot or hint.channel) and p.direct and not p.dot and #amounts == 1 then
        p.dot, p.dotDur, p.direct = p.direct, hint.channel or hint.dur, nil
    end

    if p.direct or p.dot or p.weapon or p.swingBonus or p.rangedBonus or p.perCP then return p end
    return nil
end

local profiles = {}         -- [Zauber-ID] = Profil oder false
local profileAt = {}

function Model:Reset()
    wipe(profiles); wipe(profileAt)
    self.ranges = nil
end

function Model:Profile(key)
    local d = SP[key]
    local id = d and (d.id or d.ref)
    if not id then return nil end
    local now = GetTime()
    local p = profiles[id]
    -- gelesene Profile gelten eine Minute (Ausruestung und Talente aendern die Zahlen);
    -- ein leerer Text wird bald noch einmal versucht (Daten noch nicht geladen)
    if p ~= nil and now - (profileAt[id] or 0) < (p and 60 or 5) then return p or nil end
    local text = Get(C_Spell.GetSpellDescription, id)
    if type(text) ~= "string" or text == "" then
        if p == nil then profiles[id], profileAt[id] = false, now end
        return profiles[id] or nil
    end
    p = Model.Parse(text, d) or false
    if p then p.text = text end
    profiles[id], profileAt[id] = p, now
    return p or nil
end

------------------------------------------------------------------------------
-- Schaden und Wert eines Moves
------------------------------------------------------------------------------

-- Erwarteter Schaden einer Anwendung jetzt und die Zeit, die sie belegt.
-- Rueckgabe: Schaden, Zeit, davon Schaden ueber Zeit (ungekuerzt)   oder nil
function Model:Damage(S, key, noKite)
    local d = SP[key]
    if not d or d.nodmg then return nil end
    local st = self.stats
    -- Zauberstab und anderes Dauerfeuer: ein Schuss je Angriffstempo
    if d.wand then
        if not (st.rAvg and st.rSpeed) then return nil end
        return st.rAvg * (1 + (st.critRanged or 0)), st.rSpeed, 0
    end
    local p = self:Profile(key)
    if not p then return nil end

    local dmg, dot, dotDur, crit
    if d.fin and p.perCP then
        local cp = max(1, min(5, S.cp or 1))
        local v = p.perCP[cp]
        if not v then return nil end
        if p.perCPDur and p.perCPDur[cp] then
            dmg, dot, dotDur = 0, v, p.perCPDur[cp]
        else
            dmg = v
        end
        crit = st.critMelee
    elseif p.swingBonus then
        dmg, crit = p.swingBonus, st.critMelee                  -- der Schlag selbst faellt ohnehin
    elseif p.rangedBonus or d.weapon == "ranged" then
        if not st.rAvg then return nil end
        dmg, crit = st.rAvg + (p.rangedBonus or p.direct or 0), st.critRanged
    elseif p.weapon then
        if not st.mhAvg then return nil end
        dmg = st.mhAvg * (p.weaponPct or 100) / 100 + (p.weaponBonus or 0) + (p.direct or 0)
        crit = st.critMelee
    else
        dmg, crit = p.direct or 0, (st.critSpell or 0) * 0.5    -- Zauber treffen kritisch mit 150 %
    end
    dmg = dmg * (1 + (crit or 0))
    if not dot and p.dot then dot, dotDur = p.dot, p.dotDur or d.dur end

    -- Schaden ueber Zeit zaehlt nur, solange der Gegner lebt
    local dotFull = dot or 0
    if dot and dot > 0 then
        local ttd = S.ttd
        local fit = (ttd and dotDur and dotDur > 0) and min(1, ttd / dotDur) or 1
        dmg = dmg + dot * fit
    end

    -- Flaeche: je Gegner, bis zur Obergrenze des Zaubers
    if d.aoe then dmg = dmg * max(1, min(S.aoe or 1, d.aoe == true and 10 or d.aoe)) end

    -- Zeit
    local time
    if d.swing then
        time = 0
    else
        time = S:castLen(key)
        local cast = d.channel or d.castTime or d.cast or 0
        -- wer nebenher von selbst schiesst, verliert waehrend der Zauberzeit diese Schuesse
        if NM.class.autoShot and cast > 0 and st.rangedDPS then dmg = dmg - st.rangedDPS * cast end
    end

    -- Verlangsamen eines Gegners, der auf einen zukommt: die gewonnene Zeit auf Abstand
    if d.slow and not noKite and not S.sim and S.eta and S.kitePenalty and S.kitePenalty > 0 then
        local dur = d.slowDur or d.dur or 4
        local extra = min(d.slow * dur, S.eta * d.slow / (1 - d.slow))
        dmg = dmg + extra * S.kitePenalty
    end
    if dmg <= 0 then return nil end
    return dmg, time, dotFull
end

-- Sekunden, die ein Punkt der Kraft wert ist
function Model:CostWeight(S)
    local pt = S.powerType
    if pt == 3 then
        return 1 / max(5, S.regen or 10)
    elseif pt == 1 then
        local L = S.level or 1
        local c = 0.0091107836 * L * L + 3.225598133 * L + 4.2652911
        local rate = 7.5 * (self.stats.meleeDPS or L) / c + (S.hitRate or 0) * 2
        local cw = 1 / max(1.5, min(20, rate))
        if S:atLeast(60) then cw = cw * 0.4 end                 -- volle Wut will ausgegeben werden
        return cw
    end
    -- Mana: ein Punkt kostet die Zeit, die man dafuer trinkt
    local pmax = S.powerMax or 0
    if pmax <= 0 then return 0 end
    local cw = REST_TIME / pmax
    local style = NM.db and NM.db.playStyle or "auto"
    if style == "fast" then cw = cw * 0.3 elseif style == "thrifty" then cw = cw * 2 end
    -- in der Gruppe und gegen starke Gegner zaehlt der Kampf, nicht die Pause danach
    local t = S.target
    if S.group or (t and (t.boss or t.elite)) then cw = cw * 0.4 end
    -- reicht das Mana nicht einmal fuer diesen Kampf (gelernt: Mana je Kampf), wird es kostbar
    if S.fightsLeft and S.fightsLeft < 1.2 then cw = cw * 1.5 end
    return cw
end

-- Anteil der eigenen Gesundheit, den ein Treffer eines gleich starken Gegners etwa kostet
local HIT_SHARE = { MAGE = 0.04, PRIEST = 0.04, WARLOCK = 0.04, ROGUE = 0.03, DRUID = 0.03, HUNTER = 0.03, SHAMAN = 0.03,
                    WARRIOR = 0.02, PALADIN = 0.02 }

-- Wie teuer ist eine Sekunde unter Beschuss? Treffer je Sekunde mal ihr Anteil an der
-- Gesundheit mal die Zeit, die das Erholen kostet. onMe: so rechnen, als stuende der Gegner
-- schon an einem (fuer den Wert von Abstand).
function Model:Hurt(S, onMe)
    local t = S.target
    local hits = S.inCombat and S.hitRate or 0
    if onMe or (t.valid and t.targetingMe == true and (t.close == true or (S.isMelee and t.melee == true))) then
        hits = max(hits, 0.4)
    end
    if hits <= 0 then return 0 end
    local share = HIT_SHARE[NM.classToken or ""] or 0.03
    if t.boss then share = share * 4 elseif t.elite then share = share * 2.5 end
    if t.level and t.level > 0 and S.level then share = share * max(0.5, min(2, 1 + (t.level - S.level) * 0.1)) end
    return min(3, hits * share * REST_TIME)
end

-- Wert je Sekunde: Schaden durch belegte Zeit plus den Zeitwert der Kosten. nil = unbekannt.
function Model:Value(S, key, noKite)
    local dmg, time = self:Damage(S, key, noKite)
    if not dmg then return nil end
    local cw = S.costW
    if not cw then cw = self:CostWeight(S) end
    local cost = SP[key].wand and 0 or S:cost(key)
    return dmg / max(0.3, time * (S.timeW or 1) + cost * cw), dmg, time
end

-- der beste Einzelziel-Wert der Rotation (ohne Abstandsgewinn): Mass fuer den eigenen Schaden je Sekunde
function Model:Best(S)
    if S.bestValue ~= nil then return S.bestValue or nil end
    local groups = NM.class.rotation
    if type(groups) == "function" then groups = groups(S) end
    local best
    for _, group in ipairs(groups or EMPTY) do
        for _, key in ipairs(group) do
            if S:known(key) and not SP[key].aoe then
                local v = self:Value(S, key, true)
                if v and (not best or v > best) then best = v end
            end
        end
    end
    S.bestValue = best or false
    return best
end

-- Zauberer im Nahkampf: jeder Treffer wirft das Zaubern zurueck (etwa ein Drittel des eigenen
-- Schadens) und kostet Gesundheit, also Zeit zum Erholen. So viel ist eine Sekunde Abstand wert.
function Model.CasterKite(S, M)
    local best = M:Best(S)
    return best and best * (0.3 + M:Hurt(S, true)) or nil
end

-- die erste Prozentzahl im Zaubertext ("erhoeht das Angriffstempo um 20%")
function Model:Percent(key)
    local d = SP[key]
    local text = d and d.id and Get(C_Spell.GetSpellDescription, d.id)
    local v = type(text) == "string" and text:match("(%d+)%s*%%")
    return v and tonumber(v) or nil
end

-- Dauerleistung eines Zaubers: Schaden je Sekunde, wenn man ihn immer bei Bereitschaft wirkt
function Model:Rate(S, key)
    if not S:known(key) then return 0 end
    local dmg, time, dot = self:Damage(S, key, true)
    if not dmg then return 0 end
    local d = SP[key]
    local period = max(NM.State.CooldownLength(key) or 0, time, 1)
    if dot and dot > 0 then period = max(period, d.dur or 12) end
    return dmg / period
end

------------------------------------------------------------------------------
-- Rotation ordnen: innerhalb einer Gruppe nach berechnetem Wert
------------------------------------------------------------------------------

local slotPrio, members = {}, {}
local function byValue(a, b) return a.value > b.value end
local function desc(a, b) return a > b end

-- class.rotation = { { "sinister", "backstab" }, { ... } }: die Kandidaten einer Gruppe
-- tauschen ihre Plaetze so, dass der wertvollste den hoechsten Platz der Gruppe bekommt.
-- Kandidaten ohne bekannten Wert, Reaktionen und fest gesetzte (fixed) bleiben, wo sie sind.
function Model:Order(S, list)
    if not (NM.db and NM.db.useModel) then return end
    local groups = NM.class.rotation
    if type(groups) == "function" then groups = groups(S) end
    if not groups then return end
    if not S.costW then S.costW = self:CostWeight(S) end
    for _, group in ipairs(groups) do
        local inGroup = group.set
        if not inGroup then
            inGroup = {}
            for _, k in ipairs(group) do inGroup[k] = true end
            group.set = inGroup
        end
        wipe(slotPrio); wipe(members)
        for _, c in ipairs(list) do
            if inGroup[c.key] and not c.kind and not c.react and not c.fixed then
                local v, dmg = self:Value(S, c.key)
                if v then
                    c.value, c.dmg = v, dmg
                    members[#members + 1] = c
                    slotPrio[#slotPrio + 1] = c.prio
                end
            end
        end
        if #members >= 2 then
            table.sort(members, byValue)
            table.sort(slotPrio, desc)
            for i, c in ipairs(members) do c.prio = slotPrio[i] end
        end
    end
end

------------------------------------------------------------------------------
-- Entfernung des Ziels und Zeit, bis es bei einem ist
------------------------------------------------------------------------------

-- Reichweiten der eigenen Zauber (hoechstens acht verschiedene), kleinste zuerst
function Model:Ranges()
    if self.ranges then return self.ranges end
    local seen, list = {}, {}
    for _, d in pairs(SP) do
        if d.id and d.unit ~= "player" and not d.pet and not d.foreign then
            local info = Plain((Call(C_Spell.GetSpellInfo, d.id)))
            local mx = type(info) == "table" and Plain(info.maxRange)
            if type(mx) == "number" and mx > 0 and mx <= 100 then
                d.maxRange = mx
                d.minRange = Plain(info.minRange) or 0
                local r = floor(mx + 0.5)
                if not seen[r] then seen[r] = true; list[#list + 1] = { id = d.id, range = mx } end
            end
        end
    end
    table.sort(list, function(a, b) return a.range < b.range end)
    while #list > 8 do table.remove(list, floor(#list / 2)) end
    self.ranges = list
    return list
end

-- geschaetzte Entfernung des Ziels in Metern: zwischen der groessten Reichweite, die nicht
-- mehr reicht, und der kleinsten, die reicht
function Model:Distance(S)
    local t = S.target
    if t.close == true or (S.isMelee and t.melee == true) then return 3 end
    local lo, hi
    for _, r in ipairs(self:Ranges()) do
        local ok = Get(C_Spell.IsSpellInRange, r.id, "target")
        if ok == true or ok == 1 then
            if not hi or r.range < hi then hi = r.range end
        elseif ok == false or ok == 0 then
            if not lo or r.range > lo then lo = r.range end
        end
    end
    if lo and hi and hi > lo then return (lo + hi) / 2 end
    if hi then return max(6, hi * 0.6) end
    if lo then return lo + 5 end
    return nil
end

------------------------------------------------------------------------------
-- Verbuchter Schaden je Ziel; gelernt: was ein Gegner aushaelt, was ein Kampf kostet
------------------------------------------------------------------------------

local dealt = {}                    -- [GUID] = verbuchter Schaden
local fight = { spent = 0, hits = 0 }
local swingSeen, lastAccrual = false, 0
local simS = { ttd = 999, aoe = 1, cp = 1, sim = true }     -- Rechenzustand fuer das Verbuchen

local function learn(tbl, id, value)
    local adb = NM.adb
    if type(adb[tbl]) ~= "table" then adb[tbl] = {} end
    local k = adb[tbl][id]
    if not k then
        adb[tbl][id] = { avg = value, n = 1 }
    else
        k.avg = k.avg * 0.7 + value * 0.3
        k.n = k.n + 1
    end
end

local function learned(tbl, id, minN)
    local adb = NM.adb
    local k = adb and type(adb[tbl]) == "table" and adb[tbl][id]
    if k and k.n >= (minN or 2) then return k.avg end
end

local function book(guid, amount)
    if guid and amount and amount > 0 then dealt[guid] = (dealt[guid] or 0) + amount end
end

-- ein eigener Zauber wurde gewirkt (von State gemeldet)
function Model:OnCast(key, cp, guid)
    local d = SP[key]
    if not d then return end
    simS.cp = cp or 1
    simS.castLen = simS.castLen or function(_, k)
        local dd = SP[k]
        return max(1.5, dd and (dd.channel or dd.castTime or dd.cast) or 0)
    end
    local dmg = self:Damage(simS, key, true)
    guid = guid or Plain(UnitGUID("target"))
    book(guid, dmg)
    if not d.wand then fight.spent = fight.spent + (d.costNow or d.cost or 0) end
end

-- ein Treffer, den man einsteckt (von State gemeldet)
function Model:OnHit() fight.hits = fight.hits + 1 end

-- ein eigener Schlag oder Schuss (PLAYER_SWING: Dauer, Art)
local function OnSwing(_, swingType)
    swingSeen = true
    local st = Model.stats
    swingType = Plain(swingType)
    local ST = Enum and Enum.PlayerSwingType
    local amount
    if ST and swingType == ST.Ranged then amount = st.rAvg and st.rAvg * (1 + (st.critRanged or 0))
    elseif ST and swingType == ST.OffHand then amount = st.ohAvg and st.ohAvg * (1 + (st.critMelee or 0))
    else amount = st.mhAvg and st.mhAvg * (1 + (st.critMelee or 0)) end
    Model.swings = (Model.swings or 0) + 1
    book(Plain(UnitGUID("target")), amount)
end

-- Der Kampf gegen ein Ziel ist zu Ende (von State gemeldet): id = "KLASSE:rang-stufe-gruppe"
function Model:OnKill(id, guid)
    local d = guid and dealt[guid]
    if d and d > 0 then learn("health", id, d) end
    if guid then dealt[guid] = nil end
end

local function OnCombatEnd()
    local id = Model.fightId
    if id then
        if fight.spent > 0 then learn("fightCost", id, fight.spent) end
        learn("fightHits", id, fight.hits)
    end
    fight.spent, fight.hits = 0, 0
    Model.fightId = nil
    wipe(dealt)
end

-- Restlebenszeit aus verbuchtem Schaden: was Gegner dieser Art aushalten, minus was das
-- Ziel schon bekommen hat, durch das bisherige Tempo. nil, solange nichts gelernt ist.
function Model:TTD(id, guid, fightTime, killAvg)
    local H = learned("health", id, 3)
    if not (H and H > 0 and killAvg and killAvg > 0) then return nil end
    local D = guid and dealt[guid] or 0
    local rate = (fightTime and fightTime >= 3 and D > 0) and D / fightTime or H / killAvg
    if rate <= 0 then return nil end
    return max((H - D) / rate, max(1.5, killAvg * 0.1))
end

------------------------------------------------------------------------------
-- Je Takt: Werte auffrischen und den Zustand ergaenzen
------------------------------------------------------------------------------

function Model:Snapshot(S)
    local now = S.now
    -- Werte des Charakters: ausserhalb des Kampfes alle zwei Sekunden, im Kampf seltener
    if now - lastStats > (S.inCombat and 10 or 2) then
        lastStats = now
        self:ReadStats()
    end
    local st = self.stats
    S.model = st

    -- Schlaege ohne PLAYER_SWING (anderer Client): nach der Zeit verbuchen
    if S.inCombat and not swingSeen and S.target.valid and S.target.guid then
        local dt = min(1, now - lastAccrual)
        if lastAccrual > 0 and dt > 0 then
            if S.isMelee and S.target.melee == true and st.meleeDPS then book(S.target.guid, st.meleeDPS * dt) end
        end
    end
    lastAccrual = now

    if S.inCombat then self.fightId = self.fightId or S.killId end

    -- Mana: fuer wie viele Kaempfe reicht es noch?
    if S.powerType == 0 and S.killId and (S.powerMax or 0) > 0 then
        local costPerFight = learned("fightCost", S.killId, 2)
        if costPerFight and costPerFight > 0 then
            local mana = S.power or ((S.powerLo or 0) + (S.powerHi or S.powerMax)) / 2
            S.fightsLeft = mana / costPerFight
        end
    end
    S.costW = self:CostWeight(S)
    -- Zeit unter Beschuss zaehlt mehr (nur wo Zeit gegen Mana steht)
    S.timeW = (S.powerType == 0) and (1 + self:Hurt(S)) or 1

    -- Kommt das Ziel auf einen zu? Dann: wie lange noch, und was kostet der Nahkampf
    local t = S.target
    S.eta, S.kitePenalty, S.distance = nil, nil, nil
    if t.valid then
        S.distance = self:Distance(S)
        local coming = t.close ~= true and not t.player and not (S.isMelee and t.melee == true)
            and (t.targetingMe == true or (not S.inCombat and not S.group and not S.pet))
        if coming and S.distance then
            local slowed = 0
            for k, d in pairs(SP) do
                if d.slow and d.unit == "target" and S:aura(k) > 0 and d.slow > slowed then slowed = d.slow end
            end
            S.eta = max(0, S.distance - 4) / (MOB_SPEED * (1 - min(0.9, slowed)))
            S.slowed = slowed > 0
            local kite = NM.class.kite
            if kite then S.kitePenalty = kite(S, self) end
        end
    end
end

------------------------------------------------------------------------------
-- Auskunft
------------------------------------------------------------------------------

local function num(v)
    if not v then return "?" end
    if v >= 100 then return ("%d"):format(v + 0.5) end
    return ("%.1f"):format(v)
end
Model.Num = num

-- Kurztext zum Profil eines Zaubers ("sofort 18, 2 ueber 4 s")
function Model:ProfileText(key)
    local p = self:Profile(key)
    if not p then return nil end
    local parts = {}
    if p.weapon then parts[#parts + 1] = T("Waffe", "weapon") .. (p.weaponPct and (" " .. p.weaponPct .. "%") or "") .. (p.weaponBonus and (" +" .. num(p.weaponBonus)) or "") end
    if p.swingBonus then parts[#parts + 1] = T("nächster Schlag +", "next swing +") .. num(p.swingBonus) end
    if p.rangedBonus then parts[#parts + 1] = T("Schuss +", "shot +") .. num(p.rangedBonus) end
    if p.direct then parts[#parts + 1] = T("sofort ", "direct ") .. num(p.direct) end
    if p.dot then parts[#parts + 1] = num(p.dot) .. T(" über ", " over ") .. num(p.dotDur or 0) .. " s" end
    if p.perCP then
        local list = {}
        for i = 1, 5 do if p.perCP[i] then list[#list + 1] = num(p.perCP[i]) end end
        parts[#parts + 1] = T("je Combopunkt ", "per combo point ") .. table.concat(list, "/")
    end
    return table.concat(parts, ", ")
end

-- Zeile fuer Tooltip und /nxm info: "≈ 42 Schaden, Wert 18 je Sekunde"
function Model:ValueText(S, key)
    local v, dmg, time = self:Value(S, key)
    if not v then return nil end
    return (T("≈ %s Schaden in %s s, Wert %s je Sekunde", "≈ %s damage in %s s, value %s per second")):format(num(dmg), num(time), num(v))
end

function Model:StatsText()
    local st = self.stats
    local parts = {}
    if st.meleeDPS then parts[#parts + 1] = T("Nahkampf ", "melee ") .. num(st.meleeDPS) end
    if st.rangedDPS then parts[#parts + 1] = (st.wand and T("Zauberstab ", "wand ") or T("Fernkampf ", "ranged ")) .. num(st.rangedDPS) end
    if #parts == 0 then return T("Waffenwerte noch nicht gelesen", "weapon values not read yet") end
    return table.concat(parts, ", ") .. T(" Schaden je Sekunde", " damage per second")
end

-- /nxm model: Werte des Charakters und alle Zauber nach Wert
function Model:Print()
    local S = NM.State:Snapshot()
    NM.Print(T("Schadensmodell", "Damage model") .. (NM.db.useModel and "" or T(" (ausgeschaltet)", " (off)")))
    local say = function(text) DEFAULT_CHAT_FRAME:AddMessage("  " .. text) end
    say(self:StatsText())
    if S.powerType ~= 3 then
        say((T("Zeitwert der Kraft: %.3f s je Punkt, Zeit unter Beschuss zählt %.1f-fach", "Time value of power: %.3f s per point, time under fire counts %.1fx")):format(S.costW or 0, S.timeW or 1)
            .. (S.fightsLeft and (T(", Mana für etwa %s Kämpfe", ", mana for about %s fights")):format(num(S.fightsLeft)) or ""))
    end
    if S.distance then say((T("Ziel etwa %s m entfernt", "Target about %s m away")):format(num(S.distance))
        .. (S.eta and (T(", in %s s bei dir", ", reaches you in %s s")):format(num(S.eta)) or "")) end
    local rows = {}
    for key, d in pairs(SP) do
        if d.id then
            local v, dmg, time = self:Value(S, key, true)
            if v then rows[#rows + 1] = { key = key, name = d.name or key, v = v, dmg = dmg, time = time } end
        end
    end
    table.sort(rows, function(a, b) return a.v > b.v end)
    for _, r in ipairs(rows) do
        say(("%s: %s %s, %s s, %s %s"):format(r.name, num(r.dmg), T("Schaden", "damage"), num(r.time), T("Wert", "value"), num(r.v)))
    end
    if #rows == 0 then say(T("Noch kein Zauber mit lesbarem Schaden.", "No spell with readable damage yet.")) end
end

-- fuer die Auswertung nach dem Spielen: Werte, Zaubertexte und was daraus gelesen wurde
function Model:Dump()
    local st, out = self.stats, { spells = {} }
    local parts = {}
    for k, v in pairs(st) do
        if type(v) == "number" then parts[#parts + 1] = k .. "=" .. num(v) elseif v == true then parts[#parts + 1] = k end
    end
    table.sort(parts)
    out.stats = table.concat(parts, " ")
    out.swings = self.swings or 0
    for key, d in pairs(SP) do
        if d.id and not d.foreign then
            local text = Get(C_Spell.GetSpellDescription, d.id)
            if type(text) == "string" and text ~= "" then
                out.spells[key] = (self:ProfileText(key) or "-") .. " <= " .. text:sub(1, 240):gsub("[\r\n]+", " ")
            end
        end
    end
    return out
end

function Model:Init()
    if NM.cdb and type(NM.cdb.stats) == "table" then self.stats = NM.cdb.stats end
    NM.On("PLAYER_SWING", OnSwing)
    NM.On("PLAYER_REGEN_ENABLED", OnCombatEnd)
    NM.On("PLAYER_EQUIPMENT_CHANGED", function() lastStats = 0; Model:Reset() end)
    NM.On("SPELLS_CHANGED", function() Model:Reset() end)
    NM.On("PLAYER_LEVEL_UP", function() lastStats = 0; Model:Reset() end)
end
