# Corpus scaling

What bounds how big the corpus can get, and which of those bounds actually
bind. The short answer: **disk does not bind, and neither does fill throughput;
scoring memory, read latency, and DCSS's release cadence do.**

## The measured cost of a seed

Measured on the 1.3M corpus (1,299,999 seeds on 0.34.1 plus 10k each on
0.33.1/0.32.1 — 1,319,999 total, `D:8`, server, 2026-09-07, on
`recordsize=16K, compression=lz4`):

| | |
|---|---|
| `logicalused` | 15.2 GB |
| `used` | 7.98 GB |
| `compressratio` | 1.90x |
| bytes/seed logical | 12,328 |
| **bytes/seed on disk** | **6,488** |

**These figures are a property of the dataset's ZFS settings, not of the
schema.** The same file on the same day read 2.79x and 4,197 bytes/seed under
`recordsize=64K, compression=zstd`; it was moved to 16K/lz4 because 64K records
cost 16x read amplification on every scattered 4K page read, which is what the
corpus does whenever a query is selective. The ratio bought by 64K is exactly
the thing that made reads slow — see "The recordsize change" below. Storage was
never the binding constraint, so trading 2.5 GB to take `name~dragon` from 9.9s
to 0.22s is not a close call.

Superseded, and superseded *for a different reason* — corpus growth rather than
a settings change: ~~4,608 bytes/seed on disk, 2.62x, at 30k~~ (2026-09-02), and
before that ~~2.51x on a 500-seed sample~~. Small samples read pessimistic
here — fixed schema and index overhead dominate, and the string vocabulary has
not saturated. That prediction held across a 44x change in corpus size: at a
fixed 64K/zstd the ratio improved 2.62x → 2.84x and per-seed cost fell 9% while
the corpus grew. Take the figure from the largest corpus to hand, not from a
sample — and read the recordsize off the dataset before comparing two figures.

Take these figures **after** post-fill maintenance. Mid-fill the same corpus
read 4,022 bytes/seed on disk at the 1M mark (then still 64K/zstd), with a
50 MB uncheckpointed WAL and no `analyze` — write-amplified pages that the
checkpoint reclaims, and a number that is neither the fill's nor the settled
one.

The whole-file figure for comparison is 3.02x (laptop, 10k, `D:8`, 0.34.1,
2026-09-01, 102 MB), which is what a compressor achieves when it is handed the
whole file at once rather than a record at a time. Per-record compression is
necessarily worse, and the gap widens as the record shrinks: 2.6x at 64K/zstd
against 3.0x whole-file, and 1.9x at 16K/lz4. That last gap is the price of
random access, paid deliberately.

Per-seed logical cost is not uniform across versions: at 10k each, 0.34.1
carried 1,027,389 entries against 0.33.1's 914,588 and 0.32.1's 903,713, so
0.34 is ~12% denser. Parchments are most of that (see `AGENTS.md` on
`base_type = 'book'`). The 1.3M fill holds 133,652,360 entries for 0.34.1
(135,470,661 across all three builds; the figure drifts upward by a few hundred
as the deepen queue serves requests, so it is a reading, not a constant)
against those same two 10k blocks, so any cross-version comparison here is now
a comparison across a 130x difference in sample size — see "Versions do not
share seeds" below.

Interning does amortise across versions — the second and third fills share most
of their item and monster vocabulary with the first — which is what makes
multi-version corpora cheaper than the per-version figures suggest.

## What a target costs

At 6,488 bytes/seed on disk (16K/lz4 — see the note on settings above):

| seeds | on disk |
|---|---|
| 1M | 6.5 GB |
| 10M | 65 GB |
| 100M | 649 GB |
| 200M | 1.30 TB |

These are storage only. **Scoring a corpus costs far more memory than storing
it costs disk**, and past ~1.3M that is the number to plan against — see
"Rescore" below.

## What actually binds

**Not disk.** 200M is ~1.3 TB, which is an ordinary amount of disk to buy, and
the pool it would live on already has 1.68 TB free. The 16K/lz4 switch raised
this line by 55% and did not move it into contention.

