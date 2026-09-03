-- Minimal WoW 1.12 + aux-addon environment for running OctoKillValue
-- under a modern Lua VM (fengari, Lua 5.3). Only what the addon touches.

-- Lua 5.0 names the addon relies on
string.gfind = string.gfind or string.gmatch
math.mod = math.mod or math.fmod
table.getn = table.getn or function(t) return #t end
format = string.format
function getglobal(name) return _G[name] end
local now = 1000
function GetTime() return now end
-- fengari has no collector hook; the client has both of these (Lua 5.0)
collectgarbage = function() end
gcinfo = nil
function AdvanceTime(s) now = now + s end

-- chat
ChatLog = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(self, msg) table.insert(ChatLog, msg) end }
SlashCmdList = {}

-- frames / events
CreatedFrames = {}
function CreateFrame(kind, name)
  local f = { scripts = {}, events = {} }
  function f.RegisterEvent(self, e) self.events[e] = true end
  function f.SetScript(self, which, fn) self.scripts[which] = fn end
  table.insert(CreatedFrames, f)
  return f
end
function FireEvent(e)
  event = e
  for _, f in ipairs(CreatedFrames) do
    if f.events[e] and f.scripts.OnEvent then f.scripts.OnEvent(f) end
  end
  event = nil
end

-- tooltip: lines are mirrored into GameTooltipTextLeftN globals like the client does
GameTooltip = { lines = {}, visible = false, scripts = {}, shown = 0 }
local function syncLines(self)
  for i = 1, 40 do _G["GameTooltipTextLeft" .. i] = nil end
  for i, l in ipairs(self.lines) do
    local left = string.match(l, "^(.-) | ") or l
    _G["GameTooltipTextLeft" .. i] = { GetText = function() return left end }
  end
end
function GameTooltip.GetName(self) return "GameTooltip" end
function GameTooltip.NumLines(self) return #self.lines end
function GameTooltip.SetUnit(self, unit)
  -- the client rebuilds the tooltip from scratch: name line only
  self.lines = { (Units[unit] and Units[unit].name) or "?" }
  self.visible = true
  self.unit = unit
  syncLines(self)
end
function GameTooltip.AddDoubleLine(self, l, r) table.insert(self.lines, l .. " | " .. r); syncLines(self) end
function GameTooltip.AddLine(self, l) table.insert(self.lines, l); syncLines(self) end
function GameTooltip.Show(self) self.shown = self.shown + 1 end
function GameTooltip.IsVisible(self) return self.visible end
function GameTooltip.GetScript(self, which) return self.scripts[which] end
function GameTooltip.SetScript(self, which, fn) self.scripts[which] = fn end
function GameTooltip.Hide(self)
  self.visible = false
  if self.scripts.OnHide then self.scripts.OnHide() end
end
-- what the client does for a world mouseover: rebuild with the unit's name
function GameTooltip.ClientShowUnit(self, unit)
  self.lines = { (Units[unit] and Units[unit].name) or "?" }
  self.visible = true
  syncLines(self)
end

-- units: Units[unit] = { guid=, player=, name=, friendly=, dead= }
Units = { player = { guid = "0x000000003B9E9C90", name = "Tester", player = true } }
function UnitExists(unit)
  local u = Units[unit]
  if not u then return nil end
  return 1, u.guid
end
function UnitIsPlayer(unit) return Units[unit] and Units[unit].player end
function UnitName(unit) return Units[unit] and Units[unit].name end
function UnitCanAttack(a, unit) return Units[unit] and not Units[unit].friendly end
function UnitIsDead(unit) return Units[unit] and Units[unit].dead end

-- items / skills
ItemInfo = {}   -- id -> { name, quality, level, equip }
function GetItemInfo(id)
  local i = ItemInfo[id]
  if not i then return nil end
  return i.name, "item:" .. id, i.quality, i.level, "Armor", "Cloth", 1, i.equip
end
Skills = {}
function GetNumSkillLines() return #Skills end
function GetSkillLineInfo(i) return Skills[i] end

-- aux-addon module system: require('aux.core.history').value(key) etc.
AuxPrices = {}       -- key "id:suffix" -> value copper
AuxToday = {}        -- key -> today's min buyout (counts as one observation)
AuxDays = {}         -- key -> list of pushed daily data points
AuxHistoryKeys = {}  -- faction_data.history table: real aux packs each record
                     -- into a string ("next#today#v@t;v@t"); a string value here
                     -- is parsed directly by the addon, anything else makes it
                     -- fall back to the API stubs above. Keys that only exist
                     -- in AuxPrices/AuxToday/AuxDays read as `true` (API path);
                     -- unknown keys read as nil, like aux's history for an item
                     -- never seen.
HistoryMT = { __index = function(_, key)
  if AuxPrices[key] ~= nil or AuxToday[key] ~= nil or AuxDays[key] ~= nil then return true end
  return nil
end }
function NewHistoryKeys(t) return setmetatable(t or {}, HistoryMT) end
AuxHistoryKeys = NewHistoryKeys()
AuxDE = {}           -- item id -> disenchant expectation
AuxLoaded = true
function require(name)
  if not AuxLoaded then return {} end
  if name == "aux.core.history" then
    return {
      value = function(key) return AuxPrices[key] end,
      market_value = function(key) return AuxToday[key] end,
      data_points = function(key) return AuxDays[key] or {} end,
    }
  elseif name == "aux" then
    return { faction_data = { history = AuxHistoryKeys } }
  elseif name == "aux.core.disenchant" then
    return { value = function(slot, quality, level, id) return AuxDE[id] end }
  end
  return {}
end

-- zone lookup (pfQuest) - a tiny world: Dun Morogh holds Kobold Vermin and Flesh Eater, Onyxia's Lair holds Onyxia
ZoneName = "Dun Morogh"
function GetRealZoneText() return ZoneName end
pfDB = {
  zones = { loc = { [1] = "Dun Morogh", [2] = "Onyxia's Lair" } },
  units = {
    data = {
      [6] = { coords = { { 50, 50, 1, 300 } } },
      [3] = { coords = { { 40, 40, 1, 300 }, { 10, 10, 2, 300 } } },
      [10184] = { coords = { { 50, 50, 2, 0 } } },
      [999999] = { coords = { { 1, 1, 1, 0 } } },
    },
    loc = { [6] = "Kobold Vermin", [3] = "Flesh Eater", [10184] = "Onyxia" },
  },
}
