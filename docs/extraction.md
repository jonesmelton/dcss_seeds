# Extraction: filling the corpus

How seeds get from a crawl build into `corpus.db`, and the things that bite.
Companion to `docs/corpus.md` (the data model) and `README.md` (the JSONL
reporting path).

There are **two dumpers**, and they are not interchangeable:

| script | emits | consumer | scan |
|---|---|---|---|
| `scripts/seed_dump.lua` | JSONL, one object per record | `scripts/render_seed_report.lua` → markdown | its own cell scan |
| `scripts/seed_dump_sexp.lua` | `#SEED#` sexps, one per level | `bin/ingest.exe` → SQLite | its own cell scan, grouped per level |

`tools/explore` drives the **JSONL** one. Nothing drove the sexp one until
`tools/corpus-fill`; the commands in `README.md` invoke crawl by hand.

## The trap: stock explorer returns display strings

`dat/dlua/explorer.lua` is crawl's own seed-catalog library. Its
`catalog_dungeon` returns, per level, a table of category → **array of
formatted strings**:

```
(features ("a snail-covered altar of Cheibriados" "a transporter" ...))
```

`lib/corpus/reader.ml` expects each entry to be a **record** with `kind`,
`name`, `base_type`, `quantity`, `artefact`, nested `items`, and so on — the
shape the fixtures in `test/test_reader.ml` show. Feeding it stock explorer
output rejects every line with `expected a record, got an atom`, silently
ingesting nothing (rejections are counted, not fatal, by design).

This is true on **trunk and 0.34.1 alike** — it is not a version skew. Stock
explorer has always emitted strings for display; the structured extraction is
ours. `seed_dump.lua` already did its own scan (`dgn.items_at`,
`dgn.shop_inventory_at`, `dgn.mons_at`, `dgn.feature_name`) to build records;
`seed_dump_sexp.lua` originally delegated to `explorer.catalog_dungeon` and so
could never produce the format its own reader wanted. It now runs the same
structured scan, grouped per level.

If you ever see a run report `N lines rejected` with `expected a record, got an
atom`, this is what regressed.

## Wire format the reader wants

One line per level, `#SEED#`-prefixed, no whitespace inside:

```
#SEED#((format 2)(version "0.34.1")(seed "1")(level "D:2")(cats (items (RECORD ...))(monsters (RECORD ...))))
```

- Category keys are `features`, `items`, `monsters`, `vaults` (`Record.Cat`).
  A category with no entries is **omitted entirely**.
- Every record carries `kind` and either `name` or `text`. Features carry
  `feat` + `text` and no `name`; `text` stands in, because the schema's `name`
  is not null. That substitution is the *only* use of `text`: after it the two
  are identical on every row (verified across all 15,336,469 rows of the 100k
  corpus), so `text` is not stored.
- Lua conventions: `t`/`nil` for booleans, `nil` also for absent. `(artefact
  nil)` and an omitted `artefact` are indistinguishable — both read as "no".
- A monster's `items` nest one level deep and are flattened by the reader into
  their own `entries` rows with `carried_by` set. Nesting deeper is not
  supported.
- `cost` present ⇒ shop item. It is the only thing distinguishing a shop item
  from a floor item.
- `format` is checked at the parse boundary. Bump `FORMAT` in the lua script and
  `Reader.supported_format` together, or every line is rejected loudly — which
  is the intent.

### Format 2

A portal level carries `(parent_level "D:5")` beside `level`, naming the level
its entrance sat on. It is **required** on portals: a portal without one is
rejected, because the failure is otherwise silent — the level simply becomes
unrankable again.

Entry-scoped additions:

- `x`, `y` on everything with a position (vaults have none).
- `timeout_turns` on a timed portal's entrance feature, from the marker's
  `turns` property. `dgn.marker_at_pos` returns userdata, so `m.dur` **errors**
  and `m:property("turns")` is the only path; it returns a *string*, and most
  features have no marker at all, so the whole lookup sits inside a `pcall`.
- `ego` on items, from `item.ego(true)`. Note this is a *function*, not the
  `ego_type` field — that one returns the literal string `"unknown"` under a
  managed VM. `ego` is wider than `branded`: it covers jewellery, so a ring of
  protection is `(ego "AC")` with `(branded nil)`.