**Compute.** 611 seeds/min wall, sustained over the 27.3-hour 1M-seed fill
that took the corpus from 300k to 1.3M (8-way, prod, 0.34.1, `D:8`,
2026-09-04/05). That puts 100M at ~114 days of continuous fill and 200M at
~227. Three earlier figures are all misleading: 612/min at 500 seeds is
measuring crawl's per-process startup more than generation (8 chunks of 63),
1004/min at 4000 seeds was taken against a nearly empty corpus, and ~~717/min
over the 30k run~~ divided a seed count by a progress-log elapsed that did not
cover the whole wall time.

Quote the **wall** rate when sizing a fill and the **per-chunk** rate when
asking whether cost varies with corpus size; they answer different questions
and differ by ~8x here because eight workers run at once.

**The fill rate does not decay.** Superseded: ~~the 30k run's three sequential
fills (734.4 / 715.1 / 705.1 seeds/min) read as ~4% decay per 10k~~. Three
points taken across three *different versions* could not separate corpus growth
from a per-version difference, and the 100k fill first settled it. The 1M-seed
fill from 300k to 1.3M is the strongest form of the measurement — one version,
one continuous run, 4,000 chunks, **zero chunk failures**, twelve equal slices
of 27.3 hours (0.34.1, `D:8`, 8-way, prod, 2026-09-04/05):

| slice | chunks | seeds/min |
|---|---|---|
| 1 | 336 | 76.7 |
| 2 | 336 | 76.5 |
| 3 | 334 | 76.6 |
| 4 | 332 | 76.4 |
| 5 | 334 | 76.3 |
| 6 | 332 | 76.4 |
| 7 | 333 | 76.4 |
| 8 | 334 | 76.3 |
| 9 | 331 | 76.0 |
| 10 | 332 | 76.1 |
| 11 | 333 | 76.2 |
| 12 | 333 | 76.1 |

**−0.8% first slice to last**, across a corpus growing 4.3x during the run and
13x larger than the one the 100k table measured. The earlier ~1.5% drift over
10x now reads as the same noise floor seen from fewer points. **Fill cost is
independent of corpus size** — over 300k → 1.3M there is no decay to
extrapolate and no asymptote to find, and ZFS compression on `/corpus` is not
visible in it.

The rate is also stable *within* a run: the same band held at 300k
(2026-09-03) and across every hour of the 27.3-hour fill.

The per-chunk log is what made this answerable, and it stays: an average over a
whole run cannot tell an asymptote from a decline. (The absolute rate here is
per-chunk and not comparable to the 611/min whole-fill figure above.)

**Rescore, which was the binding constraint and is now bounded by
`recompute_surprise` rather than by the scoring scan.** At 1.3M the pass used
to die: the OOM killer took it 11 minutes in, at **29.0 GiB resident** on a
31 GB box (`anon-rss:30437800kB`, 0.34.1, prod, 2026-09-05). The corpus filled
and verified clean; only the scoring pass died. That was a deliberate
experiment — the fill was sized past the projected ceiling to find which side
of it we were on — and the answer was that 1.3M was past it.

**Sharding the scoring scan fixed it the same day.** `Db.rescore` takes
`?shards`, splitting the scan into N seed ranges so only one shard's rows are
live at a time; scores are byte-identical at any N, because `Heat.score` reads
one seed's observations plus `surprise` and `n`, both fixed above the loop.
Measured on the same box and corpus at `-shards 16`:

| | before | after |
|---|---|---|
| peak RSS | 29.0 GiB (killed) | **9.10 GiB** |
| wall | died at 11 min | **30m29s** |
| outcome | OOM | exit 0, 1,299,999 of 1,299,999 seeds scored |

**Two constraints on how the shard bounds are computed**, both measured on the
1.3M corpus and neither obvious from the code:

- Bounds must be derived from the data, not computed over the seed space.
  `seed` is unpadded decimal TEXT, so leading digit 1 holds 3.6x its share of a
  prefix cut — and the largest shard sets the peak.
- Every shard must be a *closed* range, the last one included. An open-ended
  upper bound loses the primary-key range seek and degenerates to a full scan:
  70s against 2.7s for the same 6.03M rows. Modulo sharding is fatal for the
  same reason and is not offered.

Size K from a memory budget: roughly 120 MB fixed plus 24 KB per seed in the
shard, so 1.3M at K=16 peaks near 2.1 GB. That per-seed figure averages over a
non-uniform population — validate with a single-shard dry run before committing
a long pass.

