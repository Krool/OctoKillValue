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
  local gold, drops, refs, skin = string.match(s, "^(%d*)|([^|]*)|([^|]*)|([^|]*)")
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
local FLESH  = "0xF130000003000001"       -- creature 3 (Flesh Eater: world-drop pools)
local function sellable(id) return not OKV_GREY[id] and OKV_BIND[id] ~= 1 and OKV_BIND[id] ~= 4 end
-- first (ref, mult, item, qty) in a creature's pools whose item is sellable and whose
-- per-kill expected qty satisfies pred
local function poolItem(refs, pred)
  for ref, mult in pairs(refs) do
    for id, q in string.gmatch(OKV_REF[ref], "(%d+):([%d%.e%-]+)") do
      id, q = tonumber(id), tonumber(q)
      if sellable(id) and pred(q * mult) then return ref, mult, id, q end
    end
  end
end
local ONYXIA = "0xF1300027C8000002"       -- creature 10184 = 0x27C8

-- boot
FireEvent("VARIABLES_LOADED")
check("config defaults applied", OctoKillValueDB.enabled == true and OctoKillValueDB.detail == 3
  and OctoKillValueDB.cut == 5 and OctoKillValueDB.mindays == 3)
local okv = SlashCmdList["OCTOKILLVALUE"]
check("slash command registered", type(okv) == "function")
OctoKillValueDB.cut = 0 -- exact arithmetic below; the cut has its own check

-- ---- pure math via /okv id: aux knows only Shiny Red Apple (white, 13.5%), vendor floor off
local gold6, drops6, refs6 = parseData(6)
local appleQty = drops6[4536]
check("Kobold Vermin data: coins and apple qty present", gold6 == 3 and appleQty and appleQty > 0.1)
AuxPrices["4536:0"] = 100
OctoKillValueDB.vendor = false
ChatLog = {}
okv("id 6")
local expected = gold6 + appleQty * 100
check("total = coins + qty*price (" .. total() .. "c vs " .. expected .. ")", math.abs(total() - expected) <= 1)
check("breakdown lists the apple with qty", chatHas("item:4536 13%%") ~= nil)
check("unpriced drops are counted", chatHas("have no known price") ~= nil)

-- ---- reference pool expansion: price one sellable item from one of Flesh Eater's pools
AuxPrices = {}
OctoKillValue_ResetAux()
local gold3, drops3, refs3 = parseData(3)
local refId, refMult, refItem, refQty = poolItem(refs3, function() return true end)
check("Flesh Eater has a pool with a sellable item", refItem ~= nil and not drops3[refItem])
AuxPrices[refItem .. ":0"] = 100000
OctoKillValueDB.rare = 0 -- pool entries are far below 0.1%; count it in the total here
ChatLog = {}
okv("id 3")
OctoKillValueDB.rare = 0.001
expected = gold3 + refMult * refQty * 100000
check("reference pool contributes mult*qty*price (" .. total() .. " vs " .. math.floor(expected + 0.5) .. ")",
  math.abs(total() - expected) <= 1)

-- ---- vendor floor: vendor price above aux value wins; source tag shown
-- Flesh Eater: Wool Cloth (33c vendor) at ~37%
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
AuxPrices = { ["4536:0"] = 1000 }
OctoKillValue_ResetAux()
OctoKillValueDB.vendor = false
OctoKillValueDB.cut = 10
ChatLog = {}
okv("id 6")
check("10% cut: total = coins + qty*900", math.abs(total() - (gold6 + appleQty * 900)) <= 1)
OctoKillValueDB.cut = 0

-- ---- bind-on-pickup never takes an auction price; quest items are a known 0
local _, dropsOny = parseData(10184)
check("Onyxia head 18422 is bind-on-pickup in data", OKV_BIND[18422] == 1)
AuxPrices = { ["18422:0"] = 100000000 } -- 10,000g "auction value" for a BoP head
AuxDays["18422:0"] = { { value = 100000000 }, { value = 100000000 }, { value = 100000000 } }
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
AuxPrices = { ["4536:0"] = nil, ["4536:12"] = 300, ["4536:13"] = 100, ["4536:14"] = 200 }
AuxHistoryKeys = { ["4536:12"] = "x", ["4536:13"] = "x", ["4536:14"] = "x", ["1:0"] = "x" }
OctoKillValue_ResetAux()
ChatLog = {}
okv("id 6")
check("suffix variants priced by their median (200)", math.abs(total() - (gold6 + appleQty * 200)) <= 1)
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
AuxPrices = { ["4536:0"] = 100 }
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
OKV_MOB[999999] = "0|||M:15410:1|10:0:100"
Skills = { "Skinning" }
FireEvent("SKILL_LINES_CHANGED")
hover("mouseover", "0xF1300F423F000001", "Rock thing") -- 0x0F423F = 999999
check("mining loot hidden for a skinner", findLine("mining") == nil)
Skills = { "Mining" }
FireEvent("SKILL_LINES_CHANGED")
hover("mouseover", "0xF1300F423F000001", "Rock thing")
check("mining loot shown for a miner", findLine("mining") ~= nil)