- `spells` on randart books, `artprops` on artefacts. Both are non-scalar and
  are emitted only when non-empty, so neither reader has to tell `()` from nil.
  `artprops` drops the `Brand` key, whose value is a `brand_type` ordinal rather
  than a usable integer — `ego` already carries that fact.
- `type_name` and `native` on monsters.

### Format 3

`shop_type` on an `enter_shop` feature, from `dgn.shop_type_at` — a binding this
repo added to crawl (`l-dgnit.cc`), because none existed: the lua API exposed a
shop's stock and its *name* but never its type.

The name is not a substitute. `shop_name()` builds `<Keeper>'s <TypeName>
[<Suffix>]`, so 89% of shops parse — but a vault may override the type name
outright, and those are exactly the run-defining shops. Measured over a
10k-seed corpus, 2,388 of 21,159 shops (11.3%) were unparseable, and the
failures are not random: `Sanarr's Fire Supplies` and `Saerghouwk's Gadget
Gallery` are both General Stores, `The Oracle's Delphic Readings` is a Magic
Scroll shop. Parsing does not merely miss those, it gets them *wrong*.

It sits on the **feature** row, not on each stocked item. A shop averages 5.4
stock rows, so the feature is 5.4x fewer rows for the same fact, and the shop's
position joins the two. `shop_type` is null on every other row.

The type is the canonical enum spelling (`shop_type_name()`), not the vault's
display override — a stable vocabulary is the point. The dumper guards the call
(`if dgn.shop_type_at == nil`), so an unpatched build emits nothing and its rows
read null rather than failing.

The binding is ours, not upstream's, so it lives in `patches/` and
`tools/provision` applies it before building. **Re-provision before a fill** —
an unpatched build produces a corpus that looks complete and has a null
`shop_type` on every shop.

An existing corpus takes `tools/corpus-reindex`, which adds the column in place.
It stays null on rows filled before the binding existed; backfilling is a
re-fill, not a migration.

### Format 4

Two fields, both un-backfillable, both cheap. **The wire-completeness audit is
done and format 4 is soft-locked (2026-09):** every un-backfillable extraction
field was considered in one pass so the format would take one bump rather than
several. Changing it is still possible and is not expected. The known
exclusion is the unidentified item appearance — see AGENTS.md, which records
why it costs a re-fill.

`toll_note` on an `enter_trove` feature, from the trove marker's
`overview_note` property. A trove's toll is the only thing distinguishing one
from another — two troves on a seed are the same portal at different prices —
and nothing else in the corpus records it. The structured `props.toll` table
(`base_type`, `sub_type`, `ego_type`, `plus1`, `quantity`, `artefact_name`) is
**not** reachable through `:property()`; only the rendered string
`TroveMarker:overview_note` builds is, and getting the structured form would
mean another binding in `patches/` the way `dgn.shop_type_at` was added. The
lookup is the same userdata path `timeout_turns` uses — `dgn.marker_at_pos`
returns userdata, so field access errors and `:property()` is the only route —
wrapped in a `pcall`, with an empty string read as an absent key.

**A `D:8` fill records no toll at all.** `trove.des` declares
`default-depth: D:12-, Swamp, Snake, Shoals, Spider`, so a trove cannot
generate above D:12 — the shallowest of the 4,537 in the 100k corpus is exactly
D:12, and those rows come from the deep fills. Verifying the field means
filling past D:12; at the default cap the column is null everywhere and the
"100% of trove rows carry a toll" check passes over an empty set.

The vocabulary is crawl's own, and it is four prefixes:
`give`/`show` (an item, shown if the trove displays it), `lose all piety`,
`suffer the <Bane name>`, `suffer draining`. A `be buggy` is crawl's fallback
for a malformed toll table and means something is wrong upstream. A normalised
`toll_type` is derivable from the prefix, so it stays a later schema question
rather than a freeze blocker.

`gold` beside `level`, a **level-scoped sum** of `item.quantity` over every
`base_type == "gold"` pile. `explorer.item_ignore_boring` drops those piles
outright (`dat/dlua/explorer.lua`, under crawl's own `-- show gold totals?`
TODO), so they never reach the wire and the sum cannot be recovered from an
existing corpus. The accumulator therefore sits **outside** the `item_notable`
filter: the piles are counted and never emitted as rows. A pile as a row would
be the worst row in the schema — 5-10 per level to carry one integer, against
15.66M existing rows — and neither a pile's position nor its individual size is
a fact a reader asks for.