`tools/corpus-fill` derives K itself, one shard per 100k seeds in the version
(13 at 1.3M), overridable as `SHARDS`. It did not until 2026-09-08: sharding
landed in `Db.rescore` and `bin/rescore.ml` on 2026-09-05 but the fill's own
final rescore kept calling it at the default K=1 — the configuration that had
just been OOM-killed. Nothing caught it because the equivalence property is
tested in `test_db_heat.ml` against the library, and the caller is a shell
script.

The 9.10 GiB peak is now **entirely `recompute_surprise`**, which is untouched
and unsharded — it measured 9.06 GiB before the change and 9.10 GiB after. The
sharded scoring phase that used to climb 9 GB → 29 GB now holds *flat* at
9.05 GiB for its whole 20 minutes, which is the retained high-water mark from
the surprise pass rather than anything scoring allocates.

So the ceiling moved but did not disappear, and it moved onto a different
function. `recompute_surprise` and `early_spell_counts` (22.3M book rows at
1.3M) are still whole-cohort and still materialise; they fit today and are the
next thing to break. Shard them before the next doubling.

The old per-row analysis still explains why the scan was so expensive: each row
boxes four separate strings, and `group_observations` builds two hashtables
over the list before any of it can be freed. That is why bounding *residency*
rather than reducing total work was enough — the work was never the problem.

**It was not a ZFS ARC problem, which was the other hypothesis.** Sampled at 5s
through the failed run, ARC yielded on demand the whole way — 18.2 GB down to
0.6 GB as the rescore climbed 0.8 GB to 29.0 GB. The shrinker kept up; there
was simply nothing left to give. Capping `zfs_arc_max` would not have helped,
and neither would any other tuning: the pass genuinely needed more memory than
the machine had.

Superseded, kept because the extrapolation is what sized the fix: ~~~22 GB per
million seeds, ~45 GB at 2M, ~223 GB at 10M~~. Those described the unsharded
fold and no longer predict anything. The sharded scan's residency is set by
shard size, not corpus size — at K=16 a 1.3M cohort is 81,250 seeds per shard —
so the scoring phase no longer scales with the corpus at all. What still does
is `recompute_surprise`.

Time, for what it is still worth: measured on the 100k fill (0.34.1, server,
2026-09-02) the fill's parallel phase took **39s** and the rescore **1391s**,
36x the work it was scoring; a 300k rescore took **18m20s** (2026-09-03).
Superseded: ~~4.31s at 10k, linear in rows, ~860s at 2M~~ (`db.mli`, 10k,
2026-08-29, laptop) — that figure no longer predicts observed behaviour and
should not be quoted. Superseded: ~~rescore is the binding *compute* cost~~ —
it is the binding *memory* cost, and the distinction decides which fix helps.

Two things drive it, and they are worth separating because only one is real
scaling.

*The cap count is an accident, not a design.* `rescore` and
`recompute_surprise` run once per distinct `seed_fills.depth` for the version,
and eligibility is `depth >= cap` — so a cap is not a cohort, it is a
*threshold*. The 100k corpus carried five caps:

| cap | seeds AT this depth | seeds ELIGIBLE (`depth >= cap`) |
|---|---|---|
| 4 | 1 | 100,000 |
| 5 | 1 | 99,999 |
| 6 | 1 | 99,998 |
| 8 | 99,994 | 99,997 |
| 15 | 3 | 2 |

Only cap 15 is a real deepen request. **Caps 4, 5 and 6 are damage**: seeds
67207, 66707 and 67958 are truncated fills from the chunks that lost their tails
to writer contention, and a truncated fill records a truncated depth. Three
broken seeds made the pass ~5x more expensive than the corpus needs, and
`corpus-check` reported the corpus clean throughout — a seed alone in its depth
cohort is trivially that cohort's maximum. Both are fixed: `corpus-check` now
fails any seed recorded below the shallow cap, and `tools/corpus-drop-seeds`
deletes them so a refill can see work to do (`--skip-done` alone cannot: it
skips seeds that are present, and a truncated seed is present).

