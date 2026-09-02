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
  hello = true,     -- one-line "loaded" message at login
}
local SETTING_HELP = {
  enabled = "tooltip line", detail = "contributor lines under the total", price = "aux source: value|today",
  skin = "gather line (skinning/mining/herbalism)", vendor = "vendor price as fallback/floor",
  de = "disenchant estimate (aux)", friendly = "show on friendly NPCs", cut = "auction house cut %",
  rare = "rare threshold (fraction of a drop per kill)", mindays = "days an expensive price must be seen",
  trust = "copper below which one sighting is trusted", hello = "login message",
}
local SETTING_ORDER = { "enabled", "detail", "price", "cut", "rare", "mindays", "trust", "vendor", "de", "skin", "friendly", "hello" }
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
-- price cache as three flat maps (one table per entry was itself memory
-- pressure on the client's fixed Lua pool during a zone report)
local priceT, priceP, priceS = {}, {}, {}   -- itemId -> time / price / source (30s, see CACHE_TTL)
local zoneIndex = {}   -- zone id -> creature ids with data (see ZoneCreatures)
local function ClearCaches()
  computeCache = {}
  priceT, priceP, priceS = {}, {}, {}
  zoneIndex = {}
end
function OctoKillValue_ResetAux()
  auxModules = {}
  auxChecked = {}
  suffixIndex = nil
  ClearCaches()
end

-- aux's raw observations for a key: the pushed daily minimum buyouts plus
-- today's, sorted ascending. Empty when aux has none.
local function Observations(h, key)
  local vals = {}
  if type(h.data_points) == "function" then
    local ok, pts = pcall(h.data_points, key)
    if ok and type(pts) == "table" then
      for _, p in ipairs(pts) do
        if type(p) == "table" and type(p.value) == "number" then table.insert(vals, p.value) end
      end
    end
  end
  if type(h.market_value) == "function" then
    local ok, today = pcall(h.market_value, key)
    if ok and type(today) == "number" then table.insert(vals, today) end
  end
  table.sort(vals)
  return vals
end

-- One aux history key ("id:suffix") -> trusted unit price or nil.
-- aux's own value() is a weighted median that returns the HIGHER of two
-- observations, so one troll listing next to one real price wins; we take
-- the lower median of the raw observations instead (aux's value() only as
-- a fallback when the raw points are unavailable).
local function AuxKeyPrice(h, key)
  local v, days
  if cfg.price == "today" then
    if type(h.market_value) ~= "function" then return nil end
    local ok, t = pcall(h.market_value, key)
    if ok and type(t) == "number" then v = t end
    days = v and 1 or 0
  else
    local vals = Observations(h, key)
    days = table.getn(vals)
    if days > 0 then
      v = vals[math.floor((days + 1) / 2)]
    elseif type(h.value) == "function" then
      local ok, t = pcall(h.value, key)
      if ok and type(t) == "number" then v = t end
    end
  end
  if not v or v <= 0 then return nil end
  -- A lone sighting of an absurd buyout (one 166,000g listing seen once)
  -- would dominate every mob that can drop the item at 0.02%. Expensive
  -- prices must have been seen on several days before they count.
  if v > cfg.trust and cfg.mindays > 1 and days < cfg.mindays then return nil end
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
-- Quest items are a known 0. Containers (clams, lockboxes) are worth the
-- better of their own price and their expected contents when opened.
local ParsePairs -- forward declaration (defined in the data section)
local contentsCache = {}

local CACHE_TTL = 30        -- per-creature breakdowns (tooltips)
local PRICE_TTL = 30        -- per-item prices; same horizon so a fresh AH scan
                            -- reaches tooltips within 30s (tested)

local PriceUncached
-- Cached per item (top level only - container contents are priced with a
-- depth cutoff). A zone report prices the shared world-drop pools once
-- instead of once per creature, which is what exhausted the client's Lua
-- pool (lmemPool.cpp crash on /okv zone in Redridge, 2026-09-02).
local function Price(itemId, depth)
  if depth and depth > 0 then return PriceUncached(itemId, depth) end
  local now = GetTime and GetTime() or 0
  local t = priceT[itemId]
  if t and now - t < PRICE_TTL then return priceP[itemId], priceS[itemId] end
  local price, src = PriceUncached(itemId, 0)
  priceT[itemId], priceP[itemId], priceS[itemId] = now, price, src
  return price, src
end

PriceUncached = function(itemId, depth)
  depth = depth or 0
  local bind = OKV_BIND and OKV_BIND[itemId]
  if bind == 4 then return 0, "quest" end
  local net = 1 - (cfg.cut or 0) / 100
  local best, src = nil, nil
  -- bind-on-pickup never reaches the auction house; greys have no market
  -- there (any aux value for one is a troll listing)
  if bind ~= 1 and not (OKV_GREY and OKV_GREY[itemId]) then
    local ah = AuxPrice(itemId)
    if ah then best, src = ah * net, "ah" end
  end
  local dev = DisenchantValue(itemId)
  if dev and (not best or dev * net > best) then best, src = dev * net, "de" end
  if cfg.vendor and OKV_SELL and OKV_SELL[itemId] then
    local vendor = OKV_SELL[itemId]
    if not best or vendor > best then best, src = vendor, "vendor" end
  end
  if OKV_ITEM and OKV_ITEM[itemId] and depth < 3 then
    local list = contentsCache[itemId]
    if not list then list = ParsePairs(OKV_ITEM[itemId]); contentsCache[itemId] = list end
    local sum, any = 0, false
    for _, d in ipairs(list) do
      local p = Price(d[1], depth + 1)
      if p then sum = sum + d[2] * p; any = true end
    end
    if any and (not best or sum > best) then best, src = sum, "opened" end
  end
  return best, src
end

-- ---------------------------------------------------------------- data
local mobCache = {}   -- entry -> parsed record (false = no data)
local refCache = {}   -- refId -> { {id, qty}, ... }

ParsePairs = function(s)
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

local function ParseMob(s)
  local _, _, gold, drops, refs, skin, info = string.find(s, "^(%d*)|([^|]*)|([^|]*)|([^|]*)|?(.*)$")
  local gather = "S"
  if skin then
    local _, _, g, rest = string.find(skin, "^([HM]):(.*)$")
    if g then gather, skin = g, rest end
  end
  local _, _, lvl, rank, hp = string.find(info or "", "^(%d+):(%d+):(%d+)$")
  m = {
    gold = tonumber(gold) or 0,
    drops = ParsePairs(drops),
    refs = ParsePairs(refs),
    skin = ParsePairs(skin),
    gather = gather,
    lvl = tonumber(lvl), rank = tonumber(rank), hp = tonumber(hp),
  }
  return m
end

local function GetMob(entry)
  local m = mobCache[entry]
  if m ~= nil then return m or nil end
  local s = OKV_MOB and OKV_MOB[entry]
  if not s then mobCache[entry] = false; return nil end
  m = ParseMob(s)
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
  acc.lvl, acc.rank, acc.hp = m.lvl, m.rank, m.hp
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

local SRC_TAG = { vendor = " (vendor)", de = " (DE)", quest = " (quest)", opened = " (opened)", ah = "" }

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
-- ---------------------------------------------------------------- requirements
-- Hard: a guid-returning UnitExists (Turtle WoW / OctoWoW client API;
-- stock 1.12 returns only a boolean and the addon can never identify a
-- creature). Optional: aux-addon (auction prices; vendor-only without),
-- pfQuest (item names for uncached items, spawn zones for /okv zone).
local function Requirements()
  local _, guid = UnitExists("player")
  local r = {
    guid = type(guid) == "string" and string.len(guid) >= 16,
    aux = AuxHistory() ~= nil,
    pfquest = (pfDB and pfDB["units"] and pfDB["units"]["data"]) and true or false,
    data = (OKV_MOB and OKV_MOB[6]) and true or false,
  }
  return r
end

local function Status(verbose)
  local r = Requirements()
  local function mark(ok) return ok and "|cff33ff33yes|r" or "|cffff3333no|r" end
  Print("creature ids " .. mark(r.guid) .. ", aux prices " .. mark(r.aux) .. ", pfQuest "
    .. mark(r.pfquest) .. ", loot data " .. mark(r.data))
  if not r.guid then
    Print("|cffff3333This client does not report creature ids (UnitExists returns no guid).|r "
      .. "OctoKillValue needs the Turtle WoW / OctoWoW client API; no tooltip line can be shown.")
  elseif verbose then
    if not r.aux then Print("aux-addon not found: kill values use vendor sell prices only. Install aux and scan the auction house for real prices.") end
    if not r.pfquest then Print("pfQuest not found: /okv zone is unavailable and uncached items show as item:<id>.") end
  end
end

local announced = false
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    InitConfig()
  elseif event == "PLAYER_ENTERING_WORLD" then
    if cfg and not announced then
      announced = true
      local r = Requirements()
      if not r.guid or not r.aux or not r.data then Status(true) end
      if cfg.hello ~= false and r.guid then
        Print("loaded. Hover a creature for its kill value; /okv for commands.")
      end
    end
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
local RANK_TAG = { [1] = " elite", [2] = " rare-elite", [3] = " BOSS", [4] = " rare" }
local function Report(entry, label)
  local acc = Compute(entry)
  if not acc then Print("no loot data for " .. label .. " (creature " .. entry .. ")"); return end
  Print(label .. " (creature " .. entry .. "): " .. Money(acc.total) .. " per kill"
    .. (AuxHistory() and "" or " (vendor prices only)")
    .. (acc.lvl and (" [L" .. acc.lvl .. (RANK_TAG[acc.rank or 0] or "") .. ", " .. (acc.hp or "?") .. " hp]") or ""))
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

-- Best farm targets in the current zone: creatures that pfQuest knows to
-- spawn here, ranked by kill value. Level, rank and value per 1000 health
-- let you weigh a 2g elite against a 40s wolf.

local GC_BUDGET_KB = 2048

-- Kill value for the zone report only: same total as Compute() (coins +
-- non-rare loot) but RETAINS NOTHING - no compute-cache entry, no mob-cache
-- entry, no per-item tables. A zone is 100-200 creatures; caching each
-- one's full breakdown for 30s is what pushed Mulgore over the client's
-- fixed Lua pool (lmemPool.cpp crash, 2026-09-02) even with periodic GC.
local function ZoneValue(entry, includeElite)
  local m = mobCache[entry]
  if m == nil then
    local s = OKV_MOB and OKV_MOB[entry]
    if not s then return nil end
    m = ParseMob(s)
  elseif not m then
    return nil
  end
  -- rank is known before any pricing: skip elites up front when excluded
  if not includeElite and m.rank and m.rank ~= 0 then return nil end
  local qty = {}
  for _, d in ipairs(m.drops) do qty[d[1]] = (qty[d[1]] or 0) + d[2] end
  for _, r in ipairs(m.refs) do
    for _, d in ipairs(GetRef(r[1])) do qty[d[1]] = (qty[d[1]] or 0) + d[2] * r[2] end
  end
  local loot = 0
  for id, q in pairs(qty) do
    if q >= cfg.rare then
      local p = Price(id)
      if p then loot = loot + q * p end
    end
  end
  return m.gold + loot, m.lvl, m.rank, m.hp
end

-- pfQuest's unit table is every creature on the server; walking it (and every
-- spawn row) per report is the second-largest cost, so remember each zone's
-- creature ids after the first run.
local function ZoneCreatures(zid)
  local ids = zoneIndex[zid]
  if ids then return ids end
  ids = {}
  for id, u in pairs(pfDB["units"]["data"]) do
    if type(u) == "table" and type(u["coords"]) == "table" and OKV_MOB[id] then
      for _, c in ipairs(u["coords"]) do
        if c[3] == zid then table.insert(ids, id); break end
      end
    end
  end
  zoneIndex[zid] = ids
  return ids
