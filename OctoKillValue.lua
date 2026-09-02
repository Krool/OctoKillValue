-- OctoKillValue - expected gold per kill on creature tooltips.
--
-- value(mob) = avg coin drop
--            + sum over drop table of expectedQty(item) * price(item)
-- where expectedQty comes from Data.lua (Turtle 1.18.1 loot templates,
-- see tools/gen-data.js) and price(item) is the best of:
--   * aux-addon's auction value (never for bind-on-pickup items), minus
--     the AH cut, aggregated across random-suffix variants when the base
--     item has no history;
--   * aux's disenchant estimate (optional, /okv de);
--   * the vendor sell price.
-- Quest items are worth 0. Aux prices above `trust` copper must have been
-- seen on `mindays` days (one absurd listing straddling midnight counts
-- twice). Drops below `rare` expected qty are reported outside the total.
--
-- Lua 5.0 (WoW 1.12): no string.match, no #, event args are globals.

local ADDON = "OctoKillValue"
local PREFIX = "|cff33ff99OctoKillValue|r: "
local LINE_LABEL = "Kill value"

OctoKillValueDB = OctoKillValueDB or {}
local DEFAULTS = {
  enabled = true,   -- tooltip line on/off
  detail = 3,       -- top-N contributor lines under the total (0 = none)
  price = "value",  -- aux price source: "value" (weighted median) or "today" (daily min buyout)
  skin = true,      -- show gather (skinning/mining/herbalism) line when the player has the skill
  vendor = true,    -- use vendor sell price when aux has no value / as a floor
  de = false,       -- also consider aux's disenchant estimate for gear
  friendly = false, -- show the line on friendly (non-attackable) NPCs too
  cut = 5,          -- auction house cut in percent, taken off AH and disenchant values
  rare = 0.001,     -- drops with expected qty below this (0.1%) go to a separate "rare" line
  mindays = 3,      -- aux prices above `trust` copper need this many daily observations
                    -- (a single 24h listing can straddle a midnight push = 2 observations)
  trust = 500000,   -- 50g: prices at or below this are trusted from a single sighting
}
local cfg

local function InitConfig()
  for k, v in pairs(DEFAULTS) do
    if OctoKillValueDB[k] == nil then OctoKillValueDB[k] = v end
  end
  cfg = OctoKillValueDB
end

local function Print(msg)
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end
end

-- ---------------------------------------------------------------- aux access
-- aux exposes its modules through a GLOBAL `require` (libs/package.lua).
-- Asking for a module that is not loaded yields an empty interface, so
-- every function is type-checked before use.
local auxModules = {}
local auxChecked = {}

local function AuxModule(name)
  if auxChecked[name] then return auxModules[name] end
  auxChecked[name] = true
  if type(require) == "function" then
    local ok, m = pcall(require, name)
    if ok and type(m) == "table" then auxModules[name] = m end
  end
  return auxModules[name]
end

local function AuxHistory()
  local h = AuxModule("aux.core.history")
  if h and type(h.value) == "function" then return h end
  return nil
end

-- Re-detect aux (e.g. after it loads late); also used by the test harness.
local suffixIndex = nil
local computeCache = {}
function OctoKillValue_ResetAux()
  auxModules = {}
  auxChecked = {}
  suffixIndex = nil
  computeCache = {}
end

-- One aux history key ("id:suffix") -> trusted unit price or nil.
local function AuxKeyPrice(h, key)
  local fn = (cfg.price == "today") and h.market_value or h.value
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, key)
  if not ok or type(v) ~= "number" or v <= 0 then return nil end
  -- A lone sighting of an absurd buyout (one 166,000g listing seen once)
  -- would dominate every mob that can drop the item at 0.02%. Expensive
  -- prices must have been seen on several days before they count.
  if v > cfg.trust and cfg.mindays > 1 then
    local days = 0
    if type(h.data_points) == "function" then
      local ok2, pts = pcall(h.data_points, key)
      if ok2 and type(pts) == "table" then days = table.getn(pts) end
    end
    if type(h.market_value) == "function" then
      local ok3, today = pcall(h.market_value, key)
      if ok3 and today then days = days + 1 end
    end
    if days < cfg.mindays then return nil end
  end
  return v
end

