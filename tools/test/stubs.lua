-- Minimal WoW 1.12 + aux-addon environment for running OctoKillValue
-- under a modern Lua VM (fengari, Lua 5.3). Only what the addon touches.

-- Lua 5.0 names the addon relies on
string.gfind = string.gfind or string.gmatch
math.mod = math.mod or math.fmod
table.getn = table.getn or function(t) return #t end
format = string.format

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

-- tooltip
GameTooltip = { lines = {}, visible = false, scripts = {}, shown = 0 }
function GameTooltip.SetUnit(self, unit) self.lines = {}; self.visible = true; self.unit = unit end
function GameTooltip.AddDoubleLine(self, l, r) table.insert(self.lines, l .. " | " .. r) end
function GameTooltip.AddLine(self, l) table.insert(self.lines, l) end
function GameTooltip.Show(self) self.shown = self.shown + 1 end
function GameTooltip.IsVisible(self) return self.visible end
function GameTooltip.GetScript(self, which) return self.scripts[which] end
function GameTooltip.SetScript(self, which, fn) self.scripts[which] = fn end
function GameTooltip.Hide(self)
  self.visible = false
  if self.scripts.OnHide then self.scripts.OnHide() end
end

-- units: Units[unit] = { guid=, player=, name= }
Units = {}
function UnitExists(unit)
  local u = Units[unit]
  if not u then return nil end
  return 1, u.guid
end
function UnitIsPlayer(unit) return Units[unit] and Units[unit].player end
function UnitName(unit) return Units[unit] and Units[unit].name end

-- items / skills
ItemNames = {}
function GetItemInfo(id) return ItemNames[id] end
Skills = {}
function GetNumSkillLines() return #Skills end
function GetSkillLineInfo(i) return Skills[i] end

-- aux-addon module system: require('aux.core.history').value(key)
AuxPrices = {}       -- key "id:0" -> value copper
AuxToday = {}        -- key -> today's min buyout (counts as one observation)
AuxDays = {}         -- key -> list of pushed daily data points
AuxLoaded = true
function require(name)
  if name ~= "aux.core.history" or not AuxLoaded then return {} end
  return {
    value = function(key) return AuxPrices[key] end,
    market_value = function(key) return AuxToday[key] end,
    data_points = function(key) return AuxDays[key] or {} end,
  }
end
