# Excluding shop stock by default

Status: **implemented 2026-09-15**. Proposed 2026-09-10; amended the same day for
sequencing against the search index. Supersedes the approach in fossil ticket
`7cbd40b3ed`, which is now **closed** — see *Sequencing* below.

**Ship this before `e51d6c4e0c`** (the posting-list search index,
`docs/plans/seed-search-index.md`). The reasoning is in *Sequencing*; the short
form is that almost none of this work is rewritten by the index, two of its
open decisions are deleted by it, and the index's on-disk format depends on the
criterion vocabulary this plan changes.

## What changes

Shop stock is excluded from search by default. `shop ` opts back in, per term.

| term | before | after |
|---|---|---|
| `potion:haste` | floor or shop | **floor only** |
| `shop potion:haste` | shop only | shop only |
| `floor potion:haste` | floor only | floor only (accepted, no longer emitted) |
| `name~Wyrmbane` | floor or shop | **floor only** |
| `props:Conj` | floor or shop | **floor only** |
| `staff props:Conj` | floor or shop | **floor only** |
| `shop props:Conj` | *misparsed* | **shop only** |
| `shop staff props:Conj` | *misparsed* | **shop only** |
| `artefact` | floor or shop | floor or shop (unchanged) |

Compatibility is deliberately broken. The app has been public a few days with
single-digit users; this is the cheapest moment it will ever have.

## Why a changed default is not the toggle that was rejected

`docs/architecture.md` rejects a search-wide shop filter:

> A search-wide "exclude shops" toggle could not express that, and would make a
> term's meaning depend on state outside the term.

That objection does not reach this change, and the distinction is worth keeping
straight. A toggle makes one term text denote different sets depending on a
switch. A changed default does not: `potion:haste` denotes floor-only always,
fixed by the term text alone. Nothing outside the term is consulted.

What the objection *does* survive as is the `min_count` partition, which is
untouched and still true: `Floor` and `Shop` totally partition the union, so a
floor search is not a union search with shop hits struck off. A seed with two
potions on the floor and one behind a counter satisfies `3x potion:haste` today
and will not after this change. Measured local 10k, 0.34.1: 2,435 seeds → 2,142,
**12% of matches lost**. That is the change working as intended, but it is the
most visible break and the help text has to say so.

## No union form in v1

With `shop ` kept as shop-only and no new prefix, the union becomes
inexpressible. This is a real loss, not a deferral: the question `3x
potion:haste` answers today has no v1 spelling.

Shipping without it is the reversible direction. If it is asked for, the answer
is an `anywhere ` prefix — and it brings an evidence problem with it, recorded
here so it is not rediscovered:

`group_term_hits` (`db.ml:1850`) collapses many rows into **one hit per seed per
term** — a total `count`, the shallowest contributing `level` and `name`, and
`distinct`. It is deliberately lossy. So `anywhere potion:haste` would render "3
potions of haste, D:4" where the 3 might be 2 floor + 1 shop, with nothing
saying so. Today's `Item` union has the same lossiness and it does not matter,
because the reader did not ask about shops. Under `anywhere ` the shop share is
exactly what they opted into and cannot see.

The proportionate fix, when it is wanted: add `e.cost` to `term_hits_columns`,
count non-null rows in `group_term_hits`, and add `shop_count : int` to
`Match.hit`. Additive, composes with the grouping, does not perturb
`shallowest_hit` or `Rank.Shallowest`. Splitting the hit per position is more
honest and much larger — it breaks the one-hit-per-term-per-seed invariant both
of those depend on — and it answers a question nobody has asked yet.

## `artefact` stays a union, and that is an inconsistency

`artefact` gets no positional form in v1. Generic artefact search is a weak
question and the parse boundary would need new syntax for it (`shop artefact`
fails today: `item_type "artefact"` requires a colon).

But it is a *visible* inconsistency, because artefacts are where shop stock
concentrates. Measured 2026-09-10:

- named entries in shops: **14.4%** (1,514,027 / 10,535,946, prod 1.3M)
- artefacts in shops: **42.7%** (1,503,208 / 3,518,219, prod 1.3M; local 10k agrees at 43%)
- prop-carrying entries in shops: **39.7%** (9,042 / 22,764, local 10k)

