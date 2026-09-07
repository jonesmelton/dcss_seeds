# seed_corpus

Turns the s-expression records emitted by
`scripts/seed_dump_sexp.lua` into a queryable SQLite corpus, so
set-containment questions ("seeds with Wyrmbane and 3+ potions of experience on
D:1") are indexed lookups rather than scans.

## Layout

- `lib/corpus/` — the `seed_corpus` library
  - `record.ml` — the parsed catalog record and its entries
  - `reader.ml` — `#SEED#` line → `Record.t`
  - `db.ml` — the SQLite writer
  - `cli.ml` — the `ingest` command
- `bin/ingest.ml` — the `ingest` executable
- `test/` — inline expect tests
- `schema.sql` — the corpus schema

Commands live in `README.md` and `AGENTS.md`; the layering and the
Dream/Core/storage decision live in `docs/architecture.md`.

## Ingesting

`ingest` reads filtered `#SEED#` lines on stdin. Everything crawl writes that is
not so prefixed is noise and must be filtered out before it reaches the reader:

```sh
cd crawl-ref/source
util/fake_pty ./crawl -script seed_dump_sexp.lua -seed 5000 -count 500 -depth D:5 2>&1 \
  | grep '^#SEED#' \
  | ingest -db corpus.db
```

Counts are reported at exit: levels ingested, entries written, lines rejected.

Re-ingesting a `(seed, version, level)` replaces it rather than duplicating, so
a rerun after an interrupted batch is safe. Output is deterministic for a given
`(seed, version, depth)`, which makes ingest-twice-and-diff a valid idempotency
check.

## Fill depth is part of a seed's identity

Every seed was extracted to some depth, and until deep generation existed that
depth was the same for all of them — so completeness could be inferred from the
level list and nothing had to record it. Once one seed stops at `D:8` while its
neighbour reaches `Swamp:4`, that inference breaks **silently**: "this seed has
no Wyrmbane" and "this seed was not searched deep enough to know" become
indistinguishable.

`seed_fills` records it, one row per `(seed, version)`, holding a `Depth.t`
(reach order, not a level name) so cohort comparison is an integer test. It is
**derived from the levels a seed holds**, not carried on the wire — which is
what makes it backfillable: an existing corpus is evidence of its own fill
depth. `tools/corpus-reindex` backfills it, and `Db.write_batch` recomputes it
from `seed_levels` after each batch, because a seed's levels can split across
batches and only the stored list is authoritative.

### Why a cohort, not a partition

Deep generation is a **strict prefix extension** of shallow. Verified row-for-row
over all 14 comparable columns: a deep seed's `Temple`/`D:1`–`D:8` rows are
byte-identical to a shallow fill of the same seed, and the Temple altar bitmasks
agree. So a deep seed is a *valid member* of every shallower cohort rather than
something to quarantine out of one.

A query names a depth cap; every seed filled at least that deep is eligible, and
is counted only over levels within the cap. That is what keeps deep seeds
contributing to statistics instead of distorting them. The distortion is not
hypothetical — measured over 200 deep seeds against 10,000 shallow ones, **100%
of the deep held an artefact against 86.7% of the shallow**, entirely because the
deep ones were searched further.

The corollary is that a query's cap sets its denominator, and the interface has
to say so: "12 seeds have X" means something different drawn from 200 than from
10,200. A cap deeper than the shallow fill silently shrinks the population to
the deep cohort alone.

Portals never set a fill depth. A portal ranks at its parent's depth, so it
cannot be the deepest thing in a seed, and one with no recorded parent ranks
`unknown` — which taken as a maximum would call every pre-format-2 seed
infinitely deep. See `lib/corpus/fill_depth.mli`.

## Notes on the data

- Seeds are only meaningful relative to a build, so `version` is part of the
  identity of every row.
- **Fill depth is part of it too.** A statistic drawn across seeds filled to
  different depths measures extraction effort as much as dungeon content; scope
  it to a cohort. See above.
- Monster inventories are flattened: a carried item is its own `entries` row
  with `carried_by_id` interning the monster's name. An `entries` row is
  therefore not 1:1 with a catalog record — counting floor items needs
  `where carried_by_id is null`.
- `cost` is present only on shop items; its presence is how a shop item is told
  from a floor item.
- Booleans are `integer` 0/1 (`strict` mode has no boolean type, and the
  `entries_search_artefact` partial index is defined on `artefact = 1`).
- `entries.id` is an alias for the rowid, so it costs no extra storage. It
  exists because `entry_spells` and `entry_props` need something to reference:
  `(seed, version, level, name)` is not unique, since a level can hold two of
  the same item.
- Both child tables carry their own foreign key to `seed_levels` rather than
  relying on a cascade through `entries`, so re-ingesting a level cleans them up
  with no extra delete logic. That cascade is inert without
  `pragma foreign_keys = on` — verified: with it off, a property row outlives
  its parent level.
- `entry_props.value` is crawl's raw integer, not its display spelling. `rF+`
  and `rF++` are 1 and 2; `rElec` is 1. Crawl chooses between a bare name, a
  repeated sign and a signed number using `artp_data`'s `value_types`, which the
  lua bindings do not expose, so `entries.name` is the only place its own
  rendering survives.
- **`entry_spells` holds randart books only.** A parchment's single spell is its
  own `sub_type` minus the prefix, and a named book's set is fixed by the build
  and lives in `book_spells` once per version; together they were 93% of the
  table on a 10k-seed 0.34.1 corpus. So `entry_spells` is not the list of spells in a seed — `Db.seed_levels`
  reunites all three sources, and anything reading the table directly sees only
  the randart books. Crawl's `artefact` flag is what separates the generated
  books from the designed ones. See `lib/corpus/book.mli`.
- **A `book_spells` conflict is an error, not a merge.** A released version is
  one build, so a title's spell set cannot change within it; ingest rejects a
  record that disagrees with the recorded set rather than letting one seed's
  book stand for every seed's. This is one of the places the corpus depends on
  trunk being out of scope.
- `ego` is the enchantment's identity where `branded` is only its existence, and
  it is the wider of the two: `branded` is weapon/armour-only, while `ego` also
  covers jewellery. A ring of protection is `ego = 'AC'`, `branded = 0`.
- `seed_levels.temple_altars` is a 22-bit mask over crawl's temple god pool, set
  only on a Temple level. Those gods' altar rows are **not in `entries`** — they
  were 64% of every altar row — so counting altar rows undercounts, and a
  feature search for a pool god has to consult the mask too. The four
  vault-placed gods (Lugonu, Beogh, Jiyva, Ignis) and `altar_ecumenical` are
  outside the pool and keep ordinary rows. See `lib/corpus/temple.mli`.
- `seed_levels.gold` is **floor gold and a lower bound**: the summed size of the
  gold piles on the level, which crawl's own item filter drops before the wire,
  so it counts nothing a monster carries and nothing Gozag makes. It is not
  "gold available on this floor", and anything displaying it says "floor gold"
  for that reason. Zero is a real answer — a Temple has none — and is distinct
  from the null a level ingested before format 4 carries. The piles are
  deliberately not rows: neither a pile's position nor its individual size is a
  fact a reader asks for, and they would be 5-10 rows per level to carry one
  integer.
- `entries.toll_note` is a trove's price as crawl renders it, and is the only
  thing distinguishing one trove from another. It sits on the `enter_trove`
  feature row. Note that **no `D:8` corpus has one**: `trove.des` sets
  `default-depth: D:12-`, so a trove cannot generate above D:12 and the column
  is null across a default fill — it is populated only on the deepened subset,
  which on the current corpus is vanishingly small: **5 of 1,299,999 seeds**
  reach `D:9`+ (1.3M, 0.34.1, 2026-09-05), against 10,418 of 100,001 on the
  100k corpus that carried a deliberate 10k deep cohort. The deep block was not
  carried into the 1.3M fill, so anything wanting trove data needs one filled
  again. Only the structured toll would need a crawl
  binding; the rendered string is all `:property()` exposes.
- `seed_levels.parent_level` is the level a portal was entered from, and null
  for everything else. It is what makes a portal depth-rankable; see the depth
  notes in `AGENTS.md` ("Depth is reach order").
- There is **no `text` column**, and **no vault rows**. `text` was a
  byte-for-byte duplicate of `name` on every row; its one job is standing in for
  a feature's missing `name`, which happens in `Reader` before storage. Vaults
  and `runed_clear_door` are dropped by `Reader.drop_entry` — 24% of rows. A
  query written against an older corpus that reads `text` or counts
  `cat = 'vaults'` will not run.

## `name` is not a function of the other columns

`name` is crawl's rendered display string, and it cannot be reconstructed from
`(base_type, sub_type, plus, branded)`. Three separate reasons, measured over
the 100k-seed 0.34.1 corpus:

**Randomized display bases.** Two weapon types render under an alternate name
that `sub_type` does not record:

| `sub_type` | also displays as | rate |
| --- | --- | ---: |
| `mace` | `hammer` | 5,767 / 25,638 (22.5%) |
| `halberd` | `scythe` | 6,568 / 12,745 (51.5%) |

The choice is **per item, not per game** — 830 seeds hold both spellings of
`mace`, and seed 10204 has `+0 mace of protection` and `+0 hammer of
protection` on D:3 together. A per-seed reskin map would therefore be wrong;
the only ground truth is the stored string.

**Brands render as a prefix, not a suffix.** `heavy`, `vampiric`, `spectral`,
`devious` and `antimagic` render before the base (`+1 heavy hand axe`), while
every other brand renders after it (`+1 whip of freezing`). Both have
`branded = 1`, so brand position is not derivable from the columns either.
Naively stripping a leading `+N ` and comparing to `sub_type` counts these as
mismatches: 17.6% of non-artefact weapon rows, of which only 3.3% are true
reskins.

**Pluralized armour slots.** `gloves` and `boots` display as `pair of gloves` /
`pair of boots` (18,310 rows). Purely grammatical, but still not `sub_type`.

The practical consequence: `sub_type` is the search key and `name` is the
display value, and neither substitutes for the other. Deriving `name` at
render time is lossy in ways that produce plausible-looking wrong answers —
exactly one of which (`hammer`) is common enough to look like a bug report.

These losses are **accepted deliberately** rather than treated as
disqualifying. The standard is "close and obvious" — the rendered name
identifies the same thing to a reader — not byte-equality with crawl's string.
`Display_name` renders the canonical base for both reskin pairs, and the
resulting divergence is 0.11% of derived item rows, all of it reskins (100k,
0.34.1, D:8, 2026-08-28).

Brand position and the `pair of` slots are *not* losses at all: both are
derivable and `Display_name` derives them. The claim above that they are not is
a statement about naive stripping, not about a table-driven renderer.

`name` still exists on the rows whose spelling the other columns do not fix:
`entries.name_id` is null exactly where `Display_name.of_entry` answers
`Derived`, and set for the irreducible tail — artefacts, monsters, unrecognised
feats. That is 92% of rows storing no name (400 seeds, 0.34.1, D:8,
2026-08-28).

## Item exclusion groups

Some items are drawn once per game from a mutually exclusive group: a seed gets
exactly one member, never two. Measured over 100k seeds on 0.34.1 across
D:1–D:8 + Temple, no seed holds two members of any group — the per-seed count
of group members is only ever 0 or 1.

| Group | Members | Seeds with one |
| --- | --- | --- |
| wand A | charming / paralysis | 55,764 |
| wand B | iceblast / roots / warping | 57,468 |
| wand C | acid / light / quicksilver | 41,098 |
| scroll | butterflies / summoning | 46,688 |
| evoker A | condenser vane / tin of tremorstones | 9,197 |
| evoker B | Gell's gravitambourine / phial of floods | 8,937 |
| evoker C | box of beasts / sack of spiders | 8,797 |

The pick is uniform within a group: the three-way wand split runs 32.6 / 32.4 /
34.9%. Totals fall well short of 100k because a seed can generate no member of
a group in the first eight levels — absence is not evidence of exclusion, only
co-occurrence is.

**There are no potion or jewellery exclusions.** Every potion-potion pair sits
at lift 1.000–1.001 (textbook independence). The ~50k cluster of ambrosia,
berserk rage, resistance, cancellation, magic and invisibility looks like paired
structure and is only shared generation rarity. Rings likewise all land at
23–24k, amulets at ~14.6k, with no exclusion among them.

Which member a seed drew is a stable per-seed fact with a uniform split, so it
is a legitimate fingerprint axis for comparison — unlike richness, below. That
is what `lib/corpus/exclusion.ml` reports, and the seed page prints above its
floors; see *The exclusive draws* in `architecture.md`.

Across all seven groups there are **2,938 distinct state vectors** out of 3,888
possible — the groups are independent, so the space is near-saturated rather
than collapsed. That also makes this a comparison feature and not a storage
saving: the 318,882 rows involved carry level, position and shop cost, and the
group identity is already derivable from the `sub_type` they store, so encoding
it would add a column beside them rather than replace them. See change 7 in
[`schema-decisions.md`](schema-decisions.md).

## Seed richness is not a seed property

Item richness varies a lot per seed (16–63 distinct item types, mean 33.9,
unimodal), and dungeon.cc has an explicit concept for it — `_num_items_wanted`
returns `9 + random2avg(80, 2)` on a `// rich level!` branch instead of the
usual `3 + roll_dice(3, 9)`. That branch is gated on `absdepth0 > 5` and
`one_chance_in(500 - 5 * absdepth0)`, and the corpus shows it firing on roughly
0.15% of levels, climbing 0.064% → 0.20% from D:1 to D:8.

But the roll is **per level, independent each time** — there is no per-seed
richness parameter. Splitting each seed's distinct item types into shallow
(D:1–4) and deep (D:5–8) halves and correlating them gives **Pearson r =
0.0022**. A seed rich in its first four levels is not rich in its next four.
Total richness is nine independent draws summed, so it has a tidy distribution
that looks like a seed trait and is only the CLT.

This matters when reading co-occurrence: it is a confound that inflates lift
between any two rare items. `potion:experience` ↔ `talisman:fortress` measures
lift 1.70, but bucketing seeds by total item count shows both probabilities
climbing in lockstep (0.025 → 0.198 and 0.013 → 0.132), and the association
disappears once richness is controlled for. No genuine positive dependency
between items survives that control. Any "interesting seed" score built on raw
item counts will mostly rank seeds by total volume; weight by item rarity
(`-log P(item)`, ideally conditioned on the depth window) instead.

All figures above are D:1–D:8 on 0.34.1, so rarity means rarity *in the early
game*: an item common at depth but absent above D:8 reads as ultra-rare here for
the wrong reason.

## Heat: `surprise`, `seed_scores`, `heat_bands`

Three tables back the seed-heat mark on the listing (`lib/corpus/heat.ml`;
design and formula in `docs/heat.md`). All three are keyed by
`(version, cap)`, never by `version` alone — a score is a population
statistic against the cohort filled to at least `cap`, and a `D:8` cohort and
a `Swamp:4` cohort are different populations even within one version. None of
the three is written by a request handler: `recompute_surprise` and `rescore`
are full scans of `entries`, run by `bin/rescore.ml` as an explicit pass after
a fill (see `docs/extraction.md`), in the same posture as
`tools/corpus-reindex`.

- **`surprise`** — the derived tail probability `P(count >= n)` per
  `(version, cap, base_type, sub_type, count)`, over the eligible population
  (seeds filled to at least `cap`, counted only over levels within it). Also
  holds one reserved row per `(version, cap)` for the book term, keyed under
  `Heat.book_surprise_key` — a seed's count of distinct level-≤4 spells,
  fed through the same curve as any other quantity.
- **`seed_scores`** — one row per `(seed, version, cap)`: the computed
  `Heat.score` and its `Heat.Band.t` (stored as an ordinal 0–3, not derived at
  read time, since deriving it needs the cut points and that is a second
  lookup per page for a fact fixed until the next rescore). A seed absent from
  this table for a `(version, cap)` is **unscored, not `Cold`** — either not
  yet rescored since ingest, or ineligible at that cap. Absence is a claim
  about the corpus; `Cold` is a claim about the seed. See the invariant in
  `AGENTS.md`.
- **`heat_bands`** — the four percentile cut points (`min_score` per band) for
  one `(version, cap)`, stored rather than hardcoded because a weight-table
  edit moves every score and a percentile cut holds its meaning where an
  absolute one would silently drift.

The listing scores at `Fill_depth.shallow` (`D:8`) specifically — the widest
cap every seed shown is guaranteed to be at least that deep, so no row on the
page is ever falsely excluded from the cohort. A seed filled deeper than `D:8`
still gets scored at `D:8` for the listing (as well as at its own deeper cap,
for anything that reads at that cap instead), because `D:8` remains a valid
cohort for it — see the fill-depth invariant above.