So the cap count is *two* problems. The spurious caps are a data-integrity bug
with a repair. What remains after the repair — one pass for `D:8` and one for
each genuine deepen cap, each scanning a population defined by `depth >= cap` —
is the design issue: a handful of deepened seeds still drags a full-corpus pass
behind each one. Scoping a rescore to the caps whose population actually changed
is the fix, and it is not algorithmic.

**The repair held.** The 1.3M corpus carries exactly two caps and no damage
(0.34.1, prod, 2026-09-05):

| cap | seeds AT this depth |
|---|---|
| 8 | 1,299,994 |
| 15 | 5 |

`corpus-check` passes clean — 1,299,999 seeds over a contiguous range 1..1,299,999,
every seed with a full level count for its fill depth, and no seed recorded
below the shallow cap. So the ~5x the spurious caps used to cost is gone, and
the 29.0 GiB OOM below is the cost of a corpus with *nothing* wrong with it.
That matters for reading the rescore figure: it is two passes, not five, and it
still did not fit — before sharding. It does now, at 9.10 GiB.

*The per-cap cost is where the real growth is.* Each cap does two full scans and
materialises both into OCaml lists: `eligible_seeds` builds a list of every
eligible seed, and the `score_rows_sql` fold builds a list of **every item
observation across every eligible seed** — the larger of the two by a wide
factor, since a seed carries many entries. At 100k that is ~10.3M entries
filtered down per cap; at 1.3M the scan returns 96,524,762 rows and the list did
not fit at all. Memory is the first thing that breaks, not time — **confirmed
2026-09-05 by an OOM at 29.0 GiB**, not predicted.

`score_rows_sql`'s fold is now sharded, so its list is one shard's worth rather
than the cohort's and that scan no longer sets the peak. `eligible_seeds` is
still a whole-cohort list, but it is one string per seed rather than one tuple
per observation — ~1.3M strings against 96.5M six-tuples — which is why it was
never the one that broke.

Then both passes delete and rebuild unconditionally: `delete_surprise_sql`,
`delete_seed_scores_sql`, `delete_heat_bands_sql`. Every score row is rewritten
every pass whether or not anything about that seed changed.

### What would actually help

**Reordered 2026-09-05, twice.** The ranking was originally by payoff over
effort, with the memory fix last as an orthogonal nicety; the 1.3M OOM promoted
it to the only thing that unblocked anything. Sharding the scoring scan then
resolved that the same day — the pass completes at 1.3M — so these are once
again optimisations of a pass that finishes, and (1) is no longer a blocker for
the 2M target. It is still the right long-term shape, and it is what would let
the scoring phase stop materialising per-shard lists at all.

1. **Shard the whole-cohort passes that are still unsharded.**
   `recompute_surprise` (9.10 GiB at 1.3M) and `early_spell_counts` (22.3M book
   rows) now set the ceiling, since the scoring scan no longer does. They fit
   at 1.3M and are the next thing to break, which makes this the blocker for
   the next doubling.
2. **Push the aggregate into SQL.** Removes the materialised lists — the
   `score_rows_sql` fold especially, which is the 96.5M-row one. Sharding
   bounds that fold's residency without removing it, which is why this stays on
   the list: it is the difference between "fits in a shard" and "streams".
   Downgraded from blocker to improvement 2026-09-05. The reduction it has to
   preserve is not `min(level)` — a portal ranks at its parent's depth through
   `Depth.of_level_with_parent` — which is the reason sharding was worth doing
   first.
3. **Do not rewrite unchanged rows.** A fill adds seeds; it does not change the
   facts of existing ones. If the comparison distribution has not moved enough
   to shift a band cut, only the new seeds need scoring — 378 rows rather than
   100,000. The largest win once the ceiling is not the issue, and it also
   shrinks the write set that ceiling is measured against.
4. **Scope the caps.** Rescore only caps whose population changed. A fill that
   adds seeds at `D:8` does not change what cap 15 means. Cheap, ~5x on the
   measured run, no algorithmic risk. It used to be moot — one cap alone
   exhausted the machine — but with the scoring scan sharded, skipping an
   unchanged cap is real time saved: cap 15's 5 seeds cost a full
   `recompute_surprise` on the 2026-09-05 run.