So `artefact` leaks shop stock at three times the rate of the vocabulary it sits
beside. The help text must state this deliberately, on the same rule the current
"Floor or shop" note follows — an asymmetry that is explained is a decision, one
that is discovered is a bug.

`props:` was nearly dropped from v1 for the same reason as `artefact` and put
back precisely because of the 39.7%.

## Sequencing: this ships first, and it gets smaller for it

The posting-list index (`e51d6c4e0c`) replaces the SQL predicate path for
search. Sorting this plan's work by whether that replacement touches it:

**Untouched by the index — the bulk of the diff.** `Criterion.t` and the
`position` type, `to_query_string`, `to_string`, the `.mli` doc comment, the
whole of `params.ml`, the help text in `views.ml`, the docs, and all the test
churn. These sit *above* the storage boundary: the new store's interface is
`search : t -> Search.t -> Match.t list`, consuming the same `Search.t` this
plan reshapes. Deferring does not avoid any of it — it relocates it onto a
codebase that is mid-rewrite, and lands the test churn on tests just rewritten
for the index.

**Deleted by the index — a small slice.** `criterion_where`'s `cost is null` /
`cost is not null` arms (the store holds separate floor and shop posting lists,
so the predicate stops existing) and `criterion_driver_rank` in its entirety
(driver selection is a SQL-planner concern; postings merge shortest-list-first,
so ordering comes from list length, not a static table).

That second list is what makes shipping now *cheaper* rather than merely
earlier, because it contains both decisions this plan is least sure of. See the
two amendments below.

There is also a forcing constraint in the other direction: **the index's
criterion id space is baked into its on-disk format.** Building the store
against `Floor_item`/`Shop_item` and flipping afterwards costs either a format
bump or a compatibility shim in the builder, for a distinction already decided
against.

Finally, this plan needs no schema change and no reindex (see *No schema
change*), so it can ship on its own schedule. The index cannot: it is behind a
format decision and a builder.

### Amendment 1: do not introduce the `Props` driver-rank asymmetry

The work section below flags `Props (_, _, Shop)` ranking ahead of its `Floor`
counterpart as a **new** decision needing measurement. Drop it. Give both
positions the rank `Props` has today (2), and do not measure the alternative.

`criterion_driver_rank` is deleted by the index, so a new static-rank decision
has a known expiry date and is not worth a prod measurement. The cost of
declining is bounded and already stated in *Risks*: results are the same set in
a different order. Record the reasoning in the commit so it does not read as an
oversight.

This removes one measurement task and one risk from the plan.

### Amendment 2: skip the `entries_search_name` covering optimisation

*No schema change* already concludes the index change is a live optimisation
rather than a prerequisite (`name~dragon` 1.252s → 1.769s at prod, +41%,
against the 60s search timeout). Treat that as settled and do not revisit it later
either: ticket `7cbd40b3ed`, which held it, is closed, and under the new design
`name~` runs as a trigram filter over the store's *candidate set* rather than
over the whole dictionary. Optimising the index for a query path being replaced
is wasted work.

What does **not** get skipped is this plan's obligation to `name~`. As written
above this said `name~` "still matching shop stock" — stale wording carried from
the closed ticket, which was drafted for a world where `name~` stayed a union.
**`name~` is floor-only**, as the table in *What changes*, the `params.ml` work
item, and this section's own 1.252s → 1.769s measurement all require: that
regression exists only because `Name_like` gained the `cost is null` predicate.
The real obligation is the other half — `name~` is the one criterion with no
shop opt-in, and the help text must say so and say why.

## Representation: a position field

    type position =
      | Floor
      | Shop
    [@@deriving compare, equal, sexp_of]

    | Item of Item_type.t * position
    | Name_like of string * position
    | Props of { base_type : string option; props : string list; position : position }

`Shop_item` and `Floor_item` are deleted.

Ticket `7cbd40b3ed` flagged this choice and asked for it to be settled "before
adding the second one, not the third". With `Item`, `Name_like` and `Props` all
positional, this is that moment. A constructor per combination is 3 criteria × 2
positions now and grows multiplicatively; adding `anywhere ` later costs one
variant here against three constructors and three match arms there.