end

local function ZoneReport(n, includeElite)
  if not (pfDB and pfDB["zones"] and pfDB["zones"]["loc"] and pfDB["units"] and pfDB["units"]["data"]) then
    Print("/okv zone needs pfQuest (creature spawn zones)"); return
  end
  local zoneName = GetRealZoneText and GetRealZoneText() or nil
  local zid
  for id, name in pairs(pfDB["zones"]["loc"]) do
    if name == zoneName then zid = id; break end
  end
  if not zid then Print("unknown zone: " .. tostring(zoneName)); return end
  local list = {}
  -- the 1.12 client crashes (lmemPool.cpp) when a burst of garbage outruns
  -- its collector, and a whole zone is such a burst. Collect whenever the
  -- Lua heap has grown by GC_BUDGET_KB since the last sweep (gcinfo() is
  -- KB in use); without gcinfo fall back to a sweep every 20 creatures.
  local computed = 0
  local gcBase = gcinfo and gcinfo() or 0
  for _, id in ipairs(ZoneCreatures(zid)) do
    computed = computed + 1
    if collectgarbage then
      if gcinfo then
        if gcinfo() - gcBase > GC_BUDGET_KB then collectgarbage(); gcBase = gcinfo() end
      elseif math.mod(computed, 20) == 0 then
        collectgarbage()
      end
    end
    local total, lvl, rank, hp = ZoneValue(id, includeElite)
    if total and total >= 1 and (includeElite or not rank or rank == 0) then
      table.insert(list, { id = id, total = total, lvl = lvl, rank = rank, hp = hp })
    end
  end
  table.sort(list, function(a, b) return a.total > b.total end)
  local names = pfDB["units"]["loc"] or {}
  Print(zoneName .. ": top " .. n .. " of " .. table.getn(list) .. " creatures by kill value"
    .. (includeElite and "" or " (non-elite; /okv zone " .. n .. " all)"))
  for i = 1, math.min(n, table.getn(list)) do
    local e = list[i]
    local per = (e.hp and e.hp > 0) and ("  " .. Money(e.total / e.hp * 1000) .. "/1k hp") or ""
    Print(format("  %s (L%s%s): %s%s", names[e.id] or ("creature " .. e.id), tostring(e.lvl or "?"),
      RANK_TAG[e.rank or 0] or "", Money(e.total), per))
  end
  if collectgarbage then collectgarbage() end
  if gcinfo then Print(format("  (Lua heap %d KB in use after the report)", gcinfo())) end