5. **Sample the comparison population, not the write set.** Computing what
   "surprising" *means* is genuinely samplable (50k seeds fixes the percentiles
   to more precision than the bands render), but writing a score per eligible
   seed is unavoidably O(N). A constant factor, maybe 2x — its real value is as
   the cheap *test* for (3): did the distribution move enough to require a full
   pass?

**Read latency, which is new at this size and was not on the list.** The corpus
filled and verified clean, but the webapp got materially slower in a way no
storage or fill figure predicts. Warm, on prod (1.3M, 0.34.1, `D:8`,
2026-09-05, end to end over HTTP): `artefact` 2.48s, a three-term search 3.70s,
`name~Throatcutter` 7.02s, against tens of milliseconds for the same shapes at
100k. Two causes, neither a missing index, and both since addressed:

- **The interning dictionary is now 2.99M rows / 159 MB**, and `Name_like`
  scanned all of it (~3.3s of its 7.02s). Addressed by a trigram fts5 index over
  `strings` (`strings_fts`, +432 MB). The scan is gone rather than kept as a
  fallback: `name~` is refused while the index is stale, because a 129 MB read
  per request on a public endpoint is an amplification surface. See
  `docs/architecture.md`.
- **The dataset was `recordsize=64K`**, so each of the scattered 4K reads the
  trigram index produces cost a full 64K fetch and decompress. Addressed by
  moving the corpus to `recordsize=16K, compression=lz4` (2026-09-07). This one
  had been taxing every scattered read since the dataset was created; the index
  did not cause it, it made it visible. See "The recordsize change" below.

Together those took every measured shape to ~0.2s: `artefact` 2.48s → 0.20s,
`name~dragon` 9.9s → 0.22s.

Plus a cold start: `Db.distinct_criteria` is ~140s at 1.3M and is cached only
per process, so a restart makes the first search request wait over two minutes.
This is now the *only* slow path left on the read side, and it is the one a
reader is most likely to hit after a deploy — 76s on the first request after
the 2026-09-07 restart, with every subsequent request at 0.2s.

The recordsize change roughly halved it (~140s → ~75s) without touching what
makes it slow. Measured directly against SQLite, 1.3M / 0.34.1, 2026-09-07,
16K/lz4:

| query | at 64K/zstd | at 16K/lz4 | user | sys |
|---|---|---|---|---|
| `item_pairs_sql` | 126s | 71.5s | 51.1s | 20.2s |
| `feat_names_sql` | 13.5s | 3.8s | 2.7s | 1.2s |

The split is the point. These were `sys`-dominated before, which was the
amplification; they are now `user`-dominated, which is the temp b-tree for the
`distinct` over every entry of the build. What is left is the actual
algorithmic cost, it still grows linearly with the corpus, and precomputing the
vocabulary at fill time is the only thing that removes it.

None of this is fundamental — see `docs/architecture.md` for the shapes and the
fixes — but it belongs here because it is the first bound that shows up as
*product* degradation rather than as a job that fails. Filling further makes the
site worse for readers before it makes anything break, which is a failure mode
the storage and fill-rate curves are silent about.

Buying a bigger machine is a real option and buys roughly one doubling per
32 GB, which does not reach the 2M target cheaply and does not reach 10M at
all. It is a way to run one more fill, not a fix.

A shared fill/deepen queue and a move to Postgres were both considered and
neither addresses this. The queue is a *latency* mechanism; rescore is not
contended, it is just long. Postgres does not make a single-threaded analytical
scan faster, and the two things that would justify it — write concurrency and
write throughput at scale — are the two that measured fine.

**The release cadence, which is the constraint nobody budgets for.** DCSS ships
one or two major releases a year, so a fill of current stable is racing the next
point release — and 0.34.1 arrived ~20 days after 0.34.0. A 97-day fill against
a version with a 20-day expected life never finishes.

## Versions do not share seeds, and cannot be checked

Any two distinct version strings describe different corpora. Not just major
versions — point releases too.

A point release can change one vault. That changes only the seeds which draw it,
and only from that draw onward: affected seeds are byte-identical up to the
divergence and wrong afterward. **This makes sampling useless as a check.** The
unaffected seeds verify clean while an unknown fraction of rows are stale, so
the corpus looks healthy right until a reader's game disagrees with it.

Changelogs do not close the gap either — an author need not realise a change
consumed an RNG draw, and "people miss things" is the normal case rather than
the exceptional one.

