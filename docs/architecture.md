# Architecture

How the webapp gets built: the layering, the project layout it needs, the
rendering stance, and the SQLite contract. Companion to `style.md` (how it
looks). Where something here says *decided*, treat it as a constraint.

The governing ethic: **fewer moving parts, fewer failure modes.** Prefer
structure the compiler or the test suite enforces over discipline someone has to
remember.

## Platform

Settled, not under discussion:

- **OCaml 5.5**, **Dream**, **TyXML** for HTML, **htmx** for interactivity,
  **SQLite 3** for storage via the synchronous `sqlite3`/`sqlite3_utils`
  bindings.
- Single process, single SQLite file. The corpus *is* the database; there is no
  second store and no cache tier.
- **Core** is the prelude throughout (`open! Core`, `ppx_jane`).

Deliberately excluded: no query builder, no ORM, no SQL codegen, no JS build
step, no client-side framework, no CDN.

## Decided: Dream + Core + synchronous storage

The three choices interact, so they were settled together. The short version:
**keep Dream, keep Core, do not adopt Caqti.**

### Dream, despite Lwt

Dream is Lwt-only and will stay that way on any timeline that matters here
(still `1.0.0~alpha8`). Lwt is not what we would pick today — the ecosystem is
moving to Eio's direct style — but Dream does what it does very well: routing,
static serving with correct MIME types, signed cookies and sessions, CSRF,
graceful shutdown, request logging. For a read-only site those are exactly the
small correct things that are tedious and error-prone to hand-roll.

The alternatives were weighed and rejected *for now*: `cohttp-eio` or
`httpun-eio` would give direct style and drop the Lwt seam entirely, at the cost
of hand-writing routing, static serving, and session cookies. That trade is bad
while the interesting part of this project is the corpus rather than the server.

### Core, and why Lwt does not force it out

The usual argument against Core alongside Dream is monad stacking:
`Or_error.t Lwt.t` is genuinely unpleasant, and it is what pushes people off
Jane Street on Dream projects.

**It does not arise here, because the storage layer is synchronous.** The
`sqlite3` bindings are blocking C calls. A handler calls `Db.some_accessor`,
gets a value back, and wraps it once:

```
handler → Db.accessor (synchronous, Core, Or_error.t)
        → render
        → Lwt.return
```