end

local function Toggle(key, label)
  cfg[key] = not cfg[key]
  ClearCaches()
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
    if arg == "today" or arg == "value" then cfg.price = arg; ClearCaches() end
    Print("aux price source: " .. cfg.price)
  elseif cmd == "cut" then
    local pct = tonumber(arg)
    if pct then cfg.cut = pct; ClearCaches() end
    Print("auction house cut: " .. cfg.cut .. "%")
  elseif cmd == "rare" then
    local pct = tonumber(arg)
    if pct then cfg.rare = pct / 100; ClearCaches() end
    Print("drops below " .. (cfg.rare * 100) .. "% are listed as rare, outside the total")
  elseif cmd == "mindays" then
    local n = tonumber(arg)
    if n then cfg.mindays = math.floor(n); ClearCaches() end
    Print("aux prices above " .. Money(cfg.trust) .. " need " .. cfg.mindays .. " daily observation(s)")
  elseif cmd == "zone" then
    local _, _, num, rest = string.find(arg, "^(%d*)%s*(.*)$")
    ZoneReport(tonumber(num) or 10, rest == "all")
  elseif cmd == "guid" then
    local exists, guid = UnitExists("target")
    Print("target guid: " .. tostring(guid) .. " -> creature " .. tostring(GuidEntry(guid))
      .. (GuidEntry(guid) and OKV_MOB[GuidEntry(guid)] and " (has data)" or " (no data)"))
  elseif cmd == "status" then
    Status(true)
  elseif cmd == "mem" then
    if gcinfo then
      local used, threshold = gcinfo()
      Print(format("Lua heap: %d KB in use, next automatic sweep at %s KB", used, tostring(threshold)))
    else Print("gcinfo() unavailable") end
  elseif cmd == "hello" then Toggle("hello", "login message")
  elseif cmd == "config" then
    for _, k in ipairs(SETTING_ORDER) do
      local v = cfg[k]
      if type(v) == "boolean" then v = v and "on" or "off" end
      if k == "rare" then v = (cfg.rare * 100) .. "%" end
      if k == "trust" then v = Money(cfg.trust) end
      Print(format("  %-8s %-10s %s", k, tostring(v), SETTING_HELP[k] or ""))
    end
  elseif cmd == "reset" then
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
    ClearCaches()
    Print("settings restored to defaults")
  elseif cmd == "target" or cmd == "" or cmd == "help" then
    local entry = (cmd ~= "help") and UnitEntry("target") or nil
    if entry then
      Report(entry, UnitName("target") or "target")
    elseif cmd == "target" then
      Print("no creature targeted")
    else
      Print("commands:")
      Print("  /okv                     breakdown for your target")
      Print("  /okv id <creatureId>     breakdown for any creature")
      Print("  /okv zone [n] [all]      best farm targets in this zone (needs pfQuest)")
      Print("  /okv config | reset      show all settings / restore defaults")
      Print("  /okv status | guid | mem requirement check / target guid / Lua heap use")
      Print("  /okv toggle | detail <n> | price value|today | cut <pct> | rare <pct> | mindays <n>")
      Print("  /okv vendor | de | skin | friendly | hello    (on/off switches)")
      Status(false)
    end
  elseif cmd == "id" then
    local entry = tonumber(arg)
    if entry then Report(entry, "creature") else Print("usage: /okv id <creatureId>") end
  else
    Print("unknown command '" .. cmd .. "'; /okv help")
  end
end
