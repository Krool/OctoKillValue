-- Behavior checks for OctoKillValue. Runs after stubs.lua, Data.lua and
-- OctoKillValue.lua in the same VM. Each check() must be true.

local passed, failed = 0, 0
local function check(label, cond)
  if cond then passed = passed + 1; print("ok   " .. label)
  else failed = failed + 1; print("FAIL " .. label) end
end
local function strip(s) return (string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")):gsub("|r", "") end
local function lastChat() return strip(ChatLog[#ChatLog] or "") end
local function findLine(pat)
  for _, l in ipairs(GameTooltip.lines) do
    if string.find(strip(l), pat) then return strip(l) end
  end
  return nil
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

-- boot
FireEvent("VARIABLES_LOADED")
check("config defaults applied", OctoKillValueDB.enabled == true and OctoKillValueDB.detail == 3)
local okv = SlashCmdList["OCTOKILLVALUE"]
check("slash command registered", type(okv) == "function")

-- ---- pure math via /okv id, aux knows only Linen Cloth, vendor floor off
local gold6, drops6, refs6 = parseData(6)
local linenQty = drops6[755]
check("Kobold Vermin data: coins and linen qty present", gold6 == 3 and linenQty and linenQty > 0.2)
AuxPrices["755:0"] = 100
OctoKillValueDB.vendor = false
ChatLog = {}
okv("id 6")
local expected = gold6 + linenQty * 100
local line = strip(ChatLog[1])
local gotC = tonumber(string.match(line, "(%d+)c per kill"))
check("total = coins + qty*price (" .. gotC .. "c vs " .. expected .. ")",
  gotC and math.abs(gotC - expected) <= 1)
check("breakdown lists Linen with qty", (function()
  for _, l in ipairs(ChatLog) do if string.find(strip(l), "item:755 30%%") then return true end end
end)())
check("unpriced drops are counted", (function()
  for _, l in ipairs(ChatLog) do if string.find(l, "have no known price") then return true end end
end)())

-- ---- reference pool expansion: price one item from ref 30017 only
AuxPrices = {}
local refMult = refs6[30017]
local refItem, refQty
for id, q in string.gmatch(OKV_REF[30017], "(%d+):([%d%.e%-]+)") do refItem, refQty = tonumber(id), tonumber(q); break end
AuxPrices[refItem .. ":0"] = 100000
OctoKillValueDB.rare = 0 -- the pool entry is far below 0.1%; count it in the total here
ChatLog = {}
okv("id 6")
OctoKillValueDB.rare = 0.001
line = strip(ChatLog[1])
local g, s, c = string.match(line, "(%d+)g (%d+)s (%d+)c per kill")
local got = g and (tonumber(g) * 10000 + tonumber(s) * 100 + tonumber(c)) or tonumber(string.match(line, "(%d+)c per kill"))
expected = gold6 + refMult * refQty * 100000
check("reference pool contributes mult*qty*price (" .. got .. " vs " .. math.floor(expected + 0.5) .. ")",
  math.abs(got - expected) <= 1)

-- ---- vendor floor: vendor price above aux value wins
AuxPrices = { ["755:0"] = 1 }
OctoKillValueDB.vendor = true
ChatLog = {}
okv("id 6")
line = strip(ChatLog[1])
gotC = tonumber(string.match(line, "(%d+)c per kill")) or (function()
  local g2, s2, c2 = string.match(line, "(%d+)g (%d+)s (%d+)c per kill")
  if g2 then return tonumber(g2) * 10000 + tonumber(s2) * 100 + tonumber(c2) end
  local s3, c3 = string.match(line, "(%d+)s (%d+)c per kill")
  return s3 and tonumber(s3) * 100 + tonumber(c3)
end)()
check("vendor floor raises a 1c aux value to sell price (linen sells for " .. OKV_SELL[755] .. "c)",
  gotC and gotC > gold6 + linenQty * OKV_SELL[755] - 1)

-- ---- tooltip: mouseover event adds lines once, hide resets
AuxPrices = { ["755:0"] = 100 }
OctoKillValueDB.vendor = false
Units.mouseover = { guid = "0xF130000006000001", name = "Kobold Vermin" }
GameTooltip.lines = {}; GameTooltip.visible = true; GameTooltip.shown = 0
FireEvent("UPDATE_MOUSEOVER_UNIT")
check("tooltip gets Kill value line", findLine("^Kill value") ~= nil)
check("tooltip gets coins detail line", findLine("coins | 3c") ~= nil)
check("tooltip re-shown to resize", GameTooltip.shown == 1)
local n1 = #GameTooltip.lines
FireEvent("UPDATE_MOUSEOVER_UNIT")
check("same guid does not duplicate lines", #GameTooltip.lines == n1)
GameTooltip:Hide()
GameTooltip.lines = {}; GameTooltip.visible = true
FireEvent("UPDATE_MOUSEOVER_UNIT")
check("after hide the lines are added again", findLine("^Kill value") ~= nil)

-- SetUnit path (unit frames) uses the same guard
GameTooltip:Hide()
Units.target = { guid = "0xF1300027C8000002", name = "Onyxia" } -- 0x27C8 = 10184
GameTooltip:SetUnit("target")
local kv = findLine("^Kill value")
check("SetUnit hook adds line for Onyxia", kv ~= nil)
check("Onyxia total shows at least her 99g of coins", kv and tonumber(string.match(kv, "(%d+)g")) >= 99)
FireEvent("UPDATE_MOUSEOVER_UNIT") -- mouseover still Kobold: different guid, tooltip now Onyxia's
-- players and non-creature guids are ignored
GameTooltip:Hide(); GameTooltip.lines = {}; GameTooltip.visible = true
Units.mouseover = { guid = "0x0000000000000001", name = "Someone", player = true }
FireEvent("UPDATE_MOUSEOVER_UNIT")
check("players get no line", findLine("^Kill value") == nil)
Units.mouseover = { guid = "0xF130FFFFFF000001", name = "Unknown mob" }
FireEvent("UPDATE_MOUSEOVER_UNIT")
check("creature without data gets no line", findLine("^Kill value") == nil)

-- skinning line only with the profession
GameTooltip:Hide(); GameTooltip.lines = {}; GameTooltip.visible = true
AuxPrices["15410:0"] = 50000
Units.mouseover = { guid = "0xF1300027C8000002", name = "Onyxia" }
FireEvent("UPDATE_MOUSEOVER_UNIT")
check("no skinning line without Skinning skill", findLine("skinning") == nil)
Skills = { "Skinning" }
-- HasSkinning caches; re-trigger via a fresh VM state is not possible, so
-- the cache is invalidated through the SKILL_LINES_CHANGED event.
FireEvent("SKILL_LINES_CHANGED")
GameTooltip:Hide(); GameTooltip.lines = {}; GameTooltip.visible = true
FireEvent("UPDATE_MOUSEOVER_UNIT")
local sk = findLine("skinning")
check("skinning line = 3 scales x 5g = 15g", sk ~= nil and string.find(sk, "15g") ~= nil)

-- toggle off hides the line
okv("toggle")
GameTooltip:Hide(); GameTooltip.lines = {}; GameTooltip.visible = true
FireEvent("UPDATE_MOUSEOVER_UNIT")
check("/okv toggle disables the tooltip line", findLine("^Kill value") == nil)
okv("toggle")

-- no aux at all: vendor-only tag
AuxLoaded = false
-- the addon caches the aux lookup; a fresh check is forced by the reset hook
OctoKillValue_ResetAux()
OctoKillValueDB.vendor = true
GameTooltip:Hide(); GameTooltip.lines = {}; GameTooltip.visible = true
Units.mouseover = { guid = "0xF130000006000001", name = "Kobold Vermin" }
FireEvent("UPDATE_MOUSEOVER_UNIT")
kv = findLine("^Kill value")
check("without aux the line is tagged vendor only", kv ~= nil and string.find(kv, "vendor only") ~= nil)

-- ---- outlier guards: rare split and min-days rule
AuxLoaded = true
OctoKillValue_ResetAux()
OctoKillValueDB.vendor = false
-- item 14305 sits in Kobold Vermin's world-drop pool at ~0.02%; a lone
-- 166,000g sighting must not count at all.
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
line = strip(ChatLog[1])
check("single-day 166kg price is ignored (total stays " .. line:match("(%d+c) per kill") .. ")",
  string.find(line, "^Kobold") == nil and tonumber(line:match("(%d+)c per kill")) <= 40)
-- seen on three days -> counts, but lands in the rare line, not the total
AuxDays[foror .. ":0"] = { { value = 1661992960 }, { value = 1661992960 }, { value = 1661992960 } }
ChatLog = {}
okv("id 6")
line = strip(ChatLog[1])
check("three-day expensive price counts only in the rare line",
  tonumber(line:match("(%d+)c per kill")) <= 40 and (function()
    for _, l in ipairs(ChatLog) do if string.find(strip(l), "rare drops") then return true end end
  end)())
GameTooltip:Hide(); GameTooltip.lines = {}; GameTooltip.visible = true
Units.mouseover = { guid = "0xF130000006000001", name = "Kobold Vermin" }
FireEvent("UPDATE_MOUSEOVER_UNIT")
kv = findLine("^Kill value")
check("tooltip total excludes rare tail", kv ~= nil and string.find(kv, "g") == nil)
check("tooltip shows rare line", findLine("rare drops") ~= nil)
-- cheap prices are trusted from one sighting
AuxPrices = { ["755:0"] = 100 }
AuxDays = {}
GameTooltip:Hide(); GameTooltip.lines = {}; GameTooltip.visible = true
FireEvent("UPDATE_MOUSEOVER_UNIT")
check("cheap single-day price still counts", findLine("item:755") ~= nil)

print(passed .. " passed, " .. failed .. " failed")
if failed > 0 then error("behavior checks failed") end