The cost is churn: every exhaustive match over `Criterion.t` moves. That is
mostly a feature — see the stale-index site below — but it is the bulk of the
diff.

## Work

### `lib/corpus/search.ml{,i}`

- Add `position`. Rewrite the three constructors. Delete `Shop_item`/`Floor_item`.
- `to_query_string`: `Floor` emits bare, `Shop` emits `shop `-prefixed. `Floor`
  never emits `floor `, so the round-trip is lossy in spelling and exact in
  meaning.
- `to_string` (prose) currently distinguishes shop from floor by constructor and
  needs an explicit qualifier instead.
- `is_cheap` (`search.ml:259`) and `is_indexed` do not depend on position.
  Note this leaves `shop staff props:Conj` on the inline path too, on the same
  `Option.is_some base_type` test — see the hot-path note below, which measures
  only the `Floor` form.
- The `Criterion` doc comment in the `.mli` is load-bearing and largely about
  this exact partition — it needs rewriting, not patching.

### `lib/corpus/db.ml`

- `criterion_where`: `Floor` adds `cost is null`, `Shop` adds `cost is not null`.
  **Keep the `Shop` predicate explicit.** `db.ml:1467` records that dropping it
  makes SQLite fall onto `entries_search_type` and return floor stock too
  (335,174 vs 30,870 rows, `wand:digging`, 1.3M, prod).
