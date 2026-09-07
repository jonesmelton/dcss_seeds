# AGENTS.md

What an agent (or a person) needs to know to work in this repository: what it
is, how to build and run it, and the domain facts that produce plausible-looking
wrong answers when forgotten.

## What this is

**dcss-seed-explorer** — tooling for asking *what does this DCSS seed contain, and how early* across several game versions, plus a server-rendered webapp for browsing and comparing seeds.

Two halves, joined by SQLite:

1. **The extraction pipeline** (built, `make`-driven). Per-version crawl worktrees, compiled from `versions.conf`; lua scripts run inside crawl's sandbox to generate dungeons and emit a catalog per level. Output is JSONL (+ a markdown report) or s-expressions.
2. **The corpus** (built, `lib/corpus` + `bin/ingest.ml`). An OCaml program reading those s-expressions into SQLite (`schema.sql`), so set-containment questions — "seeds with Wyrmbane and 3+ potions of experience" — are indexed lookups rather than scans over per-seed dumps.
3. **The webapp** (`lib/web` + `bin/main.ml`). Dream + TyXML + htmx over the corpus. A paginated seed listing, a per-seed catalog page, and the search surface ("which seeds have X"), all version-scoped, over the `Db.list_seeds`/`Db.seed_levels`/`Db.search_seeds` accessors. See `docs/architecture.md`.

The product goal: **browse and compare seeds against each other**, which is exactly what the per-seed JSONL reports deliberately don't do. A seed report answers "what's on this seed"; the webapp answers "which seeds have this", "how does this seed compare", and "what's unusual here". Version is part of every question, because a seed number means nothing without a build.

## Commands

### Extraction (root `Makefile`)

```sh
make versions                              # configured versions and build state
make provision                             # build every version in versions.conf
make provision-trunk                       # or just one (minutes each)

make seed SEED=1234567890                  # one seed -> out/<v>-<seed>.jsonl + .md
make seed SEED=1234567890 V=0.34.1 DEPTH=D:4
make batch SEEDS=seeds.txt                 # a file of seeds, batched and parallel
make report IN=out/trunk-batch.jsonl       # re-render an existing dump
```

`DEPTH` defaults to `D:8` (roughly the early game) and is the dominant cost — raise or lower it first. `V` defaults to `trunk`. Needs a crawl clone (`CRAWL_REPO`, default `~/code/crawl`).

### Corpus (`just`-driven)

