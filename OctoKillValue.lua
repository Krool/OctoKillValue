-- OctoKillValue - expected gold per kill on creature tooltips.
--
-- value(mob) = avg coin drop
--            + sum over drop table of expectedQty(item) * price(item)
-- where expectedQty comes from Data.lua (Turtle 1.18.1 loot templates,
-- see tools/gen-data.js) and price(item) is aux-addon's auction value
-- for "item:0", falling back to (or raised to) the vendor sell price.
--
-- Lua 5.0 (WoW 1.12): no string.match, no #, event args are globals.

local ADDON = "OctoKillValue"
local PREFIX = "|cff33ff99OctoKillValue|r: "

OctoKillValueDB = OctoKillValueDB or {}
local DEFAULTS = {
  enabled = true,   -- tooltip line on/off
  detail = 3,       -- top-N contributor lines under the total (0 = none)
  price = "value",  -- aux price source: "value" (weighted median) or "today" (daily min buyout)
  skin = true,      -- show skinning value line when the player has Skinning
  vendor = true,    -- use vendor sell price when aux has no value / as a floor
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

-- ---------------------------------------------------------------- prices
local auxHistory = nil
local auxChecked = false

local function AuxHistory()
  if auxChecked then return auxHistory end
  auxChecked = true
  if type(require) == "function" then
    local ok, h = pcall(require, "aux.core.history")
    if ok and type(h) == "table" and type(h.value) == "function" then
      auxHistory = h
    end
  end
  return auxHistory
end

-- Re-detect aux (e.g. after it loads late); also used by the test harness.
function OctoKillValue_ResetAux()
  auxChecked = false
  auxHistory = nil
end

local function AuxPrice(itemId)
  local h = AuxHistory()
  if not h then return nil end
  local key = itemId .. ":0"
  local fn = (cfg.price == "today") and h.market_value or h.value
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

-- Unit price in copper, or nil when nothing is known.
local function Price(itemId)
  local ah = AuxPrice(itemId)
  local vendor = cfg.vendor and OKV_SELL and OKV_SELL[itemId] or nil
  if ah and vendor then
    if vendor > ah then return vendor, "vendor" end
    return ah, "ah"
  elseif ah then
    return ah, "ah"
  elseif vendor then
    return vendor, "vendor"
  end
  return nil
end

-- ---------------------------------------------------------------- data
local mobCache = {}   -- entry -> parsed record
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

local function GetMob(entry)
  local m = mobCache[entry]
  if m ~= nil then return m or nil end
  local s = OKV_MOB and OKV_MOB[entry]
  if not s then mobCache[entry] = false; return nil end
  local _, _, gold, drops, refs, skin = string.find(s, "^(%d*)|([^|]*)|([^|]*)|(.*)$")
  m = {
    gold = tonumber(gold) or 0,
    drops = ParsePairs(drops),
    refs = ParsePairs(refs),
    skin = ParsePairs(skin),
  }
  mobCache[entry] = m
  return m
end

-- ---------------------------------------------------------------- compute
-- Returns { total, gold, loot, rare, skin, known, unknown,
--           top = { {id, qty, value} ... }, raretop = { same, below the rare threshold } }
-- total = gold + loot; rare is reported separately (not part of total).
local function AddContrib(acc, id, qty)
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
  local m = GetMob(entry)
  if not m then return nil end
  local acc = { gold = m.gold, loot = 0, rare = 0, skin = 0, known = 0, unknown = 0,
    top = {}, raretop = {}, all = {}, byItem = {} }
  -- first merge quantities per item (an item can arrive via several pools)
  for _, d in ipairs(m.drops) do AddContrib(acc, d[1], d[2]) end
  for _, r in ipairs(m.refs) do
    for _, d in ipairs(GetRef(r[1])) do AddContrib(acc, d[1], d[2] * r[2]) end
  end
  -- then price each item once and split by expected quantity
  for _, c in ipairs(acc.all) do
    local price = Price(c.id)
    if price then
      c.value = c.qty * price
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

local hasSkinning = nil
local function HasSkinning()
  if hasSkinning ~= nil then return hasSkinning end
  hasSkinning = false
  local n = GetNumSkillLines and GetNumSkillLines() or 0
  for i = 1, n do
    local name = GetSkillLineInfo(i)
    if name == "Skinning" then hasSkinning = true; break end
  end
  return hasSkinning
end

-- Creature entry from Turtle's extended UnitExists guid ("0xF130EEEEEELLLLLL").
local function UnitEntry(unit)
  if not UnitExists(unit) or UnitIsPlayer(unit) then return nil end
  local _, guid = UnitExists(unit)
  if type(guid) ~= "string" or string.sub(guid, 1, 5) ~= "0xF13" then return nil end
  return tonumber(string.sub(guid, 7, 12), 16)
end

-- ---------------------------------------------------------------- tooltip
local shownGuid = nil

local function AddTooltipLines(tooltip, unit)
  if not cfg.enabled then return end
  local entry = UnitEntry(unit)
  if not entry then return end
  local _, guid = UnitExists(unit)
  if shownGuid == guid then return end
  local acc = Compute(entry)
  if not acc then return end
  shownGuid = guid

  local tag = ""
  if not AuxHistory() then tag = " |cff888888(vendor only)|r"
  elseif acc.unknown > 0 and acc.known == 0 and acc.loot == 0 then tag = " |cff888888(no prices)|r" end
  tooltip:AddDoubleLine("Kill value", Money(acc.total) .. tag, 0.2, 1, 0.6, 1, 1, 1)

  if cfg.detail > 0 then
    if acc.gold > 0 then
      tooltip:AddDoubleLine("  coins", Money(acc.gold), 0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
    end
    local n = 0
    for _, c in ipairs(acc.top) do
      if n >= cfg.detail or c.value < 1 then break end
      tooltip:AddDoubleLine("  " .. ItemName(c.id) .. " " .. FmtQty(c.qty), Money(c.value),
        0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
      n = n + 1
    end
    if acc.rare >= 100 then
      tooltip:AddDoubleLine("  rare drops (<" .. (cfg.rare * 100) .. "%)", "+" .. Money(acc.rare),
        0.6, 0.6, 0.6, 0.7, 0.7, 0.7)
    end
  end
  if cfg.skin and acc.skin > 0 and HasSkinning() then
    tooltip:AddDoubleLine("  skinning", "+" .. Money(acc.skin), 0.7, 0.7, 0.7, 0.8, 0.8, 0.8)
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
    hasSkinning = nil
  elseif event == "UPDATE_MOUSEOVER_UNIT" then
    if cfg and GameTooltip:IsVisible() then AddTooltipLines(GameTooltip, "mouseover") end
  end
end)

-- Unit frames / nameplates call SetUnit from Lua.
local origSetUnit = GameTooltip.SetUnit
GameTooltip.SetUnit = function(self, unit)
  origSetUnit(self, unit)
  if cfg then AddTooltipLines(self, unit) end
end

local origOnHide = GameTooltip:GetScript("OnHide")
GameTooltip:SetScript("OnHide", function()
  if origOnHide then origOnHide() end
  shownGuid = nil
end)

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
    Print("  " .. ItemName(c.id) .. " " .. FmtQty(c.qty) .. ": " .. Money(c.value))
    n = n + 1
  end
  if acc.rare > 0 then
    Print("  rare drops (<" .. (cfg.rare * 100) .. "%, not in total): +" .. Money(acc.rare))
    n = 0
    for _, c in ipairs(acc.raretop) do
      if n >= 5 or c.value < 1 then break end
      Print("    " .. ItemName(c.id) .. " " .. FmtQty(c.qty) .. ": " .. Money(c.value))
      n = n + 1
    end
  end
  if acc.skin > 0 then Print("  skinning: +" .. Money(acc.skin)) end
  if acc.unknown > 0 then Print("  " .. acc.unknown .. " drop(s) have no known price") end
end

SLASH_OCTOKILLVALUE1 = "/okv"
SlashCmdList["OCTOKILLVALUE"] = function(msg)
  msg = string.lower(msg or "")
  local _, _, cmd, arg = string.find(msg, "^(%S*)%s*(.*)$")
  if cmd == "toggle" then
    cfg.enabled = not cfg.enabled
    Print("tooltip line " .. (cfg.enabled and "on" or "off"))
  elseif cmd == "detail" then
    local n = tonumber(arg)
    if n then cfg.detail = math.floor(n) end
    Print("detail lines: " .. cfg.detail)
  elseif cmd == "price" then
    if arg == "today" or arg == "value" then cfg.price = arg end
    Print("aux price source: " .. cfg.price)
  elseif cmd == "skin" then
    cfg.skin = not cfg.skin
    Print("skinning line " .. (cfg.skin and "on" or "off"))
  elseif cmd == "vendor" then
    cfg.vendor = not cfg.vendor
    Print("vendor price fallback/floor " .. (cfg.vendor and "on" or "off"))
  elseif cmd == "rare" then
    local pct = tonumber(arg)
    if pct then cfg.rare = pct / 100 end
    Print("drops below " .. (cfg.rare * 100) .. "% are listed as rare, outside the total")
  elseif cmd == "mindays" then
    local n = tonumber(arg)
    if n then cfg.mindays = math.floor(n) end
    Print("aux prices above " .. Money(cfg.trust) .. " need " .. cfg.mindays .. " daily observation(s)")
  elseif cmd == "target" or cmd == "" then
    local entry = UnitEntry("target")
    if entry then
      Report(entry, UnitName("target") or "target")
    elseif cmd == "target" then
      Print("no creature targeted")
    else
      Print("/okv target | /okv id <creatureId> | toggle | detail <n> | price value|today | skin | vendor | rare <pct> | mindays <n>")
      Print("aux: " .. (AuxHistory() and "connected" or "not found") .. ", tooltip "
        .. (cfg.enabled and "on" or "off") .. ", detail " .. cfg.detail .. ", price " .. cfg.price)
    end
  elseif cmd == "id" then
    local entry = tonumber(arg)
    if entry then Report(entry, "creature") else Print("usage: /okv id <creatureId>") end
  else
    Print("unknown command; /okv for help")
  end
end