Stored as `seed_levels.gold`, the same shape as `temple_altars`. It counts the
floor and nothing else: **no monster drops, no Gozag**, so it is a lower bound
on purchasing power. Anything displaying it says "floor gold", never "gold" —
the bare word reads as what a player can spend, which this is not. Zero is a
real answer (a Temple has none) and stays distinct from the null a level
ingested before format 4 carries.

Measured on the verification fill (10k, 0.34.1, `D:8`, 2026-09): `gold` is
non-null on 96,235 of 96,235 levels, mean 54.5, max 1,636, rising monotonically
50.2 at D:1 to 74.5 at D:8. The 13,084 zeroes are real — all 10,000 Temples,
crawl placing no gold there, plus the smaller portals. Cross-checked against
`-all-items` runs on seeds 1 and 4242, where the piles are emitted as rows:
19 of 19 levels matched exactly. Tolls, on a fill deep enough to hold any
(400 seeds, 0.34.1, `D:15`, 2026-09): 70 trove rows, `toll_note` non-null on
70 of 70, and the vocabulary exactly the four prefixes with no `be buggy`.

Neither field takes an index. A trove stands on 4.5% of seeds, so a `like` over
the `strings` dictionary is cheap at any corpus size, and gold is read per level
alongside the row it sits on.

An existing corpus takes `tools/corpus-reindex`, which adds both columns in
place so it loads under the new reader. They stay null until a re-fill — that is
the point of the bump, since neither fact is recoverable from what is already
stored.

### Dropped at ingest

The dumper still emits these; `Reader.drop_entry` discards them before they
reach storage, so re-pruning costs a re-run of the fill rather than a schema
migration. Measured over 60 seeds: **24.0% fewer rows, 21.7% smaller on disk.**

- **Vaults, the whole category.** Level-generation scaffolding
  (`layout_basic`, `layout_loops_ring`, `layout_rooms`). The `uniq_*` vaults
  look like they carry unique placement but are redundant — no seed holds one
  without the corresponding `monsters` row, and `unique_mons` already covers it.
- **`runed_clear_door`.** Records that a vault exists without recording what is
  in it, which is exactly what dropping vaults discards.

Both are storage, not capability. See `docs/schema-decisions.md`.

`ood` was **removed**, not filled: `explorer.rare_ood` needs
`avg_local_depth > you.depth() + max(2, br_depth()/3)`, which no early-game
notable reaches, so it never fires in D:1-D:8 and is not a useful fact about a
seed.

## Dumps are reproducible across platforms, but not byte-identical

Seed 12345 on 0.34.1 at D:8, dumped on macOS/arm64 and on Linux/x86-64,
produces the same 9 records and the same 24706 bytes, with **one** difference:
the order of the fields inside one randart's `artprops`.

```
laptop  ((Dex 3) (rC -1) (rElec 1) (Will 1))
server  ((Dex 3) (Will 1) (rC -1) (rElec 1))
```

Same properties, same values, different iteration order — crawl's artefact
property table does not enumerate in a stable order across standard library
implementations. Everything else in the dump matched byte for byte.

So the dungeon a seed names is a property of the seed and the version, not of
the machine that generated it. Corpora built on either platform are
interchangeable, and the existing corpus is not tied to the laptop that filled
it.

Two things follow.

**Ingest is unaffected.** `entry_props` is one row per (entry, prop, value) with
no ordinal column, so the order properties arrive in is not recorded and cannot
be observed downstream. Two machines ingesting the same seed produce the same
rows.

**Byte-comparing dumps across machines is not a valid check.** Hashing or
diffing sexp output will show spurious differences on any seed containing a
multi-property randart. Compare the ingested rows instead, or normalise
`artprops` order before diffing. An expect test asserting on dump text would be
machine-dependent for the same reason.

## Provisioning gotcha: scripts are copied, not linked

`tools/provision` copies both lua dumpers into
`builds/<version>/crawl-ref/source/scripts/` **at build time**. A build
provisioned before a script existed (or before it changed) has a stale or
missing copy, and crawl fails with a script-not-found that looks like a crawl
problem rather than a staleness problem.

`tools/corpus-fill` re-copies the scripts on every run, so this cannot bite it.
If invoking crawl by hand, copy first:

```sh
cp scripts/seed_dump_sexp.lua builds/0.34.1/crawl-ref/source/scripts/
```

