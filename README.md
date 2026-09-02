# OctoKillValue

Expected gold per kill on creature tooltips, for WoW 1.12 (Turtle / OctoWoW).

    Kill value            12s 40c
      coins                   3s
      Wool Cloth 37%       6s 20c
      Small Lustrous Pearl 2%  2s 10c
      skinning            +1s 80c

`value = average coin drop + sum(drop chance x average stack x item price)`

* **Drop tables** are baked into `Data.lua` from the Turtle WoW 1.18.1
  preservation database (github.com/Penqle/tortoise-wow): coin ranges,
  every loot row with its min/max stack, group and reference-loot
  semantics resolved the way the server rolls them.
* **Prices** are the best of three sources per item:
  * [aux-addon](https://github.com/shirsig/aux-addon)'s auction history
    (the same "Value" it shows on item tooltips) minus the AH cut. Never
    used for bind-on-pickup items. Random-suffix gear ("of the Bear") is
    priced by the median of the suffix variants aux has seen.
  * aux's disenchant estimate (off by default, `/okv de`), minus the cut.
  * the vendor sell price. Without aux this is all you get and the line
    says so. Quest items are a known 0.
  * for containers (clams, lockboxes, gem bags): the expected value of
    the contents when opened, if that beats the container's own price.
    Nested containers resolve three levels deep.
* **Skinning** value is shown as a separate line when the character has the
  skill (it is not part of the kill total). Data marks herb and ore
  "skinning" tables too, but Turtle's database has none.
* **Friendly NPCs** show nothing unless `/okv friendly` is on. Corpses do.

## Install

Copy the `OctoKillValue` folder into `Interface\AddOns`. Optional but
recommended: aux-addon (prices), pfQuest (item names for uncached items).

## Commands

| command | effect |
|---|---|
| `/okv` or `/okv target` | print the breakdown for the current target |
| `/okv id <creatureId>` | breakdown for any creature entry |
| `/okv toggle` | tooltip line on/off |
| `/okv detail <n>` | number of top-contributor lines under the total (default 3) |
| `/okv price value\|today` | aux source: weighted median (default) or today's min buyout |
| `/okv guid` | print the target's raw guid, parsed creature id and whether data exists (use this first if no line ever appears) |
| `/okv cut <pct>` | auction house cut taken off AH and disenchant values (default 5) |
| `/okv de` | consider aux's disenchant estimate (default off) |
| `/okv friendly` | show the line on friendly NPCs too (default off) |
| `/okv skin` | skinning line on/off |
| `/okv vendor` | vendor price fallback/floor on/off |
| `/okv rare <pct>` | drops below this chance are listed as "rare drops", outside the total (default 0.1) |
| `/okv mindays <n>` | aux prices above 50g must have been seen on n days (default 3) |

## Why the two guards

Auction history contains lone absurd listings (one 166,000g buyout seen
once). Multiplied through a 0.02% world-drop pool that every mob shares,
one such record adds gold to every creature in the game. So prices above
50g need at least three daily observations (one listing can straddle a midnight push and count twice), and the sub-0.1% tail is shown
on its own line where a bad price is visible instead of hidden in the
total.

## Caveats

* Data is Turtle 1.18.1. OctoWoW-only creatures and any loot rebalances
  are not in it; those mobs show no line.
* Quest-conditional drops (negative chance in the loot table) are skipped.
* Class/race-conditioned loot rows count at full chance.
* Group loot rows are treated as "pick one per group"; multi-roll bosses
  are modelled exactly as the loot templates specify.
* Results are cached for 30 seconds per creature; config commands flush it.

## Regenerating the data

    node tools\gen-data.js

Downloads the five SQL tables into `tools\sqlcache` on first run and
rewrites `Data.lua`. Delete the cache to pull fresh copies.

## Tests

    cd tools\test
    npm install
    npm test

Syntax-checks the Lua, validates `Data.lua` sentinels, then runs the real
addon under fengari with a stubbed WoW + aux environment (47 behavior
checks). Runs on every push via GitHub Actions.

## License

MIT