`Or_error` never meets `Lwt.t`. The entire Lwt surface is one `Lwt.return` per
handler plus whatever Dream's own middleware needs. Core stays clean on the
inside, which is where the parser lives and where it earns its keep
(`Or_error.all`, `errorf`, and `Let_syntax` are doing real work in
`Reader.parse_line`'s field decoding).

### Not Caqti

Caqti is the piece that *would* force the collision, and it is the one to skip.

Adopting `caqti-lwt` would make the storage layer `Lwt.t`-returning, which
reintroduces `Or_error.t Lwt.t`, and would require the ingest CLI — a batch
program with no Lwt anywhere — to grow an `Lwt_main.run` or maintain a second
storage path.

What it would buy is **typed query encoders** (arity and column-type mismatches
become compile errors) and **connection pooling**. Both are real, and neither is
worth the cost yet: the `.mli` accessors already document their shapes, and the
expect tests run against a real database, so an arity bug dies in `just test`
rather than in production.

**What Caqti would *not* buy is concurrency.** `caqti-driver-sqlite3` is the
same synchronous C binding underneath; wrapping it in `Lwt.t` does not make a
query yield. Anyone reaching for Caqti to avoid blocking the scheduler is
reaching for the wrong tool — see below.

**Revisit Caqti when** any of these become true:

- the query surface passes roughly fifteen accessors, where hand-written column
  extraction starts being a real source of bugs;
- the web layer needs to write (the `ingest_jobs` queue is the likely first
  case), so transactions and pooling start
  mattering;
- sustained concurrent load makes a single connection a measured bottleneck.

**Revisited when the deepen queue landed, and still no.** The second trigger
fired — the web layer writes — so the criteria were checked rather than assumed:

- *Accessor count.* Seven query accessors, not fifteen; the other six `val`s in
  `db.mli` are connection lifecycle. The queue adds ~six, landing around
  thirteen. And the threshold was about hand-written column extraction becoming
  a bug source, which is true in exactly one place — `entry_of_row`'s nineteen
  positional reads — that a queue-shaped migration would not touch. The queue
  accessors are three to six columns each.
- *Transactions.* `Db.with_txn` already exists and `begin immediate` is one
  `exec_script`. Caqti's transaction support is the same two statements with a
  wrapper around them.
- *Pooling.* The need is **two connections, not a pool**: one reader for the web
  path, one writer for the enqueue. A pool arbitrates among many writers; there
  is one, and it runs one insert. (This is about the *write* path and stands.
  The read path grew an actual pool of its own for a different reason — see
  "The sharp edge: blocking the scheduler", below — but it is a pool of
  interchangeable read-only connections behind `Lwt_preemptive.detach`, not
  Caqti-style connection arbitration for writers, so it does not revisit this
  bullet.)
- *Concurrent load.* Not measured, and the queue's own numbers say it will not
  be — a handful of readers with at most one outstanding job each.

The cost side is unchanged and it decides it. Caqti makes storage
`Lwt.t`-returning, reintroducing `Or_error.t Lwt.t` and forcing `bin/ingest.ml`
— a batch program with no Lwt, which the generator pipes into — to grow an
`Lwt_main.run` or a second storage path. That puts the extraction pipeline in
the blast radius to buy typed encoders for six small queries and a pool of one.

If typed encoders are what's wanted, `entry_of_row` is the higher-value target
and it is addressable without Caqti.

**The accessor trigger has since fired, and the answer is still no.** `db.mli`
now has 30 `val`s, 23 of them query accessors against a threshold of fifteen —
the projection above ("landing around thirteen") was wrong, because heat,
scoring and fill-cap accessors arrived that the queue-shaped estimate did not
anticipate. What the count was a proxy for did not follow it. The threshold was
about hand-written column extraction becoming a *bug source*, and that is still
true in exactly one place: `entry_of_row`'s positional reads, which is why
`Db.Columns` exists — the column list is one value, `check_header` verifies the
prepared statement's own header on first use, and a round-trip expect test
covers what the mechanism cannot. Every accessor added since is three to six
columns wide and reads by name. So the count crossed the line while the risk it
was standing in for went *down*. Treat the fifteen as retired rather than
merely passed: the live question is whether `entry_of_row` is still the only
wide positional read, and the cost side above continues to decide the rest.

### The sharp edge: blocking the scheduler

**A synchronous SQLite call blocks the entire Lwt scheduler**, so a slow query
stalls every concurrent request — not just its own.

This *was* tolerable at 100k, where the slowest request-path query was
`seed_count` at 11ms. **It is no longer true at 1.3M**, and the warning this
section used to carry — "index-backed is a claim about the plan, not about
latency; a seek whose matched set grows with the corpus gets slower with it" —
is what actually happened. Measured warm on prod (1.3M, 0.34.1, `D:8`,
2026-09-05, server), end to end over HTTP:

| request | wall |
|---|---|
| `/0.34.1/` (seed listing) | 0.11s |
| `/0.34.1/search/help` | 0.05s |
| `has=wand:digging` (335k rows) | 0.11s |
| `has=unique:Sigmund` (425k rows) | 0.13s |
| `has=shop potion:haste` | 0.54s |
| `has=potion:haste` (2.0M rows) | 1.74s |
| `has=floor potion:haste` | 1.82s |
| `has=2x potion:haste` | 1.90s |
| `has=artefact` (3.46M rows) | 2.48s |
| `has=artefact&has=unique:Sigmund` | 3.42s |
| three-term | 3.70s |
| `has=name~Throatcutter` | 7.02s |

`seed_count` was 43ms at 1.3M, not 11ms, because counting on
`seed_fills_cohort` is linear in the corpus. It now reads a trigger-kept counter
instead (below).

**Cost tracks the term's total matched rows, not the page size.** `limit=1` and
`limit=200` cost the same (1.78s for `potion:haste`), while `wand:digging` at
6x fewer rows costs 16x less. The keyset `limit 51` never reaches the index:

```
|--CO-ROUTINE (subquery-4)
|  |--SEARCH entries USING COVERING INDEX entries_search_type (version_id=? AND base_type_id=? AND sub_type_id=? AND seed>?)
|--SCAN (subquery-4)
`--USE TEMP B-TREE FOR ORDER BY
```

The seek is covering and the `distinct` is load-bearing (see *Evidence* below),
but because `select distinct seed` sits in a subquery that the outer
`order by seed limit ?` reads, SQLite materialises **every** distinct seed
through a temp b-tree before the limit applies. So a term matching a million
seeds sorts a million rows to return 51. The same query without `distinct`
returns in 1ms against 1.40s with it — a 1400x gap, and the whole of the
end-to-end cost above.

It scales with the corpus exactly as feared: `potion:haste` costs **25ms at 10k
and 1.40s at 1.3M** (0.32.1 vs 0.34.1, same query, 2026-09-05), 56x for 130x
the seeds. Nothing here is a missing index; the index is already covering and
already ordered by seed. The fix is to stop nesting the `distinct` under a
sort — `group by seed` in the outer query, or pushing the keyset predicate and
limit inside the distinct so the index order can serve both.

**Landed 2026-09-05.** `Db.search_seeds_sql` no longer builds this shape at
all: instead of an `intersect` of per-term `distinct` subqueries wrapped in an
outer `order by ... limit`, it picks one term as the driver and renders every
other term as a correlated `exists` (or, for `min_count`, a scalar-sum
comparison) against the driver's own `entries e` row, with `distinct e.seed`
sitting directly under the same `order by e.seed limit ?` rather than under a
wrapper. There is exactly one `distinct`, and it reads off the driver index's
own order rather than materialising a separate merge first. Measured 1-4ms per
query at 1.3M against the 1.4-3.5s figures above (2026-09-05, prod); see
`Db.driver_select`, `Db.correlated_select`, `Db.driver_rank`, and
`Db.search_seeds_sql`'s own comment for the shape and the driver-choice rule
(a `min_count > 1` driver's own `group by ... having` form was fixed
2026-09-05 after landing with a full-table-scan cliff — see below). The old
`intersect` claim in that
function's comment — that SQLite merges sorted arms without a temp b-tree — was
also checked and found false while this landed: `explain query plan` showed
`TEMP B-TREE` on every arm.

**Re-measured directly against SQL, not HTTP, after the rewrite** (bypassing
the old app process, which still ran the pre-rewrite code): every shape below
is a single `explain query plan` verdict of `USING COVERING INDEX` with no
`TEMP B-TREE` and no `SCAN (subquery`, and every one but the two flagged
answered in low single-digit milliseconds warm (1.3M, 0.34.1, `D:8`,
2026-09-05, prod, direct SQL via `sqlite3 -readonly`, median of 3 warm runs):

| shape | ms | plan |
|---|---|---|
| empty listing | <1 | `USING COVERING INDEX` |
| `Item` with no position predicate (the pre-2026-09-15 union) | <1 | `USING COVERING INDEX` |
| 2-term combo | ~1 | `USING COVERING INDEX` (both arms) |
| 3-term combo | ~2-3 | `USING COVERING INDEX` (all arms) |
| `Artefact` | <1 | `USING COVERING INDEX` |
| `Unique` (`Sigmund`) | <1 | `USING COVERING INDEX` |
| `Item (_, Shop)` (`shop potion:haste`) | <1 | `USING INDEX` (not covering — see below) |
| `Item (_, Floor)` (`potion:haste`) | <1 | `USING COVERING INDEX` |
| `Feature` (`enter_shop`) | <1 | `USING COVERING INDEX` |
| worst two common terms | ~1-2 | `USING COVERING INDEX` (both arms) |
~~| `Item` with `min_count=2`, **as driver** | **>100s (timed out)** | `SEARCH e USING COVERING INDEX entries_seed (seed>?)` — no seek |~~
| `Name_like` (`Throatcutter`) | ~3400 | `SCAN strings`, `USE TEMP B-TREE FOR DISTINCT` |

Two rows changed meaning under the 2026-09-15 position change without being
re-measured. The first `Item` row is the *union* shape — no `cost` test at all
— which no term produces any more; it is kept because the multi-term rows
below it were measured against that same shape. And `Name_like` now carries the
position predicate like the other two, so `cost is null` rides along on
`entries_search_name`, which does not carry `cost` and therefore stops covering:
`name~dragon` (the worst case, 33,523 distinct names) goes 1.252s → 1.769s,
+41% (1.3M, 0.34.1, prod, 2026-09-10). Accepted rather than fixed — it is
nowhere near the 60s `SEED_SEARCH_TIMEOUT`, and adding `cost` to that index buys
a query path the posting-list store replaces.

~~Two findings this pass surfaced that the query-shape fix does not touch:~~

~~- **`min_count` as the query's driver is not merely un-cheap, it is
  catastrophic.** `driver_rank` can pick any indexed term as the driver,
  including a `min_count` one, and that term's driver clause is `seed in
  (select seed from entries where ... group by seed having sum(...) >= ?)` —
  a correlated-list subquery with no seek of its own against the outer
  `entries e`. The plan shows `SEARCH e USING COVERING INDEX entries_seed
  (seed>?)`: a scan of the entire `entries` table (135M rows at 1.3M),
  re-running the grouped subquery per candidate row. Timed out past 100
  seconds where every other shape above was sub-5ms. This is why
  `search_is_cheap` still refuses any `min_count > 1` term outright rather
  than trusting `Criterion.is_cheap` alone — see below.~~ (That guard was
  dropped when the driver was fixed, and restored 2026-09-10 in the narrower
  form described below: two or more counted terms, not one.) Out of scope to fix
  here (it is a `driver_rank`/query-builder change); reported, not patched.~~

**Fixed 2026-09-05.** `Db.driver_select` no longer renders a `min_count > 1`
driver as a membership test against a grouped subquery; it renders the driver
term's own flat `group by e.seed having sum(coalesce(e.quantity, 1)) >= ?`
directly over `entries e`, with every other term's `exists`/scalar-sum
predicate composed into the same `where` clause (row-level predicates apply
before grouping, so this is correct regardless of the outer query's shape).
`Db.driver_rank` also now biases `min_count > 1` terms to the back of the
driver preference — a term with `min_count <= 1` is always chosen as driver
over one with `min_count > 1` when both are available, since the correlated
scalar-sum form is the cheap role for a `min_count` term and the group-by-driver
form is only needed when nothing cheaper is left. Measured directly against
SQL (1.3M, 0.34.1, `D:8`, 2026-09-05, prod, median of 3 warm runs): `2x
potion:haste` alone answers in **~1ms**, `SEARCH e USING COVERING INDEX
entries_search_type`, no temp b-tree; combined with a second plain term
(`wand:digging`) it answers in **~6ms**, driver and correlated arm both
`USING COVERING INDEX`.

**Amended 2026-09-10.** `Seed_web.search_is_cheap` special-cases `min_count`
again, but on the *count* of such terms rather than their presence. Only one
term becomes the driver, and the flat group-by above is what makes a
`min_count > 1` driver cheap. A **second** counted term has no driver slot left
and falls back to the correlated scalar-sum, which the 2026-09-09 decorrelation
did not touch — that rewrite covers the `min_count <= 1` branch only. Measured
on prod (1.3M, 0.34.1, 2026-09-10, box contended by a neighbor process, so
these are pessimistic): `9x artefact` alone **0.20s**, `9x floor potion:haste`
alone **0.24s**, the two together **23.2s**. A counted term beside a plain one
stays cheap (0.21s), since the counted one takes the driver slot.

Until this landed the predicate checked only `Criterion.is_cheap`, so those
23.2 seconds ran *inline on the Lwt scheduler thread*, blocking every other
request in the process — and the search timeout could not fire there, because
an inline query never yields. That combination is what made `is_cheap`'s
accuracy a liveness property rather than a tuning knob.

- **A `Shop` criterion seeks `entries_search_shop` but is not covering.** The query's
  own `e.cost is not null` predicate re-checks `cost` against the table even
  though the partial index's `where cost is not null` already guarantees it —
  SQLite does not use a partial index's own qualifier to satisfy an identical
  predicate in the query. Harmless at this volume (sub-ms; `cost` is one
  column, one row lookup per match). **Checked whether to drop it
  (2026-09-05):** dropping it does not make `entries_search_shop` covering —
  that index simply doesn't carry `cost` as a column — it instead makes
  SQLite stop choosing `entries_search_shop` at all and fall onto the
  differently-partialed `entries_search_type` (`where sub_type_id is not
  null`), which *is* covering but carries no shop qualifier and so silently
  returns floor stock too: 335,174 rows without the predicate against 30,870
  with it, for `wand:digging` (1.3M, 0.34.1, 2026-09-05, prod). Kept.

**`Name_like` was the worst case and for a different reason:** 7.02s, of which
~3.3s was a full `SCAN strings` over the interning dictionary, now 2.99M rows
and 159 MB. Counting that table alone takes 3.03s. Interning made this criterion
cheap relative to scanning `entries` (measured 16.9s → 0.10s at 100k) and that
is still the right trade, but "scales with the vocabulary rather than the row
count" stopped being a synonym for "cheap" once the vocabulary reached three
million.

A prefix index cannot serve `like '%x%'`, so the substring-capable index this
called for is now `strings_fts`: fts5 over `strings`, external content, trigram
tokenizer (`%Wyrmbane%` 3.15s → 0.003s on a byte-exact replica of prod's
dictionary; +432 MB, ~2.7% of the database). Two properties of it are easy to
lose:

- **No `escape` clause on the indexed `like`.** fts5 declines the trigram
  optimisation when one is present and silently reverts to the scan — 0.005s
  against 1.056s for the same lookup. So the fragment's `%` and `_` reach the
  index as live wildcards, making it a superset filter, and a second escaped
  `like` against `strings` re-checks the survivors literally by primary key.
  Both stages are in `criterion_where`; dropping the second makes `100%pure`
  match `100%_pure`.
- **Staleness is silent, and is refused rather than absorbed.** An
  external-content fts5 table has no triggers unless written, so names added by
  a fill are simply absent and a search for them returns "no such seed". It
  cannot be detected from the fts table — `max(rowid)` and `count(*)` there both
  read *through* to `strings` and report the content's health. So the rebuild
  records its own high-water mark in `strings_fts_state`, and `search_seeds`
  compares it against `max(id) from strings` per search, **refusing** a
  `Name_like` term when they disagree (`Search.stale_index_tag`; a 503 with
  `Retry-After` at the web layer, since the reader's query is well-formed).

  Falling back to the dictionary scan would also be correct, and was the first
  design. It was dropped because the scan reads all 129 MB per request on a
  public endpoint with no account behind it — an amplification factor reachable
  from a query parameter, and `is_cheap` returning false only bounds scheduler
  damage, not disk. A refusal costs readers one criterion for as long as a
  rebuild takes; a fallback costs everyone the box. Only searches that carry a
  `Name_like` term are refused; `fts_is_current` is not queried otherwise.

  The cost is a step that follows every fill: `tools/corpus-fts-rebuild`, which
  is not part of ingest. It does not follow every *deploy* — the index is
  derived from `strings`, so shipping code cannot make it stale.

  A fill is not the only writer that appends there. Deepening runs the same
  ingest, and a deepened seed reaches levels the fill never saw, so it interns
  names the dictionary lacks; since currency is a high-water mark over the whole
  dictionary, one such name withdraws `name~` corpus-wide. The generator closes
  that by calling `Db.catch_up_fts` after every job — index the rows above the
  mark, advance the mark, one transaction — which is proportional to what was
  added rather than to the dictionary, and skips the `analyze` a full rebuild
  does. The full rebuild stays the right shape for a fill's millions of rows.

  It is release-blocking only once, before the index first serves, and
  afterwards for a change that alters the dictionary or the index itself.

**One path is a deliberate exception:** `Rank.Shallowest` fetches the whole
matched set rather than a page, which is why `Rank.sort_limit` caps it at 5000
and a larger match is refused with a 400 rather than answered slowly. That cap
is doing its job — `wand:digging&rank=shallowest` is 0.57s, cheaper than the
unranked `artefact`, because the cap bounds it where nothing bounds the others.

So: **a query that is not index-backed must run under
`Lwt_preemptive.detach`**, which hands it to a worker thread and lets the
scheduler keep going. If you find yourself adding a scanning query, that is
usually a missing index rather than a reason to detach — check that first.

This hazard is invisible until it bites and does not show up in single-user
testing. It applies to Caqti-over-SQLite equally; it is a property of the
driver, not of our choice to skip Caqti.

**Detach gets a query off the scheduler, not off SQLite's own lock.**
`Lwt_preemptive.detach` moves a query onto a worker thread, but if every
worker thread ran it against the same shared connection, the queries would
still serialize — SQLite serializes execution per connection. That used to be
exactly the app's shape: one reader, shared by every handler and every detach
site, so a detached search freed the scheduler but not the database. What
actually buys parallelism is `Seed_corpus.Pool` (`lib/corpus/pool.mli`): a
fixed set of read-only connections, one checked out per detached query and
returned after. sqlite3-ocaml releases the OCaml runtime lock inside
`sqlite3_step`, so N pooled connections on N preemptive worker threads
genuinely run concurrently. `bin/main.ml` sizes the pool from
`SEED_POOL_SIZE` (default 4) and raises `Lwt_preemptive`'s thread-pool cap to
match, since Lwt's own default cap (4) would otherwise throttle concurrency
back down regardless of pool size.

The dedicated `reader` connection from *Writer stance*, below, is unaffected
and still exists: cheap, inline (non-detached) queries keep using it directly,
since a sub-ms indexed seek has no reason to pay pool-checkout overhead. Only
detached queries — the ones `search_is_cheap` (`lib/web/seed_web.ml`) has
already decided are not cheap — go through the pool. See `Pool`'s `.mli` for
the two tradeoffs that come with it: checkout has no bound or timeout on the
wait (in practice absorbed by the thread-pool cap agreeing with the pool
size), and two concurrent requests on two different pooled connections can see
different snapshots if a write lands between their checkouts — accepted for a
read-mostly corpus.

**A search request is bounded even though a checkout is not.** `SEED_SEARCH_TIMEOUT`
(default 60s) races the search against a timer and answers the styled 503 when
the timer wins, so a reader is never left waiting on a query that will not
finish. Two gaps, both deliberate as of 2026-09-10 and both left for the load
test (`ops/loadtest.md`) to size:

- It does not cancel the query. sqlite3-ocaml 5.4.2 binds neither
  `sqlite3_interrupt` nor a progress handler, so the abandoned search runs to
  completion still holding its pool connection. The timeout bounds what a client
  waits for, not what a query occupies; closing this needs a C stub.
- It covers only the detached path. A search `search_is_cheap` calls cheap runs
  inline on the scheduler thread and never yields, so no Lwt timer can fire —
  which makes an `is_cheap` misjudgment the one failure the timeout cannot
  contain, and the reason that predicate's accuracy is a liveness property
  rather than a performance one.

### Consequence for the corpus library's interface

Core is the prelude on both sides of the tree, so no translation layer is
needed. But the corpus library's public interface is still the seam a future
change would pivot on — if the web layer ever moves to Eio, or storage ever
moves to Caqti, the accessors in `Db` are what gets rewritten. Keep them
returning plain values and `Or_error.t`, never anything Lwt-flavoured. Nothing
in `lib/corpus` should mention Lwt or Dream.

## Layout

One dune project at the root. `ingest/` used to be a nested project with its own
`dune-project`, `justfile`, and switch; it was hoisted so there is one opam
switch, one `just ci` gate, and so the web layer can depend on the corpus **as a
library** rather than shelling out to a binary or re-implementing the schema.
The corpus's typed accessors are the thing the web layer most wants.

```
/dune-project        packages: seed_corpus, tyxml-htmx
/justfile            build, test, fmt, ci — everything OCaml
/Makefile            the crawl provisioning/dump side
/schema.sql
/lib/corpus/         the seed_corpus library: domain + storage (below)
/lib/htmx/           tyxml-htmx, vendored
/lib/web/            Dream handlers + TyXML views
/bin/ingest.ml       the ingest CLI
/bin/main.ml         the server
/static/             style.css, htmx.min.js, type/alegreya/*.woff2
/tools/              explore, provision, corpus-fill — the crawl-side scripts
/scripts/            the lua dumpers, run inside crawl's sandbox
/test/               inline expect tests
```

Two build systems, one boundary: **`make` owns the crawl side** — provisioning
worktrees, running the lua dumpers, rendering markdown reports. **`just` owns
everything OCaml.** They meet at the database file and nowhere else.

`bin/` holds OCaml executables only; the hand-written shell scripts live in
`tools/` so dune's build directory and hand-maintained scripts don't share a
directory. Both scripts resolve the repo root as
`dirname($BASH_SOURCE)/..`, so they must stay one level below the root.

### Splitting the corpus library

`lib/corpus` is currently domain and storage fused in one dune library.
`record.ml`/`reader.ml` are the pure half; `db.ml` is storage; `cli.ml` is the
CLI surface. That is fine at this size, but respect the boundary *within* the
library — nothing in `record.ml` or `reader.ml` may reach for `Sqlite3`. Split
into separate dune libraries when the query surface grows enough that the
dependency direction needs enforcing rather than observing.

## Layering

Three layers, with a hard rule about which way dependencies point: **web →
domain → storage**, never the reverse, and the domain core depends on nothing
with I/O.

### Domain (pure)

No SQLite, no Dream. Values and functions.

- **`Record`** — the parsed catalog record and its entries; the `Cat` vocabulary.
- **`Reader`** — `#SEED#` line → `Record.t`. The `format` check lives here, at
  the parse boundary, so a serializer change fails loudly rather than writing
  nulls.
- **`Search`** — what it means for a seed to "contain" something, and how
  several such questions compose. See *The search vocabulary* below.
- **`Depth`** — how early a level is reached, which is what "shallowest first"
  ranking and heat's depth cap both ask.
- **`Floor`** — a level's flat entry list split into the things a reader
  actually asks of it separately, plus its standing facts, the branch index and
  the order the seed's floors are read in. See *A floor is a ledger sheet*
  below.
- **`Exclusion`** — the seven mutually exclusive item groups and which member a
  seed drew. See *The exclusive draws* below.

Keeping this layer I/O-free is what makes exhaustive expect-testing tractable.
The parser is the highest-stakes code in the repo — it is the only thing standing
between a truncated crawl line and a corrupt corpus.

### Storage (SQL)

All SQL lives here, behind typed accessors. Nothing outside this layer issues
SQL; handlers never see a query string.

- **Hand-written parameterized SQL only.** No query builder, no codegen, no
  string-built SQL anywhere. The load-bearing queries — set containment across
  seeds, partial-index artefact lookups, the idempotent re-ingest — are exactly
  the queries an abstraction layer fights.
- **`Db.query` is for inspection, not features.** It returns pipe-joined strings
  and exists for poking at a corpus from the outside. Anything structured gets
  its own typed accessor.
- **Every query is version-scoped.** A seed number without a version is not a
  question. The scoping argument is *required*, not defaulted, so it cannot be
  forgotten. A new
  accessor that takes a seed but not a version is a bug.

### Web (Dream + TyXML)

Thin. A handler validates the request, calls domain/storage, renders. No business
logic, no SQL.

- **The build is in the path, and the served set is closed.** Every address is
  `/<version>/…`, because a seed number without a build is not an address — a
  query parameter makes the build look optional and gives a bare `/seed/123`
  a silent default, which answers a question the reader did not ask. `Served`
  (in `lib/web`) is the closed set of builds this deployment routes to, and it
  is deliberately a *different type* from `Query.Version`: the latter is any
  build the corpus could hold or a generator could build, and `bin/deepen`
  discovers those by listing `builds/` on disk, so that set is open by
  construction. Fusing the two would break the generator.

  The served set is compiled in rather than read from `versions`, because
  adding a build is already a manual, code-touching job — a test ingest, a
  decision about renamed items, a new `current`. A lookup would let the router
  serve a build the code has not been taught about, which is the failure mode
  rather than the feature; the price is that a new corpus is not served until
  the binary is rebuilt. Closing the set is also what makes an unknown build a
  **404 at the routing boundary** (`with_version`) instead of a listing that
  renders empty: "no such build" and "no seeds on that build" are different
  answers. `/` redirects to `Served.current`, a hand-set editorial claim about
  which build a reader should see first — the corpus holds nothing that could
  decide it.

  Because the set is closed and small, the masthead renders it as a **picker**:
  a native `<details>` whose summary is the build at display size and whose
  panel lists every `Served.all` entry with its seed count. Native `<details>`
  and links, so it is keyboard-operable with no script — which it must be, since
  the CSP forbids inline scripts and a `<select>` that navigates on change would
  need another `/static` file and a listener to do the same job. The current
  build is marked by weight and the word "showing", never by colour alone.

  The counts come from one `Db.seed_count` per served build, read per render
  from `seed_fill_counts`, a per-version counter kept by trigger on
  `seed_fills`. Counting was a covering seek on `seed_fills_cohort`, and a seek
  that *counts* is linear in what it counts: ~~11ms for the full 100k~~
  (2026-08-29, M-series laptop), then 43ms for the full 1.3M (0.34.1, `D:8`,
  2026-09-05, server). So the count was cached per process, which under-reported
  a build being filled alongside the server until restart.

  A stored count was first rejected as a second source of truth that ingest,
  deepen and the truncated-fill repair would each have to keep honest, for a
  number only the picker read. Two things changed that (2026-09-16). The search
  store's currency check needs the same count on every store-served search, at
  88ms per search at 1.3M. And a trigger keeps the counter honest without any
  writer knowing about it: a fill's insert and a repair's delete each fire one,
  and a deepen's `on conflict do update` fires neither. The one write that
  would drift it, `insert or replace`, is not used on `seed_fills`, and
  `tools/corpus-check` compares the counter with `count(*)`. The read is a
  primary-key lookup, 16-22µs at 10k and flat in corpus size, so the cache is
  gone and the count is exact during a fill. A build whose count errors is
  dropped from the panel rather than shown as zero: a corpus that failed to
  answer is not a corpus with no seeds.

  Every emitted link carries the build, including the masthead. A link that
  falls back to `/` moves the reader to `current` and lands them on a page that
  looks correct and describes a different dungeon; `test_served.ml` renders the
  pages and prints every `href`/`action`/`hx-*` target to hold that down.
- Handlers come in **page** and **fragment** flavours. A fragment handler returns
  the partial HTML htmx swaps in; a page handler wraps the same fragment in the
  document chrome. Both call the same view functions, so a seed card renders
  identically whether it arrives by full page load or by swap.
- Mutations, if any appear, route through a single CSRF-enforcing wrapper — not
  scattered ad-hoc handlers. Note that this app is mostly *read-only over a
  corpus*; if the ingest queue (`ingest_jobs`) gets a web trigger, that is the
  first real mutation and it needs the wrapper.

### A floor is a ledger sheet, not one table

`Db.seed_levels` returns each level as one flat `Record.Entry.t list`, because
that is the shape the `entries` table has. The seed page does **not** render it
that way. `Floor.of_level` splits it, and each part gets a layout of its own:

| Part | Shape | Why |
| --- | --- | --- |
| uniques | one line each, with what they carry | everything kept is a unique, so the label says it once |
| stairs and portals | line with a flag | a stair is a route; it is the thing a reader plans around |
| altars | field of names | a set, not a sequence of positioned things |
| notable | line with a flag | artefacts, the enchanted, and books that hide a spell set — the reason to visit |
| also here | a sentence | fourteen consumables are a sentence, not fourteen rows |
| shops | a bill, with a total | stock only means anything read with its shop and its prices |

**That order is the reading order**, and it is the order a player meets a floor:
what can kill you, then where you can go, then what you can pick up, then what
you can buy.

Two structural facts carry the design:

- **The part label lives in the margin, not above the content.** Each floor is a
  grid with a fixed left rail; the label sits in the rail beside its part. Six
  stacked headings restart the eye six times, where a rail lets it run down one
  column. A label repeated by a second shop is elided, exactly as a repeated
  grouping value is in a table.
- **Items divide in two rather than sorting into one run.** `notable` is
  artefacts, the enchanted, and the books carrying a spell set their name does
  not state; `sundries` is the rest. This is the same significance ranking the
  old single ordered list used, given structure instead of a left-edge stripe —
  a floor of sixteen items where four matter should not ask a reader to scan
  sixteen rows to find them. The book case is the one that is not an item
  property: a named book carries no artefact flag and no enchantment, but its
  contents are as much the reason to take it as an artefact's properties, and
  nothing in "Fen Folio" says what is in it. A parchment's single spell *is* its
  name minus the prefix, so it states its own contents and stays ordinary.

Three consequences worth knowing:

- **A coordinate is printed only for what stays put.** `Record.Entry.position`
  returns `None` for a monster and for anything a monster carries, whatever `x`
  and `y` hold: a monster's position is where it spawned and it moves the moment
  the level is entered, and a carried item is recorded on its carrier's square,
  so it is the same stale number one step removed. Floor items, altars, stairs
  and shops do not move and keep theirs.
- **A shop's stock is joined to its shop by position.** Stock is flattened into
  `entries` beside floor items (`cost` is the only discriminator) and carries the
  shop's own `(x, y)` rather than a reference. Two shops cannot share a square
  and a priced item can only be inside the shop whose square it shares, so the
  join is exact rather than heuristic. A shop carries its own `total` and
  `artefacts` count, because twenty artefacts and twenty potions are both
  "20 items" — one corpus shop holds 20 artefacts worth 81,470 gold.
- **A parchment's spell is not printed as a note.** It is the item's own name
  minus the prefix, so the note set `Sandblast` twice on one line. A book's set
  is not recoverable from its name and is still shown.

`Floor.standing_facts` is the one derived line: the short phrases a reader wants
before a floor's contents — what is rare, what it commits you to, what it costs.
It is empty when there is nothing to say, which is itself the answer. Artefacts
report how many are for sale, since a floor's worth of artefacts behind a shop's
prices is a different proposition from the same number on the ground.

**The corpus cannot tell an unrand from a randart** — both are `artefact = 1`,
and nothing else separates them — so the facts line says "artefact" for both.
Distinguishing them is a question for the item-significance model, not a
name-shape heuristic bolted on here.

### The branch index

Above the floors, `Floor.entrances` collects every `enter_*` feature across the
seed into one list: the branch stairs and portal entrances, with the D-level each
stands on and a timed portal's turn count.

This is the first question asked of a seed — is there a Lair stair, how deep is
the Temple, did a Sewer spawn — and it was previously one row buried in a
different table on each of eight levels.

- **Ordered by `Depth.of_level_with_parent`, not by name**, so it reads as a
  route: D:2 before D:7 whatever the branches are called.
- **The branch name is derived from the feat**, not matched against a table, so a
  portal `Depth` has never heard of still appears. That matters today:
  `enter_necropolis` and `enter_abyss` are both in the corpus and neither is in
  `Depth.portals`, because neither is generated as a level.
- **Shops are excluded.** A shop is a room on the level, not a way off it, and at
  ~2 per seed it would swamp the entries that matter.

`Floor.Entrance.branch_of_feat` is the same derivation exposed on its own, so a
stairs-and-portals line can name its destination. Crawl names most portal
entrances for their appearance rather than their destination —
`enter_ossuary` is "a sand-covered staircase" — so without it the page asks a
reader to have crawl's feature vocabulary memorised.

### Reach order

`Floor.in_reach_order` places each level directly after the floor its entrance
stands on. Storage returns levels ordered by name (`Db.seed_level_list_sql`),
which puts every portal and the Temple after D:8, so a Sewer off D:3 is read
eight floors from the drain leading to it.

The parent is `Level.parent_level` where format 2 recorded one, which covers
portals. **A branch level records none** — the Temple is not a portal, so
nothing on the wire says which floor its stair is on — and it is recovered from
the entrance instead: the level whose entries hold the matching `enter_*`
feature. `Level.parent_of` already does that derivation but gates it on
`Depth.is_portal`, so it never fires for the Temple.

A level with no recoverable parent, or one whose parent this seed does not hold,
keeps its storage position. Placement is on evidence, never on a guess. The
traversal is depth-first, so a portal that itself holds an entrance keeps its own
child beneath it rather than beside it, and a visited set makes the acyclicity
structural rather than assumed.

### The exclusive draws

Crawl draws some items once per game from a group whose members exclude one
another: a seed that can generate a wand of charming cannot generate a wand of
paralysis anywhere, at any depth. `Exclusion.draws` reports, per group, which
member this seed drew.

Measured over the 100k-seed 0.34.1 corpus, and re-verified on the current one:
**zero seeds hold two members of any of the seven groups.** The pick is uniform
within a group. That makes a seed's draw seven independent axes of stable
per-seed identity — the comparison feature `docs/schema-decisions.md`
declined to make a *storage* change, since the group is already derivable from
the `sub_type` those rows carry.

- **Derived, not stored.** Encoding it would add a column beside 318,882 rows
  that each carry level, position and shop cost, replacing nothing.
- **Keyed on `(base_type, sub_type)`.** A `sub_type` is a bare word another base
  type may reuse; a potion of paralysis is not the wand group's business.
- **Shop stock and a unique's inventory both count.** The exclusion is on
  generation, not on reachability.
- **`Unseen` is not exclusion.** A group with no member found is the common case,
  because a seed can simply generate no member this shallow. Only a drawn member
  is evidence, and the page says so.
- **`Conflict` exists so a broken model fails visibly.** If exclusivity ever
  stops holding, returning one arbitrary member of a contradicting pair would
  launder that into a page that reads as ordinary.

## The search vocabulary

"Which seeds have X" is the product question, and `lib/corpus/search.ml` is
where it is answered in the abstract. Five decisions shape everything else.

**A criterion is a type, not a name.** `entries.name` is a display string
carrying enchantment, brand and artefact epithet (`+3 greatsling "Punk" {acid,
rCorr}`). Over a 2000-seed corpus it has 7562 distinct values against 420 for
`(base_type, sub_type)`, and nearly every artefact name is unique — so exact
name matching finds one seed or none. The type pair is the stable vocabulary and
`Criterion.Item` is keyed on it. `sub_type` is the bare type (`haste`, not
`potion of haste`); `base_type` disambiguates it.

`Name_like` remains as the escape hatch, because an unrand is identifiable only
by a substring of its display name (`Throatcutter` under a varying `+N`
prefix). It was the one criterion no index could serve; interning changed that.
The `like` now runs over the `strings` dictionary and yields ids that
`entries_search_name` seeks on, so its cost scales with the corpus's vocabulary
rather than its row count. See *Covering is the whole game* below for the
measurement, and `search.mli` for its provenance.

It narrowed in the same move, and that is the price of the speed. A name is
stored only where `Display_name` cannot rebuild one, so `Name_like` reaches the
irreducible tail — artefacts, unrands, monsters — and no longer matches a name
the columns imply: `name~potion of haste` found 274 seeds before interning and
none after (400 seeds, 0.34.1, `D:8`, 2026-08-28). `Item` is the criterion for
that question and always was the better one.

`partition_terms` and `Criterion.is_indexed` survive the change and now answer
`true` for everything. They are kept because the distinction is real and a
future criterion could reintroduce it — reopening the seam costs more than
leaving it open.

**Where an item sits is part of the criterion, not a modifier on it.** A price
is the only thing separating shop stock from floor loot (`cost` present), and
`Criterion.position` — `Floor` or `Shop` — is a *field* on `Item`, `Name_like`
and `Props` rather than a constructor beside them. The two values partition the
union totally: measured 2388 + 282 = 2670 rows for `wand:digging` (10k seeds,
0.34.1, D:8, 2026-09-01). It is a field and not a constructor per combination
because that grows multiplicatively, and `Props` was the third criterion to want
one; `Shop_item` and `Floor_item` were deleted for it (2026-09-15).

**`Floor` is the default** as of the same change: `potion:haste` is floor-only,
`shop ` is the per-term opt-in, `floor ` is accepted, redundant and never
emitted. The union has no spelling left, which is a real loss taken
deliberately — "is it there" and "can I afford it" are different questions and
the second is the rarer one. There is no `anywhere ` prefix; if one is ever
wanted, `docs/plans/shop-exclusion-default.md` records the evidence problem it
brings with it (`group_term_hits` collapses a term to one hit per seed, so the
shop share of a union count would be exactly what the reader opted into and
could not see).

The partition is what makes this a criterion rather than a filter, because it
reaches `min_count`: two potions on the floor and a third behind a counter
satisfy neither `3x potion:haste` nor `3x shop potion:haste`, so a floor search
is not a union result with the shop hits struck off and can match strictly
fewer seeds (2,435 → 2,142 seeds, 12% of matches lost, 10k local, 0.34.1,
2026-09-10). A search-wide "exclude shops" toggle is still rejected on exactly
that ground, and the changed default is not one: a toggle makes one term text
denote different sets depending on state outside the term, where `potion:haste`
denotes floor-only always, fixed by the term text alone with nothing outside it
consulted.

`Artefact` is the one criterion still holding the union, and it takes no
position at all — `shop artefact` is an error, not a narrowing. A generic
artefact search is a weak question and qualifying it would need parse syntax it
does not have (`artefact` carries no colon for a prefix to lead). The
inconsistency is visible rather than theoretical, because artefacts are where
shop stock concentrates: 42.7% of artefact entries sit in a shop against 14.4%
of named entries (1.3M, 0.34.1, prod, 2026-09-10). The help text states it for
that reason — an asymmetry that is explained is a decision, one that is
discovered is a bug. `name~` breaks the symmetry the other way and has no shop
form: gold binds the early game, so an unrand you can afford in a shop is one
you could have afforded off the floor.

`cost is null` used to fall outside the covering index, so the floor arm read
the index for the seek and the table for the test — a shape that read as cheap
at 10k seeds (measured at parity with the unqualified form, 20ms end-to-end
over HTTP, 10k seeds, 0.34.1, 2026-09-01) and was not: at 300k it cost 4.65s
against 0.08s for the bare `Item` shape (0.34.1, 2026-09-03, warm, prod).
`entries_search_type` now carries `cost` as its trailing column, so the test is
covering and the criterion is volume-bound like the other common-row ones. That
holds for `Item` only: `entries_search_name` carries no `cost`, so `Name_like`
pays the non-covering shape now that it takes a position too — the measurement
is under *The sharp edge: blocking the scheduler*. See `db.ml`'s
`position_where` and the index's comment in `schema.sql`.

**A property set is one criterion, because the properties share an item.**
`entry_props` holds one row per artefact property per item, and "a staff with
Conj and Alch" is a question about one object. Expressed as conjunction it would
not be: a Conj ring on D:3 beside an Alch staff on D:5 satisfies the seed-level
reading, and the evidence rendering cannot say so — `hit_line` renders name,
count and level, so two unrelated items are two indistinguishable lines. That is
the failure the `by D:n` removal was about, one level up. So `Props` carries the
whole set and correlates every `exists` on the same `entries.id`.

The base type folds in for the same reason. `item:staff` beside `props:Conj,Alch`
is two seed-scoped terms and leaks the same way, and it is not a rare leak:
school enhancers roll off-staff about 45% of the time (staff 223, armour 170,
jewellery 15 across the ten school properties, 10k local corpus, 0.34.1) — so
`Fire`+`rF` lands on armour in 12 seeds against staves in 4.

Two things are deliberately not in the grammar. There is **no count**: two of a
property is not a more interesting seed than one, and the two ways it could go
wrong are both dull (every build holds several `rF+`; nobody wants two `rMut`).
There is **no strength**, so a bare property means "at least 1" — which is also
the grouping mechanism, since `props:rF` covering `rF+` and `rF++` is just the
floor, and `entry_props.value` runs negative on about one row in five of `Str`,
`rF`, `Slay` and their kin. A resistance you asked for is not answered by a
vulnerability.

**Drawbacks are excluded on domain grounds, not technical ones.** `*Noise`,
`^Contam`, `-Tele`, `Bane` and the rest are not searchable because nobody picks
a seed for a drawback: whether one is worth living with is decided once you hold
the item, and it changes what you carry rather than what you play. This is
unlike the uniques dropped 2026-09-10, where the wanted question was the
negative one and search has no negation — there is no missing operator here and
nothing waiting on one. `*Rage` is the exception and stays, being a build to
commit to. `nupgr` is excluded on a third ground: `ARTP_NO_UPGRADE` is an engine
flag on self-upgrading unrands, never shown to a player. The sigils (`*`, `^`,
`-`) are how the list is derived, not why — see `Search.Prop`.

The vocabulary is listed in code rather than read from the corpus. It is closed
and small (55 names), the parse boundary is synchronous, and an unknown property
has to be *rejected*: a property search that runs and matches nothing reports
that the build holds no such artefact, which is false and indistinguishable from
true. The concrete case is a hand-typed `props:Conj+Alch` — `Dream.queries`
decodes a raw `+` to a space, so it arrives as one property named `Conj Alch`.
That is also why the separator is a comma: `+Blink` and `+Inv` are property
names, so a `+` separator would spell a set holding one as `Conj++Blink`.

**Conjunction is a flat query, one driver plus correlated predicates.** Each
criterion is one covering index seek; the query used to combine them with
`intersect`, but that turned out not to merge them for free — see *The sharp
edge*, below, for why and what replaced it. What survives from that shape is
the reason the criteria are all-or-nothing predicates rather than scored
contributions: the moment a criterion is partial, the merge stops being a set
operation. Disjunction is deliberately absent for the same reason — "a shop or
Sigmund" is two searches to compare, not one query.

**Ranking is `Seed` by default, and that is not laziness.** Seed order is the
corpus's own order, so it pages by keyset and stays flat at a hundred thousand
seeds.

`Shallowest` — order by how early the evidence sits, which is the question a
player actually asks — abandons that order, and the consequence is bigger than
it first looks: **a ranking applied to a page is not a ranking.** Sorting the
fifty rows a keyset page returned reorders those fifty and nothing else, so page
two restarts from a deeper seed and the result reads as sorted while being
wrong. So the whole matched set is fetched, ranked, and sliced, and the cursor
becomes an *offset* into the ranked order rather than a seed.

That only works while the matched set fits in hand, which is what
`Rank.sort_limit` (5000) bounds. Past it the search is **refused** — a 400 that
says to add a term or rank by seed — because an honest refusal beats an order
that silently only holds within one page.

### The term cap and the suggestion list

A search is a conjunction, so more terms only ever shrink the result — but the
cost of building the per-term subqueries grows with the count, and `has=` is a
repeated query parameter that anything can send. `Params.max_terms` (10) is the
ceiling, applied in `Params.boxes` (and `Params.terms_of_strings`, which the
bench and equivalence tools use) before any term is parsed. It is a
constant rather than configuration because no real question needs an eleventh
term.

The form's term boxes carry a `<datalist>` of the build's own vocabulary: the
`base:sub` item pairs and the bare feature names its entries actually hold,
which is exactly the token shape a term takes. It is version-scoped like every
other question, and `Db.distinct_criteria` is the accessor. The measurement that
decided the shape: 427 item pairs and 52 feature names on the largest build,
about 10.5 KB of text (0.34.1, D:8, 2026-09) — small enough that a
flat list beats server-side filtering, which would need a round trip per
keystroke to save 25 KB once. The *output* is small; the query that produces it
is not, and the gap has widened sharply — see below.

The datalist suggests tokens; it does not teach the grammar. That is
`/<version>/search/help` (`Views.search_help`), the one page in the app that
reads no corpus — but it is still version-scoped, and every example on it is a
link into a real search on the build being read rather than inert syntax. Both
halves are deliberate: an example naming an item a build does not generate
would demonstrate the exact mistake the path-scoped address exists to prevent,
and a reader learns what `3x shop potion:haste` means faster by
following it than by parsing a grammar. It carries the ordinary masthead, so
`served_builds` is the one query the handler does run.

That query is a temp b-tree over every entry of the build, so it is not a
per-render cost: `Seed_web.criteria_for` runs it once per process per version
under `Lwt_preemptive.detach` and caches the list. The corpus only grows by
fill, so a stale cache is a missing suggestion, never a wrong one, and a restart
picks up the difference. The htmx partial swap skips it entirely — the datalist
sits outside the swapped results, so re-sending it would be dead weight on every
keystroke.

**The once-per-process caveat is now load-bearing rather than a nicety.**
Measured on the 1.3M corpus (0.34.1, `D:8`, 2026-09-05, server, warm):

| query | wall |
|---|---|
| `item_pairs_sql` | **126s** |
| `feat_names_sql` | 13.5s |
| `version_levels` (`levels_sql`) | 9.5s |

So building the datalist costs ~140s, and it grows linearly — at 10M it is ~18
minutes.

**No reader waits for it.** As of 2026-09-10 `criteria_for` is not an Lwt
function: a cache hit returns the options, and a miss returns `None` and starts
the scan in the background. The page renders without suggestions until it lands,
which the views already supported — `suggestions` is an option, and `None` drops
both the input's `list` attribute and the `<datalist>` element. A second table,
`criteria_pending`, keyed the same way, is what keeps concurrent cold requests
from each launching their own scan: without it, four cold searches start four
140s scans and occupy the entire pool. It is cleared whether the scan succeeded
or failed, so a failure is retried by the next miss rather than wedging that
version out of ever having a datalist.

Warming the cache at startup was the alternative and was rejected: it only
removes the cost if startup blocks on it, which turns every deploy into a ~140s
outage — precisely the case that mattered, a deploy during a traffic spike.
Precomputing the vocabulary into a table was the better fix, and the search
store's catalog turned out to be that table. When the store is current,
`Db.distinct_criteria` reads its item pairs from `search_criteria`'s floor and
shop item rows, unioned with the deep cohort's own entries, since a deepened
level can hold a pair the build never saw (`Search_index.item_pairs`). The
output is identical: 427 pairs, 340ms for the scan against 1ms for the catalog
(10,000 seeds, 0.34.1, local, 2026-09-16), and the catalog's cost depends on
the vocabulary and the cohort, not the corpus. A stale store, or a cohort past
the overlay cap, falls back to `item_pairs_sql`, so the background scan and the
single-flight guard stay, as the fallback's protection.

Unrands are in the list too, and they arrive by a different route. They cannot
be observed: the stored name carries a varying enchantment prefix and
inscription (`+7 Throatcutter {drain, coup de grace}`), so the bare name is not
a column, and an unrand nobody has rolled has no row at all — 95 of 0.34.1's
112 appear in the corpus. Frequency does not separate them from randarts
either, since randart books collide on shared title words (`Octavo of
Retrieval`, `Almanac of Retrieval`) at the same counts a rare unrand sits at.

So the roster is *declared*, from crawl's own `art-data.txt` filtered to the
entries that enter the item pool, checked in per version under
`data/unrand-names/` by `tools/unrand-roster` and embedded at build time by the
rule in `lib/corpus/dune` — the webapp must not need a provisioned build tree.
It is per version because the roster moves: 110, 113 and 112 names across the
three builds served, with `sword of Power` retired and `crown of vainglory`
added between the ends. Suggesting an unrand no seed has yet is correct; it
exists in the build, and searching for it is a fair question with an empty
answer. Regenerate on a version bump.

Unrand options carry their `name~` prefix, because that is the only criterion
that reaches them and the prefixed form is what round-trips as a link — a bare
name would parse as an item and fail.

The list does not replace the help text. It covers the *nouns*; the affixes
(`3x`, `shop `, `unique:`) are grammar a datalist cannot express,
and `name~` is only pre-filled for the unrands.

### A rejected search hands the form back

Every 400 from the search route re-renders the search page with each box as
the reader typed it, a note under each box that failed, and a `role="alert"`
summary whose entries link to those boxes; each failing input carries
`aria-invalid` and an `aria-describedby` pointing at its note. The results are
emptied, since the last query's results under a query that did not run read as
its answer. A bad `limit` or `rank`, too many terms, and a set too broad to rank
land in the same summary. Other routes keep the bare 400 page. htmx 4 swaps a
4xx like a 2xx (its `noSwap` is 204 and 304 only), so a scripted search gets the
fragment shape: the form out of band, as on success.

A bare word (no colon, no `name~`) is looked up before it is refused, because
unprefixed words were a tenth of human search terms and fell into three intents:
a name fragment (`hat`, `spectral`), a bare base type (`talisman`), and a
misspelled sub type (`aquirement`). `Params.box` resolves it against the item
pairs and the property list. One exact match runs, and the box shows the term it
became, with a line above the results saying so. Several exact matches, or a
near miss (a whole word of a sub type, or one edit or transposition away from
one), run nothing and are offered as links; with no match the offer is `name~<word>`,
never run automatically, because `name~` is the one criterion whose cost the
vocabulary does not bound. The vocabulary is the store's catalog, read
synchronously (`Db.catalog_item_pairs`, ~850 rows, no cohort), falling back to
the datalist cache; with neither, nothing resolves and the reader is told the
syntax. A word containing `_` keeps the feature rejection.

### Depth is reach order, not generation order

Crawl's `explorer.generation_order` puts Temple *first*, because Temple is
generated before D:1. A player reaches it around D:5. Ranking results by
generation index would report the Temple's altars as the shallowest thing in
every seed, which is exactly backwards, so `Depth` encodes reach order from
crawl's own `branch-data.h` `mindepth` values instead.

Portals are the one place depth is per-seed rather than per-name. A portal
hangs off the level holding its entrance, so `Sewer` alone implies no depth.
Format 2 records the entrance's level as `seed_levels.parent_level`, and a
portal ranks at its parent's depth.

A level ingested before format 2 has no parent, stays unrankable and sorts
last: the corpus cannot prove where it sits.

**Search carries no depth cap.** A `<term> by D:n` modifier existed and was
removed (2026-09-03): the corpus's own fill depth already bounds every result,
and D:8 is early enough in a game that a further cap answered few real
questions. It cost a two-clause filter — an `in` list over qualifying level
names plus a `portal_exclusion` correlating per seed — and measured at 300k
seeds it added ~3s to an otherwise-cheap term (`unique:Sigmund` 0.03s bare
against 3.89s with `by D:3`; a shop item 0.02s against 2.95s; an artefact 0.10s
against 4.39s). Since the matched set grows linearly with the corpus, that was
the one search shape projected to break outright at 1M. The parser rejects the
old syntax rather than ignoring it, so a stale bookmark gets an error instead of
a quietly different answer. `Depth` still ranks (`Rank.Shallowest`, floor
ordering) and heat still caps — `Db.level_within_cap` is that path and is
unaffected.

### Evidence, and the three traps in producing it

A match carries the evidence that satisfied it, per term. Three things there are
easy to get wrong and were:

- **A seed matching a term several times must appear once.** The per-criterion
  subquery yields a row per matching entry, so without `distinct` a seed with
  three potions is returned three times — duplicating it in the listing and
  silently shrinking the keyset page.
- **A count threshold can be met across levels.** Three potions on D:1, D:3 and
  D:6 satisfy `3x potion:haste`. Evidence grouped by level would report the
  shallowest level's share alone (`x1`) and leave the reader unable to see why
  the seed matched. Evidence is grouped by seed, totalled, and reported against
  the shallowest contributing level.
- **The total belongs to the term, not to the item named beside it.** Grouping
  by seed is right, but it makes `name` an *exemplar* — the shallowest matching
  item — while `count` spans every matching item on the seed. For
  `3x potion:haste` those are the same fact. For `artefact` they are not: a seed
  with sixteen unrelated randarts rendered as `+8 storm bow {elec, penet} ×16`,
  claiming sixteen of one bow. A hit therefore carries `distinct`, the number of
  differently-named items the total spans, and the view quantifies the exemplar
  only when `distinct = 1`; otherwise it states the total separately
  (`· 16 artefacts`, falling back to `matches` for a criterion naming no
  category — see `Criterion.plural_noun`).

### Covering is the whole game

Every search index ends with the columns a term *reads*, not just the ones it
seeks on — `seed`, then `level` and `quantity`. That suffix is not padding. A
term reporting evidence has to read `level`, and one carrying a count threshold
has to read `quantity`; if the index does not carry them the seek is still
index-driven but every matching row costs a random table lookup. A common term
matches
millions of rows.

Measured over the finished 100k-seed corpus (15.3M entries):

| query | uncovered | covered |
|---|---|---|
| `altar_trog by D:3` (since removed) | 7.6s | 8ms |
| `2x potion:haste` | 8.0s | 21ms |
| the three-term search below | 16.2s | 0.7s |

The covered column no longer holds at 1.3M — see *The blocking rule* below for
the current figures. The *ratio* is what this table is for and it stands:
covering is still the difference between an index-driven query and a table
lookup per row. It is just no longer sufficient on its own, because the temp
b-tree under *The sharp edge* costs the same whether the index covers or not.

So when adding a criterion, check what its SQL *reads* as well as what it seeks
on, and put the read columns in the index. `explain query plan` saying `SEARCH …
USING INDEX` is not good enough — it has to say **`USING COVERING INDEX`**.

The same trap has a second form: a redundant predicate outside the index defeats
covering just as thoroughly. `Criterion.Unique` originally tested
`cat = 'monsters' and unique_mons = 1`, but `unique_mons = 1` already implies the
first (verified: all 478,797 such rows are monsters), and the extra column is not
in the partial index — so it cost a table lookup per row, 5.6s against 10ms.

### The blocking rule, concretely

`docs/architecture.md` says a query that is not index-backed must run under
`Lwt_preemptive.detach`. For search that means: **detach unless every term is
indexed and none carries a `min_count`.** Measured over 2000 seeds, a single
indexed term answers in well under a millisecond, while a conjunction involving
a grouped `min_count` term costs ~6ms warm and ~120ms cold — and cold cost grows
with the corpus. `Seed_web.search_is_cheap` is that rule in code.

On the finished 100k corpus every indexed shape landed in single- or
double-digit milliseconds (`unique` 6ms, `shop` 2ms, `min_count` 25ms,
`artefact` 28ms), and the three-term search 0.7s (100k, 0.34.1, D:8, 2026-08,
M-series laptop).

~~**At 1.3M the rule is wrong, and wrong in the direction that hurts.** Every
figure above has grown by roughly the corpus factor, because the temp b-tree
described under *The sharp edge* makes a term's cost linear in its matched rows
(1.3M, 0.34.1, `D:8`, 2026-09-05, server, end to end over HTTP):~~

~~| shape | 100k | 1.3M | `search_is_cheap` |~~
~~|---|---|---|---|~~
~~| `unique:Sigmund` | 6ms | 0.13s | cheap → **inline** |~~
~~| `shop potion:haste` | 2ms | 0.54s | cheap → **inline** |~~
~~| `artefact` | 28ms | 2.48s | cheap → **inline** |~~
~~| `potion:haste` | — | 1.74s | cheap → **inline** |~~
~~| `2x potion:haste` | 25ms | 1.90s | not cheap → detached |~~
~~| three-term | 0.7s | 3.70s | cheap → **inline** |~~
~~| `name~Throatcutter` | 0.10s | 7.02s | cheap → **inline** |~~

~~`search_is_cheap` asks only whether every term is indexed and free of
`min_count`. Both are still true of `artefact` and of `Name_like`, so the two
most expensive searches in the table run **on the scheduler thread**, where a
synchronous SQLite call stalls every concurrent request. The one shape the rule
does detach, `min_count`, is no longer among the worst. The predicate is
measuring the wrong property: it asks about the *plan* when the cost is now set
by the *matched set*, which is exactly the distinction this document draws at
the top of *The sharp edge* and which the rule predates.~~

~~Until the `distinct` shape is fixed, the honest rule is to detach every search;
the fix that makes a narrow rule meaningful again is the one under *The sharp
edge*, not a longer list of exceptions here.~~

**Superseded 2026-09-05** by the flat driver+correlated-exists rewrite (see
*The sharp edge* above for the shapes and figures). The temp b-tree that made
every criterion's cost linear in its matched rows is gone, and with it the
entire premise of the table above: re-measured directly against SQL (1.3M,
0.34.1, `D:8`, 2026-09-05, prod), every shape without a `min_count > 1` term —
`unique`, `shop`, `artefact`, bare item, three-term, `Name_like` included —
answers in 1-4ms with a covering-index plan. `Criterion.is_cheap` now says
cheap for all of those, correctly.

~~The rule is not simply "everything is cheap now," though. The rewrite
introduced a new term-level hazard the old shape never had: a `min_count > 1`
term chosen as the query's *driver* (which `driver_rank` can do — it has no
opinion on `min_count`) degrades to a full-table scan of `entries`, timing out
past 100s at 1.3M where every sibling shape is sub-5ms (see *The sharp edge*
above). So `Seed_web.search_is_cheap` keeps its `min_count <= 1` guard on
every term, not just the driver candidate — simplest honest rule available
without teaching the web layer which term `driver_rank` would actually pick,
which would couple it to `Db`'s internal driver-choice heuristic for no
present benefit. The combined rule: **cheap iff every term is
`Criterion.is_cheap` and no term carries `min_count > 1`** — the same
predicate as before the rewrite, but no longer wrong, because both of its
conjuncts are now measured true of exactly the shapes that are actually cheap.~~

**Fixed 2026-09-05**, alongside the driver fix above: `Db.driver_select` now
renders a `min_count > 1` driver as its own flat `group by ... having` rather
than a membership test, so it streams off the criterion's covering index the
same as every other shape (~1ms alone, ~6ms combined with a second term;
1.3M, 0.34.1, `D:8`, 2026-09-05, prod). `Seed_web.search_is_cheap` no longer
carries a `min_count` guard at all — the rule is simply **cheap iff every term
is `Criterion.is_cheap`**, `min_count` included, because there is no longer a
term-level hazard for it to guard against.

`Name_like` was the standing example of a scan; interning removed that,
measured 16.9s to 0.10s (100k, 0.34.1, D:8, 2026-08-28, M-series laptop). Its
substring match runs over the `strings` dictionary and the ids it yields are
covering seeks on `entries_search_name`, so its cost scales with the corpus's
*vocabulary* rather than its row count — but the vocabulary reached 2.99M rows
and 159 MB, and the dictionary scan alone was ~3.3s of its 7.02s (1.3M, 0.34.1,
2026-09-05, server). Scaling with the vocabulary was the right trade and still
is; it just stopped being cheap, which is what `strings_fts` addresses above.

It stays *not* `is_cheap` regardless, and prod made that emphatic. Trigram is
fast for the selective fragments people actually search — `name~Throatcutter`
7.02s to 0.21s, `name~Wyrmbane` 3.15s to 0.27s — but a common fragment got
*worse*: `name~dragon` matches 33,523 distinct names and went 3.17s to 9.9s
(1.3M, 0.34.1, warm, over HTTP, 2026-09-07). The index is not the cost there;
the candidate set it hands to the `distinct`-under-a-sort is, and that was
always linear in matched rows. Making the dictionary stage fast enlarged the
input to the stage that was already dominant.

So `Name_like` cannot run inline no matter how good the index is, and the
remaining work for common fragments is the `distinct` nesting, not the search
index. See `docs/corpus-scaling.md`.

### A seed-granular store answers "which seeds"; SQL still answers "with what"

Search is now two implementations of one predicate semantics. `Db.search_seeds`
drives the seed-granular posting-list store (`lib/corpus/search_index.mli`,
`docs/plans/seed-search-index.md`) when it is current for the version, and
falls back to everything above — the SQL predicate path this whole section
describes — when it is not.

That is a fallback, not a refusal, and the two stale-index failure modes look
alike without being alike. A stale trigram index refuses (`stale_index_tag`,
above) because its fallback is a 129 MB dictionary scan reachable from a public
query parameter — an amplification factor, not a slow correct answer. A stale
search store falls back instead, because its fallback *is* the implementation
that has been answering every search in production up to now: refusing would
trade a correct, slow answer for no answer, for a store whose only failure mode
is being one fill behind. Not one *deepen* behind: deepening changes no seed
count, so it leaves the store current, and the seeds it did change — the deep
cohort, every seed deeper than the build recorded it — are subtracted from the posting
stream and re-derived through this section's SQL on every search. That is sound
only because deepening is a strict prefix extension of a shallow fill
(`fill_depth.mli`), so a stale posting is true-but-incomplete, never wrong. The
store also holds no names, levels or evidence,
so the second round trip — `term_hits`, per seed, per term — is unchanged
regardless of which path found the seeds.

Not every criterion the store helps with is answered exactly. A multi-property
`props:` only narrows: the store intersects each property's own posting list
down to a candidate set, but membership at seed granularity can't confirm the
properties landed on *one* item — it can't tell a Conj ring from an Alch staff
on the same seed apart, which is the whole reason `Criterion.Props` exists
(above). So a narrowing criterion's candidates are re-checked against SQL
before they page — the two-stage shape the design predicted, and the case it
is right for.

`name~` is not that case either, and is handled in the other order. Driving on
the store and re-checking the fragment per candidate batch would be backwards:
the merge drives on its *rarest* list, a `name~` term's companions are
typically far broader than the fragment, and `name~Wyrmbane potion:haste` would
walk the ~1M-posting haste list re-running the trigram lookup per batch. So the
fragment is resolved *first* — the same two-stage `strings_fts`-then-`like`
lookup the SQL path uses, grouped per seed into an in-memory posting list with
the builder's depth and count — and that list joins the merge as an exact term,
where it is almost always the driver. Production traffic is what justified it:
of 2,472 human searches carrying `name~`, the ones combining it with another
term had a p99 of 58.4s and 123 over 5s, nearly all a selective unrand name
beside a property or item term (access log, 2026-09-09 to 2026-09-26).

Resolution is unbounded for a broad fragment (`name~the` is 762,835 names and
over 300k seeds), so it stops at `Search_index.max_name_seeds` (20,000) and the
store declines past it, leaving the search on the SQL path as before. 97.5% of
human fragment occurrences resolve under that cap (315 distinct fragments, 1.3M,
0.34.1, D:8, prod, 2026-09-26); the rest are mostly readers using `name~` for
enchantment level or property strength (`+10`, `Slay+3`, `speed`). A declined
fragment pays the partial resolution first, on top of the SQL path: 0.50s
(`hat`) to 1.01s (`the`) to reach the cap.

What it bought, first page warm, store against the SQL path (1.3M, 0.34.1, D:8,
prod clone, cores 1-3,5-7, neighbor idle, ARC cap 10 GB, 2026-09-29): the shape
still slow in production, `name~` beside a bare `props:`, went from 1.5-8.2s to
0.11-0.42s (`name~heavy crossbow "Sniper"; props:Dex` 8.22s → 0.11s). What it
cost: a selective fragment beside a selective term, and a lone fragment, are
~0.07s slower (`name~hood of the Assassin` alone 0.07s → 0.13s, `name~robe of
Vines; props:Conj` 0.10s → 0.18s), since the whole fragment is resolved on every
page. A lone fragment under `Shallowest` is now answered where the SQL path
refused it past `Rank.sort_limit` (`name~Throatcutter`, 0.07s).

Paging order is the one place the two paths visibly disagree: the store pages
by ordinal (append order), the SQL path by seed text, and both are "the
corpus's own order" — the listing caption already declines to promise which.
A reader paging across the moment the store flips between current and stale
can see one seed twice, or not at all, exactly once, at that boundary.

`Search.Rank.sort_limit`, `Search.Rank.is_too_broad`, and
`Seed_web.search_is_cheap` are untouched by any of this — they still govern the
SQL path above and retire only when it does, which is gated on a
production-scale equivalence run, not on this landing.

## Rendering

**TyXML, not a template language.** Views are OCaml functions returning typed
elements. Malformed HTML is a compile error, and escaping is the default rather
than a thing to remember.

- **Escape on output, by default.** TyXML escapes; `Unsafe.*` is a reviewed
  exception. Item names, vault names, and monster names come from crawl — they
  are trustworthy in provenance but they are still *data*, and they get escaped
  like anything else.
- **`tyxml-htmx`** supplies typed htmx attributes (`hx_get`, `hx_target`, typed
  `hx_swap`). Use it rather than hand-writing `Unsafe.string_attrib` at call
  sites; the escaping is audited in one place.
- **No inline scripts or styles.** The CSP forbids them. JS lives in
  `/static/*.js`, served as files.

### Flush the formatter before reading the buffer

`render_html`/`render_fragment` build a `Buffer`, hand TyXML a
`Format.formatter_of_buffer`, and read the buffer back. **`Format` buffers
output internally**, so the buffer is only complete after
`Format.pp_print_flush`. Without it a render silently loses whatever the
formatter still holds.

This hid for a long time because a single-element render usually spills enough
to look right. It surfaced the moment a fragment handler returned several
elements and only the last one arrived — a heading and an out-of-band announcer
vanished from every htmx swap while the full page rendered fine.
`test/test_render.ml` pins it.

### CSP and security headers

Set on every response by a middleware:

```
Content-Security-Policy: default-src 'self'; script-src 'self'; object-src 'none';
                         base-uri 'none'; frame-ancestors 'none'
X-Content-Type-Options: nosniff
```

`default-src 'self'` is what makes self-hosting the fonts mandatory rather than
merely preferable — a CDN face would be blocked.

### htmx stance

htmx is an **enhancement over working HTML**, not a replacement for it. Every
view must work as a plain page load; htmx removes the round-trip flash, it does
not carry the feature. A filter control that only works with JS is a defect.

Prefer typed `hx_swap` over raw strings. Morphing swaps (`InnerMorph`/
`OuterMorph`) preserve node identity across a swap — focus, open disclosures,
scroll position — which matters for a filter-as-you-type surface over a large
result set.

## SQLite contract

### Pragmas (per-connection)

Several are **per-connection** and default off, which is the classic silent-
breakage source. `Db.open_` sets them on every connection, not once at startup:

| Pragma | Value | Why |
|---|---|---|
| `journal_mode` | `wal` | Concurrent readers, one serialized writer — the app's exact shape. Persists in the file, but set on connect anyway. |
| `foreign_keys` | `on` | **Per-connection, off by default.** The `seed_levels` → `entries` cascade is what makes re-ingest idempotent. Inert without this. The easiest invariant in the repo to lose silently. |
| `synchronous` | `normal` | The standard WAL pairing: durable across app crashes; only power loss at the wrong instant risks the last transaction. |
| `busy_timeout` | `30000` | Lets a reader wait out a write batch instead of taking an instant `SQLITE_BUSY`. Raised from 5s after a 100k fill lost chunks: eight ingest processes plus the deepen generator on one write lock hold it for seconds at a 2000-record batch, and 5s was short enough to turn a wait into a failed chunk. |
| `mmap_size` | `1 GB` | Maps the corpus instead of `read()`ing it: one fewer syscall and copy per page. Worth ~20% on the hot query that joins out of `entries`, and nothing on the indexed seeks, which already touch too few pages to care (107 MB corpus, warm connection, 2026-09-02). 1 GB is this SQLite build's clamp — a larger constant would be silently truncated. Address space over the shared page cache, so it neither multiplies across a fill's eight ingest processes nor shows up as resident memory; expect a startling `VSZ` and an `RSS` that tracks the corpus. |

### Writer stance

Ingest is a batch writer holding one transaction per batch; the web layer is a
reader. That asymmetry is the whole concurrency story — WAL plus `busy_timeout`
covers it, with no application-level mutex. The web layer writes in exactly one
place (the deepen enqueue), and it takes
`begin immediate` so it fails fast or waits, rather than discovering the
conflict mid-transaction.

**The web process holds a dedicated reader, a dedicated writer, and a pool of
read-only connections for detached queries.** A single shared handle cannot
serve reads and writes: the read accessors take deferred transactions for
their snapshot, so an enqueue taking `begin immediate` on the same handle
would collide with an open read transaction. Separating reader from writer
makes them independent, which is the whole reason WAL exists. This is what
the Caqti revisit would have called pooling; at a pool size of one writer it
is a second `Db.open_`.

The reader alone is not what a *detached* query runs against, though — see
"The sharp edge: blocking the scheduler" above. `Seed_corpus.Pool` is a third,
separate set of connections, sized by `SEED_POOL_SIZE`, opened `~readonly`
(refusing writes at the SQLite level, and skipping `pragma optimize` on close
since a read-only handle cannot run it) and handed out one per detached query
so concurrent detached queries genuinely run in parallel rather than
serializing on one shared connection. The reader stays the sole connection for
*inline*, non-detached, already-cheap queries — pool checkout has real cost,
so it stays out of the sub-ms path.

**Two long writers are excluded by a file lock, not by `busy_timeout`.** A fill
is eight ingest processes; the deepen generator is a ninth, running continuously
and on nobody's schedule. When the 100k fill overlapped a deepen pass both sides
sat on the write lock long enough to exhaust the other's timeout, and the fill
lost the tails of four chunks. `busy_timeout` is sized for one long writer, not
two.

So `tools/corpus-fill` takes `flock` on `<db>-write.lock` for its parallel
phase, and the generator tests the same lock non-blockingly before each pass and
*skips* rather than queueing. The lock is derived from the database path
(`Deepen.fill_lock_path`) so the three processes that consult it agree without
configuration. Two properties matter:

- **The lock is released before the rescore**, not at exit. It exists to keep
  eight writers off one lock for hours; the rescore is a single writer, which is
  what `busy_timeout` is for. Holding it through scoring would make a reader's
  deepen request wait out the scoring pass too — on a 100k corpus, the larger
  half of the wait (1391s against 39s). The ratio inverts at scale: the 1.3M
  fill ran 27.3 hours against a rescore that died at 11 minutes, so the lock is
  now the long pole and the release is a smaller mercy than it was. It stays
  released because the reasoning is about contention, not duration.
- **The generator keeps heartbeating through a fill.** `Db.heartbeat` declares
  which versions a generator *can* build, not that it is working — a fill pauses
  the work, not the capability. Skipping it with the claim loop would lapse the
  300s window, answering every deepen request `No_generator` and reporting
  `/health` as "no generator" for the whole of a multi-hour fill: a false
  statement about the build, and a red liveness check for a healthy host. Caught
  before it ever shipped — the flock change was committed but not deployed.

A request made during a fill is still enqueued and still served, just later. The
web layer tests the same lock to say so: the seed page withdraws the deepen
button and explains that searches are paused, rather than offering a control
whose only outcome is an unexplained wait. A job already queued keeps polling —
only the offer of new work is withdrawn.

The lock is derived from the database path, which is exactly what makes it
blind to a second process reading a frozen *copy* of the corpus: a read-only
instance opens its own `<copy>-write.lock`, one the live fill never touches, so
it sees no lock and would enqueue happily into a database nothing will ever
drain. `SEED_DISABLE_DEEPEN` (`Params.deepen_disabled`) is the explicit
counterpart for that case — checked alongside the lock everywhere the lock is,
so a read-only instance withdraws the offer, refuses the POST, and (see
`Seed_web.health`) stops treating generator liveness as a health signal, for
the same reason: no generator will ever heartbeat there.

The lock is consulted rather than a flag in the corpus because it is
self-healing: a fill killed mid-run releases it when its fd closes, where a
column would record a fill that is no longer running until someone cleared it by
hand. On macOS there is no `flock(1)`, so a dev fill degrades to no locking —
a laptop has no generator to contend with.

**Multi-statement reads take a transaction.** WAL's snapshot is per *statement*.
`Db.seed_levels` joins four of its five statements on `entries.id`, which a
re-ingest reassigns, so a commit landing mid-call yields entries whose ids the
spell and property tables have never seen — a randart book with an empty spell
list, no error raised. `Db.between_reads` is that window, exposed for the test
that proves it closed.

### Schema notes

`strict` tables throughout, `without rowid` where the primary key *is* the
identity. Consequences worth keeping in mind:

- `strict` has no boolean type, so booleans are `integer` 0/1, and the
  `entries_search_artefact` partial index is defined on `artefact = 1`.
- `entries` is deliberately *not* `without rowid` — it is the wide, many-rows
  table and the indexes carry the lookups.
- Indexes exist for the questions the app asks: the `entries_search_*` family
  for "which seeds have X", `entries_seed` for "what's on this seed", and
  `seed_levels_version_seed` for the version-scoped seed listing. A new query
  pattern that scans is a missing index, not a slow database.
- **Every index on `entries` leads with `version_id`.** Three that did not —
  `entries_name`, `entries_feat`, `entries_artefact` — were dropped: the
  `entries_search_*` indexes are strictly better prefixes and the planner never
  chose them. Measured 669 MB, 16% of the database, with no change to results or
  timings. Don't add a non-version-leading index back without a query that needs
  one.
- `seed_levels`' primary key leads with `seed`, so it cannot serve a
  version-scoped listing: SQLite searches on `seed` and filters `version` row by
  row. `seed_levels_version_seed` is what makes that listing a covering-index
  seek. `test_read.ml` asserts on `explain query plan` output for both read
  accessors, so an index regression fails the suite rather than quietly scanning.

### Pagination

Listings page by **keyset, not offset**: the cursor is the last seed of the
previous page (`where seed > ?`), so SQLite seeks straight to it. `offset n`
would make it count and discard `n` rows first — the scanning query the indexes
exist to avoid, and at a hundred thousand seeds the difference between flat and
linear. The accessor reads `limit + 1` rows and discards the surplus, which is
how a full last page is told from a full page with more behind it without a
second `count(*)` over the corpus.

## Testing

- **Inline expect tests** (`ppx_expect`) are the default. The corpus test library
  declares `schema.sql` as a dependency so tests build a real database.
- The **parser** deserves adversarial cases: truncated lines (a crawl crash
  mid-level produces them), unknown `format`, missing categories, nested monster
  inventories, and the `nil`-means-both-absent-and-false ambiguity.
- **Idempotency is testable**: ingest twice, diff. Output is deterministic for a
  given `(seed, version, depth)`.
- **Rejected lines are counted, not fatal.** A malformed line increments
  `Counts.rejected` and reports to `on_reject`; a run that aborts on the first
  bad line would lose a whole batch to one truncation.