## Item filtering differs between the dumpers

`seed_dump.lua` accepts `--all-items` / `--artefacts`, and `tools/explore`
defaults to adding `-unique-items`. `seed_dump_sexp.lua` takes `-mon-items` to
scan every monster's inventory; without it, only **uniques'** inventories are
read. That default is deliberate: uniques carry artefacts roughly 19x as often
as ordinary monsters, and ordinary monsters account for ~70% of carried items
but ~11% of carried artefacts. The item filter is crawl's own
`item_ignore_boring` in both.

Monsters themselves are recorded per `explorer.mons_ignore_boring`: uniques,
crawl's `dangerous_monsters` list, player ghosts, and pandemonium lords. Rank
and file monsters are not catalogued — they are not a property of the seed worth
indexing.

## Filling the corpus

`tools/corpus-fill` is the batch driver: it chunks a seed range across cores,
runs one crawl process per chunk, and pipes each chunk straight into
`ingest.exe`.

```sh
tools/corpus-fill 0.34.1 -n 100000                  # seeds 1..100000 at D:8
tools/corpus-fill 0.34.1 -s 100001 -n 50000         # a later range
tools/corpus-fill 0.34.1 -n 1000 -d D:4 --db /tmp/x.db
```

Defaults: depth `D:8`, database `corpus.db`, `JOBS` = core count, `CHUNK` = 250
seeds per crawl process. It creates the database from `schema.sql` if absent.

Why one process per chunk rather than one long-lived one: crawl process startup
is ~0.6s and amortises away over a few hundred seeds, while a process that dies
mid-chunk (crawl asserts occasionally on hostile dungeon states) costs only that
chunk. Ingest is idempotent per `(seed, version, level)`, so re-running a failed
chunk is safe and needs no bookkeeping.

**`util/fake_pty` has two watchdogs, and one can eat a chunk silently.** It is
crawl's own test harness: it opens a pty, points crawl's stdin and stdout at it
so `isatty()` succeeds, and discards everything crawl paints. A compiled-in
`alarm(TIMEOUT * 60)` caps total runtime, and a `poll(..., 60000)` kills crawl
after **60 seconds with no stdout**. That timer watches the curses repaints, not
our `#SEED#` records on stderr, so ordinary generation never trips it — but a
seed that stalls in generation without touching the screen would be killed with
no error written anywhere. It would surface only as missing seeds in
`tools/corpus-check`, which is one of the reasons to run it after every fill.

**Writers serialize.** SQLite in WAL mode takes one writer at a time, so the
parallel `ingest.exe` processes contend on commit. `busy_timeout=30000` (set by
`Db.open_`) is what makes them wait rather than fail; batches are 2000 records,
so a commit is short relative to the ~2 minutes of dungeon generation feeding
it. Among the fill's own workers, contention is not the bottleneck — dungeon
generation is.

A *tenth* writer is a different matter. The deepen generator runs continuously
and on nobody's schedule, and when it overlapped the 100k fill both sides
exhausted the other's timeout (then 5s) and four chunks lost their tails. Two
fixes: the timeout is now 30s, and `write_batch` takes `begin immediate` so a
batch that reads before it writes cannot lose the lock upgrade partway through
and unwind work already done. A fill also holds `flock` on `<db>-write.lock` for
its parallel phase, which the generator yields to — see `docs/architecture.md`,
"Writer stance".

**The last phase is rescoring heat**, after every worker above has exited:

```sh
./_build/default/bin/rescore.exe -db corpus.db -build 0.34.1
```

`tools/corpus-fill` runs this automatically as its final step, with its own
`==>` progress line. It is a whole-population aggregate — the surprise
table and the score cut points both describe the whole eligible cohort at a
`(version, cap)`, not one seed — so it runs once per fill, never per batch and
never per request; see `docs/heat.md`, "Running it" — the surprise pass runs
after a fill completes, not per batch". `bin/rescore.ml` enumerates every
distinct `seed_fills.depth` a version holds and rescopes at each: a seed
filled to `Swamp:4` also needs a `D:8` score to stay a member of the shallow
cohort's percentile, which enumerating every distinct fill depth (rather than
just the deepest) achieves for free, since eligibility is `depth >= cap`.