-- Random-suffix gear ("of the Bear") is auctioned under "id:suffix" keys;
-- the base "id:0" rarely has history. Index aux's faction history once.
local function SuffixKeys(itemId)
  if not suffixIndex then
    local aux = AuxModule("aux")
    local hist = aux and type(aux.faction_data) == "table" and aux.faction_data.history
    if type(hist) ~= "table" then return nil end -- aux not through LOAD2 yet; retry later
    suffixIndex = {}
    for key in pairs(hist) do
      local _, _, id, suf = string.find(key, "^(%d+):(%-?%d+)$")
      if id and suf ~= "0" then
        id = tonumber(id)
        local list = suffixIndex[id]
        if not list then list = {}; suffixIndex[id] = list end
        if table.getn(list) < 16 then table.insert(list, key) end
      end
    end
  end
  return suffixIndex[itemId]
end

local function AuxPrice(itemId)
  local h = AuxHistory()
  if not h then return nil end
  local v = AuxKeyPrice(h, itemId .. ":0")
  if v then return v end
  local keys = SuffixKeys(itemId)
  if not keys then return nil end
  local vals = {}
  for _, key in ipairs(keys) do
    local kv = AuxKeyPrice(h, key)
    if kv then table.insert(vals, kv) end
  end
  local n = table.getn(vals)
  if n == 0 then return nil end
  table.sort(vals)
  return vals[math.floor((n + 1) / 2)]
end

-- aux's disenchant expectation for gear; needs quality/level/slot, which
-- GetItemInfo only knows for cached items - Data.lua carries a fallback.
local function DisenchantValue(itemId)
  if not cfg.de then return nil end
  local de = AuxModule("aux.core.disenchant")
  if not de or type(de.value) ~= "function" then return nil end
  local quality, level, slot
  local name, _, q, lvl, _, _, _, equip = GetItemInfo(itemId)
  if name and q then
    quality, level, slot = q, lvl, equip
  elseif OKV_DE and OKV_DE[itemId] then
    local _, _, a, b, c = string.find(OKV_DE[itemId], "^(%d+):(%d+):(.*)$")
    quality, level, slot = tonumber(a), tonumber(b), c
  else
    return nil
  end
  local ok, v = pcall(de.value, slot, quality, level, itemId)
  if ok and type(v) == "number" and v > 0 then return v end
  return nil
end

-- Unit price in copper and its source, or nil when nothing is known.
-- Quest items are a known 0.
local function Price(itemId)
  local bind = OKV_BIND and OKV_BIND[itemId]
  if bind == 4 then return 0, "quest" end
  local net = 1 - (cfg.cut or 0) / 100
  local best, src = nil, nil
  if bind ~= 1 then -- bind-on-pickup never reaches the auction house
    local ah = AuxPrice(itemId)
    if ah then best, src = ah * net, "ah" end
  end
  local dev = DisenchantValue(itemId)
  if dev and (not best or dev * net > best) then best, src = dev * net, "de" end
  if cfg.vendor and OKV_SELL and OKV_SELL[itemId] then
    local vendor = OKV_SELL[itemId]
    if not best or vendor > best then best, src = vendor, "vendor" end
  end
  return best, src
end

-- ---------------------------------------------------------------- data
local mobCache = {}   -- entry -> parsed record (false = no data)
local refCache = {}   -- refId -> { {id, qty}, ... }

local function ParsePairs(s)
  local list = {}
  if not s or s == "" then return list end
  for id, q in string.gfind(s, "(%d+):([%d%.e%-]+)") do
    table.insert(list, { tonumber(id), tonumber(q) })
  end
  return list
end

local function GetRef(refId)
  local r = refCache[refId]
  if r then return r end
  r = ParsePairs(OKV_REF and OKV_REF[refId])
  refCache[refId] = r
  return r
end

local GATHER = { S = "skinning", H = "herbalism", M = "mining" }
local GATHER_SKILL = { S = "Skinning", H = "Herbalism", M = "Mining" }

