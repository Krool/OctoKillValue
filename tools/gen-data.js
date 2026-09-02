// OctoKillValue data generator.
//
// Reads the Turtle WoW 1.18.1 preservation world database
// (github.com/Penqle/tortoise-wow, sql/base/tw_world_*.sql) and bakes
// Data.lua: per-creature expected coin drop, expected item quantities
// (drop chance x average stack, fully resolved through group and
// reference loot semantics) and vendor sell prices for every item that
// can drop. The addon multiplies these by aux-addon's live auction values.
//
// Usage:  node tools\gen-data.js          (downloads the SQL into
//         tools\sqlcache on first run; delete the cache to refresh)
//
// Loot semantics follow vmangos/cmangos LootMgr:
//  * groupid 0 rows roll independently at ChanceOrQuestChance %.
//  * rows sharing a groupid > 0 yield at most ONE item: explicit-chance
//    rows are tried in turn (P = chance/100), the leftover probability
//    is split evenly among the zero-chance rows of the group.
//  * mincountOrRef < 0 references reference_loot_template entry
//    -mincountOrRef, processed maxcount times when its row is hit.
//  * negative chance = quest-conditional drop; worthless to sell, skipped.
//  * item count is uniform in [mincountOrRef, maxcount] -> avg (min+max)/2.
"use strict";
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const CACHE = path.join(__dirname, "sqlcache");
const OUT = path.join(__dirname, "..", "Data.lua");
const RAW = "https://raw.githubusercontent.com/Penqle/tortoise-wow/main/sql/base/tw_world_";
const TABLES = ["creature_template", "creature_loot_template", "reference_loot_template",
  "skinning_loot_template", "item_template"];

fs.mkdirSync(CACHE, { recursive: true });
for (const t of TABLES) {
  const f = path.join(CACHE, t + ".sql");
  if (!fs.existsSync(f)) {
    console.log("downloading " + t);
    execFileSync("curl", ["-sL", "-o", f, RAW + t + ".sql"], { stdio: "inherit" });
  }
}