**A corpus filled before this existed needs one explicit run.** Nothing
backfills `seed_scores` or `surprise` automatically — run
`./_build/default/bin/rescore.exe -db corpus.db` once by hand (all versions,
every cap each holds) and every seed listing gains its heat mark from then on.
Re-running is always safe: both `Db.recompute_surprise` and `Db.rescore`
delete-then-insert for the `(version, cap)` they are given.

### Cost

Measured on 0.34.1, 8-core M-series, `D:8`, structured scan. The right-hand
column is a full 100k fill run end to end (2026-08-27) rather than an
extrapolation from a sample, and it supersedes the 2000-seed projection beside
it — that projection overestimated entries per seed by 49% and size by 12%,
because a small contiguous sample from the start of the range is not
representative of the population:

| | 2000-seed projection | measured, 100k |
|---|---|---|
| per seed, single process | ~0.42s | — |
| per seed, 8-way parallel | ~0.067s | 0.0636s |
| wall, 100k seeds | ~1.9h | 6360s (1h46m) |
| on disk, 100k seeds | ~2.8 GB | ~~2.5 GB~~ 1.11 GB |
| entries per seed | ~153 | 103.0 |
| KB per seed | — | ~~25.6~~ 11.1 |
| rescore, 100k | — | ~~164s~~ 69s |

The struck figures are pre-interning. Re-measured on the reingested corpus
(100k, 0.34.1, `D:8`, 2026-08-28, M-series laptop, 8-way): the D:8 fill alone
is 1,108,291,584 bytes at 7180s, with a 69s single-cap rescore. Size fell by
2.3x and rescore by 2.4x from
interning; the wall time did
not move, because extraction is bound by crawl's dungeon generation and not by
what ingest writes.

Depth dominates everything else; see the curve in `README.md`. `D:4` is roughly
2.5x cheaper than `D:8`, `D:15` roughly 2.5x dearer.

**Throughput does not decay as the corpus grows.** Sampled every two minutes
across that run, the rate held at 16.5 seeds/s from 66k through 96k while the
database grew 1.63 GB to 2.38 GB — no measurable slope. The parallel
`ingest.exe` processes sat at roughly 0% CPU throughout, blocked on `read()`
waiting for crawl, and the writers' commit contention never became visible.
This is the evidence for the claim above that dungeon generation is the
bottleneck, and it is what makes a linear projection to 1M defensible on time
and size. Re-measure it if ingest ever grows a per-row cost that scales with
table size.

**Extraction is CPU-bound, at about 70% efficiency.** During the fill: 89%
user, 10% sys, 0.8% idle, load average 16 on 8 cores, with each `crawl` pinned
at 67-71% rather than 100%. The missing third goes to `util/fake_pty` and the
pty handoff — crawl will not run without a terminal, so every byte it paints to
an invisible 24x80 screen is rendered by curses, pushed through the pty, read
by `fake_pty`, and discarded. Our records reach us on *stderr*, which is why
every invocation is `2>&1 | grep '^#SEED#'`; `fake_pty` swallows stdout by
design. Removing that overhead means patching crawl to run headless, which is a
real change to a vendored dependency for maybe 20-30% throughput — not worth it
at present scale, but it is the obvious lever if extraction cost ever binds.

### Deep fills

`-d Swamp:4` is the deep extraction: it reaches through the Lair branch set
without generating the late game. Measured over 200 seeds, every seed yields
D:1–15, Temple, Orc and all five Lair levels, plus whichever two of
Shoals/Snake/Spider/Swamp that seed rolled (each appears in roughly half of
them). Nothing from Vaults, Depths, Elf, Crypt, Slime or Zot is generated. Every
seed therefore records the same fill depth, 15, taken from `D:15` rather than
from the branch cap — the Lair-branch variance does not perturb it, so the
cohort is homogeneous.

An earlier cap of `Depths:4` stopped exactly at the Zot entrance. Crawl's
`explorer.generation_order` is a flat list, and `Depths:4` is index 51 against
`Zot:1`'s 56, so that cap excluded Zot — and, because they are generated *after*
Zot in that order, Elf and Slime too. Reaching those without generating Zot is
not expressible as a single index, since the order is linear rather than a
reachability graph.

Measured on 0.34.1, 8-core, against a matched `D:8` control over the same 200
seeds. The `Depths:4` column is retained as the cost of the deeper cap:

| | deep (`Swamp:4`) | deep (`Depths:4`) | shallow (`D:8`) | `Swamp:4` ratio |
|---|---|---|---|---|
| wall, 200 seeds, 8-way | 65s | 135s | 12s | 5.4x |
| entries per seed | 445.4 | 794 | 103 | 4.3x |
| KB per seed | 118 | 238 | 26 | 4.5x |
| levels per seed | 33.1 | 45.6 | 9 | 3.7x |

Measured again 2026-08-27, as a real 10,000-seed deep block (seeds
45000-54999) filled on top of a complete 100k `D:8` corpus. Unlike the shallow
projection above, the 200-seed deep sample held up:

| | 200-seed sample | measured, 10k |
|---|---|---|
| wall | 65s / 200 | ~~3581s / 10k (59m41s)~~ 3470s |
| per seed, 8-way | 0.325s | ~~0.358s~~ 0.347s |
| entries per seed | 445.4 | 443.7 |
| levels per seed | 33.1 | 33.1 |
| rescore, two caps | — | ~~349s~~ 105s |

Re-measured on the reingested corpus (10k deep seeds over a 100k base, 0.34.1,
`Swamp:4`, 2026-08-28, M-series laptop, 8-way). Extraction is unchanged within
noise, as expected — it is crawl-bound. Rescore fell 3.3x, which is the
interned schema making the scoring queries cheaper, not a change in what is
scored. A deep seed costs 46,061 bytes against a shallow seed's 10,957, so the
4.2x ratio the shallow-vs-deep comparison rests on survives interning.

Rescore costs roughly 2x the shallow figure (349s against 164s) because a
corpus holding two distinct fill depths is scored once per cap: cap 8 over all
100k, then cap 15 over the 10k deep block, each with its own surprise pass.
That is the mechanism described above, and its cost is per *cap*, not per seed
— a third distinct fill depth would add a third pass.

At those rates 100k `Swamp:4` seeds is ~12 GB and ~9h; 1M is ~118 GB. Deep
extraction is a per-seed request, not a fill mode — see
`docs/schema-decisions.md` for the corpus-wide budget.

**A contiguous deep block is a valid random sample; do not build tooling to
draw a scattered one.** Seeds are opaque 64-bit keys, so a contiguous range
carries no shared structure. Measured on the 2026-08-27 corpus, the deep block
(45000-54999, n=10,000) against the remaining 90,000, compared at the `D:8` cap
they share: mean surprise 77.10 against 76.73, sd 33.3 against 32.2 — a
difference of about 1.05 standard errors, inside noise, with matching spread.
So `-s <offset> -n <count>` is all a representative subset needs. This tests
contiguity against content only; it says nothing about PCG stream quality,
which is not worth testing.

**A random deep subset is worth filling anyway, for the statistics.** Serving
deep requests on demand makes the deep cohort a sample of what readers found
interesting, which is not a population. Filling a random slice — order 5%, so
50k deep against 1M shallow, ~6 GB and ~4.5h — gives that cohort a base drawn
without reference to anyone's interest, large enough that reader-driven
one-offs are noise against it. Fill it by range like any other fill, with
`-d Swamp:4`; there is nothing special about these seeds except that nobody
chose them.

**A deep fill is a strict prefix extension of a shallow one.** Verified
row-for-row over all 14 comparable columns: a deep seed's `Temple`/`D:1`–`D:8`
rows are byte-identical to a shallow fill of the same seed, and the Temple altar
bitmasks agree. So a deep run over an already-shallow seed supersedes it with no
conflict, on top of the ordinary `(seed, version, level)` idempotency — and a
deep seed stays a valid member of the shallow cohort. See
`docs/corpus.md`, "Fill depth is part of a seed's identity".

### Serving deep requests

`tools/corpus-fill` fills a contiguous range; `corpus-deepen` serves the queue
one seed at a time, for the seeds a reader has actually stopped on.

```sh
just deepen                             # the generator, against corpus.db
just dev-all                            # the web server and a generator together
./_build/default/bin/deepen.exe -db corpus.db -once   # one pass, for checking
```

**It is a plain process with no supervisor.** Nothing starts it, nothing
restarts it, and `just dev` deliberately does not — the generator writes to the
real corpus and spawns crawl, which is a wider blast radius than an
edit-reload loop wants on every save. `just dev-all` is the opt-in for working
on this feature, and its trap is load-bearing: without it, Ctrl-C on the watcher
leaves a generator running against your corpus.