local function GetMob(entry)
  local m = mobCache[entry]
  if m ~= nil then return m or nil end
  local s = OKV_MOB and OKV_MOB[entry]
  if not s then mobCache[entry] = false; return nil end
  local _, _, gold, drops, refs, skin = string.find(s, "^(%d*)|([^|]*)|([^|]*)|(.*)$")
  local gather = "S"
  if skin then
    local _, _, g, rest = string.find(skin, "^([HM]):(.*)$")
    if g then gather, skin = g, rest end
  end
  m = {
    gold = tonumber(gold) or 0,
    drops = ParsePairs(drops),
    refs = ParsePairs(refs),
    skin = ParsePairs(skin),
    gather = gather,
  }
  mobCache[entry] = m
  return m
end

-- ---------------------------------------------------------------- compute
-- Returns { total, gold, loot, rare, skin, gather, known, unknown,
--           top = { {id, qty, value, src} ... }, raretop = { same, below the rare threshold } }
-- total = gold + loot; rare is reported separately (not part of total).
local function AddQty(acc, id, qty)
  local c = acc.byItem[id]
  if c then
    c.qty = c.qty + qty
  else
    c = { id = id, qty = qty }
    acc.byItem[id] = c
    table.insert(acc.all, c)
  end
end

local CACHE_TTL = 30

local function Compute(entry)
  local hit = computeCache[entry]
  local now = GetTime and GetTime() or 0
  if hit and now - hit.t < CACHE_TTL then return hit.acc end
  local m = GetMob(entry)
  if not m then return nil end
  local acc = { gold = m.gold, loot = 0, rare = 0, skin = 0, gather = m.gather,
    known = 0, unknown = 0, top = {}, raretop = {}, all = {}, byItem = {} }
  -- merge quantities per item first (an item can arrive via several pools)
  for _, d in ipairs(m.drops) do AddQty(acc, d[1], d[2]) end
  for _, r in ipairs(m.refs) do
    for _, d in ipairs(GetRef(r[1])) do AddQty(acc, d[1], d[2] * r[2]) end
  end
  -- then price each item once and split by expected quantity
  for _, c in ipairs(acc.all) do
    local price, src = Price(c.id)
    if price then
      c.value = c.qty * price
      c.src = src
      acc.known = acc.known + 1
      if c.qty < cfg.rare then
        acc.rare = acc.rare + c.value
        table.insert(acc.raretop, c)
      else
        acc.loot = acc.loot + c.value
        table.insert(acc.top, c)
      end
    else
      acc.unknown = acc.unknown + 1
    end
  end
  for _, d in ipairs(m.skin) do
    local price = Price(d[1])
    if price then acc.skin = acc.skin + d[2] * price end
  end
  acc.total = acc.gold + acc.loot
  local byValue = function(a, b) return a.value > b.value end
  table.sort(acc.top, byValue)
  table.sort(acc.raretop, byValue)
  acc.byItem = nil
  acc.all = nil
  computeCache[entry] = { t = now, acc = acc }
  return acc
end

-- ---------------------------------------------------------------- helpers
local function Money(copper)
  copper = math.floor(copper + 0.5)
  local g = math.floor(copper / 10000)
  local s = math.floor(math.mod(copper, 10000) / 100)
  local c = math.mod(copper, 100)
  local out = ""
  if g > 0 then out = out .. "|cffffd700" .. g .. "g|r " end
  if g > 0 or s > 0 then out = out .. "|cffc7c7cf" .. s .. "s|r " end
  out = out .. "|cffeda55f" .. c .. "c|r"
  return out
end

local function ItemName(id)
  local name = GetItemInfo(id)
  if name then return name end
  if pfDB and pfDB["items"] and pfDB["items"]["loc"] and pfDB["items"]["loc"][id] then
    return pfDB["items"]["loc"][id]
  end
  return "item:" .. id
end

local function FmtQty(q)
  if q >= 1 then return format("x%.1f", q) end
  if q >= 0.01 then return format("%.0f%%", q * 100) end
  return format("%.2f%%", q * 100)
end

local SRC_TAG = { vendor = " (vendor)", de = " (DE)", quest = " (quest)", ah = "" }

local skillCache = {}
local function HasSkill(skillName)
  if skillCache[skillName] ~= nil then return skillCache[skillName] end
  local found = false
  local n = GetNumSkillLines and GetNumSkillLines() or 0
  for i = 1, n do
    if GetSkillLineInfo(i) == skillName then found = true; break end
  end
  skillCache[skillName] = found
  return found
end

