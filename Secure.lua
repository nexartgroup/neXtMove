--[[---------------------------------------------------------------------------
    Secure.lua - Tasten: womit ein Move ausgeloest wird

    Grundsatz: Die Rotation laeuft ueber die Tasten, auf denen die Zauber ohnehin liegen.
    An jedem empfohlenen Move steht deshalb die Taste seiner Aktionsleiste (oder man
    klickt den Knopf dort an; er leuchtet).

    Die zwei neXtMove-Tasten sind feste Hilfstasten fuer das, was oft auf keiner Leiste
    liegt. Jede hat vier Plaetze (ohne Zusatztaste, Umschalt, Alt, Strg):

      Taste 1   ohne      Unterbrechen        Taste 2   ohne      Heilung
                Umschalt  Betaeuben/Kontrolle           Umschalt  Flucht
                Alt       Buff                          Alt       Schmuck
                Strg      Debuff                        Strg      Schutz

    Womit ein Platz belegt wird, sagt die Klasse (slots in Classes/*.lua): nach gelernten
    Zaubern, Gegenstaenden in den Taschen und angelegtem Schmuck. Stehen fuer einen Platz
    mehrere Zauber zur Wahl, bekommt ihn der, der auf keiner Aktionsleiste liegt - so
    erweitern die Hilfstasten die Leisten, statt sie zu doppeln.

    Die Grenze des Clients: ein Addon darf einen Zauberknopf nur ausserhalb des Kampfes neu
    belegen. Die Plaetze werden deshalb ausserhalb des Kampfes laufend angepasst und bleiben
    im Kampf, wie sie beim Kampfbeginn waren. /nxm keys zeigt die aktuelle Belegung.
-----------------------------------------------------------------------------]]

local _, NM = ...
local Call, Get, T, Print = NM.Call, NM.Get, NM.T, NM.Print
local SP = NM.SPELLS

local Sec = {}
NM.Secure = Sec

local BTN = { "NextMoveButton1", "NextMoveButton2" }
local CMD = { "CLICK NextMoveButton1:LeftButton", "CLICK NextMoveButton2:LeftButton" }

BINDING_HEADER_NEXTMOVE = "neXtMove"
_G["BINDING_NAME_" .. CMD[1]] = T("Hilfstaste 1 (Unterbrechen, Betäuben, Buff, Debuff)", "Utility key 1 (interrupt, stun, buff, debuff)")
_G["BINDING_NAME_" .. CMD[2]] = T("Hilfstaste 2 (Heilung, Flucht, Schmuck, Schutz)", "Utility key 2 (heal, escape, trinket, defense)")

-- Die acht Plaetze in der Reihenfolge, in der sie im Makro stehen (ohne Zusatztaste zuletzt)
local SLOTS = {
    { id = "stun",      btn = 1, mod = "SHIFT", title = T("Betäuben", "Stun") },
    { id = "buff",      btn = 1, mod = "ALT",   title = "Buff" },
    { id = "debuff",    btn = 1, mod = "CTRL",  title = "Debuff" },
    { id = "interrupt", btn = 1, mod = "",      title = T("Unterbrechen", "Interrupt") },
    { id = "escape",    btn = 2, mod = "SHIFT", title = T("Flucht", "Escape") },
    { id = "trinket",   btn = 2, mod = "ALT",   title = T("Schmuck", "Trinket") },
    { id = "defense",   btn = 2, mod = "CTRL",  title = T("Schutz", "Defense") },
    { id = "heal",      btn = 2, mod = "",      title = T("Heilung", "Heal") },
}
local MOD_PREFIX = { SHIFT = "S-", CTRL = "C-", ALT = "A-", [""] = "" }
local MAX_ENTRIES = 3

local buttons, current = {}, {}
Sec.built = {}      -- [Kennung eines Moves] = { btn, mod, cond }: was die Knoepfe wirklich tragen
Sec.layout = {}     -- [Platz-ID] = Liste der Eintraege, fuer /nxm keys

------------------------------------------------------------------------------
-- Belegung der acht Plaetze: Helfer fuer die Klassen
------------------------------------------------------------------------------

local H = {}
local gear

function H.known(key) local d = SP[key]; return d and d.id and d.name end

-- Der erste gelernte Zauber der Liste, der auf keiner Aktionsleiste liegt; liegen alle auf
-- einer Leiste, der erste gelernte
function H.pick(keys)
    local first
    for _, k in ipairs(keys) do
        if H.known(k) then
            first = first or k
            if not NM.Bars:OnAnyBar(SP[k].id) then return k end
        end
    end
    return first
end

function H.spell(key, cond) return (key and H.known(key)) and { kind = "spell", key = key, cond = cond } or nil end
function H.item(id, cond) return id and { kind = "item", item = id, cond = cond } or nil end
function H.trinket()
    local slot = gear and gear.trinkets and gear.trinkets[1]
    return slot and { kind = "trinket", slot = slot } or nil
end

local function TokenOf(e)
    if e.kind == "spell" then return "spell:" .. e.key end
    if e.kind == "poison" then return "poison:" .. e.slot end
    if e.kind == "trinket" then return "trinket:" .. e.slot end
    return "item:" .. e.item
end

local function ArgOf(e)
    if e.kind == "spell" then return SP[e.key].name end
    if e.kind == "trinket" then return tostring(e.slot) end
    return "item:" .. e.item
end

-- Das Makro eines Knopfes aus seinen vier Plaetzen
local function BuildMacro(btn, layout, built)
    local parts, extra = {}, {}
    for _, slot in ipairs(SLOTS) do
        if slot.btn == btn then
            local list = layout[slot.id] or {}
            for i = 1, MAX_ENTRIES do       -- (Luecken sind erlaubt: ein Eintrag kann fehlen)
                local e = list[i]
                if e then
                    local cond = (slot.mod ~= "") and ("mod:" .. slot.mod:lower()) or "nomod"
                    if e.cond then cond = cond .. "," .. e.cond end
                    parts[#parts + 1] = ("[%s] %s"):format(cond, ArgOf(e))
                    -- ein Waffengift braucht zwei Schritte: benutzen, dann die Waffe waehlen
                    if e.kind == "poison" then extra[#extra + 1] = ("/use [%s] %d"):format(cond, e.slot) end
                    built[TokenOf(e)] = { btn = btn, mod = slot.mod, cond = e.cond }
                end
            end
        end
    end
    if #parts == 0 then return nil end
    local text = "/use " .. table.concat(parts, "; ")
    if #extra > 0 then text = text .. "\n" .. table.concat(extra, "\n") end
    return text
end

local function Set(i, text)
    if InCombatLockdown() then return false end
    if current[i] ~= text then
        local b = buttons[i]
        if text then
            b:SetAttribute("type", "macro")
            b:SetAttribute("macrotext", text)
        else
            b:SetAttribute("type", nil)
            b:SetAttribute("macrotext", nil)
        end
        current[i] = text
    end
    return true
end

-- Ausserhalb des Kampfes: die Plaetze an Zauber, Taschen und Ausruestung anpassen
function Sec:Update(S)
    if InCombatLockdown() then return end
    gear = S.gear
    local layout = NM.class.slots and NM.class.slots(S, H) or {}
    local built = {}
    local text1 = BuildMacro(1, layout, built)
    local text2 = BuildMacro(2, layout, built)
    self.tooLong = ((text1 and #text1 > 255) or (text2 and #text2 > 255)) and true or false
    if Set(1, text1) and Set(2, text2) then
        self.built, self.layout = built, layout
    end
end

------------------------------------------------------------------------------
-- Beschriftung
------------------------------------------------------------------------------

function Sec:Keys()
    return (GetBindingKey(CMD[1])), (GetBindingKey(CMD[2]))
end

local function MoveToken(m)
    if m.kind == nil then return "spell:" .. m.key end
    if m.kind == "poison" then return "poison:" .. m.slot end
    if m.kind == "trinket" then return "trinket:" .. m.slot end
    if m.kind == "item" then return "item:" .. m.item end
end

-- Beschriftung fuer einen Move. Rueckgaben:
--   Text, Art, Knopf
--   Art: "bar" Taste der Aktionsleiste, "click" auf einer Leiste, aber ohne Taste (anklicken),
--        "own" Hilfstaste, nil = der Move liegt nirgends
--   Knopf: der Leistenknopf, falls sichtbar (zum Leuchten)
function Sec:KeyFor(S, m)
    -- 1. die Aktionsleiste
    local e
    if m.kind == nil then e = NM.Bars:ForSpell(S:id(m.key), S.stealthed)
    elseif m.kind == "item" then e = NM.Bars:ForItem(m.item) end
    if e and e.key then return e.key, "bar", e.shown and e.frame or nil end
    -- 2. eine der Hilfstasten
    local token = MoveToken(m)
    local place = token and self.built[token]
    if place then
        local ok = true
        if place.cond == "stealth" then ok = S.stealthed
        elseif place.cond == "nostealth" then ok = not S.stealthed
        elseif place.cond == "nocombat" then ok = not S.inCombat end
        local base = GetBindingKey(CMD[place.btn])
        if ok and base then return MOD_PREFIX[place.mod] .. NM.ShortKey(base), "own" end
    end
    -- 3. auf einer Leiste, aber ohne Taste
    if e and e.shown then return T("Klick", "click"), "click", e.frame end
    return nil, nil
end

function Sec:PrintKeys()
    local base = { self:Keys() }
    Print(T("Hilfstasten (in der Anzeige gelb):", "Utility keys (yellow in the display):"))
    for btn = 1, 2 do
        if not base[btn] then
            DEFAULT_CHAT_FRAME:AddMessage(("  %s %d: %s"):format(T("Hilfstaste", "Utility key"), btn,
                T("keine Taste festgelegt - /nxm bind ", "no key set - /nxm bind ") .. btn .. T(" TASTE", " KEY")))
        end
        for _, mod in ipairs({ "", "SHIFT", "ALT", "CTRL" }) do
            for _, slot in ipairs(SLOTS) do
                if slot.btn == btn and slot.mod == mod then
                    local names = {}
                    local list = self.layout[slot.id] or {}
                    for i = 1, MAX_ENTRIES do
                        local e = list[i]
                        if e then
                            local name
                            if e.kind == "spell" then name = SP[e.key].name
                            elseif e.kind == "trinket" then name = T("Schmuckstück", "Trinket") .. " " .. e.slot
                            else name = Get(C_Item.GetItemNameByID, e.item) or ("item:" .. e.item) end
                            if e.cond == "stealth" then name = name .. T(" (verstohlen)", " (stealthed)")
                            elseif e.cond == "nocombat" then name = name .. T(" (außerhalb des Kampfes)", " (out of combat)") end
                            names[#names + 1] = name
                        end
                    end
                    DEFAULT_CHAT_FRAME:AddMessage(("  |cffffd100%s%s|r  %s: %s"):format(MOD_PREFIX[mod],
                        NM.ShortKey(base[btn]) or ("T" .. btn), slot.title, #names > 0 and table.concat(names, ", ") or "-"))
                end
            end
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage("  " .. T("S- = Umschalt, A- = Alt, C- = Strg. Alle anderen Moves: Taste der Aktionsleiste (weiß).",
        "S- = Shift, A- = Alt, C- = Ctrl. All other moves: the action bar key (white)."))
    if self.tooLong then
        DEFAULT_CHAT_FRAME:AddMessage("  " .. T("Achtung: ein Makro ist länger als 255 Zeichen.", "Warning: a macro is longer than 255 characters."))
    end
end

-- Die Belegung als acht Zeilen fuer das Einstellungsfenster: { head = Taste und Kategorie,
-- body = Inhalt }, in der Reihenfolge Taste 1 (ohne, Umschalt, Alt, Strg), Taste 2 (ebenso)
function Sec:LayoutLines()
    local base = { self:Keys() }
    local lines = {}
    for btn = 1, 2 do
        for _, mod in ipairs({ "", "SHIFT", "ALT", "CTRL" }) do
            for _, slot in ipairs(SLOTS) do
                if slot.btn == btn and slot.mod == mod then
                    local names = {}
                    local list = self.layout[slot.id] or {}
                    for i = 1, MAX_ENTRIES do
                        local e = list[i]
                        if e then
                            local name = (e.kind == "spell" and SP[e.key].name)
                                or (e.kind == "trinket" and T("Schmuckstück", "Trinket"))
                                or Get(C_Item.GetItemNameByID, e.item) or "?"
                            if e.cond == "stealth" then name = name .. T(" (verstohlen)", " (stealthed)")
                            elseif e.cond == "nocombat" then name = name .. T(" (vor dem Kampf)", " (before combat)") end
                            names[#names + 1] = name
                        end
                    end
                    lines[#lines + 1] = {
                        head = ("|cffffd100%s%s|r  %s"):format(MOD_PREFIX[mod], NM.ShortKey(base[btn]) or ("T" .. btn), slot.title),
                        body = #names > 0 and table.concat(names, ", ") or "-",
                    }
                end
            end
        end
    end
    return lines
end

function Sec:Bind(index, key)
    if not (index == 1 or index == 2) or not key then
        Print(T("Beispiel: /nxm bind 1 F   oder   /nxm bind 2 G", "Example: /nxm bind 1 F   or   /nxm bind 2 G"))
        return
    end
    if InCombatLockdown() then
        Print(T("Tasten lassen sich im Kampf nicht ändern.", "Keys cannot be changed in combat."))
        return
    end
    local ok = Get(SetBindingClick, key, BTN[index], "LeftButton")
    if ok then
        Call(SaveBindings, Get(GetCurrentBindingSet) or 1)
        Print(("%s %d: %s"):format(T("Hilfstaste", "Utility key"), index, key))
    else
        Print(T("Diese Taste nimmt der Client nicht an: ", "The client does not accept this key: ") .. key)
    end
end

function Sec:Init()
    for i = 1, 2 do
        local b = CreateFrame("Button", BTN[i], UIParent, "SecureActionButtonTemplate")
        -- der Client loest je nach Einstellung beim Druecken oder beim Loslassen aus
        b:RegisterForClicks("AnyUp", "AnyDown")
        buttons[i] = b
    end
    C_Timer.After(8, function()
        local k1, k2 = Sec:Keys()
        if not (k1 and k2) then
            Print(T("Lege die zwei Hilfstasten fest: Optionen > Tastaturbelegung > AddOns > neXtMove, oder /nxm bind 1 TASTE und /nxm bind 2 TASTE. /nxm keys zeigt die Belegung.",
                    "Set the two utility keys: Options > Keybindings > AddOns > neXtMove, or /nxm bind 1 KEY and /nxm bind 2 KEY. /nxm keys shows the layout."))
        end
    end)
end