An unexpected exception no longer ends it — `Deepen.guard` logs and continues,
matching how every *expected* failure in a pass is already handled. With no
supervisor there is nothing to restart it, and a dead generator is invisible
until its heartbeat ages out and requests start being refused. Hosting is where
that gets a real answer: it runs under systemd with `Restart=always`.

It claims the oldest unclaimed job for each version it can build, runs the same
pipeline `corpus-fill` runs with a chunk of one, and records the outcome. A run
takes ~3s wall for one seed. It serves **released versions only** — a trunk
build tree under `builds/` is deliberately skipped, since trunk is a moving tag
and the corpus's per-version facts would describe whichever build was checked
out.

The web process must not do this. It has no build tree, and storage is
synchronous, so a ~2.5s extraction on the request thread would stall every
concurrent reader rather than just the one who asked.

Two things bite if you run it by hand:

- **The corpus path must be absolute**, and the binary resolves it for you. The
  pipeline `cd`s into the build tree, so a relative path resolves *there* — and
  since ingest creates a database it does not find, the symptom is a stray empty
  file in `builds/` and a job that fails with `no such table: versions`, naming
  nothing about the real cause.
- **A generator declares what it can build**, through the `generators` table, on
  every pass. The web process refuses a deepen request for a version with no
  recent heartbeat, because a job nothing can claim is indistinguishable from a
  queued one and would sit against the queue cap forever.

### Verifying a fill

`tools/corpus-check` looks for what a silent extraction failure actually looks
like — the failure modes here are quiet, not loud:

```sh
tools/corpus-check 0.34.1 --range 1-100000
```

It checks:

- **Seeds short on levels, per fill-depth cohort.** A crawl process that dies
  mid-chunk leaves a seed present but truncated. The threshold is per cohort,
  not corpus-wide: a deep seed holds 43 non-portal levels against a shallow
  seed's 9, so one global threshold is set by whichever depth is more numerous
  and the other cohort is measured against a number that means nothing. With
  10,000 shallow seeds and 200 deep ones, a deep seed truncated from 47 levels
  to 12 passed the old check clean.

  Portals are excluded from the count because *their* number genuinely varies
  per seed — 43 to 49 total levels across 200 deep seeds — while the non-portal
  count is fixed by the fill depth and had zero variance in both cohorts.
  Counting all levels flags a seed for generating fewer bazaars than its
  neighbours, which is a fact about the dungeon, not a truncated extraction.

- **Seeds recorded below the shallow cap**, which is the hole the per-cohort
  check leaves open. A truncated fill writes a short *depth* as well as short
  levels, so the seed lands alone in a cohort of one, is trivially that cohort's
  maximum, and passes. Three seeds sat truncated through a clean `corpus-check`
  that way (100k, 0.34.1, 2026-09-02): 67207 stopped at `D:2`, 66707 at `D:5`,
  67958 at `D:6` — each the last seed of a chunk whose ingest lost its tail to
  the writer contention above.

  Extraction has exactly two caps, shallow (`D:8`) and deep, and membership is
  two-valued rather than an ordering (see `Fill_depth`), so a depth strictly
  below the shallow cap is a truncation by definition — no operator input needed
  to say so, and a deepened seed is *above* the cap and unaffected. The check
  reads the cap from `lib/corpus/fill_depth.ml` rather than hardcoding it.

  **`--skip-done` does not repair these.** It selects seeds absent from
  `seed_levels`, and a truncated seed is present — so the refill skips exactly
  the seeds that need it. Delete them first with `tools/corpus-drop-seeds`,
  which relies on the `on delete cascade` from `seed_levels` to take `entries`
  and the per-entry tables with them (and sets `foreign_keys` explicitly,
  because it is per-connection and defaults *off* — without it the delete
  orphans every entry).

  These also cost real time downstream: each spurious depth is a distinct cap,
  and `rescore` runs a full pass per cap over a population defined by
  `depth >= cap` — so three truncated seeds made the 100k rescore roughly five
  times more expensive than the corpus needed. See `docs/corpus-scaling.md`.

- **Seeds with no recorded fill depth**, which predate `seed_fills` and cannot
  be checked against their peers. `tools/corpus-reindex` derives it from the
  levels already stored.
- **Gaps in a contiguous range**, when `--range` says the range should be
  complete. Refill with `corpus-fill --skip-done`.
