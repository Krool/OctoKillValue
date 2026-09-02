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
  "skinning_loot_template", "item_loot_template", "item_template"];

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
const itemLoot = loadLoot("item_loot_template"); // openable containers: clams, lockboxes, bags of gems
console.log("loot templates: creature", creatureLoot.size, "reference", refLoot.size, "skinning", skinLoot.size, "item", itemLoot.size);

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
    typeFlags: +r[ct.idx.type_flags],
    lvl: +r[ct.idx.level_max], rank: +r[ct.idx.rank], hp: +r[ct.idx.health_max],
  });
}
console.log("creatures:", mobs.size);

// ---- item classes (for gather-type detection) ------------------------------
// Turtle's creature_template does not carry the HERBLOOT/MININGLOOT type
// flags, so classify a "skinning" template by what it yields:
// trade goods subclass 9 = Herb, 7 = Metal & Stone, 6 = Leather.
const it = load("item_template");
const itemKind = new Map();
for (const r of rows(it.sql, "item_template")) {
  if (+r[it.idx.class] === 7) itemKind.set(+r[it.idx.entry], +r[it.idx.subclass]);
}
function gatherPrefix(items) {
  let herb = 0, ore = 0, other = 0;
  for (const [id, q] of items) {
    const k = itemKind.get(id);
    if (k === 9) herb += q; else if (k === 7) ore += q; else other += q;
  }
  if (herb > ore && herb > other) return "H:";
  if (ore > herb && ore > other) return "M:";
  return "";
}

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
    if (skin) skin = gatherPrefix(ex.items) + skin;
  }
  const gold = Math.round(m.gold);
  if (!gold && !drops && !refs && !skin) continue;
  mobsWithData++;
  mobLines.push("[" + entry + "]=\"" + gold + "|" + drops + "|" + refs + "|" + skin + "|" + m.lvl + ":" + m.rank + ":" + m.hp + "\",");
}

const refLines = [];
for (const ref of [...usedRefs].sort((a, b) => a - b)) {
  const ex = expand(refLoot.get(ref), true, 0);
  for (const it of ex.items.keys()) usedItems.add(it);
  refLines.push("[" + ref + "]=\"" + encodeItems(ex.items, MIN_Q) + "\",");
}

// Containers among the droppable items: expected contents per opening.
// Contents can themselves be containers, so iterate to a fixpoint.
const itemLines = [];
{
  const queue = [...usedItems];
  const seen = new Set();
  while (queue.length) {
    const id = queue.pop();
    if (seen.has(id) || !itemLoot.has(id)) continue;
    seen.add(id);
    const ex = expand(itemLoot.get(id), true, 0);
    const enc = encodeItems(ex.items, MIN_Q);
    if (!enc) continue;
    itemLines.push("[" + id + "]=\"" + enc + "\",");
    for (const it of ex.items.keys()) { if (!usedItems.has(it)) { usedItems.add(it); queue.push(it); } }
  }
  itemLines.sort((a, b) => parseInt(a.slice(1)) - parseInt(b.slice(1)));
}

const sellLines = [], bindLines = [], deLines = [], greyLines = [];
let sellCount = 0;
// inventory_type -> INVTYPE token (what GetItemInfo returns; aux's
// disenchant module keys its slot filter on these)
const INVTYPE = ["", "INVTYPE_HEAD", "INVTYPE_NECK", "INVTYPE_SHOULDER", "INVTYPE_BODY", "INVTYPE_CHEST",
  "INVTYPE_WAIST", "INVTYPE_LEGS", "INVTYPE_FEET", "INVTYPE_WRIST", "INVTYPE_HAND", "INVTYPE_FINGER",
  "INVTYPE_TRINKET", "INVTYPE_WEAPON", "INVTYPE_SHIELD", "INVTYPE_RANGED", "INVTYPE_CLOAK", "INVTYPE_2HWEAPON",
  "INVTYPE_BAG", "INVTYPE_TABARD", "INVTYPE_ROBE", "INVTYPE_WEAPONMAINHAND", "INVTYPE_WEAPONOFFHAND",
  "INVTYPE_HOLDABLE", "INVTYPE_AMMO", "INVTYPE_THROWN", "INVTYPE_RANGEDRIGHT", "INVTYPE_QUIVER", "INVTYPE_RELIC"];