-- Creature entry from Turtle's extended UnitExists guid: 16 hex digits,
-- "F130" + 6-digit entry + 6-digit spawn counter for creatures.
local function GuidEntry(guid)
  if type(guid) ~= "string" then return nil end
  guid = string.upper(guid)
  if string.sub(guid, 1, 2) == "0X" then guid = string.sub(guid, 3) end
  if string.len(guid) ~= 16 or string.sub(guid, 1, 3) ~= "F13" then return nil end
  return tonumber(string.sub(guid, 5, 10), 16)
end

local function UnitEntry(unit)
  if not UnitExists(unit) or UnitIsPlayer(unit) then return nil end
  local _, guid = UnitExists(unit)
  return GuidEntry(guid)
end

local function IsAttackable(unit)
  if cfg.friendly then return true end
  if UnitIsDead and UnitIsDead(unit) then return true end
  if UnitCanAttack then return UnitCanAttack("player", unit) and true or false end
  return true
end

-- ---------------------------------------------------------------- tooltip
-- Both the mouseover event and a SetUnit call can fire for one hover
-- (unit frames: OnEnter -> SetUnit, then UPDATE_MOUSEOVER_UNIT). The
-- tooltip's own text is the only reliable "already added" state, since a
-- SetUnit rebuild wipes our line without an OnHide in between.
local function HasOurLine(tooltip)
  local name = tooltip.GetName and tooltip:GetName()
  if not name or not tooltip.NumLines then return false end
  for i = 1, tooltip:NumLines() do
    local fs = getglobal(name .. "TextLeft" .. i)
    if fs and fs.GetText and fs:GetText() == LINE_LABEL then return true end
  end
  return false
end