So the invariant is **assumed, not verified**: a version is an opaque
identifier. `versions` is a table with a foreign key and no comparison order,
and nothing may acquire one.

## The consequence: a fill of current stable is on loan

A finished line can never be invalidated, so compute spent there is safe.
Current stable is racing the next point release, and anything filled against it
may have to be refilled.

That argues for putting the depth on the frozen lines — but it argues against
what people actually play, which is current stable, and a corpus is worth
having in proportion to how many readers it answers for. **No sizing policy
follows from this, and none is committed to.** The tension is real in both
directions and gets settled per fill, not by rule.

The stake has grown with the corpus: 1.3M on 0.34.1 is 27.3 hours of wall
clock, so a 0.34.2 would cost that much compute to chase rather than the five
hours a 300k fill cost. That does not change the argument, only its price.

One consequence does hold regardless: **a statistic quoted across versions may
be quoted across different sample sizes**, so nothing may compare two versions'
counts without accounting for their fill sizes.

## Fill sizes in practice

100k per version has been the working size for verifying a wire-format bump —
built and discarded at each bump rather than kept. Most measured figures in
`docs/` carry a `100k` annotation for that reason; those corpora were real and
the numbers stand, even though no 100k corpus exists at any given moment.

The staged path is 1M → 10M → 100M, each stage a checkpoint rather than a
milestone. 1M was the one that mattered most: the first size at which the
rate-decay curve has enough points to extrapolate, and the first at which
bytes/seed reflects a saturated string vocabulary. **That checkpoint is passed
(1.3M, 0.34.1, 2026-09-05)** and it answered both questions — no decay over
−0.8% across 27.3 hours, and 4,197 bytes/seed still improving (at the 64K/zstd
setting then in force; 6,488 at today's 16K/lz4). On those two numbers alone
100M is a plan.

It also produced two answers nobody was looking for: **10M is blocked on
scoring, not on storage or fill throughput**, and the webapp's read latency
degrades linearly with the corpus for reasons that are fixable but unfixed.
The next stage does not begin with a fill — it begins with the SQL aggregate in
`rescore`, and with the cold `distinct_criteria` build, which is what remains
after the recordsize change took the warm read path to 0.2s.

## What the trigram index did and did not fix

Measured on prod over HTTP, warm, 1.3M seeds / 0.34.1, 2026-09-07, after the
index was built:

| fragment | distinct names matched | before | after index | after 16K/lz4 |
|---|---|---|---|---|
| `name~Throatcutter` | 1 | 7.02s | 0.21s | 0.23s |
| `name~Wyrmbane` | 2 | 3.15s | 0.27s | 0.21s |
| `name~dragon` | 33,523 | 3.17s | 9.9s | 0.22s |

Selective fragments — what readers actually search — are 10-30x faster, which
is what the index was for. A common fragment got **worse**, and the reason was
not the index and not the query plan: it was ZFS record amplification. The
trigram converted one sequential dictionary scan into 33,523 scattered lookups,
and at `recordsize=64K` every scattered 4K page read fetched and decompressed a
full 64K record. That is the access pattern the setting punished hardest, which
is why the same commit made selective fragments 30x faster and `name~dragon`
slower. Moving the dataset to 16K/lz4 removed it; the final column is the same
queries on the same corpus after that change.

An earlier revision of this section blamed the `distinct`-under-a-sort and the
size of the candidate set. **That was wrong.** `distinct` is served off index
order as `db.ml:1585` claims, and the cost was per-read amplification rather
than per-row work — a 33,523-row scattered read took 1,723ms against 2ms for
the same 33,523 rows read sequentially, with four ARC misses across the whole
comparison. The companion claim that the first read after a rebuild is slow
(40s+) "because nothing is in page cache yet" was also wrong: ZFS has no page
cache, and repeat runs of the slow query were identically slow (1.68s / 1.73s).
Both readings survived because `free` reports `buff/cache: 0` on ZFS, which
looks like a cold cache and is not one.

`Criterion.is_cheap` still returns false for `Name_like` regardless, and should
stay that way — see `docs/architecture.md`.

## Building the name~ substring index, measured

The trigram index over `strings` (`strings_fts`, see `docs/architecture.md`) is
built by a pass over the whole dictionary, so its cost is worth knowing before
the next fill rather than during it. Measured on prod, 1,319,999 seeds /
2,991,161 names, 0.34.1, 2026-09-07:

| step | wall | user | sys |
|---|---|---|---|
| `tools/corpus-reindex` | 5m18s | 42s | 4m36s |
| `tools/corpus-fts-rebuild` | 10m26s | 2m10s | 8m16s |

Both are `sys`-dominated by a factor of six or more, which is why the same
rebuild is 24s on an M-series laptop against 10m26s here. Note that these
figures were taken at `recordsize=64K`, so an unknown part of that `sys` time
is the record amplification described below rather than I/O proper; they have
not been re-measured at 16K/lz4 and should be treated as an upper bound. Scale
the expectation by the box's storage, not by its cores — and
budget both steps, since a corpus predating the index needs `corpus-reindex`
first to create it (13 → 19 tables: the fts5 table, its four shadow tables, and
`strings_fts_state`).

The rebuild takes the write lock for its duration, so it runs after a fill
rather than during one. It adds ~432 MB (~2.7% of the database) and is not read
by `rescore`, so it does not move the rescore memory ceiling that actually
bounds the next stage.

**What any given corpus holds is not recorded here.** It changes faster than a
document can track it; `tools/corpus-check <version>` reports the seed and entry
counts for a version in the corpus at hand.

## The recordsize change

The corpus dataset was created `recordsize=64K, compression=zstd`, which is a
reasonable default for a large file read sequentially and the wrong one for a
SQLite database with 4K pages. Every scattered page read fetched and
decompressed a full 64K record: 16x read amplification, paid as kernel CPU on
every random read since the dataset was created.

It stayed invisible while search was dominated by a sequential dictionary scan.
The trigram index removed that scan and replaced it with 33,523 scattered
lookups — the access pattern this setting punishes hardest — which is how one
commit made selective fragments 30x faster and `name~dragon` 3x slower.

The evidence that it was amplification and not I/O, measured on prod with a
warm ARC (1.94B hits against 348k misses):

| access pattern | rows | time |
|---|---|---|
| scattered (`strings_fts where val like '%dragon%'`) | 33,523 | 1,723ms |
| sequential (`strings where id between 1 and 33523`) | 33,523 | 2ms |

860x for the same row count, with four ARC misses across the whole comparison —
no disk involved. Repeat runs were identically slow, and `sys` was ~97% of every
slow measurement.

Five candidate settings, measured by copying the corpus into scratch datasets:

| dataset | ratio | on disk | trigram stage | full search |
|---|---|---|---|---|
| 64K zstd (was) | 2.79x | 5.4 GB | 1.83s | 4.94s |
| 16K zstd | 2.04x | 7.5 GB | 0.78s | 1.38s |
| 8K zstd | 1.94x | 7.9 GB | 0.46s | 0.90s |
| **16K lz4 (chosen)** | 1.90x | 8.0 GB | 0.25s | 0.60s |
| 16K off | 1.00x | 15.2 GB | 0.17s | 0.34s |

The compression ratio is not recoverable at a sane recordsize: 64K is what makes
zstd look good and 64K is what causes the amplification. zstd at 16K gives up
most of the ratio and still pays decompression per scattered read, so the real
choice is lz4 or nothing — and `off` buys 0.26s for another 7 GB. Applied
2026-09-07 by rewriting the file onto a new dataset created with the properties
set at creation time.

Two things to know if this is ever done again:

- **`cp` is not a rewrite.** ZFS block cloning makes it complete in under a
  second, inheriting the source's 64K records and reporting the *old*
  `compressratio` on the new dataset. It looks like it worked and is a complete
  no-op. Use `dd`, `cp --reflink=never`, or `zfs send | recv`, and verify the
  ratio moved before trusting anything downstream.
- **A clean `systemctl stop` did not checkpoint the WAL.** 437 MB of `-wal`
  survived the stop and had to be cleared with an explicit
  `pragma wal_checkpoint(TRUNCATE)` before the copy. Check for `-wal` and `-shm`
  rather than assuming a clean shutdown removed them.

`integrity_check` on the 15 GB copy took 11m22s and dominated the ~29 minutes of
downtime; the `dd` copy itself was under a minute.
