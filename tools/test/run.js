// OctoKillValue test runner.
// 1. Syntax-checks the addon Lua (luaparse, Lua 5.1 grammar - the 1.12
//    client accepts this superset of its Lua 5.0).
// 2. Validates Data.lua (counts, sentinel creatures/items).
// 3. Executes the real addon under a stubbed WoW + aux environment
//    (fengari) and runs the behavior checks in test.lua.
const fs = require("fs");
const path = require("path");
const luaparse = require("luaparse");
const { lua, lauxlib, lualib, to_luastring } = require("fengari");

const root = path.join(__dirname, "..", "..");
const addonFiles = ["Data.lua", "OctoKillValue.lua"];
let failed = false;

// ---- 1. syntax
for (const f of addonFiles) {
  const src = fs.readFileSync(path.join(root, f), "utf8");
  try {
    luaparse.parse(src, { luaVersion: "5.1" });
    console.log("syntax ok: " + f);
  } catch (e) {
    console.log("SYNTAX FAIL: " + f + ": " + e.message);
    failed = true;
  }
}

// ---- 2. data sanity
const data = fs.readFileSync(path.join(root, "Data.lua"), "utf8");
function section(name) {
  const i = data.indexOf(name + "={");
  const j = data.indexOf("\n}\n", i);
  return data.slice(i, j);
}
const mob = section("OKV_MOB"), ref = section("OKV_REF"), sell = section("OKV_SELL");
const bind = section("OKV_BIND"), de = section("OKV_DE"), item = section("OKV_ITEM");
const count = (s) => (s.match(/^\[\d+\]=/gm) || []).length;
console.log(`data: ${count(mob)} creatures, ${count(ref)} reference pools, ${count(sell)} sell prices, ${count(bind)} bound, ${count(de)} disenchantable`);
if (count(mob) < 6000) { console.log("DATA FAIL: creature set suspiciously small"); failed = true; }
if (count(ref) < 500) { console.log("DATA FAIL: reference set suspiciously small"); failed = true; }
if (count(sell) < 7000) { console.log("DATA FAIL: sell-price set suspiciously small"); failed = true; }
if (count(bind) < 2000) { console.log("DATA FAIL: bind set suspiciously small"); failed = true; }
if (count(de) < 5000) { console.log("DATA FAIL: disenchant set suspiciously small"); failed = true; }
// sentinels: Kobold Vermin (6) drops Linen (755) and points at world-drop ref 30017;
// Onyxia (10184) drops her head (18422) at 100% and skins into scales (15410).
const need = [
  [mob, /^\[6\]="\d+\|755:0\.\d+/m, "Kobold Vermin linen drop"],
  [mob, /^\[6\]="[^"]*\|30017:/m, "Kobold Vermin ref 30017"],
  [mob, /^\[10184\]="\d{5,}\|[^"]*18422:1[,|]/m, "Onyxia head 100%"],
  [mob, /^\[10184\]="[^"]*\|15410:3\|63:3:\d+"/m, "Onyxia skinning scales x3 + level/rank/hp"],
  [ref, /^\[30017\]="\d+:/m, "ref pool 30017 present"],
  [sell, /^\[755\]=\d+,/m, "Linen Cloth sell price"],
  [bind, /^\[18422\]=1,/m, "Head of Onyxia bind-on-pickup"],
  [de, /^\[16846\]="4:66:INVTYPE_HEAD",/m, "Giantstalker's Helmet disenchant info"],
  [item, /^\[5523\]="5503:1,5498:0\.05",/m, "Small Barnacled Clam contents"],
  [item, /^\[7973\]="7974:1,/m, "Big-mouth Clam contents"],
];
if ((item.match(/^\[\d+\]=/gm) || []).length < 20) { console.log("DATA FAIL: container set suspiciously small"); failed = true; }
for (const [s, re, label] of need) {
  if (!re.test(s)) { console.log("DATA FAIL: sentinel missing: " + label); failed = true; }
}
if (failed) { console.log("ABORTING before behavior tests"); process.exit(1); }

// ---- 3. behavior under fengari
const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function runLua(label, src) {
  const status = lauxlib.luaL_loadbuffer(L, to_luastring(src), src.length, to_luastring("@" + label));
  if (status !== lua.LUA_OK || lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
    console.log("LUA FAIL in " + label + ": " + lua.lua_tojsstring(L, -1));
    process.exit(1);
  }
}

let output = [];
lua.lua_register(L, to_luastring("print"), (L) => {
  const n = lua.lua_gettop(L);
  const parts = [];
  for (let i = 1; i <= n; i++) parts.push(lua.lua_tojsstring(L, i) || lauxlib.luaL_tolstring(L, i));
  output.push(parts.join("\t"));
  return 0;
});

runLua("stubs.lua", fs.readFileSync(path.join(__dirname, "stubs.lua"), "utf8"));
for (const f of addonFiles) runLua(f, fs.readFileSync(path.join(root, f), "utf8"));

const testSrc = fs.readFileSync(path.join(__dirname, "test.lua"), "utf8");
const status = lauxlib.luaL_loadbuffer(L, to_luastring(testSrc), testSrc.length, to_luastring("@test.lua"));
const ok = status === lua.LUA_OK && lua.lua_pcall(L, 0, 0, 0) === lua.LUA_OK;
console.log(output.join("\n"));
if (!ok) {
  console.log("BEHAVIOR TESTS FAILED: " + lua.lua_tojsstring(L, -1));
  process.exit(1);
}
console.log("ALL TESTS PASSED");
