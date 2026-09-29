# A search index separate from the record store

Status: **built**, 2026-09-15 — see *Built*, below, for what shipped, where it
departed from this design, and what is still open. The rest of this document
is the design record that led there; it is amended in place where the code
disproved it, not rewritten. Revised 2026-09-11 after review; revised again
2026-09-15 with production measurements (see *Measured at 1.3M*). Supersedes
the index work proposed in fossil ticket `ca97068b6f`, which is left open for
its measurements rather than its design.

## Settled

- **Seed order is undefined.** Not "undefined but stable" as a promise: nothing
  user-facing changes, and the listing caption already says no particular order.
  The only invariant is internal — a served `(version, fill)` pages without
  repeating or skipping rows. That is what lets ordinals be append-order.
- **Shop selection is per term** (`shop `), not a query-wide flag. A query-wide
  flag is the toggle `docs/architecture.md` rejects: it makes a term's text
  denote different sets depending on state outside the term, and it cannot
  express `shop potion:haste` beside `floor wand:digging` in one query.
- **The union item criterion is not stored.** With floor and shop lists
  present, `Item` is a merge — and, for a count threshold, an add — at query
  time. That removes ~427 lists and retires the union/`min_count` partition
  question with them. It does *not* retire `3x potion:experience` across both:
  the store makes that the cheap case, `floor[i] + shop[i]`.
- ~~**`Rank.Seed`, `sort_limit` and `is_too_broad` retire.** `Shallowest`
  becomes uncapped, multi-term included.~~ **Only for the queries the store
  answers.** The SQL path is retained as a fallback (see *Built*), and every
  query it still serves — any store-stale corpus, and every query carrying a
  `name~` term (below) — needs `sort_limit` and `is_too_broad` exactly as
  before. They retire when the SQL path does, not with this landing.
- **Postings, not dense arrays.** Settled 2026-09-15 on measurement: the store
  is 5.1% full, selectivity spans five orders of magnitude, and every dense
  layout exceeds available RAM at 10M seeds.