for (const r of rows(it.sql, "item_template")) {
  const id = +r[it.idx.entry];
  if (!usedItems.has(id)) continue;
  const sell = +r[it.idx.sell_price];
  if (sell) { sellLines.push("[" + id + "]=" + sell + ","); sellCount++; }
  // bonding: 1 = bind on pickup (no auction), 4 = quest item (no value at all)
  const bonding = +r[it.idx.bonding];
  if (bonding === 1 || bonding === 4) bindLines.push("[" + id + "]=" + bonding + ",");
  // disenchantable gear (weapon class 2 / armor class 4, uncommon+): quality,
  // item level, slot - so the disenchant estimate works for uncached items
  const cls = +r[it.idx.class], quality = +r[it.idx.quality];
  // poor-quality items have no auction market; any aux "value" for them is a troll listing
  if (quality === 0) greyLines.push("[" + id + "]=1,");
  if ((cls === 2 || cls === 4) && quality >= 2 && quality <= 4) {
    deLines.push("[" + id + "]=\"" + quality + ":" + r[it.idx.item_level] + ":" + (INVTYPE[+r[it.idx.inventory_type]] || "") + "\",");
  }
}

const header = [
  "-- OctoKillValue: GENERATED by tools/gen-data.js - do not edit by hand.",
  "-- Source: Turtle WoW 1.18.1 preservation world db (github.com/Penqle/tortoise-wow).",
  "-- OKV_MOB[creatureEntry] = \"avgCopper|item:expQty,...|refId:expTimes,...|skinItem:expQty,...|level:rank:maxHealth\"",
  "--                          rank: 0 normal, 1 elite, 2 rare elite, 3 boss, 4 rare",
  "-- OKV_REF[refId]         = \"item:expQty,...\"   (reference_loot_template, fully flattened)",
  "-- OKV_SELL[itemId]       = vendor sell price in copper (only items that can drop)",
  "-- OKV_BIND[itemId]       = 1 bind-on-pickup (never on the AH), 4 quest item (no value)",
  "-- OKV_DE[itemId]         = \"quality:itemLevel:INVTYPE\" for disenchantable gear",
  "-- OKV_ITEM[containerId]  = \"item:expQty,...\" expected contents per opening (clams, lockboxes)",
  "-- OKV_GREY[itemId]       = 1 for poor-quality items (vendor price only)",
  "-- skin segment prefix H: / M: = gathered with Herbalism / Mining, not Skinning",
  "-- expQty = drop probability x average stack size, per kill.",
  "-- Generated " + new Date().toISOString().slice(0, 10) + ": " + mobsWithData + " creatures, " +
    refLines.length + " reference pools, " + sellCount + " sell prices, " + bindLines.length + " bound, " + deLines.length + " disenchantable.",
  "",
];
const out = header.join("\n") +
  "OKV_MOB={\n" + mobLines.join("\n") + "\n}\n" +
  "OKV_REF={\n" + refLines.join("\n") + "\n}\n" +
  "OKV_SELL={\n" + sellLines.join("\n") + "\n}\n" +
  "OKV_BIND={\n" + bindLines.join("\n") + "\n}\n" +
  "OKV_DE={\n" + deLines.join("\n") + "\n}\n" +
  "OKV_ITEM={\n" + itemLines.join("\n") + "\n}\n" +
  "OKV_GREY={\n" + greyLines.join("\n") + "\n}\n";
fs.writeFileSync(OUT, out);
console.log("wrote " + OUT + ": " + mobsWithData + " creatures, " + refLines.length + " refs, " +
  sellCount + " sell prices, " + bindLines.length + " bound, " + deLines.length + " disenchantable, " +
  itemLines.length + " containers, " +
  (out.length / 1024 / 1024).toFixed(2) + " MB");