- `criterion_driver_rank` (`db.ml:1564`): preserve today's ranks — `Item (_,
  Shop)` at 0, `Item (_, Floor)` at 1. Do not collapse them; shop stock is the
  rarer side and rank 0 is what today's `Shop_item` gets for that reason.
- **`Props` keeps a single rank across both positions** (2, as today —
  `db.ml:1574`). A naive refactor gives `shop props:Conj` the same rank as
  `props:Conj`, and per *Amendment 1* that is the wanted outcome, not a bug to
  fix: the argument that puts `Shop_item` at 0 would put `Props (_, _, Shop)`
  ahead of its `Floor` counterpart, but that is a new decision in a function the
  index deletes. Do not measure it; say so in the commit.
- **`db.ml:2135`, the stale-index refusal.** The `Name_like` arm must answer
  `true` for *both* positions. The compiler will surface this site because the
  match is exhaustive; the point is to answer it, not to make it compile.
  Getting it wrong means a name search silently returns "no seeds" against a
  stale trigram index — the failure `AGENTS.md:247` exists to prevent.

### `lib/web/params.ml`

- **The position arms must recurse into the position-free parse, not call
  `item_type`.** This is sharper than "reorder the table", and the distinction
  matters: `prefixed` is consulted at `params.ml:166`, *before* the `" props:"`
  infix branch at `params.ml:175`. So `shop props:Conj` matches the `"shop "`
  prefix, is handed to `item_type`, and parses as base_type `"props"`, sub_type
  `"Conj"` — a search that runs, matches nothing, and reports the build holds no
  such thing. Reordering `prefixed` against the props branch does not fix this,
  because the props logic is not in `prefixed` at all.

  The shape that works: factor the position-free body of `criterion` (artefact /
  `<base> props:` / `props:` / `<base>:<sub>`) into a function, and have the
  `floor `/`shop ` arms strip their prefix and call it, stamping the resulting
  criterion with the position. That gets `shop staff props:Conj` and
  `shop potion:haste` right by construction rather than by case analysis, and it
  is what makes `to_query_string`'s output re-parseable for every `Shop` form.

  Two guards on that recursion: it must reject a nested position
  (`shop floor potion:haste`), and it must not let `artefact` through with a
  position, since `artefact` has no positional form in v1 — both are errors, not
  silent acceptance.
- `floor ` stays in the table, produces `Floor`, is never emitted.
- Bare `floor` / `shop` keep their existing error messages.
- `name~` builds `Floor`. There is no `shop name~`: gold is the binding
  constraint in the early game, so "is this unrand for sale" is not the
  interesting question — if you can afford it in a shop you could have afforded
  it for free. It needs its own rejection message rather than a fallthrough,
  and the help text has to say why the symmetry is broken.

### `lib/web/views.ml`

Rewrite the "Floor or shop" section: the default is floor, `shop ` is the
opt-in, the `min_count` note still applies unchanged, `name~` has no shop form
and why, and `artefact` is still a union and why.

### Docs

`AGENTS.md` search-vocabulary bullet; `docs/architecture.md` "The search
vocabulary" — the toggle paragraph needs the distinction in *Why a changed
default is not the toggle* above, since it currently reads as ruling this out;
`params.mli` syntax comment.

### Tests, first

Failing tests before the behavioural change:

- parse: the six position/criterion combinations, plus `shop props:Conj` and
  `shop staff props:Conj` asserting they no longer misparse.
- `to_query_string` round-trip through `Params.criterion`.
- search: bare `potion:haste` returns no shop hits; `shop potion:haste` returns
  only shop hits; the two partition an `anywhere`-equivalent raw SQL count.
- the `3x` partition case, as a behavioural assertion rather than a population
  statistic (no corpus-dependent numbers in tests).

Churn: `test_search.ml` holds ~53 references to the affected constructors and
seven other test files name shop/floor in expect output. The type change breaks
their compilation immediately, so this churn is part of the first commit, not a
follow-up — the build is red until it is done.

The stale-index arm cannot be tested without controlling
`strings_fts_state.built_through`. If that is not reachable from a test fixture,
say so in the commit message rather than leaving the gap silent.

## No schema change

Ticket `7cbd40b3ed` proposed adding `cost` to `entries_search_name` first, on
the grounds that `cost is null` breaks covering. Both halves reproduce; the
conclusion does not follow.

Per *Amendment 2* this is settled permanently, not deferred: `7cbd40b3ed` is
closed and the index makes `name~` a filter over a narrowed candidate set.

Covering is lost, confirmed local 10k:

    without: SEARCH e USING COVERING INDEX entries_search_name
    with:    SEARCH e USING INDEX entries_search_name

But measured at prod scale (1.3M, 0.34.1, 2026-09-10), `name~dragon` — the
ticket's own worst case, 33,523 distinct names — goes **1.252s → 1.769s**. Real,
+41%, and nowhere near the 60s `SEED_SEARCH_TIMEOUT`. The index change is a live
optimisation, not a prerequisite, and it is not being done: this plan does not
fold it in, `tools/corpus-reindex` is not needed to ship, and the ticket that
held it is closed.

`entries_search_artefact` loses covering the same way, which does not matter
while `artefact` has no positional form.

### The one thing that gets worse on a hot path

`Props` with a base type — `staff props:Conj` — returns `is_cheap = true` and so
runs **inline on the Lwt scheduler thread** (`seed_web.ml:470`). Measured prod:
**0.986s → 1.169s**.

It is not using `entries_search_type`: the plan is `SCAN e USING COVERING INDEX
entries_seed` today and `SCAN e USING INDEX entries_seed` after. It was already
scanning the build inline for ~1s; this pushes it to ~1.2s.

Pre-existing, not created here, and not a blocker. Recorded because
`docs/architecture.md` establishes that `is_cheap`'s accuracy is a liveness
property rather than a tuning knob — 23.2s once ran inline and blocked every
request in the process — and this moves that number the wrong way.

**Do not fix it here.** `is_cheap` is retired by the index for store-backed
criteria (`seed_web.ml`'s detach decision becomes "does this query contain a
`Name_like`"), and a bare or base-typed `props:` becomes a posting-list merge
rather than a scan of the build. Accepting ~1.2s inline for the interval is the
cheaper trade than tuning a predicate scheduled for deletion. If the index slips
far enough that this becomes load-bearing, this is the measurement to start
from.

## Risks

- **The `shop props:` misparse is the one silent failure.** If the position arms
  are left calling `item_type` it does not error; it returns "no seeds" for a
  well-formed query. Reordering `prefixed` looks like a fix and is not.
- ~~**`Props` driver rank is a silent behaviour change**~~ — removed by
  *Amendment 1*: both positions keep today's rank, so there is no change to be
  silent about.
- **The stale-index arm is the other.** Exhaustiveness surfaces the site but
  cannot check the answer.
- **`artefact`'s inconsistency is a documentation obligation**, not a code one.
  Untracked, it becomes a bug report.