Task runner is [`just`](https://github.com/casey/just); local opam switch in `_opam/` on OCaml 5.5.0.

```sh
just deps          # opam install . --deps-only --with-test --with-dev-setup
just build         # dune build --profile dev (warnings-as-errors)
just test          # dune runtest
just promote       # accept changed expect-test output
just fmt           # apply ocamlformat
just ci            # fmt-check + build + test — the merge gate
just db corpus.db  # create a database from schema.sql
just run           # dune exec bin/main.exe — the web server (port 8430)
just dev           # rebuild + restart on save; tees to /tmp/seed-explorer-dev.log
```

`SEED_PORT`, `SEED_INTERFACE`, and `SEED_DB` override the defaults (8430,
localhost, `corpus.db`). The server exits if the corpus file is missing.

`SEED_ORIGIN` (default `https://dcss.jonesmelton.com`) is the absolute origin
`/sitemap.xml` and the `Sitemap:` line in `/robots.txt` are built from --- the
only place the app names its own host, since every other link it emits is
relative. A trailing slash is stripped. Set it on any deployment that is not
the public one, or the sitemap advertises someone else's URLs.

`SEED_POOL_SIZE` (default 4) sets how many read-only connections
`Seed_corpus.Pool` opens for detached searches, and doubles as the
`Lwt_preemptive` worker-thread cap (`Lwt_preemptive.set_bounds (0,
SEED_POOL_SIZE)`) --- the two must agree, since a pool bigger than the thread
cap sits behind a scheduler that never sends it enough concurrent work to use
it. See `lib/corpus/pool.mli`.

`SEED_DISABLE_SEARCH=1` takes search off entirely: the search page and its
help page render a placeholder instead of running any query. Predates the
pool and is no longer load-bearing for the reason it was added --- a
leading-wildcard `like`, `floor <item>` and `altar_xom` all
used to stall the app's one shared reader connection, and now run detached
against `Pool` instead --- but it stays available as a blunt escape hatch.
Off in prod since the pool and the Floor_item covering index landed and were
measured live (fossil ticket 093f82b4a9, 2026-09-03).

Tests are inline expect tests in a `test_seed_corpus` library; `dune runtest` is the whole suite. To re-run when nothing changed: `just test-force`.

Filling the corpus:

```sh
tools/corpus-fill 0.34.1 -n 100000            # the batch driver; see docs/extraction.md
tools/corpus-fill 0.34.1 -n 5000 --skip-done  # resume an interrupted fill
tools/corpus-check 0.34.1 --range 1-100000    # verify it landed completely
tools/corpus-reindex --db corpus.db           # add tables/indexes schema.sql gained since
tools/corpus-fts-rebuild --db corpus.db       # rebuild the name~ substring index; REQUIRED after a fill
tools/fill-rate corpus-fill-progress.tsv      # the rate curve of a fill, binned
```

`corpus-fill` appends one row per chunk to `<db>-fill-progress.tsv` as it runs
(override with `PROGRESS=`, silence the stderr echo with `QUIET_PROGRESS=1`).
That log is the point, and it is what settled the question: an average over a
whole run cannot distinguish an asymptote from a linear decline, only one of
which reaches a large corpus. Binned by `tools/fill-rate` over the 300k → 1.3M
fill it showed **no decay** (−0.8% across twelve slices of 27.3 hours), which
is why the log stays even though the answer is now known — the next version, or
the next order of magnitude, re-opens it. The log is
diagnostics and never fatal: an unwritable path degrades to no log rather than
failing the fill.

A fill adds names to `strings`, and the trigram index behind `name~` is updated
by neither ingest nor a trigger, so it needs an explicit rebuild — and until it
gets one, **`name~` is refused**, not served slowly. `corpus-reindex` creates the
index; this only repopulates it, and says so if it is missing:

```sh
tools/corpus-fts-rebuild --db corpus.db
```

After a fill lands (and after `corpus-check` / `corpus-reindex` above):

```sh
sqlite3 corpus.db 'analyze; pragma wal_checkpoint(truncate);'
sqlite3 corpus.db 'vacuum;'   # optional after a fill; mandatory after an index rebuild
```

then restart anything serving the db. In order of consequence: `analyze` is
the non-negotiable one — a fill shifts the distributions the planner reads,
and stale stats once flipped a cheap search onto a non-covering index for a
100x regression (300k, 0.34.1, 2026-09-03); the checkpoint folds the fill's
WAL back into the main file instead of leaving it at hundreds of MB; `vacuum`
undoes physical page scatter, which fills (append-mostly) accrue far more
slowly than index rebuilds do — after the 2026-09 rebuild it ran 82s, shrank
3.72GB to 3.54GB, and restored cheap shapes from ~0.25s to their 0.08s
baseline (prod, 300k, 0.34.1, 2026-09-03). At ~45MB/s it is cheap enough to
just run; it does need roughly 2x the db size in free disk while it works.
The restart is because a long-lived connection can hold plans built on the
old statistics, and because the first query after any of this pays the cold
cache anyway — better spent deliberately than on a reader. At 1.3M that tail
is longer than the old ~30s: the db is 15.7 GB and a full sequential read
takes ~25s of pure CPU even entirely warm, because `/corpus` is zstd and the
cost is decompression, not disk (prod, 2026-09-05). Warming is also not a page-cache
question there — ZFS caches in the ARC, which `free` does not report under
`buff/cache`, so a warm corpus can look uncached. Read `arcstats` instead:
the corpus is 5.17 GB compressed against a 30 GB ARC cap, so it fits, and a
second pass over the whole file adds ~1 ARC miss.

By hand, one chunk at a time (note the `grep` — everything crawl writes that
isn't `#SEED#`-prefixed is noise and must be filtered before the reader sees
it):

```sh
cd crawl-ref/source
util/fake_pty ./crawl -script seed_dump_sexp.lua -seed 5000 -count 500 -depth D:5 2>&1 \
  | grep '^#SEED#' \
  | ingest -db corpus.db
```

## Read these before implementing

- `docs/architecture.md` — the layering, the Dream/Core/synchronous-storage decision and its revisit conditions, the search vocabulary, the SQLite pragma contract. Authoritative for how the webapp gets built.
- `docs/extraction.md` — how seeds get from a crawl build into the corpus, the two dumpers and why they differ, and `tools/corpus-fill`. Read before running a fill.
- `docs/corpus.md` — the corpus schema's data model and its gotchas.
- `docs/style.md` — typography and color. Authoritative for how it looks.
- `docs/what-the-corpus-is.md` — the corpus as a lossy compressor: entropy as the unit, coarse-vs-exact position, and why storage decisions are product decisions. Read before proposing any schema change that drops or reshapes data.
- `docs/schema-decisions.md` — what the schema drops and why, the saturation test a proposed drop has to pass, and the two proposals that failed it. Read with the above.
- `docs/corpus-scaling.md` — what bounds corpus size: disk does not bind, compute and DCSS's release cadence do. Read before planning a fill larger than the current one, or before assuming a version's corpus is permanent.
- `docs/single-writer.md` — **thinking, not decided.** Why corpus write contention (`BUSY`) happens, the single-writer-process idea it prompted, and what would have to be true before building it. Read before proposing anything about the write path or the fill lock.
- `docs/heat.md` — the seed heat model: the tier axis, weight vs. surprise, the bands, and what heat deliberately is not.
- `README.md` — the extraction pipeline, output format, and measured depth-cost curve.

Interface files carry the rest. `.mli` files are where the domain facts are written down — `record.mli`, `db.mli`, `heat.mli`, `weight.mli`, `job.mli`, `deepen.mli` in particular.

## Architecture

### The pipeline's shape, and why

Crawl's lua sandbox ships **no `json`, no `io`, no `os`** — every wire format is hand-written inside the sandbox. That single constraint explains most of the design:

- **Sexps, not JSON, for the corpus path.** Sexps are the cheaper thing to emit correctly by hand, and OCaml parses them for free. JSONL survives for the human-facing per-seed reports.
- **Records are line-prefixed with `#SEED#`** and read off stdout, because the script cannot open a file.
- **The database is the queryable artifact**, so the wire format stays an implementation detail. Rendering reads only the dump, never the dungeon, so report formats change without regenerating anything.

Items come from **player map knowledge**, so each level is magic-mapped before scanning. Shop stock is read directly and needs no mapping.

### Layering (webapp; see `docs/architecture.md`)

Three layers; **dependencies point web → domain → storage and never reverse.**

- **domain** — pure, no I/O. Record parsing, catalog vocabulary, comparison logic. This is the layer property/expect tests hammer; keeping it I/O-free is what makes that tractable.
- **storage** — all SQL. Hand-written parameterized SQL only: no query builder, no codegen, no string-built SQL.
- **web** — thin Dream handlers + TyXML templates. Validate, call domain/storage, render. No business logic, no SQL.

Today `lib/corpus` is domain+storage fused (`record.ml`/`reader.ml` are the pure half, `db.ml` the storage half), and `lib/web` is its own library above it. Respect the boundary *within* `lib/corpus` — nothing in `record.ml`/`reader.ml` may reach for `Sqlite3`. Splitting it into separate dune libraries waits on the query surface growing enough that the dependency direction needs enforcing rather than observing; see `docs/architecture.md`, "Splitting the corpus library", which owns that trigger.

**A page's shape is a domain fact, not a rendering detail.** `Floor.of_level` (splitting a level into items/uniques/features/shops) and `Floor.entrances` (the branch index) live in `lib/corpus` and are expect-tested there, because "what a reader asks of a level" is domain vocabulary. `views.ml` renders that split; it does not compute it. A new grouping or ordering rule goes in `floor.ml` with a test, not inline in a view.

## Data model invariants

These are in the schema and the readme, and they are the ones that produce plausible-looking wrong answers if forgotten:

- **Version is part of the identity of every row.** The same seed number on 0.33 and 0.35 describes two unrelated dungeons. There is no such thing as a version-free seed query. Rows carry `version_id`, not the string: `versions` is the one place a build name is spelled, and every scoped query resolves it with the scalar subquery `version_id = (select id from versions where version = ?)` — `Db.version_bind` still binds the *name*, so nothing above storage learns that ids exist. `versions.first_seen_at` is what orders builds, because crawl's version strings (`0.33-a0-4444-g172805db8e`) do not sort meaningfully. **In the webapp this is a path segment, not a query parameter** — every address is `/<version>/…`, so there is no bare `/seed/123` to resolve against a silent default. The served builds are a closed set compiled into `Served` (`lib/web/served.mli`), deliberately a different type from `Query.Version`: an unserved build is a 404 at the routing boundary rather than an empty listing, and `/` redirects to the hand-set `Served.current`. Adding a build is a code change, which is correct — it already is one.
- **Every repeated string is interned in `strings`, and the references are not enforced foreign keys.** `id integer primary key, val text not null unique`. Level names, item types, egos, feats, monster names and the irreducible display names all live there once and are referenced by id (`level_id`, `base_type_id`, `sub_type_id`, `ego_id`, `feat_id`, `type_name_id`, `carried_by_id`, `shop_type_id`, `name_id`, `spell_id`, `prop_id`, and `surprise`'s item key). Measured **2.36x** smaller with every index built, on identical row counts (400 seeds, 0.34.1, D:8, 2026-08-28, M-series laptop). Two rules make it work and both are load-bearing: resolve an id with the **scalar subquery** `= (select id from strings where val = ?)`, never `join strings`, which reorders the plan and adds a temp b-tree for distinct; and do **not** declare the references as foreign keys, which would be an index probe per row on the ingest hot path for a constraint ingest enforces by construction. The `unique` autoindex is what both id resolution and `Name_like` ride on. `entries.cat` is likewise an integer enum (`Record.Cat.to_int`), a stable numbering rather than an ordinal, so reordering the variant cannot reinterpret rows already written.
- **Monster inventories are flattened.** A carried item is its own `entries` row with `carried_by_id` interning the monster's name. An `entries` row is therefore **not** 1:1 with a catalog record — counting floor items needs `where carried_by_id is null`.
- **`cost` present means shop item.** Its presence is the *only* thing distinguishing a shop item from a floor item.
- **A shop's type is `shop_type_id` on its feature row, never its name.** `shop_name()` is `<Keeper>'s <TypeName>[ <Suffix>]`, but a vault may override the type name outright — 11.3% of shops in a 10k corpus — and those are the run-defining ones (`Sanarr's Fire Supplies` is a General Store). Parsing the name does not miss them, it gets them *wrong*. The value comes from `dgn.shop_type_at`, a binding this repo adds to crawl (`patches/`, applied by `tools/provision`); an unpatched build fills null. It sits on the `enter_shop` feature, not on each stocked item — 5.4x fewer rows for the same fact. This is now the *only* record of a shop: the keeper's name is dropped at ingest and `Display_name` renders the row from the type alone (`a General Store`), so a shop that was `Sanarr's Fire Supplies` reads as its type. A null `shop_type_id` renders `a shop`.
- **Booleans are `integer` 0/1.** `strict` mode has no boolean type, and the `entries_search_artefact` partial index is defined on `artefact = 1`.
- **Fill depth is part of a seed's identity, alongside version.** `seed_fills`
  records how deep each seed was extracted, as a `Depth.t`. Until deep
  generation existed every seed shared one depth, so completeness could be
  inferred from the level list; once one seed stops at `D:8` and another reaches
  `Swamp:4`, "no Wyrmbane here" and "not searched deep enough to know" become
  indistinguishable, and a population statistic across both measures extraction
  effort as much as dungeon content (measured: 100% of 200 deep seeds held an
  artefact against 86.7% of 10,000 shallow ones, purely from search depth). A
  query names a depth cap and every seed filled at least that deep is eligible,
  counted only over levels within the cap — deep generation is a strict prefix
  extension (verified byte-identical row-for-row), so a deep seed is a *valid
  member* of every shallower cohort rather than something to quarantine. The
  corollary is that a cap sets the denominator, and the interface has to say so.
  Derived from the levels a seed holds, never from the wire, which is what makes
  it backfillable; `Db.write_batch` recomputes it from `seed_levels` after each
  batch, because a seed's levels can split across batches. See
  `lib/corpus/fill_depth.mli`.
- **Re-ingesting a `(seed, version, level)` replaces it**, via `seed_levels` delete + cascade to `entries`. Reruns after an interrupted batch are safe, and ingest-twice-and-diff is a valid idempotency check (output is deterministic for a given `(seed, version, depth)`). Interning put a trapdoor under this: the delete resolves the level through `strings`, so a level name not yet in the dictionary makes the subquery null, the delete match nothing, and the insert *add* a copy rather than replace one — silently, and only on a level's first ingest. `write_batch` therefore interns the level and parent names unconditionally **before** the delete. `test_db.ml`'s "re-ingesting a record replaces it rather than adding a copy" is what holds that down, and it ingests a second, never-before-seen level precisely so the assertion cannot pass vacuously.
- **Every ingest batch must register its versions first** — `seed_levels` has a foreign key to `versions`, so the first `seed_levels` insert fails without it.
- **`format` is checked at the parse boundary.** A record carrying an unsupported `format` is rejected, not parsed, so a serializer change fails loudly instead of silently writing nulls.
- **Pruning happens at ingest, in `Reader.drop_entry`, not at extraction.** `tools/corpus-fill` pipes crawl straight into `ingest` and keeps no dumps, so the database is the only stored artifact and re-pruning costs a re-run of the fill rather than a schema migration. Currently dropped: the whole `vaults` category (level-generation scaffolding; `uniq_*` vaults are redundant against `unique_mons`) and `runed_clear_door` (records that a vault exists without recording what is in it). Together 24% of rows. The dumper still emits both, so the filter is the only thing standing between them and the corpus.
- **A Temple's altars are not rows.** The 22 gods in crawl's temple pool (`_is_temple_god`: everything except Lugonu, Beogh, Jiyva, Ignis) are a bitmask in `seed_levels.temple_altars`, not `entries` rows — they were 64% of every altar row in the corpus. `count(*) from entries where feat like 'altar_%'` therefore undercounts by that much, and a feature search for a pool god must consult the mask as well as `entries` (`Db.temple_mask_arm`). The four excluded gods and `altar_ecumenical` are outside the pool, have no bit, and keep ordinary rows, so a rare-god query needs no bit logic — **partition by god, never by level**, since all 27 feats appear on Temple levels.
- **`entry_spells` holds randart books only, and is not a seed's spell list.** A parchment's one spell is its `sub_type` minus the prefix; a named book's set is a build fact stored once per version in `book_spells`. Together 93% of the table (194,465 → 13,458 rows on a 10k-seed 0.34.1 corpus). `Db.seed_levels` reunites all three sources, so nothing above storage knows the difference — but a query reading `entry_spells` directly sees only randart books. The discriminator is crawl's own `artefact` flag, exactly as a randart is told from an unrand. A `book_spells` set that disagrees with the recorded one is **rejected**: a released version is one build. See `lib/corpus/book.mli`.
- **A parchment is a one-spell book, and crawl files it under `base_type` = `book`.** So `base_type = 'book'` does not mean "spellbook": on 0.34.1 it is 2,382,285 rows of which 2,185,320 (92%) are parchments, against 65,541 on 0.32.1 and 66,894 on 0.33.1, which have no parchments at all — the item is new in 0.34 (10k/10k/100k, D:8, 2026-08-29). The named-book population is roughly flat across the three; the 36x is entirely parchments. Nothing in the corpus is wrong about this — `book_spells`, the `#early-spells` heat signal and `Weight`'s unweighted classes are all version-scoped and derive from the wire, so each build recalibrated itself (mean seed score 73.7 / 76.3 / 76.8 at cap 8). The trap is a *future* query reading `base_type = 'book'` as a spellbook count and comparing it across builds. The corollary for `Spell`: it is consulted only to pick a parchment's tier tile, so on a build with no parchments it is never called — which is why serving 0.32.1 and 0.33.1 did not surface the version-keying question (see `lib/corpus/spell.mli` for the trigger that would).
- **`seed_levels` is the authority on which levels a seed has, not `entries`.** A Temple holding only pool-god altars has zero entry rows (57 of 60 in a sample), so building a seed's level list from its entries silently drops it. `Db.seed_levels` reads the level list first and attaches entries to it.
- **There is no `text` or `kind` column, and `name` is stored only where it cannot be derived.** `text` was a byte-for-byte duplicate of `name` on all 15,336,469 rows. Its one job is standing in for a feature's missing `name` — features carry `feat` + `text` and no `name` at all — and that substitution happens in `Reader` before storage, so the wire format still carries it. `kind` was `cat` minus the plural, 1:1 on every row; it is still *required* on the wire (it validates a record's shape at the parse boundary) and still not stored. `name` went the same way for the rows whose spelling the other columns already fix: `entries.name_id` is **null exactly where `Display_name.of_entry` answers `Derived`**, and set only for the irreducible tail — artefacts, monsters, unrecognised feats. Measured 92% of rows store no name (400 seeds, 0.34.1, D:8, 2026-08-28).
- **Every index on `entries` leads with `version_id`.** Three that did not — `entries_name`, `entries_feat`, `entries_artefact` — were dropped: the `entries_search_*` indexes are strictly better prefixes and the planner never chose them. Measured 669 MB, 16% of the database, with no change to results or timings. Don't add a non-version-leading index back without a query that needs one.
- **A query's column list is one value, and every offset resolves through it by name.** `Db.Columns` holds the list; `seed_levels_columns` generates `seed_levels_sql`'s select list and resolves `entry_of_row`'s reads, `insert_entry_columns` generates `insert_entry_sql` and numbers `bind_entry`'s binds (SQLite numbers parameters from one, the list from zero). A reorder therefore moves the SQL and the reader together, and an unknown name raises rather than reading a neighbour. `Columns.check_header` verifies the prepared statement's own header on first use, so a column list edited apart from the skeleton around it errors instead of returning a shifted row. What the mechanism cannot catch is a field wired to the wrong *name* on one side, or the read and write lists disagreeing with each other — so a column-list change still ends with the round-trip expect test in `test_db.ml`, which exists for exactly that.
- **A search criterion is a type, not a name.** A name is a display string carrying enchantment and brand (`+3 greatsling "Punk" {acid, rCorr}`) — ~18x the cardinality of `(base_type, sub_type)`, and nearly every artefact name is unique, so exact-name search finds one seed or none. `sub_type` is the bare type (`haste`, not `potion of haste`); `base_type` disambiguates it. `Name_like` is the substring escape hatch for unrands. It is no longer unindexed — the `like` runs over the `strings` dictionary, served by the `strings_fts` trigram index, and the ids it yields are covering seeks on `entries_search_name` — and it no longer matches a *derivable* name, since those are not stored: `name~potion of haste` matched 274 seeds before interning and none after (400 seeds, 0.34.1, D:8, 2026-08-28). `Item` is the criterion for a type-nameable item and always was the right one.

- **A stale `name~` index refuses the search; it does not fall back to the scan.** `strings_fts` is fts5 over the `strings` dictionary (external content, trigram), and an external-content table gets no triggers unless someone writes them — none were — so a fill leaves it not knowing about the names it added. That staleness is silent in the worst direction: an unindexed name is simply absent, so a search returns "no seeds" rather than an error. The rebuild therefore records the dictionary id it reached in `strings_fts_state`, and `search_seeds` compares it against `max(id) from strings` per search, refusing `Name_like` with `Search.stale_index_tag` (a 503 with `Retry-After` at the web layer, not a 400 — the reader's query is fine). Falling back to the dictionary scan would be *correct*, and was the first design, but the scan reads all 129 MB per request on a public endpoint with no account behind it: an amplification factor reachable from a query parameter. A refusal costs readers one criterion for as long as a rebuild takes; a fallback costs everyone the box. The scoping matters — only searches carrying a `Name_like` term are refused, and `fts_is_current` is not even queried otherwise. **The rebuild belongs to fills, not to deploys:** the index is derived from `strings`, and only a fill adds rows there, so a code-only update cannot make it stale. Run `tools/corpus-fts-rebuild` after every fill, and once before the index first serves. It is release-blocking only for a change that alters the dictionary or the index itself. Sound only because `strings` is append-only (dropping seeds orphans dictionary rows rather than pruning them); pruning it would break the high-water mark in its one fatal direction.
- **A level's entries are ordered in the domain, not in SQL.** Storage has nothing left to sort on: `cat` is an integer enum and the display name is behind a string id numbered in *insertion order*, so `order by level_id, name_id` sorts by neither depth nor spelling. `seed_levels_sql` orders by `(e.level_id, e.cat, e.id)` purely for deterministic grouping, and `Level.of_rows` re-sorts each level's decoded entries by category then rendered name — reproducing the order the old `order by e.level, e.cat, e.name` produced. Don't reach for a SQL ordering over an interned column; it will look sorted on a small corpus and be arbitrary on a real one.
- **A seed matching a term several times must be returned once.** The per-criterion subquery yields a row per matching entry, so `distinct` is load-bearing: without it a seed with three potions appears three times and the keyset page silently shrinks.
- **A count threshold can be satisfied across levels.** Three potions on D:1, D:3 and D:6 satisfy `3x potion:haste`. Evidence is grouped by seed and totalled, reported against the shallowest contributing level — grouping by level would show `x1` and hide why the seed matched.
- **Seed order is a paging cursor, not a ranking, and the UI says so.** A seed is an opaque 64-bit key, so no order over seeds means anything to a reader; the listing carries a caption saying it is in no particular order. Keyset paging still needs a *total* order — "unordered" in SQL is arbitrary **and** unstable, so pages would repeat and skip rows — and seed is the one every row has. That order is lexicographic, not numeric, because seeds are `text` (a 64-bit seed can exceed SQLite's signed integer range), so `"1025"` sorts between `"10101"` and `"10447"`. Don't "fix" it to numeric: that costs a padded sort key or a second column to buy a counting order that implies structure the data lacks.
- **A ranking applied to a page is not a ranking.** Sorting the rows a keyset page returned reorders that page and nothing else, so page two restarts and the result reads as sorted while being wrong. `Rank.Shallowest` therefore fetches the whole matched set, ranks it, and pages by *offset*; past `Rank.sort_limit` (5000) the search is refused with a 400 rather than answered with a page-local order.
- **Depth is reach order, not generation order.** Crawl generates Temple before D:1 but a player reaches it around D:5, so ranking by `explorer.generation_order` calls Temple the shallowest thing in every seed. `Depth` uses `branch-data.h` `mindepth`. A portal's own name carries no depth, so ranking one means knowing the level its entrance sat on: format 2 records that as `seed_levels.parent_level`, and a portal ranks at its parent's depth. A level ingested before format 2 has no parent, stays unrankable and sorts last — the corpus cannot prove where it sits.
- **Search cost is linear in a term's matched rows, not in the page size — the `distinct` is nested under a sort.** `select distinct seed from entries where ...` sits in a subquery that the outer `order by seed limit 51` reads, so SQLite materialises *every* distinct seed through a temp b-tree before the limit applies (`SCAN (subquery-4)` + `USE TEMP B-TREE FOR ORDER BY`). A term matching a million seeds sorts a million rows to return 51. Measured warm on prod (1.3M, 0.34.1, `D:8`, 2026-09-05, end to end over HTTP): `wand:digging` 0.11s, `potion:haste` 1.74s, `artefact` 2.48s, three-term 3.70s, `name~Throatcutter` 7.02s — and `limit=1` costs the same as `limit=200`. The same query without `distinct` returns in 1ms against 1.40s with it. It scales with the corpus: `potion:haste` is 25ms at 10k and 1.40s at 1.3M. The `distinct` is load-bearing and must not simply be dropped (it is what keeps a seed with three matching entries from appearing three times and shrinking the keyset page); the fix is to stop nesting it under a sort. **`Seed_web.search_is_cheap` is now wrong in the direction that hurts**: it asks only whether every term is indexed and free of `min_count`, both still true of `artefact` and `Name_like`, so the two most expensive searches run inline on the Lwt scheduler and stall every concurrent request. Until the shape is fixed, detach every search. See `docs/architecture.md`.

- **Full-corpus vocabulary queries are minutes, not seconds, and are cached only per process.** `Db.distinct_criteria` (the search form's datalist) is 126s for `item_pairs_sql` plus 13.5s for `feat_names_sql` at 1.3M; `version_levels` is 9.5s (0.34.1, `D:8`, prod, 2026-09-05, warm). `Seed_web.criteria_for` caches the result per version for the life of the process, so this is a ~140s cold start paid by whichever reader triggers it after a restart — detached, but real, and linear in the corpus. The output is 10.5 KB. Precompute it at fill time rather than asking the corpus a question whose answer was known when the rows were written. `Db.seed_count` is cached the same way and for the same reason: still a covering seek, but counting 1.3M index entries is 43ms rather than the 11ms it cost at 100k, so `served_builds` reads each served build once and holds it for the life of the process instead of paying ~45ms per render. It under-reports a build being filled alongside the server until the next restart, which is acceptable only while fills stay manual.

- **Search carries no depth cap.** The `<term> by D:n` modifier was removed 2026-09-03. The corpus's own fill depth already bounds every result and D:8 is early in a game, so a per-term cap answered few real questions for what it cost: measured at 300k seeds it added ~3s to an otherwise-cheap term (`unique:Sigmund` 0.03s bare vs 3.89s with `by D:3`), and because the matched set grows linearly with the corpus it was the one search shape projected to break outright at 1M. The parser *rejects* the old syntax rather than ignoring it — silently dropping the cap would answer a different question than the one asked, and `potion:haste by D:5` otherwise parses as a sub_type matching nothing. `Depth` still ranks (`Rank.Shallowest`, floor ordering) and heat still caps via `Db.level_within_cap`. Put it back only with a design for the cost; see `docs/architecture.md`.
- **An item's unidentified appearance is not on the wire, and cannot be backfilled.** `seed_dump_sexp.lua` calls `item.name()` — `item_def::name(DESC_PLAIN)` — which respects identification state, so a potion dumps as `potion of heal wounds` and never `puce potion`. The appearance is a pure function of `subtype_rnd` and therefore seed-determined (`item-name.cc`: `potion_qualifiers[PQUAL]` × `potion_colours[PCOLOUR]`, 15 × 21; wands use `wand_secondary_string`/`wand_primary_string`, scrolls a generated label), but it is absent from every row we have. Surfacing it means a wire-format bump and a full re-fill. The wire-completeness audit considered it and **format 4 shipped without it** (soft-locked 2026-09); it is the known cost of that lock rather than an oversight, and reopening it means reopening the format. It is a real feature, not decoration: on D:1 nothing is identified, so the appearance *is* the item to the player, and "which potion is the puce one" is unanswerable without it. Emit the string rather than reconstructing it from `subtype_rnd` on the OCaml side; reconstructing duplicates crawl's tables and re-syncs them every version. This is also the one place a crawl color word legitimately belongs in the UI (`docs/style.md`, "Do not reuse crawl's item colors") — the color is a property of the appearance.

- **Nil is ambiguous by construction.** The wire format uses lua conventions: `t`/`nil` for booleans, and `nil` also for an absent field. `(artefact nil)` and an omitted `artefact` are indistinguishable and both read as "no".
- **A seed heat score is only valid within its `(version, cap)`, and an absent `seed_scores` row is "unscored", never cold.** `surprise` and the `heat_bands` cut points are population statistics over the cohort filled to at least `cap`, so a score computed at `D:8` is not comparable to one at `Swamp:4`, and the mark shown must name the cap it was computed at. A seed with no `seed_scores` row for a `(version, cap)` — not yet rescored since ingest, or ineligible at that cap — is unscored, which is a claim about the corpus; `Cold` is a claim about the seed, and conflating the two is the same error the em-dash-vs-blank convention in `views.ml` already guards against. See `docs/heat.md` and `lib/corpus/heat.mli`.
- **A version is an opaque identifier, and two versions never share seeds.** Not "different major versions" — *any* two distinct version strings. A point release can change a single vault, which changes only the seeds that draw it and only from that draw onward; those seeds are byte-identical up to the divergence and then wrong. So sampling cannot detect it: the unaffected seeds verify clean while an unknown fraction of rows are stale, and the corpus looks healthy right up until a reader's game disagrees with it. Changelogs do not close this either — an author need not realise a change consumed an RNG draw. The invariant is therefore assumed rather than checked, which matches where the crawl devs want the guarantee to end up anyway. `versions` is a table with a foreign key and no comparison order, and nothing may acquire one.
- **A fill of current stable is on loan.** Corollary of the above: a point release discards everything filled against the line it lands on, while a finished line can never be invalidated. That argues for putting depth on the finished lines, and against them — people play current stable, and a corpus is worth having in proportion to how many readers it answers for. **No sizing policy follows, and none is committed to**; it is settled per fill. What does follow: two versions' corpora may be different sizes, so nothing may compare their counts without accounting for that.
- **Storage is not the constraint on corpus size; scoring memory is.** 6,488 bytes/seed on disk, 12,328 logical, at zfs `recordsize=16K compression=lz4` measuring 1.90x (1.3M, 0.34.1, D:8, prod, 2026-09-07). These figures are a property of the dataset's ZFS settings, not the schema: the same file read 4,197 bytes/seed at 2.84x under the previous `recordsize=64K compression=zstd`, which was changed because 64K records cost 16x read amplification on the scattered reads search actually issues. Superseded: ~~4,608 bytes/seed, 2.62x at 30k~~ (2026-09-02) and ~~2.51x on a 500-seed sample~~ — small samples read pessimistic because fixed schema and index overhead dominate and the string vocabulary has not saturated, and that prediction held across a 44x growth. That puts 100M seeds at ~649 GB, which is an ordinary amount of disk to buy. Fill rate does not bound it either: 611 seeds/min wall over the 27.3-hour fill from 300k to 1.3M, 8-way, so 100M is ~114 days. **Fill cost is independent of corpus size**: −0.8% first slice to last across twelve equal slices of that fill, one version, one continuous run, 4,000 chunks, zero chunk failures (prod, 0.34.1, D:8, 2026-09-04/05) — the strongest form of the measurement, superseding the ~1.5% drift seen at 100k and the ~~4% per 10k decay~~ read off three fills of three *different versions*. What actually binds is **rescore memory**, though less than it did: at 1.3M the pass used to OOM at 29.0 GiB on a 31 GB box, because the `score_rows_sql` fold materialised all 96,524,762 rows at once. `Db.rescore` now takes `?shards` and splits that scan into N seed ranges, which brought the same pass to **9.10 GiB and 30m29s, exit 0** (`-shards 16`, 1.3M, 0.34.1, prod, 2026-09-05) with byte-identical scores — sharding bounds residency, not work. The remaining 9.10 GiB is `recompute_surprise`, which is still whole-cohort and is now the ceiling; it and `early_spell_counts` are the next things to shard. So a corpus past ~1.3M can now be both filled and scored, and the scoring phase no longer scales with corpus size at all. A large fill still logs its rate periodically rather than deriving one average from `min`/`max` at the end: an average cannot tell an asymptote from a decline. See `docs/corpus-scaling.md`.

Uniques carry artefacts roughly 19x as often as ordinary monsters, which is why unique-carried items are collected by default and ordinary monsters are skipped. The default item filter is crawl's own `item_ignore_boring`.

## SQLite pragma contract (set per-connection)

Several are **per-connection** and default off — the classic silent-breakage source. `Db.open_` sets them on every connection: `journal_mode=WAL`, `foreign_keys=ON`, `synchronous=NORMAL`, `busy_timeout=30000`, `mmap_size=1GB`. `foreign_keys` is load-bearing, not hygiene: the `seed_levels` → `entries` cascade is what makes re-ingest idempotent, and it is inert without the pragma.

**`Db.close` runs `pragma optimize`, and a corpus without `sqlite_stat1` is a performance bug.** With no statistics the planner sizes every index from built-in defaults and underestimates the *partial* ones — which is most of the search indexes — badly enough to prefer a whole-table walk to a seek: it chose `entries_seed` over `entries_search_artefact` for the listing's artefact count and walked every entry of all 200 seeds on the page, 161ms against 1.9ms. Nothing about that is visible in a query plan review, since both plans read as `SEARCH`. `pragma optimize` re-analyzes only what has gone stale, so it is free on a connection that read nothing; `tools/corpus-reindex` runs a full `analyze` for a corpus filled before this existed. A new index is not done until the planner knows its size.

## Conventions

- **Warnings are errors** in the dev profile. `just ci` is the merge gate.
- **ocamlformat** config is committed (`janestreet` profile, v0.29.0). Formatting is mechanical, not a review concern — run `just fmt`.
- **Module-per-type.** Any type carrying *operations* — beyond bare constructors: `compare`/`equal`/`sexp_of` derivers, `to_string`/`of_string`, smart constructors — lives in its own submodule named for it, type canonically `t`, with every operation defined *inside* it (`Cat.to_string`, not a top-level `cat_to_string`). `Record.Cat` and `Record.Entry` are the template. A plain data-carrier with no operations may stay inline; the rule bites the moment a function attaches to the type.
- **`open! Core`** at the top of every module, with `ppx_jane` as the preprocessor. `tyxml-htmx` is the exception, kept on the plain stdlib prelude because it is a portable library rather than app code — don't "harmonize" either direction. See `docs/architecture.md` for why it survives the choice of Dream.
- **Storage is synchronous and stays that way.** `sqlite3`/`sqlite3_utils` blocking calls, not Caqti. `Or_error` never meets `Lwt.t`; the Lwt surface is one `Lwt.return` per handler. **A query that is not index-backed must run under `Lwt_preemptive.detach`** — a blocking SQLite call stalls the whole scheduler, not just its own request. Usually a scanning query means a missing index; check that first.
- **Comments only for hard-won, non-obvious facts** — a domain constraint, a crawl quirk, a workaround whose reason isn't recoverable from the code. No docstrings restating a function's name. A file with more than two comments is a smell; flag it.
- **Interface files carry the documentation.** `.mli` files are where the domain facts are written down (see `record.mli`, `db.mli`); the `.ml` stays quiet.
- **Format all SQL with [`sqlbrook`](https://github.com/jonesmelton/sqlbrook)** — actually run the formatter (the `format-sql-chunks` skill handles SQL embedded in `.ml` files); don't hand-approximate its style. Lowercase *everything*: keywords, identifiers, column types, function names. Multi-line SQL string literals start with a leading newline so the river column survives the `{|` opener. Sole exception: trivial one-line queries touching a single column and value may stay unformatted — still lowercased. `sqlbrook` is a tool we control; note limitations and we'll extend it rather than working around them.
- **A measured number carries the conditions that produced it.** Any figure in `docs/` that came from running something against a corpus is written with its corpus size, crawl version, fill cap where one applies, and the date it was taken — inline and terse, `(100k, 0.34.1, D:8, 2026-08)`, not a footnote apparatus. The date matters most: size and version are usually recoverable from context, when a figure was taken never is. A timing additionally names the machine, or it is not comparable to anything. This applies to numbers, not to claims — "a shop's type is on its feature row" needs no provenance; "11.3% of shops override the type name" does. There is no lint and no backfill obligation: an unannotated figure is read as unverified, and the annotated set grows as we touch things. Provenance is deliberately the *only* mechanism here — a measured number never becomes a test assertion, because a failing constant gets updated rather than re-examined, and that quietly promotes a population statistic into an invariant the codebase then defends. Re-measured figures are written with the superseded value struck through, so a reader can see the correction rather than only its result.
- **XSS: escape on output, by default.** TyXML escapes by default; `Unsafe.*` is a reviewed exception. Keep JS in external `/static` files — the CSP forbids inline scripts. Item names, vault names, and monster names come from crawl and are not trusted input, but they are *data*, and they get escaped like everything else.

## Accessibility

**We do not serve screen readers.** DCSS is not playable by a screen reader user in any practical sense, so this app has no such audience and does not carry that burden: no ARIA live regions, no `scope` on `<th>`, no visually-hidden label duplication, no skip links. That is a deliberate, documented narrowing (`docs/style.md`, "Audience") — not an oversight to be helpfully corrected. Don't add them back.

What remains, because it is ordinary web competence:

- **Color is never the only signal.** Anything distinguished by color is also distinguished by text, weight, or an underline — for grayscale, print, and color vision deficiency, not for assistive technology.
- **Tabular figures in every numeric column.** Depths, coordinates, prices, and enchantments are data; they must align. Prose numbers use oldstyle. See `docs/style.md`.
- **Every interactive element is keyboard-operable with a visible focus state.** Hover is an enhancement, never the only affordance. This is the one we care most about.
- **Honor reduced-motion.** Motion is always optional.
- **Semantic elements** (`<th>`, `<label>`, `<button>`) because correct markup is the simplest markup, not because something is listening.

## Color and type

- **A listing column whose cardinality scales with fill depth must wrap, not widen.** The "others" column carries a seed's rare altars and portals: one on a `D:8` seed, seven on a `Swamp:4` one. Sized to content it pushes the table past the page and buys a horizontal scrollbar to read one column, so `.seed-list td.tags` is a wrapping flex row (the tags are an unordered set; a second line costs nothing). Flex and not an inline run because TyXML emits adjacent spans with **no whitespace between them**, which gives the line breaker no break opportunity — the cell overflows rather than wraps, and it reads as a width bug when it is a markup one. Size any such table for the deepest fill, not the default one.
- **The build is the masthead's dominant element, and no page repeats it.** The crawl version is set at display size at the top of every page with one italic sentence under it saying the site is true of that build only; the product name is small caps above it. The product name does not decide whether an answer here is right — the build does, and a seed quoted without its build is how a shared seed becomes someone else's dungeon. Consequence: page subtitles do not restate the version.
- **A note the reader learns once folds into a `<details>`; a note that changes per seed stays inline.** The listing's "how to read this table" and the exclusive-draws explanation are folded; the depth note is not. Native `<details>`, not a scripted disclosure — keyboard operable with no script, and an htmx swap cannot desynchronise it. The summary draws its own triangle, since `inline-block` drops the UA marker.
- **The copy-seed clipboard glyph is the one icon-only control, and adding a second is an argument to be had.** It earns the exception by repeating on every row (a column of the word "copy" is a column of noise), by being one of the few glyphs with a settled meaning, and by not being alone: an accessible name, a tooltip naming the seed, and a confirmation that is a check — a different shape, not just a hue. `copy.js` toggles a class rather than `textContent`, because rewriting the text would delete the svg.
- **Color marks significance, never category.** `items` is 83% of `entries`, so tinting by category paints the page and marks nothing. The six-role accent set (`--accent`, `--gold`, `--ember`, `--verdant`, `--arcane`, `--danger`) is defined in `docs/style.md`; a seventh hue means one of them is doing two jobs.
- **Do not reuse crawl's colors; tiles are usable.** Colors were investigated and rejected on evidence: item colors are a per-seed shuffle over the *unidentified* appearance (`PCOLOUR(subtype_rnd)`), and `god_colour()` collides 27 gods onto 6 terminal colors. Tiles carry no such problem and are **not** blocked — crawl packages them for reuse, and the `LICENSE` hedge covers a possible miss rather than a known encumbrance. `rltiles/` ships per-tile PNGs and plain-text name maps, and the bridge runs through crawl's own enums — `mon-data.h`/`item-prop.cc` bind enum to display name, `dc-mon.txt`/`dc-item.txt` bind enum to file — which resolves 97/99 uniques and 192/192 in-scope item types. Deriving a filename from the display name instead is the near-miss path (25/26 uniques) and is not what ships. `Tile.of_feat`/`of_unique`/`of_item` are explicit tables with a 15-entry exception list for renames crawl never propagated to its tile files. Our obligation is attribution for the slice we ship, in `static/tiles/ATTRIBUTION.md`. Reasons are in `docs/style.md`.
- **A potion or scroll tile is composited at vendor time, and its name is trimmed to match.** Crawl draws an identified consumable as a `%back` plus an `i-*.png` overlay glyph; the glyph alone is unreadable (`i-haste` is a green wing in empty space), so the 34 vendored PNGs are the two flattened together over a *fixed* back — never `PCOLOUR(subtype_rnd)`, the per-seed unidentified-appearance shuffle the color policy already rejects. Because the tile now says "potion"/"scroll", `Floor.display_name` drops that word from the name ("scroll of butterflies" → "butterflies"), keeping quantity. A tile carrying meaning alone is a deliberate exception (potions, scrolls, parchments), so the trim fires only on an exact `base_type`/`sub_type` name match, only for those classes, and only where a tile exists — all three are expect-tested. Coverage went 55.4% → 98.4% of floor rows.
- **The three parchment tiles are ours, not crawl's, and they encode tier only.** Crawl draws parchments by spell *school* over three level tiers; that was built and measured, and 132 spells collapse to 79 composites that are indistinguishable at the ~22px a tile renders at — the school is a border tint. So `tools/draw-parchments.py` draws three tiles for crawl's own tier thresholds (8+/5+/rest, falling 71/45/16) and drops school. `Spell` resolves name → level for all 132 player-book spells by joining `book-data.h` against `spl-data.h`, with no exception table — regenerate it when a version adds spells. This is the only original art in `static/tiles/`; everything else is vendored.
- **There is no mono role.** Every shipped Alegreya face carries `tnum`, so tabular data needs tabular figures, not a monospaced font. Seed numbers are sans (`--sans`), lining, tabular. Don't reintroduce `ui-monospace`.
- **Dark mode is a first-class theme.** Light tokens on bare `:root`; dark redefined under both `prefers-color-scheme` and `:root[data-theme="dark"]` so the toggle wins in both directions. `static/theme.js` loads blocking in `<head>` — a theme applied after paint flashes, and the CSP forbids the usual inline snippet.
- **Never spend a column on what crawl's name already says.** Item names carry quantity (`2 potions of haste`), enchantment (`+4 flail`), and a parchment's spell. A column for any of those prints the fact twice and blanks every row that lacks it. This is why the seed page has no `qty` column.
- **A floor takes the breakout once, as a whole** (`.floor`), not per part. Per-element breakout leaves the rail and its labels at the prose measure and the content outside it — two columns where there should be one block. See `docs/style.md`, "The seed page".
- **A floor is a ledger sheet: the part label lives in the margin, not above the content.** Each floor is a grid with a fixed left rail (`.row` → `.rail` + `.cell`); six stacked headings restart the eye six times where a rail lets it run down one column. A label repeated by a second shop is elided (`.rail.cont`), as a repeated grouping value is in a table.
- **A coordinate is printed only for what stays put.** `Record.Entry.position` returns `None` for a monster and for anything a monster carries: a monster's `x,y` is its *spawn* square and it wanders as soon as the level is entered, and a carried item is recorded on its carrier's square — the same stale number one step removed. Floor items, altars, stairs and shops keep theirs. Don't read `e.x`/`e.y` directly in a view.