- ~~**`name~` keeps the trigram path**, as a filter over the candidate set.~~
  **Half right.** `name~` does keep the trigram path — but not as a filter
  over the store's candidate set. The store cannot be the outer loop for a
  term rarer than its own rarest list (see *Built*, #7), so a query carrying
  `name~` runs the SQL path in full, unnarrowed, exactly as it did before this
  store existed.

Open, and at the bottom: posting encoding, store format and location — both
now built; see *Built*.

## Built

Shipped 2026-09-15: `lib/corpus/search_index.mli`, `criterion_id.mli`,
`posting.mli`, the `seed_ordinals`/`search_criteria`/`search_postings`/
`search_index_state` tables at the bottom of `schema.sql`, the `Db.search_seeds`
routing, and the `corpus-index` builder (`bin/index.ml`, run as `just index`).
Seven departures from the design above, in the order they bite a reader:

1. **Store location: tables in `corpus.db`, not a companion mmap'd file** —
   the location the "Store format" open item below left unsettled. Reuses the
   existing connection pool and `Or_error` plumbing, makes a rebuild atomic
   under an ordinary WAL transaction with no file rename, keeps one file to
   deploy and copy, and leaves the in-memory test corpora working. Residency
   is a page-cache/ARC question rather than a hard allocation.

2. **Ordinals are assigned by the builder, not at insert.** *Ordinals: append
   order* (below) required assignment at insert, on the grounds that parallel
   ingest makes insert order timing-dependent and a build cannot re-derive it.
   That argument rules out re-deriving *from insert order*, which the builder
   does not do: it appends `max(ord) + 1` over seeds lacking one, in
   `(length(seed), seed)` order — deterministic, reproducible across rebuilds,
   monotone under fills, and untouched by the parallel ingest hot path.
   Measured: a rebuild on the local corpus moved zero ordinals.

3. **A correctness hole in the design: multi-property `Props`.** *The
   vocabulary is closed and tiny* (below) counts `(base_type, prop)` pairs as
   catalog rows without saying what a criterion naming *several* properties
   does with them — and intersecting two such rows is wrong: `props:Conj,Alch`
   demands both on *one* item, and a seed-level intersection matches a Conj
   ring beside an Alch staff, the exact leak `Search.Criterion.Props` exists to
   prevent (`docs/architecture.md`, "The search vocabulary"). Resolved by
   `Criterion_id.Narrowing`: those criteria narrow the store's candidate set
   through their per-property lists, then get verified against SQL before
   paging — the store still cuts 1.3M seeds to a handful, which is the whole
   of its value there.

4. **The build query in *Measured at 1.3M* is wrong, not just unmeasured at
   the right scale.** It reads `min(level_id)` off `entries` and calls that
   the shallowest depth. `level_id` is a `strings` dictionary id and carries no
   order — `schema.sql`'s own comment on `seed_levels` says so ("level_id is a
   strings id, so it carries no order: ordering a seed's levels is Depth's
   job"). The query that shipped instead (`lib/corpus/search_index.ml`)
   populates a temp `level_depth` table (`level_id -> Depth.of_level`) and
   joins it, so `min()` runs over an actual depth. That also means the 34s
   figure timed a query nothing runs — it cannot be kept as a slow-but-valid
   number for the corrected one. What is measured: the builder's full pass —
   all five criterion kinds, not just floor items — is **1.1s** on the
   10,000-seed local `corpus.db` (0.34.1, `D:8`, 2026-09-15), landing 1,294
   criteria and 711,224 postings in 2,319 blocks (2,150,361 bytes, 3.02
   bytes/posting). There is no 1.3M-scale timing of the corrected query; the
   "~1-2 minutes" extrapolation in *Measured at 1.3M* was built on the wrong
   number and should not be read as a bound until one is taken.

5. **The SQL path is retained as a fallback, not retired.** *Sequencing*
   below already conceded this would need "a production-scale equivalence
   run" before *Still open*'s "SQL: shadow or retire" could close; that run
   has not happened. `Db.search_seeds` calls the store when
   `Search_index.is_current`, and the SQL predicate path otherwise —
   including for every query the store declines outright (#7). Closing this
   needs the equivalence run at 1.3M, not just the checks recorded below.

   Staging at 100k (`/corpus/staging`, 0.34.1, `D:8`, checkout `048dfaff08`,
   app host, neighbor idle, 2026-09-16): `corpus-search-equiv`'s default set
   agrees on every query the store answers, under both ranks and paged to the
   end, three times — on the fresh build; with 29 seeds deepened through the
   web route and not rebuilt (11 of 15 matched sets grew, `9x artefact`
   3,651 → 3,678, all still equal to SQL); and after a rebuild, which emptied
   the cohort. The build is 15.4s (7,264,311 postings, 21,976,701 bytes); a
   full equiv run is ~3m30s. Declines were the expected six: `name~`, and
   `Narrowing` terms under `Shallowest`. That is a real corpus and a real
   overlay, not prod scale.

   At prod scale, on a ZFS clone of the prod corpus migrated with
   `corpus-reindex` (1,299,999 seeds, 0.34.1, `D:8`, app host, neighbor idle,
   2026-09-17): the same default set passes, exit 0 in 13m42s. Under `Seed`
   every matched set is compared whole, up to `artefact` at 1,127,767 seeds.
   Under `Shallowest` the first 100 pages (5,000 seeds) of each broad query are
   checked as a prefix of the SQL set's depth order. A full ranked walk is
   quadratic until #8 is fixed: ~3.5h for `potion:haste` alone. Declines are
   the same six. So the gate this item names is met for every shape the store
   answers. ~~What still holds the SQL path in place is its remaining
   callers: `name~`, `Narrowing` under `Shallowest` (1f26458f5a), and a stale
   store (1e34af034b).~~ `Narrowing` under `Shallowest` closed 2026-09-17 --
   see item 9. What still holds the SQL path in place: `name~` and a stale
   store (1e34af034b).

6. **Deepening no longer stales the store; it is overlaid.** *Closed
   2026-09-16, and it is what made the store deployable.* As shipped on
   2026-09-15 the currency mark was a high-water mark over `entries.id`, and
   deepening is not an append — re-ingest cascades `entries` off `seed_levels`
   and re-inserts, minting ~457 fresh ids per seed — so one deepen job staled
   every version's store. At the ~20 jobs/day production runs, search would
   have been store-backed only between a fill and breakfast.

   Two changes, both required:

   **Currency counts seeds, not rows.** `search_index_state.built_seeds`
   against `count(*) from seed_fills` for the version. Deepening moves
   `seed_fills.depth` in place and never the row count, so a deepen leaves the
   mark standing; a fill moves it. It also catches the direction the row mark
   could not see at all: dropping seeds *lowers* `max(entries.id)` while the
   mark stands still, so the old predicate reported current over postings for
   seeds that no longer existed — a false positive, the one direction this
   mechanism exists to rule out. `tools/corpus-drop-seeds` now deletes the
   state row outright rather than relying on the arithmetic, since a drop
   followed by an equal-sized refill restores the count over a store that is
   wrong about both ends. `built_through` is still recorded and nothing
   branches on it.

   Counting was not free: a covering-index scan of `seed_fills`, **88ms** at
   1,299,999 seeds (0.34.1, prod, 2026-09-16, warm), linear in the corpus and
   larger than everything else on the store path. So the count is now kept by
   trigger in `seed_fill_counts` and the check is a primary-key read: 16-22µs
   against 1.3-1.8ms for the count at 10,000 seeds (local, 2026-09-16), and
   flat in corpus size. A deepen's `on conflict do update` fires neither
   trigger; an `insert or replace` would double-count, which is why
   `tools/corpus-check` compares the counter with `count(*)`.
   `tools/corpus-reindex` replays the triggers and recounts. `Db.seed_count`
   reads the same counter, which retired the web layer's per-process cache
   and the under-report during a fill that came with it.

   **A deep-cohort overlay inside `Search_index.page`.** The dirty set is
   every seed whose `seed_fills.depth` exceeds the `seed_ordinals.built_depth`
   the last build recorded for it. The mark is per seed and written inside the
   build's transaction, from the same snapshot the postings come from, so there
   is no window between them for a deepen to land in — the race the
   `strings_fts_state` comment warns about. A null `built_depth` (a store built
   before the column, via `tools/corpus-reindex`) counts as deepened.

   As first shipped the dirty set was `seed_fills.depth > Fill_depth.shallow`,
   time-free on purpose, with the claim that "every full rebuild absorbs the
   cohort". It did not: nothing a build writes changed that predicate, so a
   deepened seed stayed dirty forever, the cohort grew monotonically per
   version, and at ~20 deepens/day the store would have declined every query
   past `max_overlay_cohort` in ~240 days with no rebuild able to clear it.
   Fixed 2026-09-16 by `built_depth`; `test_search_index.ml` pins that a
   rebuild empties the cohort and a later deepen reopens it for that seed only.

   Those ordinals are subtracted from the posting stream and the cohort is
   re-derived from SQL instead — `Db.verify_terms`, which was already exactly
   this union pass, plus a second query for the shallowest depth `verify`
   cannot return (`Db.cohort_matches`; depth comes from the level *name*
   through `Depth.of_level`, which SQLite cannot call). Subtraction, not union:
   a stale posting is a *genuine* posting carrying a depth that is merely too
   deep and a count that is merely too low, so a union double-emits under
   `Rank.Seed` and misranks under `Rank.Shallowest`.

   Sound because deepening is a strict prefix extension — `fill_depth.mli`
   records, verified row-for-row, that a deep seed's `D:1`–`D:8` rows are
   byte-identical to a shallow fill of the same seed — so a stale store's
   postings for a cohort member are true but incomplete, and re-deriving is
   always at least as correct as reading.

   The trap worth naming: `page`'s early return when a key has no catalog row,
   commented "a true answer about this build". With the overlay that is no
   longer a true answer about the *corpus* — a deepened level can mint a
   criterion the build never saw — so a query whose terms have no catalog row
   is now a page of overlay rather than a page of nothing. That path is the
   single most likely way to have shipped a silent false negative, and
   `test_search_index.ml` pins it directly.

   **Measured (prod, 1,299,999 seeds, 0.34.1, `D:8` + `Swamp:4`, 2026-09-16,
   warm):** the cohort is 206 seeds (0.016% of the corpus) holding 94,087
   `entries` rows, ~457/seed. Overlaying one term
   over the whole cohort is **11ms** verify + **2ms** depths for
   `potion:haste`, **8ms** + **3ms** for `artefact` — i.e. ~13ms per term,
   against the 88ms the currency check cost before it was counted by trigger. `Search_index.max_overlay_cohort`
   declines past 5,000 seeds and lets the SQL path take the query whole. That
   cap is a bound, not a measured crossover: overlay cost is linear in the
   cohort, so ~13ms/term at 206 seeds extrapolates to ~300ms/term at 5,000.
   At ~20 deepens/day it is most of a year between rebuilds.

   **Equivalence, local 10,000-seed `corpus.db` (0.34.1, two seeds already at
   `Swamp:4`), through the web layer:** fourteen query shapes, both ranks,
   single- and multi-term, `props:` and `name~` — identical seed sets on the
   store and SQL paths with zero duplicates, except the one shape whose result
   set exceeds a page, where the two differ by the documented *order* (ordinal
   vs. seed text) and not by membership. `test_search_index.ml` gained eight
   expect tests over a fixture deepened after its build: the currency triple
   (deepen current, fill stale, drop stale), a criterion gained only on a deep
   level, a criterion with no catalog row at all, a `min_count` the deep levels
   are what satisfy, `Rank.Shallowest` taking the shallow depth rather than the
   deepened one, paging both ranks across the cohort boundary at three page
   sizes, and the base suite's shapes re-run over the deepened corpus.

   Still not done here: the incremental posting splice in `bin/deepen.ml`
   (the ticket's option B). It is the end state and cheaper than the ticket
   assumed — ~66 posting lists per seed, one block each — but it is the version
   that can be silently wrong, and `bin/deepen.ml` stays unchanged.

7. **Not in the original design: the store declines the whole search when
   *any* term is `Criterion_id.Unindexed`, not only when every term is.** The
   design's *Query shapes* and the settled `name~` bullet above both describe
   `name~` as narrowing through the store like a `Props` term — "a trigram
   filter over the store's candidate set, faster than today." That is not
   implemented, and not implementable in that direction: the store's merge
   drives on its *rarest* posting list, and a `name~` term's companions are
   usually broader than the fragment itself. `name~Wyrmbane potion:haste`
   would drive on the haste list (~1M postings at 1.3M seeds) and re-run the
   trigram lookup once per candidate batch — on the order of 20,000 round
   trips to fill one page — against the SQL path's own 0.14s for the same
   query, earned by decorrelating both terms (`Db.correlated_select`, 1.3M,
   2026-09-09). So `page` declines the entire search — falling back to SQL in
   full — the moment any term has no catalog row, rather than verifying that
   one term per candidate batch. Making the design's claim true needs the
   *other* order, resolving `name~` to seeds first and intersecting with the
   store, which is unbounded for a broad fragment (`name~dragon` is 33,523
   distinct names, 1.252s uncached, 1.3M, 2026-09-10) and is not built. Record
   this as not done, not as done differently.

8. **The depth-band walk for `Shallowest` is not built.** *Query shapes*
   specifies it, and it is why ca97068b6f closed as superseded, but
   `Search_index.ranked_page` walks the rarest list whole, sorts every match
   by depth, and drops `after` as an offset. So a ranked page costs O(matched
   seeds) on every page: `potion:haste` 0.65s and `scroll:teleportation`
   0.83s, page 1 and page 20 alike (ZFS clone of prod, 1.3M, 0.34.1, `D:8`,
   neighbor idle, 2026-09-17). That is uncapped, as the design promised, but
   it is not early-terminating. Tracked in e5f102e19d.

   The same measurement put two more costs on the SQL fallback the store
   still leaves open: ~~`Narrowing` terms under `Shallowest`, which the store
   declines (22–54s, 1f26458f5a)~~ (closed 2026-09-17, item 9), and every
   property search while the store is stale (the same costs, 1e34af034b).

9. **`Narrowing` terms no longer decline under `Shallowest` (1f26458f5a),
   closed 2026-09-17.** The reason given in the ticket -- "no correct rank
   depth" -- was narrower than the decline it justified: `candidate_depth`
   already computed *a* depth for a narrowing term, by taking `min` over each
   property's own posting list independently, which never confirmed the
   properties landed on one item. That is a presence pre-filter, not a
   ranking depth, and it is what the SQL-decorrelated path (`Db.verify_terms`,
   already reached by `seed_page` for `Rank.Seed`) was always getting right by
   construction, through `criterion_where`'s same-item correlated predicate.

   The fix reuses that: `Db.verify_terms_with_depth` runs `verify_terms` for
   membership, then folds `Db.cohort_depths_sql` per term for the shallowest
   depth over the union of the query's terms -- the same shape
   `Db.cohort_matches` already used for the deep-cohort overlay, which is now
   a one-line wrapper over it. `ranked_page` batches narrowing candidates
   through this and combines the result with `Int.min` against any `Exact`
   terms' depth from postings.

   Kept separate from `seed_page`'s existing `verify` on purpose: `seed_page`
   is bounded by page size and never needed depth, so giving it the
   depth-carrying callback would have doubled its SQL cost (`verify_terms` and
   `cohort_depths_sql` per term, per batch) to serve a value it discards.
   `Search_index.page` therefore takes both `~verify` (membership, `seed_page`)
   and `~verify_depth` (`ranked_page`), not one widened callback.

   `ranked_page` still walks and verifies the *whole* matched set before
   cutting a page -- item 8's O(matched) shape, now paid on the verify side
   too for a narrowing query, not only the in-memory sort. That is unchanged
   scope, not a new regression: `Rank.Shallowest` already required the full
   walk for `Exact`-only terms.

   Verified at 10k local (`just ci`): a hand-built fixture where the
   per-property min would report a wrong shallow depth (two single-property
   items on `D:2`/`D:3`, no item carrying both until `D:6`) now ranks by the
   true same-item depth, matching the SQL path's own answer and order exactly.
   ~~**Not yet run: the 1.3M equivalence gate this ticket specifies** for
   `staff props:Conj,Alch` and `props:rF,rC,rPois,rElec` specifically, and no
   timing of the new verify-batched path against the 22-54s SQL cost it
   replaces. Both are pending a run against the prod corpus clone.~~

   **Run 2026-09-17**, ZFS clone of the prod corpus (`/corpus-bench`, origin
   `zp0/corpus-new@bench-20260916`, 1,319,999 seeds, 0.34.1, `D:8`,
   dcss.garden, work pinned to cores 1-3,5-7, web app left on cores 0,4).
   `corpus-reindex` found the schema already current (24 tables, 22 indexes,
   no drift); `corpus-index` rebuilt the store in 11m25s wall, 1.1G peak RSS.
   `corpus-search-equiv`'s full default set, plus both named queries run
   standalone, agree with SQL on every shape, exit 0 on all three
   invocations. The gate this ticket specifies:

   | query | rank | store | sql |
   |---|---|---|---|
   | `staff props:Conj,Alch` | seed | 0.01s | 22.48s |
   | `staff props:Conj,Alch` | shallowest | 0.01s | 22.37s |
   | `props:rF,rC,rPois,rElec` | seed | 1.11s | 53.93s |
   | `props:rF,rC,rPois,rElec` | shallowest | 2.08s | 54.27s |

   Both close: the store answers directly, well under the 22-54s SQL
   fallback it replaces.

   **New regression surfaced by the same run, on a shape neither this
   ticket nor #8 named: `props:rF,rC` under `shallowest` cost the store
   589.60s against SQL's 54.99s** — the store is the slower path here, still
   agreeing on the answer. `props:rF,rC` matches 29,983 seeds, far wider than
   either shape the ticket names (49 and 87), and it is item 8's O(matched)
   shape (below) now also paid on the verify-batched side for `Narrowing`
   terms: `Db.verify_terms_with_depth` walks and verifies the whole matched
   set before `ranked_page` cuts a page, the same way `Rank.Shallowest`
   already did for `Exact`-only terms — the paragraph above called this
   "unchanged scope, not a new regression" on correctness grounds, which
   held, but understated the cost at this match size. Filed as its own
   ticket (`72e69ef74c3b`) rather than folded into #8: it needs a timing
   curve over match-set size before it's clear whether the fix is #8's
   depth-band walk or a `Narrowing`-specific too-broad guard.

**Measured, 10,000-seed local `corpus.db`, 0.34.1, `D:8`, 2026-09-15:**

- **Builder correctness.** Every one of the 1,294 criteria's `card` equals
  `count(distinct seed)` over the matching `Db.criterion_where` predicate,
  checked across all five kinds. `sum(card)` equals `sum(n)` over
  `search_postings` exactly (711,224 both).
- **Equivalence.** Eight query shapes — broad and rare, split and combined,
  single- and multi-property, both rank orders — produced identical matched
  sets on the store and SQL paths, full pagination, zero duplicates. Order
  differs as designed: the store pages numerically, SQL lexicographically.
  `props:Conj&rank=shallowest` produced an identical depth sequence on both.
- **Latency.** The `props:` shapes are where the store's value shows even at
  10k: `props:Conj` 2.9ms store vs. 214ms SQL (74x), `staff props:Conj` 2.8ms
  vs. 87ms (31x), `props:rF,rC` (narrow + verify) 7.7ms vs. 63ms (8x). Plain
  item terms are at parity at this corpus size — the SQL path's covering seek
  is already cheap at 10k, and what the store removes is the growth in
  matched rows, which 10k seeds is too small a corpus to show. `name~Wyrmbane`
  confirms the store declines (both paths land around 4ms, since this corpus
  is far too small to expose the cost #7 exists to avoid).
- **The uncapped ranked search.** `potion:haste&rank=shallowest` matches 7,336
  seeds, above `Rank.sort_limit` (5,000): the store answers HTTP 200 in 7.9ms,
  correctly ordered; the SQL path answers HTTP 400, "too many seeds to rank."
  This is the behaviour the design exists for, and the one thing the SQL path
  cannot produce at any latency.

## The claim

Search never needs to touch `entries`. "Which seeds contain X" is set membership
over a *closed, small vocabulary* against a *large seed count* — the shape
inverted indexes exist for, and the opposite of the shape `entries` has.
Everything slow today comes from answering a seed-granular question with
row-granular storage: 135.5M rows scanned, grouped and `distinct`-ed to recover
1.3M bits of membership that could have been stored directly.

The ticket proposes adding `depth` to all 135.5M `entries` rows and forking every
search index into a depth-ordered variant. That is one route to early
termination. This is a cheaper one, because at seed granularity shallowest depth
is a property of the *membership structure*, not a new indexed column.

## The vocabulary is closed and tiny (measured)

**Re-measured on the production corpus** — 1,299,999 seeds, 0.34.1, `D:8`,
135,537,055 `entries` rows, 2026-09-15. The vocabulary did **not** grow with
130x the seeds, which is the closure claim holding up under the only test that
matters:

| vocabulary | 10k local | 1.3M prod |
|---|---|---|
| `(base_type, sub_type)`, floor only | 427 | **427** |
| `(base_type, sub_type)`, shop only | 417 | **419** |

Two shop types appeared in 130x the corpus. That is the whole drift. A criterion
id space of ~1,300 is safe to build a format around.

The remaining rows are still local-only (10k, 0.34.1, D:8, 2026-09-11):

| vocabulary | size |
|---|---|
| props, bare | 55 |
| `(base_type, prop)` | 170 |
| unrand roster | 112 |
| ego (optional) | 85 |

Floor and shop item types are stored separately, so the union is not counted
twice. Everything above comes to **~1,300 criteria**, and the same corpus holds
1.3M seeds at production size. Note this is larger than the ~800 the item
vocabulary alone suggests: props and unrands are required, and they are ~340
criteria between them.

**Amended 2026-09-15, against what actually built.** Two things the table
above doesn't say. First, props split into floor and shop lists too, once the
shop-exclusion default's position field reached `Props`
(`docs/architecture.md`, "Where an item sits is part of the criterion"): the
built vocabulary is 224 floor-prop rows (55 bare + 169 base-typed) plus 225
shop-prop rows, not the one list of 225 implied above. Second, no row here is
a multi-property criterion — `props:Conj,Alch` is not a fourth thing to count,
it is two of the rows above intersected and then re-checked against SQL,
because a seed-level intersection cannot confirm the properties landed on one
item (`Search.Criterion.Props`'s whole reason to exist; see *Built*, #3, for
the resolution). The measured total across all five built kinds — floor item,
shop item, artefact, floor prop, shop prop — is **1,294** (10k local, 0.34.1,
`D:8`, 2026-09-15), close to the ~1,300 predicted here despite a different
composition: the unrand-roster and ego rows below never shipped as catalog
rows at all (`Name_like` stayed `Criterion_id.Unindexed`, per *Settled*), and
shop-prop's doubling happens to roughly offset their absence.

Density per seed is what decides the layout (see the store section). **Measured
on the production corpus**, 1,299,999 seeds, 0.34.1, `D:8`, 2026-09-15:

| distinct pairs | count | per seed |
|---|---|---|
| `(seed, floor item-type)` | 66,646,422 | 51.3 |
| `(seed, shop item-type)` | 12,647,335 | 9.7 |
| `(seed, prop)` | 5,933,947 | 4.6 |
| `(seed, artefact)` | 1,127,766 | 0.87 |
| **total** | **86,355,470** | **66.4** |

The 10k extrapolation predicted ~62/seed and ~80M pairs; the real figures are
66.4 and 86.4M. **Density does not run away with corpus size** — the prediction
was 8% low, not the 2-3x the extrapolation risked. This is the measurement the
earlier draft called for before committing to a format, and it passed.

## Ordinals: append order

Every seed gets a dense ordinal in the order it was first ingested, stored as an
`ord -> seed` array and a `seed -> ord` map. This replaces the seed-text order
the interface pages in today.

**The map must be assigned at insert and persisted, not recomputed.** Ingest is
parallel and interleaved — `tools/corpus-fill:89` chunks a `seq` across cores —
so insert order is timing-dependent, and a build that derived ordinals by
re-scanning would produce a different assignment on every rebuild. Persist it
(~1.3M rows), and a rebuild reproduces the assignment instead of guessing at it.
That is what makes "stable for a `(version, fill)`" true rather than aspirational.

What this buys:

- **Fills append.** A new seed takes the next ordinal; nothing existing moves.
- **Deepening sets bits on existing ordinals.** Deep generation is a strict
  prefix extension, so a deepened seed's memberships only grow and its shallowest
  depth never gets shallower. Monotone in both operations.
- **No full rebuild is required by either.** This is the whole reason append
  order was chosen; seed-text order would have put a new seed in the middle of
  every array.
- Append order effectively tracks ascending seed number, which retires the
  "seeds are `text`, so `1025` sorts between `10101` and `10447`" footnote in
  `AGENTS.md` — without storing a padded sort key, which is what the current
  note forbids.

## The store: one posting list per criterion

Per version, per criterion, a list of postings sorted by ordinal. A posting
carries the ordinal, the shallowest depth at which the criterion is satisfied,
and the count. Membership is presence in the list; there is no separate
membership structure and no `group by ... having`.

The section below works through why this is a posting list rather than the
dense array the first draft proposed.

**What the cell costs.** The two axes that want bits are depth and count, and
only one of them is bounded:

- **Count fits in 4 bits.** `9x artefact` and `9x floor potion:haste` are real
  measured queries (`docs/architecture.md`), so 3 bits is not enough, but a
  threshold above 15 is not a question anyone asks — reject it at the parse
  boundary rather than saturating silently.
- **Depth does not fit in 4 bits, and this is not marginal.** `depth.ml`'s table
  is *branch entrances*: `Depths` is 15 and `Zot` 19 before either branch's own
  levels are added, so a reach-order depth runs past 30. `Depth.unknown` is
  `Int.max_value` and needs a reserved encoding of its own. A 4-bit depth field
  is already wrong for anything past D:15 — not "wrong the day a Depths fill
  lands". **Drop it as an option** rather than leaving it in the table for
  someone to pick for its simplicity.

That leaves the real choice, which is **dense versus sparse** — not a byte count.
Size is no longer the deciding axis: there is 1.6 TB on `/corpus` and the corpus
is 8 GB of it. Two things decide it instead, and they point the same way.

**The store must be resident, and RAM — not disk — is the scarce resource.**
The host has 31 GB, of which **~6 GB is available**: it is shared with a
neighbouring project that routinely holds 14 GB RSS (measured 2026-09-15). Disk
is not a constraint at all — `/corpus` is a 1.6 TB pool with 8.4 GB used. So the
residency number is the budget, and it is a *tight* one:

| layout | size at 1.3M | at 10M | fits in ~6 GB at 10M? |
|---|---|---|---|
| 2-byte cell, dense | 3.38 GB | 26 GB | no |
| 1-byte cell, dense | 1.69 GB | 13 GB | no |
| **sparse postings, 5-6 B each** | **0.43-0.52 GB** | **3.3-4.0 GB** | **yes** |

All three fit today. Only sparse survives 10M on this host, and 10M is on the
roadmap.

**A dense array over this corpus is 95% padding.** 86.4M meaningful pairs
against 1,300 criteria × 1.3M ordinals is a **5.1% fill rate**. The dense
layouts spend 1.6 GB and 3.2 GB respectively to store 86M facts.

**Dense is O(corpus) per query regardless of selectivity.** This is the stronger
argument and it was previously filed as a someday-note. A dense cell means a
32-seed `name~Wyrmbane` scans the same 1.3M cells as a 1M-seed `potion:haste`.
That is precisely the property this plan exists to remove from the SQL path —
cost scaling with the corpus rather than with the answer — and a dense array
reintroduces it one layer down. It is fast enough at 1.3M to hide, which is what
makes it a trap: it degrades linearly and silently as the corpus grows.

**Selectivity spans five orders of magnitude, which is what makes the dense
scan indefensible.** Measured 2026-09-15 at 1.3M: `artefact` 86.8% of seeds,
`potion:haste` 76.4%, `scroll:acquirement` 32.6% — against a `name~Wyrmbane`
that matches on the order of tens. A dense array charges all of them the same
1.3M-cell scan. Postings charge each one its own size.

So: **sparse postings, sorted by ordinal, one list per criterion.** Intersection
is a merge over the shortest list first, which makes cost proportional to the
rarest term — the opposite of the dense behaviour. Membership is presence in the
list, depth and count ride along in the posting, and the union case (`Item` over
floor and shop) is a merge rather than an `OR` over full-width arrays.

The one thing dense was genuinely better at is the very broad criterion: a 98%
`scroll:teleportation` posting list is larger than its bitmap. That is worth a
hybrid *later* — a bitmap for criteria above some density, postings below — but
it is an encoding detail behind the same interface, not a different design. Do
not build it until a measurement asks for it.

## Measured at 1.3M (2026-09-15)

Everything in this plan that was extrapolated from the 10k fixture has now been
measured on the production corpus: 1,299,999 seeds, 0.34.1, `D:8`,
135,537,055 `entries` rows, `/corpus/corpus.db` on `dcss.garden`.

| claim | 10k extrapolation | 1.3M measured | verdict |
|---|---|---|---|
| floor item vocabulary | 427 | 427 | closed |
| shop item vocabulary | 417 | 419 | closed |
| prop vocabulary | 55 | 55 | closed |
| pairs per seed | ~62 | 66.4 | 8% low, holds |
| total pairs | ~80M | 86.4M | holds |
| store fill rate | — | 5.1% | sparse |

The vocabulary claim is the one that could have killed the design, because the
criterion id space is baked into the format. It survived 130x the seeds with two
new shop types. The density claim is the one that decided dense vs sparse, and
it came in close enough that the sizing table can be trusted.

~~**The build pass is cheap, which was assumed and is now measured.** The exact
shape the builder needs for the largest criterion class —

```sql
select base_type_id, sub_type_id, seed, min(level_id)
from entries ... where cost is null
group by base_type_id, sub_type_id, seed
```

— emits all 66,646,422 floor postings in **34 seconds** (99% CPU, 5.7 MB
resident), grouped in criterion order with shallowest depth already computed by
`min()`. The covering index `entries_search_type` supplies the order, so there
is no sort. Extrapolating to all four classes, a **full store build is ~1-2
minutes**, not the "minutes, at fill time" the plan hedged at.~~

**Wrong on its own terms, not just unmeasured at scale — see *Built*, #4.**
`level_id` is a `strings` dictionary id and carries no order (`schema.sql`'s
comment on `seed_levels`), so `min(level_id)` is not the shallowest depth; it
is an arbitrary intern-order id. The query above times something the builder
does not run. What shipped joins a temp `level_depth` table
(`level_id -> Depth.of_level`) and takes `min()` over that instead
(`lib/corpus/search_index.ml`), so the 34s figure cannot stand in for it even
relabelled as "slow but correct." What is measured, on the *right* query: the
builder's full pass, all five criterion kinds, is **1.1s** on the 10,000-seed
local `corpus.db` (0.34.1, `D:8`, 2026-09-15) — 1,294 criteria, 711,224
postings in 2,319 blocks. There is no 1.3M-scale timing of the corrected
query; take one before trusting a minutes figure at that size again.

That still reframes the maintenance section, just on the 1.1s figure rather
than the struck one, and with less confidence than "reframes" implies until
the 1.3M number exists. Monotone catch-up for fills and deepening is still the
right design, and a full rebuild is cheap enough on the 10k evidence to be the
fallback for any case where incremental correctness is in doubt — but that is
resting on a corpus 130x smaller than production, not on the measurement this
paragraph used to cite.

## Query shapes

- **Intersection**: merge the terms' posting lists, shortest first, keeping
  ordinals present in every one (and meeting every count threshold). Cost is
  proportional to the *rarest* term, not to the corpus.
- **Union** (`Item` over floor and shop): merge for membership, `+` for counts.
  Derived, never stored.
- **Paging**: iterate ordinals from a cursor. The cursor is an ordinal, and the
  order is the store's own — undefined, but consistent for the served generation.
- **`Shallowest`, single *and* multi-term**: walk depth bands ascending; a seed is
  in band `d` if every term's shallowest depth is `<= d`. Stop at the page. Exact
  min-depth order, early termination, and no cap.

  This dissolves the ticket's concession that multi-term ranked search must stay
  capped. The reason it had to be capped was that `correlated_select` emits a
  *seed*, never a depth (`db.ml:1620`), so a seed matching the driver at D:8 and a
  second term at D:2 ranks 2 and no index on the driver can surface it. Here
  depth is stored per term, so the min over terms needs no `entries` access.

- **Counts**: `cell >= n`, or the side table for the whitelisted criteria.

## The record store stays SQLite; two round trips

The store answers *which seeds*. It holds no names, levels or evidence. The path:

```
typed query -> N posting lists -> merge / band -> page of ordinals
            -> ordinals to seed text
            -> SQLite: term_hits for <=page seeds, per term   [round trip]
                     (the seed page itself, unchanged)
```

The second round trip is bounded by page size × terms, which is what today's
`term_hits` already is. The seed page, catalog rendering, heat scores and fills
are untouched. The store is version-scoped and derived, like `strings_fts`.

### The criterion catalog

The build produces a catalog the parse boundary can validate against. This
improves a current asymmetry: an unknown `props:` name is rejected
(`lib/web/params.ml:89`) because running it would report "no such artefact" —
false and indistinguishable from true — while an unknown `<base>:<sub>` is
accepted and matches nothing (`params.ml:53`). With a catalog both can be
rejected, or both left permissive, deliberately. The catalog also replaces
the 71.5s cached `item_pairs_sql` datalist with ~1,300 rows.

**Validation has not shipped; the datalist has (2026-09-16).** `params.ml`
still validates nothing against the catalog. `Db.distinct_criteria` reads item
pairs from it whenever the store is current, unioned with the deep cohort's
entries, and falls back to `item_pairs_sql` otherwise. Identical output, 340ms
down to 1ms at 10,000 seeds (local, 2026-09-16).

## What this changes about the cuts

The terms that were going to be dropped were the wrong lever. Dropping
`artefact` removes one broad criterion and leaves `scroll:teleportation` (98% of
seeds), `potion:haste` (76%) and shop-item-any (80%) exactly as broad — and
broadness is not a problem for an inverted index — though a 98% criterion is the
one case where a bitmap beats a posting list, which is the hybrid noted below.

So these revert to *product* decisions:

- **`artefact`**: keep it if it is a question worth asking; it is one more list.
- **Features and uniques**: already dropped 2026-09-10 for the right reason (no
  negation, so the forward form answers the opposite of what is wanted). That
  reason stands and this does not change it. They would be cheap if the negation
  operator ever arrives.

The one requirement that does not fit is **free-form `name~`**. Artefact names are
unbounded (24,858 distinct at 10k, growing with the corpus), so they cannot be a
criterion id. Two options:

~~**Keep the trigram path as a filter** over the store's candidate set. It
stays the one unbounded shape, stays detached, and stays the only query that
can be slow — but it is *faster* than today, because the trigram scan now
runs over a narrowed set instead of the whole dictionary.~~ **Not built, and
not buildable in this direction — see *Built*, #7, for the numbers.** The
store cannot narrow ahead of `name~`, because its merge drives on the rarest
posting list and a `name~` term's companions are usually broader than the
fragment — the reverse of what a filter needs. What shipped instead: a query
carrying `name~` runs the SQL path whole, exactly as before this store
existed. Record this as not done, not as done differently.

~~**`name~` stays unscoped by floor/shop, and that is now permanent.**~~ **This
did not ship either — reversed, not permanent.** Ticket `7cbd40b3ed` carried a
follow-up to make name search floor-only once the covering problem on
`entries_search_name` was solved; this paragraph argued for closing it as
dropped instead, tolerating the floor/shop inconsistency in help text rather
than narrowing the criterion. The code went the other way: `Name_like` carries
a `position` field "for uniformity but `Params` builds only `Floor`"
(`lib/corpus/search.mli`), and `docs/architecture.md` states plainly that
`name~` "has no shop form." So the domain argument below for *tolerating* the
inconsistency is moot — there is no inconsistency in the shipped criterion,
because there is no shop form to disagree with the rest of search's
floor-by-default. Left here for the reasoning, not the conclusion: the domain
argument was ~16% of terms are `name~`, mostly unrands, and an unrand behind a
counter is unbuyable early anyway.

Restricting `name~` to the unrand roster was considered and rejected. It does not
make the criterion correct, only small: matching an unrand by name substring is
wrong at any roster size, because randart weapons and books roll names containing
unrand names — `%Cerebov%` matches 55 rows that are not the sword of Cerebov. A
closed vocabulary of 112 inherits that bug wholesale.

## Sequencing: the shop-exclusion default lands first

**Shipped 2026-09-15, before this, as sequenced below.**
`docs/plans/shop-exclusion-default.md`'s flip to floor-only has landed:
`Floor_item`/`Shop_item` are gone from `lib/corpus/search.mli`, and `position`
is now a field on `Item`, `Name_like` *and* `Props` — which is why the
built vocabulary has separate floor-prop and shop-prop catalog rows that this
plan's own vocabulary table did not anticipate (*The vocabulary is closed and
tiny*, above). The three reasons below are why it went first, not a live
question:

1. **The criterion id space is baked into the on-disk format here.** Building
   the store against `Floor_item`/`Shop_item` and flipping afterwards costs a
   format bump or a builder shim, for a distinction already decided against.
2. **Deferring the flip does not shrink it.** Its diff is almost entirely above
   the storage boundary — `Criterion.t`, `params.ml`, `views.ml`, the docs, and
   ~53 test references — and this store's interface consumes the same
   `Search.t`. Deferring relocates that work onto a mid-rewrite codebase.
3. **The flip needs no schema change and no reindex; this does.** It can ship on
   its own schedule, and this cannot.

Shipping it first also lets it *decline* two decisions rather than resolve them,
because both live in the slice this design deletes (`criterion_where`'s
`cost is`-null arms and `criterion_driver_rank` entirely): the new `Props`
driver-rank asymmetry, and the `entries_search_name` covering optimisation. Both
are recorded as amendments there.

## Maintenance

- **Build** is one pass over `entries`, joined to a temp `level_depth` table for
  order (*Built*, #4 — the plan here originally read the order off
  `min(level_id)`, which does not carry one). ~~**Measured at ~34s for the
  floor class at 1.3M**, so on the order of 1-2 minutes for a full build.~~
  Measured instead at **1.1s for the full build, all five kinds, on the
  10,000-seed local corpus** (0.34.1, `D:8`, 2026-09-15) — no 1.3M timing of
  the corrected query exists yet.
- **Fills** append ordinals and append postings. **Deepening** updates postings
  on existing ordinals — membership only grows, shallowest depth only shrinks.
  Both monotone; neither needs a rebuild, though there is no incremental
  catch-up built either (*Built*, #6) — a full rebuild is the only maintenance
  path today, cheap enough at 10k to be that fallback, unverified yet at 1.3M.
- ~~**Atomicity**: a rebuild must not be visible half-written. Build to a new
  file and rename, or version the store, rather than updating in place under a
  live server.~~ Resolved by *Built*, #1: tables in `corpus.db`, not a file, so
  atomicity is one ordinary WAL transaction (`Search_index.build`) rather than
  a rename or a version tag — a reader pages across it on WAL's own old
  snapshot. Ordinal assignment is reproduced, not recomputed, so a swap does
  not reorder the listing.
- **Staleness is silent in the worst direction** — the lesson `strings_fts`
  taught, and still true here: a criterion missing from a stale store reads as
  "no seeds," a true answer about the build. ~~The store needs a currency mark
  and a refusal in the same shape as `strings_fts_state`~~ — it got the mark
  (`search_index_state`, a high-water mark over `entries.id`) but not the
  refusal: `page` is consulted only when `Search_index.is_current`, and a
  `false` there falls back to the SQL path instead of erroring. That is a
  deliberate reversal of the `strings_fts` precedent, not an oversight — see
  `docs/architecture.md`'s search section for why a store's fallback is safe
  where a dictionary scan's is not.

## Risks

- ~~**A second store is a second thing that can disagree with the corpus.** The
  fts experience is the template: derived, version-scoped, refusing rather
  than falling back when stale.~~ Half the template held: derived and
  version-scoped, yes. Refusing did not — this store falls back to SQL
  instead, on purpose (above, and `docs/architecture.md`). The risk named here
  is still real, just answered differently: an out-of-sync store can only
  under-answer (fall back to a slower correct path), never lie, because
  `page` running at all already implies `is_current`.
- **Snapshot skew** between the store and SQLite during a fill: a candidate
  ordinal whose evidence query returns nothing. Bounded today by `SEED_POOL_SIZE`
  concurrency; swap the store with, or ahead of, the corpus.
- **The ordinal assignment is the one piece of state that is not derived.** Lose
  it and every stored cursor and equivalence fixture moves. Persist it.
- **Memory residency** grows with seeds and vocabulary: ~1.6 GiB at 1.3M for
  one-byte cells, ~12 GiB at 10M. That is the first number to watch, and it is
  the argument for the leaner bitmap layout if the vocabulary keeps growing.

## Verification

1. **Equivalence is the gate.** For a spread of criteria — broad (`potion:haste`),
   rare (`name~Wyrmbane`), split (`shop`/`floor`), prop-with-base — the store's
   member set must equal the current SQL result set exactly, at 10k and on a prod
   replica. This is what proves the store is a faithful projection.
2. **Ordering equivalence for `Shallowest`**, including a high-M single-term query
   (which cannot run today) and a multi-term query where a non-driver term's
   shallowest hit beats the driver's.
3. **Round-trip**: every criterion's membership cardinality equals its `count(*)`
   in the corpus, per version.
4. **Consistency across a store swap**, which is what "undefined" has to
   survive. Two processes reading one store file agree trivially; the real case
   is a reader paging across a rebuild — page 1 served from generation N, page 2
   from N+1. Append-order ordinals make that safe for a *fill* (nothing moves),
   but not for a rebuild that changes the criterion set or re-derives ordinals.
   Test that path explicitly: page, swap the store, page again, assert no repeat
   and no skip — or pin the generation for the life of a cursor.
5. **Timings against the target**, not a copied figure: median and p99 over a
   spread of shapes at prod scale. The design predicts O(page); anything that
   scales with matched rows is an implementation bug.
6. **`just ci`**, with a local 10k build as the fixture.

## Work, if built

- `lib/corpus/` — a new module (the store, its arithmetic, its format) behind an
  interface exposing only `search : t -> Search.t -> Match.t list` and its
  inverse `build`. Nothing above it learns about ordinals.
- `bin/` or `tools/` — the builder and the catch-up path called by the deepen
  generator.
- `lib/corpus/db.ml` — `search_seeds{,_ranked,_unranked}` keep the SQL
  predicates as the fallback and consult ordinals first when the store is
  current — not the replacement this line predicted; see *Built*, #5.
- ~~`lib/corpus/search.ml{,i}` — `Rank.sort_limit` and `is_too_broad`
  retire.~~ Did not retire — see *Settled*, above.
- ~~`lib/web/seed_web.ml` — `search_is_cheap` retires for store-backed
  criteria; the detach decision becomes "does this query contain a
  `Name_like`".~~ Did not retire either: `search_is_cheap`
  (`lib/web/seed_web.ml`) is byte-for-byte what it was before this landing.
  `Db.search_seeds` decides store-vs-SQL *inside* the accessor, so the web
  layer's inline-vs-detach call has nothing new to key off — it still has to
  assume the SQL fallback shape for anything not proven cheap, store or no
  store.
- `tools/corpus-reindex`, `docs/architecture.md`, `AGENTS.md` — done; see
  `AGENTS.md`'s "Filling the corpus" and its `search_index_state` note.
- Tests first: equivalence and ordering before the SQL path is removed — the
  SQL path was not removed (*Built*, #5), so this is the state the tests
  should still be read against.

## Still open

- ~~**Cell width**~~ — settled: sparse postings. Dense is unaffordable in RAM at
  10M and reintroduces O(corpus) cost regardless of selectivity. ~~What remains
  open is the *encoding* of a posting (varint delta + depth + count) and
  whether very broad criteria get a bitmap fallback — both behind the same
  interface.~~ The encoding shipped exactly as sketched — `Posting.encode_block`
  is varint delta, then depth, then count, 512 postings/block
  (`lib/corpus/posting.ml`). The bitmap fallback for a very broad criterion did
  not, and is still open; nothing has asked for it yet.
- ~~**`name~`**~~ — ~~settled: trigram filter over the candidate set.~~ **Not
  settled after all — reopened and closed the other way, 2026-09-15.** This is
  not implemented and not implementable in the direction described: the store
  cannot be the outer loop for a term rarer than its own rarest posting list,
  so it cannot filter a candidate set for `name~` the way it does for `Props`.
  What shipped instead: `page` declines the *whole* search — not just the
  `name~` term — whenever any term has no catalog row, and the SQL path
  answers it in full, same as before this store existed. See *Built*, #7, for
  the cost that forced this and *Settled*, above, for the corrected claim. The
  *other* direction — resolve the fragment to seeds first, then intersect —
  is unbounded for a broad fragment and remains genuinely open, unbuilt, and
  not merely deferred.
- ~~**Store format and location** — a companion file (memory-mapped) with a
  catalog table, or blobs in SQLite. The catalog is needed either way.~~
  Settled by building: tables in `corpus.db`, no companion file. See *Built*,
  #1, for why.
- **SQL: shadow or retire.** Retire the predicate path once the equivalence test
  is green at prod scale; keep `term_hits` forever as the evidence source, and
  free-form `name~` as the single SQL-only shape if it survives. Maintaining two
  implementations of one predicate semantics is the real long-term cost, so do
  not leave it shadowed indefinitely. Still open exactly as written — see
  *Built*, #5: the equivalence run this needs has not happened at prod scale,
  only the 10k and 100k-staging checks in *Built* have.
- **A shuffle permutation** — not needed. Seeds are 64-bit uniform and fills walk
  ascending ranges, so append order is already an unbiased sample; a shuffle
  changes the cosmetic look, not the statistics. If it is ever wanted, make it a
  stateless bijection over the ordinal space (a keyed Feistel, cycle-walked), not
  a stored permutation array, or it breaks the stability the ordinals exist for.