-- Behavior checks for OctoKillValue. Runs after stubs.lua, Data.lua and
-- OctoKillValue.lua in the same VM. Each check() must be true.

local passed, failed = 0, 0
local function check(label, cond)
  if cond then passed = passed + 1; print("ok   " .. label)
  else failed = failed + 1; print("FAIL " .. label) end
end
local function strip(s) return (string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")):gsub("|r", "") end
local function findLine(pat)
  for _, l in ipairs(GameTooltip.lines) do
    if string.find(strip(l), pat) then return strip(l) end
  end
  return nil
end
local function chatHas(pat)
  for _, l in ipairs(ChatLog) do if string.find(strip(l), pat) then return strip(l) end end
  return nil
end
-- "12g 3s 4c" / "3s 4c" / "4c" -> copper
local function copper(s)
  local g = tonumber(string.match(s, "(%d+)g")) or 0
  local sv = tonumber(string.match(s, "(%d+)s")) or 0
  local c = tonumber(string.match(s, "(%d+)c")) or 0
  return g * 10000 + sv * 100 + c
end
local function parseData(entry)
  local s = OKV_MOB[entry]
  local gold, drops, refs, skin = string.match(s, "^(%d*)|([^|]*)|([^|]*)|(.*)$")
  local function pairsOf(str)
    local t = {}
    for id, q in string.gmatch(str, "(%d+):([%d%.e%-]+)") do t[tonumber(id)] = tonumber(q) end
    return t
  end
  return tonumber(gold), pairsOf(drops), pairsOf(refs), pairsOf(skin)
end
local function total() return copper(string.match(strip(ChatLog[1]), "%): (.-) per kill")) end
local function hover(unit, guid, name, extra)
  Units[unit] = { guid = guid, name = name }
  if extra then for k, v in pairs(extra) do Units[unit][k] = v end end
  GameTooltip:Hide()
  GameTooltip:ClientShowUnit(unit)
  GameTooltip.shown = 0
  FireEvent("UPDATE_MOUSEOVER_UNIT")
end
local KOBOLD = "0xF130000006000001"       -- creature 6
local ONYXIA = "0xF1300027C8000002"       -- creature 10184 = 0x27C8

-- boot
FireEvent("VARIABLES_LOADED")
check("config defaults applied", OctoKillValueDB.enabled == true and OctoKillValueDB.detail == 3
  and OctoKillValueDB.cut == 5 and OctoKillValueDB.mindays == 3)
local okv = SlashCmdList["OCTOKILLVALUE"]
check("slash command registered", type(okv) == "function")
OctoKillValueDB.cut = 0 -- exact arithmetic below; the cut has its own check

-- ---- pure math via /okv id: aux knows only Linen Cloth, vendor floor off
local gold6, drops6, refs6 = parseData(6)
local linenQty = drops6[755]
check("Kobold Vermin data: coins and linen qty present", gold6 == 3 and linenQty and linenQty > 0.2)
AuxPrices["755:0"] = 100
OctoKillValueDB.vendor = false
ChatLog = {}
okv("id 6")
local expected = gold6 + linenQty * 100
check("total = coins + qty*price (" .. total() .. "c vs " .. expected .. ")", math.abs(total() - expected) <= 1)
check("breakdown lists Linen with qty", chatHas("item:755 30%%") ~= nil)
check("unpriced drops are counted", chatHas("have no known price") ~= nil)

-- ---- reference pool expansion: price one item from ref 30017 only
AuxPrices = {}
OctoKillValue_ResetAux()
local refMult = refs6[30017]
local refItem, refQty
for id, q in string.gmatch(OKV_REF[30017], "(%d+):([%d%.e%-]+)") do refItem, refQty = tonumber(id), tonumber(q); break end
AuxPrices[refItem .. ":0"] = 100000
OctoKillValueDB.rare = 0 -- the pool entry is far below 0.1%; count it in the total here
ChatLog = {}
okv("id 6")
OctoKillValueDB.rare = 0.001
expected = gold6 + refMult * refQty * 100000
check("reference pool contributes mult*qty*price (" .. total() .. " vs " .. math.floor(expected + 0.5) .. ")",
  math.abs(total() - expected) <= 1)

-- ---- vendor floor: vendor price above aux value wins; source tag shown
local gold3, drops3 = parseData(3) -- Flesh Eater: Wool Cloth (33c vendor) at ~37%
local vendItem, vendQty
for id, q in pairs(drops3) do
  if OKV_SELL[id] and OKV_SELL[id] > 1 and q > 0.01 and (not vendQty or q > vendQty) then vendItem, vendQty = id, q end
end
check("Flesh Eater drops something with a real vendor price", vendItem ~= nil)
AuxPrices = { [vendItem .. ":0"] = 1 }
OctoKillValue_ResetAux()
OctoKillValueDB.vendor = true
ChatLog = {}
okv("id 3")
local vendLine = chatHas("item:" .. vendItem .. " [^:]*%(vendor%): (.*)$")
check("vendor floor raises a 1c aux value to the sell price, tagged (vendor)",
  vendLine ~= nil and math.abs(copper(string.match(vendLine, ": (.*)$")) - vendQty * OKV_SELL[vendItem]) <= 1)

-- ---- AH cut applies to auction values only
AuxPrices = { ["755:0"] = 1000 }
OctoKillValue_ResetAux()
OctoKillValueDB.vendor = false
OctoKillValueDB.cut = 10
ChatLog = {}
okv("id 6")
check("10% cut: total = coins + qty*900", math.abs(total() - (gold6 + linenQty * 900)) <= 1)
OctoKillValueDB.cut = 0

-- ---- bind-on-pickup never takes an auction price; quest items are a known 0
local _, dropsOny = parseData(10184)
check("Onyxia head 18422 is bind-on-pickup in data", OKV_BIND[18422] == 1)
AuxPrices = { ["18422:0"] = 100000000 } -- 10,000g "auction value" for a BoP head
AuxDays["18422:0"] = { {}, {}, {} }
OctoKillValue_ResetAux()
OctoKillValueDB.vendor = false
ChatLog = {}
okv("id 10184")
check("BoP item ignores its aux price (total = coins only)", math.abs(total() - 990593) <= 1)
local questItem
for id, b in pairs(OKV_BIND) do if b == 4 and dropsOny[id] then questItem = id end end
if not questItem then for id, b in pairs(OKV_BIND) do if b == 4 then questItem = id; break end end end
check("quest items exist in bind data", questItem ~= nil)

-- ---- random-suffix aggregation: base id has no history, suffix keys do
AuxPrices = { ["755:0"] = nil, ["755:12"] = 300, ["755:13"] = 100, ["755:14"] = 200 }
AuxHistoryKeys = { ["755:12"] = "x", ["755:13"] = "x", ["755:14"] = "x", ["1:0"] = "x" }
OctoKillValue_ResetAux()
ChatLog = {}
okv("id 6")
check("suffix variants priced by their median (200)", math.abs(total() - (gold6 + linenQty * 200)) <= 1)
AuxHistoryKeys = {}

-- ---- disenchant value (optional) beats vendor when higher
AuxPrices = {}
OctoKillValue_ResetAux()
OctoKillValueDB.vendor = true
OctoKillValueDB.de = true
local deItem
local _, _, refsOny = parseData(10184)
for ref in pairs(refsOny) do
  for id in string.gmatch(OKV_REF[ref], "(%d+):") do
    if OKV_DE[tonumber(id)] then deItem = tonumber(id); break end
  end
  if deItem then break end
end
check("Onyxia drops disenchantable gear with baked quality/level/slot", deItem ~= nil and OKV_DE[deItem] ~= nil)
AuxDE[deItem] = 5000000 -- 500g of shards
ChatLog = {}
okv("id 10184")
check("disenchant estimate counted with (DE) tag", chatHas("item:" .. deItem .. " [^:]*%(DE%)") ~= nil)
OctoKillValueDB.de = false
AuxDE = {}
OctoKillValue_ResetAux()
ChatLog = {}
okv("id 10184")
check("disenchant off by default -> no (DE) line", chatHas("%(DE%)") == nil)

-- ---- tooltip: mouseover event adds lines once
AuxPrices = { ["755:0"] = 100 }
OctoKillValue_ResetAux()
OctoKillValueDB.vendor = false
hover("mouseover", KOBOLD, "Kobold Vermin")
check("tooltip gets Kill value line", findLine("^Kill value") ~= nil)
check("tooltip gets coins detail line", findLine("coins | 3c") ~= nil)
check("tooltip re-shown to resize", GameTooltip.shown == 1)
local n1 = #GameTooltip.lines
FireEvent("UPDATE_MOUSEOVER_UNIT")
check("second event on the same tooltip does not duplicate", #GameTooltip.lines == n1)
-- a unit frame rebuilds the tooltip via SetUnit WITHOUT an OnHide in between
Units.target = Units.mouseover
GameTooltip:SetUnit("target")
check("SetUnit rebuild gets the line again (no stale guard)", findLine("^Kill value") ~= nil)
FireEvent("UPDATE_MOUSEOVER_UNIT")
check("mouseover event after SetUnit does not duplicate",
  (function() local n = 0; for _, l in ipairs(GameTooltip.lines) do if string.find(l, "^Kill value") then n = n + 1 end end; return n == 1 end)())

-- Onyxia through the SetUnit path
GameTooltip:Hide()
Units.target = { guid = ONYXIA, name = "Onyxia" }
GameTooltip:SetUnit("target")
local kv = findLine("^Kill value")
check("SetUnit hook adds line for Onyxia", kv ~= nil)
check("Onyxia total shows at least her 99g of coins", kv and tonumber(string.match(kv, "(%d+)g")) >= 99)

-- ignored units
hover("mouseover", "0x000000003B9E9C90", "Someone", { player = true })
check("players get no line", findLine("^Kill value") == nil)
hover("mouseover", "0xF130FFFFFF000001", "Unknown mob")
check("creature without data gets no line", findLine("^Kill value") == nil)
hover("mouseover", "0xF140000006000001", "Hunter pet")
check("pet guid (F140) gets no line", findLine("^Kill value") == nil)
hover("mouseover", KOBOLD, "Friendly Kobold", { friendly = true })
check("friendly NPC gets no line by default", findLine("^Kill value") == nil)
hover("mouseover", KOBOLD, "Dead friendly Kobold", { friendly = true, dead = true })
check("dead unit still gets the line", findLine("^Kill value") ~= nil)
OctoKillValueDB.friendly = true
hover("mouseover", KOBOLD, "Friendly Kobold", { friendly = true })
check("/okv friendly shows friendly NPCs", findLine("^Kill value") ~= nil)
OctoKillValueDB.friendly = false
hover("mouseover", string.lower(KOBOLD), "lowercase guid")
check("lowercase guid parses", findLine("^Kill value") ~= nil)

-- gather line only with the profession; label follows the data prefix
AuxPrices["15410:0"] = 50000
OctoKillValue_ResetAux()
hover("mouseover", ONYXIA, "Onyxia")
check("no skinning line without Skinning skill", findLine("skinning") == nil)
Skills = { "Skinning" }
FireEvent("SKILL_LINES_CHANGED")
hover("mouseover", ONYXIA, "Onyxia")
local sk = findLine("skinning")
check("skinning line = 3 scales x 5g = 15g", sk ~= nil and string.find(sk, "15g") ~= nil)
-- synthetic mining creature
OKV_MOB[999999] = "0|||M:15410:1"
Skills = { "Skinning" }
FireEvent("SKILL_LINES_CHANGED")
hover("mouseover", "0xF1300F423F000001", "Rock thing") -- 0x0F423F = 999999
check("mining loot hidden for a skinner", findLine("mining") == nil)
Skills = { "Mining" }
FireEvent("SKILL_LINES_CHANGED")
hover("mouseover", "0xF1300F423F000001", "Rock thing")
check("mining loot shown for a miner", findLine("mining") ~= nil)

-- compute cache: config change invalidates, time expiry too
AuxPrices["755:0"] = 100
OctoKillValue_ResetAux()
hover("mouseover", KOBOLD, "Kobold Vermin")
local before = findLine("^Kill value")
AuxPrices["755:0"] = 10000
hover("mouseover", KOBOLD, "Kobold Vermin")
check("result cached within 30s", findLine("^Kill value") == before)
AdvanceTime(31)
hover("mouseover", KOBOLD, "Kobold Vermin")
check("cache expires after 30s", findLine("^Kill value") ~= before)

-- toggle off hides the line
okv("toggle")
hover("mouseover", KOBOLD, "Kobold Vermin")
check("/okv toggle disables the tooltip line", findLine("^Kill value") == nil)
okv("toggle")

-- no aux at all: vendor-only tag
AuxLoaded = false
OctoKillValue_ResetAux()
OctoKillValueDB.vendor = true
hover("mouseover", KOBOLD, "Kobold Vermin")
kv = findLine("^Kill value")
check("without aux the line is tagged vendor only", kv ~= nil and string.find(kv, "vendor only") ~= nil)

-- ---- outlier guards: rare split and min-days rule
AuxLoaded = true
OctoKillValue_ResetAux()
OctoKillValueDB.vendor = false
local foror = nil
for id, q in string.gmatch(OKV_REF[30017], "(%d+):([%d%.e%-]+)") do if tonumber(q) < 0.05 then foror = tonumber(id) end end
if not foror then
  for id, q in string.gmatch(select(2, string.match(OKV_MOB[6], "^(%d*)|([^|]*)|")), "(%d+):([%d%.e%-]+)") do
    if tonumber(q) < 0.001 then foror = tonumber(id); break end
  end
end
AuxPrices = { ["755:0"] = 100, [foror .. ":0"] = 1661992960 }
AuxDays = {}
ChatLog = {}
okv("id 6")
check("single-day 166kg price is ignored (total stays " .. total() .. "c)", total() <= 40)
AuxDays[foror .. ":0"] = { {}, {} }
OctoKillValue_ResetAux()
ChatLog = {}
okv("id 6")
check("two observations (one listing across midnight) still ignored", total() <= 40 and chatHas("rare drops") == nil)
AuxDays[foror .. ":0"] = { {}, {}, {} }
OctoKillValue_ResetAux()
ChatLog = {}
okv("id 6")
check("three-day expensive price counts only in the rare line", total() <= 40 and chatHas("rare drops") ~= nil)
hover("mouseover", KOBOLD, "Kobold Vermin")
kv = findLine("^Kill value")
check("tooltip total excludes rare tail", kv ~= nil and string.find(kv, "g") == nil)
check("tooltip shows rare line", findLine("rare drops") ~= nil)
AuxPrices = { ["755:0"] = 100 }
AuxDays = {}
OctoKillValue_ResetAux()
hover("mouseover", KOBOLD, "Kobold Vermin")
check("cheap single-day price still counts", findLine("item:755") ~= nil)

-- /okv guid diagnostic
Units.target = { guid = ONYXIA, name = "Onyxia" }
ChatLog = {}
okv("guid")
check("/okv guid reports entry and data presence", chatHas("creature 10184 %(has data%)") ~= nil)

print(passed .. " passed, " .. failed .. " failed")
if failed > 0 then error("behavior checks failed") end