-- compute cache: config change invalidates, time expiry too
AuxPrices["4536:0"] = 100
OctoKillValue_ResetAux()
hover("mouseover", KOBOLD, "Kobold Vermin")
local before = findLine("^Kill value")
AuxPrices["4536:0"] = 10000
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
-- a sellable world-drop below the 0.1% rare threshold (Foror's-like)
local _, _, foror = poolItem(refs3, function(q) return q < 0.001 end)
check("Flesh Eater has a sub-0.1% sellable world drop", foror ~= nil)
AuxPrices = { [foror .. ":0"] = 1661992960 }
AuxDays = {}
ChatLog = {}
okv("id 3")
local base = gold3 + 5
check("single-day 166kg price is ignored (total stays " .. total() .. "c)", total() <= base)
AuxDays[foror .. ":0"] = { { value = 1661992960 }, { value = 1661992960 } }
OctoKillValue_ResetAux()
ChatLog = {}
okv("id 3")
check("two observations (one listing across midnight) still ignored", total() <= base and chatHas("rare drops") == nil)
AuxDays[foror .. ":0"] = { { value = 1661992960 }, { value = 1661992960 }, { value = 1661992960 } }
OctoKillValue_ResetAux()
ChatLog = {}
okv("id 3")
check("three-day expensive price counts only in the rare line", total() <= base and chatHas("rare drops") ~= nil)
hover("mouseover", FLESH, "Flesh Eater")
kv = findLine("^Kill value")
check("tooltip total excludes rare tail", kv ~= nil and string.find(kv, "g") == nil)
check("tooltip shows rare line", findLine("rare drops") ~= nil)
AuxPrices = { ["4536:0"] = 100 }
AuxDays = {}
OctoKillValue_ResetAux()
hover("mouseover", KOBOLD, "Kobold Vermin")
check("cheap single-day price still counts", findLine("item:4536") ~= nil)

-- ---- containers: a clam is worth its contents when that beats its own price
OctoKillValueDB.cut = 0
OctoKillValueDB.vendor = false
check("Small Barnacled Clam has baked contents", OKV_ITEM[5523] ~= nil and string.find(OKV_ITEM[5523], "5498:0%.05") ~= nil)
-- a mob that drops clams: find one
local clamMob, clamQty
for id, s in pairs(OKV_MOB) do
  local q = string.match(s, "^%d*|[^|]*[^%d]5523:([%d%.]+)") or string.match(s, "^%d*|5523:([%d%.]+)")
  if q and type(id) == "number" and id < 999999 then clamMob, clamQty = id, tonumber(q); break end
end
check("some creature drops Small Barnacled Clams", clamMob ~= nil)
AuxPrices = { ["5523:0"] = 10, ["5498:0"] = 20000, ["5503:0"] = 100 } -- clam 10c, pearl 2g, meat 1s
OctoKillValue_ResetAux()
ChatLog = {}
okv("id " .. clamMob)
local clamLine = chatHas("item:5523 [^:]*%(opened%): (.*)$")
-- contents = 1 x 1s + 0.05 x 2g = 1s + 10s = 11s per clam
check("clam priced as contents (11s each) with (opened) tag",
  clamLine ~= nil and math.abs(copper(string.match(clamLine, ": (.*)$")) - clamQty * 1100) <= 1)
AuxPrices["5523:0"] = 50000 -- someone pays 5g for clams: own price wins
OctoKillValue_ResetAux()
ChatLog = {}
okv("id " .. clamMob)
check("clam's own auction price wins when higher", chatHas("item:5523 [^:]*%(opened%)") == nil and chatHas("item:5523") ~= nil)

-- ---- greys never take an auction price (Cat Figurine 999g troll listing)
check("Cat Figurine is grey in data", OKV_GREY[5329] == 1)
AuxPrices = { ["5329:0"] = 9990000 }
AuxDays["5329:0"] = { { value = 9990000 }, { value = 9990000 }, { value = 9990000 } }
OctoKillValue_ResetAux()
OctoKillValueDB.vendor = true
ChatLog = {}
okv("id 13359") -- Frostwolf Bowman: Cat Figurine at 99.7%
local catLine = chatHas("item:5329 [^:]*: (.*)$")
check("grey priced at vendor (15c) despite a 999g aux value",
  catLine ~= nil and string.find(catLine, "%(vendor%)") ~= nil and copper(string.match(catLine, ": (.*)$")) <= 15)

-- ---- lower median of raw observations beats aux's value()
AuxPrices = { ["4536:0"] = 100000 } -- what aux's value() would say
AuxDays["4536:0"] = { { value = 100 }, { value = 100000 } } -- one real, one troll
OctoKillValueDB.vendor = false
OctoKillValue_ResetAux()
ChatLog = {}
okv("id 6")
check("two observations -> the lower one is used", math.abs(total() - (gold6 + appleQty * 100)) <= 1)
AuxDays["4536:0"] = { { value = 100 }, { value = 200 }, { value = 100000 } }
OctoKillValue_ResetAux()
ChatLog = {}
okv("id 6")
check("three observations -> the middle one is used", math.abs(total() - (gold6 + appleQty * 200)) <= 1)
AuxDays = {}

-- ---- level/rank/health parsed from the fifth data segment
ChatLog = {}
okv("id 10184")
check("report shows level, rank and health", chatHas("%[L63 BOSS, 1099230 hp%]") ~= nil)

-- ---- /okv zone: creatures pfQuest places in the current zone, ranked
AuxPrices = { ["4536:0"] = 100 }
OctoKillValue_ResetAux()
OctoKillValueDB.vendor = true
ChatLog = {}
okv("zone 5")
check("zone report names the zone and counts creatures", chatHas("Dun Morogh: top 5 of 2 creatures") ~= nil)
check("zone report lists Kobold Vermin with level", chatHas("Kobold Vermin %(L%d+%)") ~= nil)
check("zone report shows value per 1k hp", chatHas("/1k hp") ~= nil)
check("zone report excludes elites by default", chatHas("Onyxia") == nil)
ZoneName = "Onyxia's Lair"
ChatLog = {}
okv("zone 5 all")
check("zone ... all includes bosses", chatHas("Onyxia %(L63 BOSS%)") ~= nil)
ZoneName = "Nowhere"
ChatLog = {}
okv("zone")
check("unknown zone is reported", chatHas("unknown zone") ~= nil)

-- ---- requirements: login summary, status, missing-guid client
ChatLog = {}
FireEvent("PLAYER_ENTERING_WORLD")
check("login prints a one-line hello when requirements are met", chatHas("loaded%. Hover a creature") ~= nil)
check("login does not spam the status when everything is present", chatHas("creature ids") == nil)
ChatLog = {}
FireEvent("PLAYER_ENTERING_WORLD")
check("login message only once per session", #ChatLog == 0)
ChatLog = {}
okv("status")
check("/okv status lists the four requirements", chatHas("creature ids .*aux prices .*pfQuest .*loot data") ~= nil)
-- a stock 1.12 client: UnitExists returns no guid
local savedPlayer = Units.player
Units.player = { name = "Tester", player = true }
ChatLog = {}
okv("status")
check("missing guid support is called out plainly", chatHas("does not report creature ids") ~= nil)
Units.player = savedPlayer
-- aux missing: status explains vendor-only
AuxLoaded = false
OctoKillValue_ResetAux()
ChatLog = {}
okv("status")
check("missing aux explains vendor-only pricing", chatHas("aux%-addon not found") ~= nil)
AuxLoaded = true
OctoKillValue_ResetAux()

-- ---- settings: config listing, reset, help
OctoKillValueDB.detail = 7
ChatLog = {}
okv("config")
check("/okv config lists detail with its value", chatHas("detail   7") ~= nil)
check("/okv config shows rare as a percent", chatHas("rare     0%.1%%") ~= nil)
okv("reset")
check("/okv reset restores defaults", OctoKillValueDB.detail == 3 and OctoKillValueDB.cut == 5)
ChatLog = {}
okv("help")
check("/okv help lists the zone command", chatHas("/okv zone") ~= nil)
ChatLog = {}
okv("bogus")
check("unknown command points at help", chatHas("unknown command 'bogus'") ~= nil)
OctoKillValueDB.cut = 0
OctoKillValueDB.vendor = false

-- /okv guid diagnostic
Units.target = { guid = ONYXIA, name = "Onyxia" }
ChatLog = {}
okv("guid")
check("/okv guid reports entry and data presence", chatHas("creature 10184 %(has data%)") ~= nil)

print(passed .. " passed, " .. failed .. " failed")
if failed > 0 then error("behavior checks failed") end