// ---- SQL parsing -----------------------------------------------------------
function columns(sql, table) {
  const m = sql.match(new RegExp("CREATE TABLE `" + table + "` \\(([\\s\\S]*?)\\n\\)"));
  if (!m) throw new Error("no CREATE TABLE for " + table);
  const cols = [];
  for (const line of m[1].split("\n")) {
    const c = line.match(/^\s*`([^`]+)`/);
    if (c) cols.push(c[1]);
  }
  return cols;
}

// Yields one row (array of raw strings / numbers) per VALUES tuple.
function* rows(sql, table) {
  const marker = "INSERT INTO `" + table + "` VALUES ";
  let pos = 0;
  while ((pos = sql.indexOf(marker, pos)) !== -1) {
    pos += marker.length;
    // parse tuples until ';'
    for (;;) {
      while (sql[pos] === "," || sql[pos] === " " || sql[pos] === "\n") pos++;
      if (sql[pos] === ";") { pos++; break; }
      if (sql[pos] !== "(") throw new Error("parse error at " + pos + " in " + table);
      pos++;
      const row = [];
      let cur = "";
      for (;;) {
        const ch = sql[pos];
        if (ch === "'") {
          pos++;
          let s = "";
          for (;;) {
            const c = sql[pos];
            if (c === "\\") { s += sql[pos + 1]; pos += 2; continue; }
            if (c === "'") { if (sql[pos + 1] === "'") { s += "'"; pos += 2; continue; } pos++; break; }
            s += c; pos++;
          }
          cur = s;
        } else if (ch === "," || ch === ")") {
          row.push(cur);
          cur = "";
          pos++;
          if (ch === ")") break;
        } else {
          cur += ch; pos++;
        }
      }
      yield row;
    }
  }
}

function load(table) {
  const sql = fs.readFileSync(path.join(CACHE, table + ".sql"), "utf8");
  const cols = columns(sql, table);
  const idx = {};
  cols.forEach((c, i) => { idx[c] = i; });
  return { sql, idx };
}

// ---- loot templates --------------------------------------------------------
function loadLoot(table) {
  const { sql, idx } = load(table);
  const tpl = new Map(); // entry -> [{item, chance, group, minOrRef, max}]
  for (const r of rows(sql, table)) {
    const e = +r[idx.entry];
    const row = {
      item: +r[idx.item], chance: +r[idx.ChanceOrQuestChance], group: +r[idx.groupid],
      minOrRef: +r[idx.mincountOrRef], max: +r[idx.maxcount],
    };
    if (!tpl.has(e)) tpl.set(e, []);
    tpl.get(e).push(row);
  }
  return tpl;
}

const creatureLoot = loadLoot("creature_loot_template");
const refLoot = loadLoot("reference_loot_template");
const skinLoot = loadLoot("skinning_loot_template");
console.log("loot templates: creature", creatureLoot.size, "reference", refLoot.size, "skinning", skinLoot.size);

// Expected quantity per item for one processing of a template.
// Returns Map(item -> expected count) plus Map(ref -> expected times) when
// flattenRefs is false (creature templates keep refs as pointers so the
// shared world-drop pools are stored once).
function expand(entries, flattenRefs, depth) {
  const items = new Map();
  const refs = new Map();
  const add = (map, k, v) => map.set(k, (map.get(k) || 0) + v);
  const hit = (row, p) => {
    if (p <= 0) return;
    if (row.minOrRef < 0) {
      const ref = -row.minOrRef;
      const times = Math.max(1, row.max);
      if (flattenRefs) {
        const sub = refLoot.get(ref);
        if (!sub || depth > 8) return;
        const r = expand(sub, true, depth + 1);
        for (const [it, q] of r.items) add(items, it, p * times * q);
      } else {
        add(refs, ref, p * times);
      }
    } else {
      const avg = (row.minOrRef + row.max) / 2;
      add(items, row.item, p * avg);
    }
  };
  const groups = new Map();
  for (const row of entries) {
    if (row.chance < 0) continue; // quest-conditional drop
    if (row.group === 0) {
      if (row.chance === 0) continue; // invalid per LootMgr
      hit(row, Math.min(row.chance, 100) / 100);
    } else {
      if (!groups.has(row.group)) groups.set(row.group, []);
      groups.get(row.group).push(row);
    }
  }
  for (const g of groups.values()) {
    let used = 0;
    const equal = [];
    for (const row of g) {
      if (row.chance > 0) {
        const p = Math.min(row.chance / 100, Math.max(0, 1 - used));
        used += p;
        hit(row, p);
      } else equal.push(row);
    }
    if (equal.length && used < 1) {
      const p = (1 - used) / equal.length;
      for (const row of equal) hit(row, p);
    }
  }
  return { items, refs };
}

// ---- creatures -------------------------------------------------------------
const ct = load("creature_template");
const mobs = new Map(); // entry -> {gold, lootId, skinId}
for (const r of rows(ct.sql, "creature_template")) {
  const entry = +r[ct.idx.entry];
  mobs.set(entry, {
    gold: (+r[ct.idx.gold_min] + +r[ct.idx.gold_max]) / 2,
    lootId: +r[ct.idx.loot_id],
    skinId: +r[ct.idx.skinning_loot_id],
  });
}
console.log("creatures:", mobs.size);

// ---- assemble --------------------------------------------------------------
function fmt(n) {
  // compact float: up to 6 significant digits, no trailing zeros
  if (n >= 1) return String(Math.round(n * 10000) / 10000);
  return n.toPrecision(4).replace(/\.?0+$/, "").replace(/e-(\d)$/, "e-0$1");
}
function encodeItems(map, min) {
  const parts = [];
  for (const [it, q] of [...map].sort((a, b) => b[1] - a[1])) {
    if (q >= min) parts.push(it + ":" + fmt(q));
  }
  return parts.join(",");
}
const MIN_Q = 1e-6;

const usedItems = new Set();
const usedRefs = new Set();
const mobLines = [];
let mobsWithData = 0;
for (const [entry, m] of [...mobs].sort((a, b) => a[0] - b[0])) {
  let drops = "", refs = "", skin = "";
  if (m.lootId && creatureLoot.has(m.lootId)) {
    const ex = expand(creatureLoot.get(m.lootId), false, 0);
    drops = encodeItems(ex.items, MIN_Q);
    for (const it of ex.items.keys()) usedItems.add(it);
    const rp = [];
    for (const [ref, t] of [...ex.refs].sort((a, b) => b[1] - a[1])) {
      if (t >= MIN_Q && refLoot.has(ref)) { rp.push(ref + ":" + fmt(t)); usedRefs.add(ref); }
    }
    refs = rp.join(",");
  }
  if (m.skinId && skinLoot.has(m.skinId)) {
    const ex = expand(skinLoot.get(m.skinId), true, 0);
    skin = encodeItems(ex.items, MIN_Q);
    for (const it of ex.items.keys()) usedItems.add(it);
  }
  const gold = Math.round(m.gold);
  if (!gold && !drops && !refs && !skin) continue;
  mobsWithData++;
  mobLines.push("[" + entry + "]=\"" + gold + "|" + drops + "|" + refs + "|" + skin + "\",");
}

const refLines = [];
for (const ref of [...usedRefs].sort((a, b) => a - b)) {
  const ex = expand(refLoot.get(ref), true, 0);
  for (const it of ex.items.keys()) usedItems.add(it);
  refLines.push("[" + ref + "]=\"" + encodeItems(ex.items, MIN_Q) + "\",");
}

const it = load("item_template");
const sellLines = [];
let sellCount = 0;
for (const r of rows(it.sql, "item_template")) {
  const id = +r[it.idx.entry];
  if (!usedItems.has(id)) continue;
  const sell = +r[it.idx.sell_price];
  if (!sell) continue;
  sellLines.push("[" + id + "]=" + sell + ",");
  sellCount++;
}

const header = [
  "-- OctoKillValue: GENERATED by tools/gen-data.js - do not edit by hand.",
  "-- Source: Turtle WoW 1.18.1 preservation world db (github.com/Penqle/tortoise-wow).",
  "-- OKV_MOB[creatureEntry] = \"avgCopper|item:expQty,...|refId:expTimes,...|skinItem:expQty,...\"",
  "-- OKV_REF[refId]         = \"item:expQty,...\"   (reference_loot_template, fully flattened)",
  "-- OKV_SELL[itemId]       = vendor sell price in copper (only items that can drop)",
  "-- expQty = drop probability x average stack size, per kill.",
  "-- Generated " + new Date().toISOString().slice(0, 10) + ": " + mobsWithData + " creatures, " +
    refLines.length + " reference pools, " + sellCount + " sell prices.",
  "",
];
const out = header.join("\n") +
  "OKV_MOB={\n" + mobLines.join("\n") + "\n}\n" +
  "OKV_REF={\n" + refLines.join("\n") + "\n}\n" +
  "OKV_SELL={\n" + sellLines.join("\n") + "\n}\n";
fs.writeFileSync(OUT, out);
console.log("wrote " + OUT + ": " + mobsWithData + " creatures, " + refLines.length + " refs, " +
  sellCount + " sell prices, " + (out.length / 1024 / 1024).toFixed(2) + " MB");