- **Missing search indexes.** `schema.sql` gains indexes over time, and a
  corpus created from an older copy silently *scans* where it should seek —
  the one failure that shows up as slowness rather than wrongness.
- **Missing tables.** `schema.sql` also gains the occasional table
  (`book_spells`). Unlike a missing index this is *fatal*, not slow: a read
  path prepares a statement against it and the request 500s with
  `no such table`.

`tools/corpus-reindex` fixes the last two by replaying `schema.sql`'s
`create table` and `create index` statements as `if not exists`, so it is
idempotent and safe to re-run:

```sh
tools/corpus-reindex --db corpus.db
```

It creates only what is *absent*; it does not alter a table whose columns
changed, so a column addition still needs its own migration.

An existing corpus needs no data migration for `book_spells` — it stays empty
until the corpus is refilled, and the read path falls through to the
`entry_spells` rows an older fill already wrote. Old and new rows render
identically; the older corpus just keeps paying for the storage.

Run it **after** a fill rather than during one — index building contends with
the ingest writers. Cost scales with row count: ~0.6s per index over 300k
entries, so roughly three minutes for all six over a full 100k-seed corpus
(~15M entries).

The difference it makes is not marginal. On a 60k-seed corpus without the search
indexes, a three-term search took **16 seconds** and a single-term search six;
with them, the same shapes answer in milliseconds. An unindexed corpus is why
`Seed_web.run_search` detaches — a 16-second blocking SQLite call would stall
every other request, not just its own.

### Resuming

The corpus itself is the progress record — there is no lock file and no state
directory. What has landed:

```sql
select count(distinct seed)
  from seed_levels
 where version_id = (select id from versions where version = '0.34.1');
```

and the gaps, for a contiguous range:

```sql
select cast(seed as integer) as s
  from seed_levels
 where version_id = (select id from versions where version = '0.34.1')
 group by s
 order by s;
```

Re-running an already-ingested range is safe but not free — it regenerates the
dungeons. `tools/corpus-fill --skip-done` filters seeds already present for the
version before chunking, which is the cheap way to resume an interrupted fill.

`schema.sql` has an `ingest_jobs` table intended as a work queue for a
background generator. `corpus-fill` does **not** use it: a shell driver over a
contiguous range with an idempotent writer needs no claim protocol. It stays for
the web-triggered generation case, which is the first real mutation the web
layer would make.

## Bringing up a new crawl version

Checklist for the first fill against a build the corpus has not seen before:

- **Provision and fill as normal** (`make provision-<version>`,
  `tools/corpus-fill <version> ...`). The fill's own final phase rescoring
  heat depends on nothing version-specific, so it needs no separate step here.
- **Check the new build's item vocabulary against `Weight`.** Every distinct
  `(base_type, sub_type)` the fill produced should resolve through
  `Weight.find`, either exactly or by its class wildcard. A pair that does not
  usually means crawl added an item. This needs a corpus, so it happens here
  rather than in CI. The equivalent check against 0.34 found `gem` and `rune`
  scoring zero with no row at all, which is the failure mode the step exists to
  catch — they are now `None` by design.
- **A missing pair scores its class at zero for every seed until the table is
  edited.** That is a silent, plausible-looking wrong ranking rather than a
  crash, which is why the check has to be run deliberately rather than relied
  on to surface itself.
- **Serving the build is a separate, deliberate step.** A filled corpus is not
  reachable until `lib/web/served.ml` names it, which is the closed set doing
  its job rather than friction to design away (see `docs/architecture.md`).
  Widen the variant, leave `current` alone unless the new build really should
  be what a reader sees first, and let the expect tests in `test_served.ml`
  confirm the routing.
- **Between the fill landing and the rescore finishing, the build is
  *unscored*, not cold.** The masthead picker shows its real count while every
  heat cell renders as an em-dash. That is correct and worth looking at once on
  a new build, since it is the only moment the state occurs naturally
  (verified on 0.33.1, 2026-08-29).
- **Heat bands are per-cohort.** `surprise` and the `heat_bands` cut points are
  population statistics over the seeds filled to at least `cap`, so a band
  computed over 10k seeds is not the same claim as one over 100k. Heat has
  never been comparable across versions; serving several builds at different
  cohort sizes is simply the first time a reader can see two marks side by side
  and mistake them for one scale.