local function AddTooltipLines(tooltip, unit)
  if not cfg.enabled then return end
  local entry = UnitEntry(unit)
  if not entry or not IsAttackable(unit) then return end
  if HasOurLine(tooltip) then return end
  local acc = Compute(entry)
  if not acc then return end

  local tag = ""
  if not AuxHistory() then tag = " |cff888888(vendor only)|r"
  elseif acc.known == 0 and acc.unknown > 0 then tag = " |cff888888(no prices)|r" end
  tooltip:AddDoubleLine(LINE_LABEL, Money(acc.total) .. tag, 0.2, 1, 0.6, 1, 1, 1)

  if cfg.detail > 0 then
    if acc.gold > 0 then
      tooltip:AddDoubleLine("  coins", Money(acc.gold), 0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
    end
    local n = 0
    for _, c in ipairs(acc.top) do
      if n >= cfg.detail or c.value < 1 then break end
      tooltip:AddDoubleLine("  " .. ItemName(c.id) .. " " .. FmtQty(c.qty) .. (SRC_TAG[c.src] or ""),
        Money(c.value), 0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
      n = n + 1
    end
    if acc.rare >= 100 then
      tooltip:AddDoubleLine("  rare drops (<" .. (cfg.rare * 100) .. "%)", "+" .. Money(acc.rare),
        0.6, 0.6, 0.6, 0.7, 0.7, 0.7)
    end
  end
  if cfg.skin and acc.skin > 0 and HasSkill(GATHER_SKILL[acc.gather]) then
    tooltip:AddDoubleLine("  " .. GATHER[acc.gather], "+" .. Money(acc.skin), 0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
  end
  tooltip:Show()
end

-- World mouseover: the client fills GameTooltip itself, then fires this.
local frame = CreateFrame("Frame", ADDON .. "Frame")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    InitConfig()
  elseif event == "SKILL_LINES_CHANGED" then
    skillCache = {}
  elseif event == "UPDATE_MOUSEOVER_UNIT" then
    if cfg and GameTooltip:IsVisible() then AddTooltipLines(GameTooltip, "mouseover") end
  end
end)

-- Unit frames call SetUnit from Lua (world units never do).
local origSetUnit = GameTooltip.SetUnit
GameTooltip.SetUnit = function(self, unit)
  origSetUnit(self, unit)
  if cfg then AddTooltipLines(self, unit) end
end

-- ---------------------------------------------------------------- slash
local function Report(entry, label)
  local acc = Compute(entry)
  if not acc then Print("no loot data for " .. label .. " (creature " .. entry .. ")"); return end
  Print(label .. " (creature " .. entry .. "): " .. Money(acc.total) .. " per kill"
    .. (AuxHistory() and "" or " (vendor prices only)"))
  if acc.gold > 0 then Print("  coins: " .. Money(acc.gold)) end
  local n = 0
  for _, c in ipairs(acc.top) do
    if n >= 10 or c.value < 1 then break end
    Print("  " .. ItemName(c.id) .. " " .. FmtQty(c.qty) .. (SRC_TAG[c.src] or "") .. ": " .. Money(c.value))
    n = n + 1
  end
  if acc.rare > 0 then
    Print("  rare drops (<" .. (cfg.rare * 100) .. "%, not in total): +" .. Money(acc.rare))
    n = 0
    for _, c in ipairs(acc.raretop) do
      if n >= 5 or c.value < 1 then break end
      Print("    " .. ItemName(c.id) .. " " .. FmtQty(c.qty) .. (SRC_TAG[c.src] or "") .. ": " .. Money(c.value))
      n = n + 1
    end
  end
  if acc.skin > 0 then Print("  " .. GATHER[acc.gather] .. ": +" .. Money(acc.skin)) end
  if acc.unknown > 0 then Print("  " .. acc.unknown .. " drop(s) have no known price") end
end

local function Toggle(key, label)
  cfg[key] = not cfg[key]
  computeCache = {}
  Print(label .. " " .. (cfg[key] and "on" or "off"))
end

SLASH_OCTOKILLVALUE1 = "/okv"
SlashCmdList["OCTOKILLVALUE"] = function(msg)
  msg = string.lower(msg or "")
  local _, _, cmd, arg = string.find(msg, "^(%S*)%s*(.*)$")
  if cmd == "toggle" then Toggle("enabled", "tooltip line")
  elseif cmd == "skin" then Toggle("skin", "gather (skinning/mining/herbalism) line")
  elseif cmd == "vendor" then Toggle("vendor", "vendor price fallback/floor")
  elseif cmd == "de" then Toggle("de", "disenchant value")
  elseif cmd == "friendly" then Toggle("friendly", "line on friendly NPCs")
  elseif cmd == "detail" then
    local n = tonumber(arg)
    if n then cfg.detail = math.floor(n) end
    Print("detail lines: " .. cfg.detail)
  elseif cmd == "price" then
    if arg == "today" or arg == "value" then cfg.price = arg; computeCache = {} end
    Print("aux price source: " .. cfg.price)
  elseif cmd == "cut" then
    local pct = tonumber(arg)
    if pct then cfg.cut = pct; computeCache = {} end
    Print("auction house cut: " .. cfg.cut .. "%")
  elseif cmd == "rare" then
    local pct = tonumber(arg)
    if pct then cfg.rare = pct / 100; computeCache = {} end
    Print("drops below " .. (cfg.rare * 100) .. "% are listed as rare, outside the total")
  elseif cmd == "mindays" then
    local n = tonumber(arg)
    if n then cfg.mindays = math.floor(n); computeCache = {} end
    Print("aux prices above " .. Money(cfg.trust) .. " need " .. cfg.mindays .. " daily observation(s)")
  elseif cmd == "guid" then
    local exists, guid = UnitExists("target")
    Print("target guid: " .. tostring(guid) .. " -> creature " .. tostring(GuidEntry(guid))
      .. (GuidEntry(guid) and OKV_MOB[GuidEntry(guid)] and " (has data)" or " (no data)"))
  elseif cmd == "target" or cmd == "" then
    local entry = UnitEntry("target")
    if entry then
      Report(entry, UnitName("target") or "target")
    elseif cmd == "target" then
      Print("no creature targeted")
    else
      Print("/okv target | id <creatureId> | guid | toggle | detail <n> | price value|today | cut <pct> | rare <pct> | mindays <n> | skin | vendor | de | friendly")
      Print("aux: " .. (AuxHistory() and "connected" or "not found") .. ", tooltip "
        .. (cfg.enabled and "on" or "off") .. ", detail " .. cfg.detail .. ", price " .. cfg.price
        .. ", cut " .. cfg.cut .. "%, de " .. (cfg.de and "on" or "off"))
    end
  elseif cmd == "id" then
    local entry = tonumber(arg)
    if entry then Report(entry, "creature") else Print("usage: /okv id <creatureId>") end
  else
    Print("unknown command; /okv for help")
  end
end
