# Seed heat

A rough, per-seed exploration mark: *how interesting does this seed look at this
depth cap*. It is not a verdict, not a ranking, and not comparable across builds
or caps. `lib/corpus/heat.mli` is the contract; this document is the model
behind it.

## What it is for

A seed listing in no particular order is a wall of undifferentiated numbers.
Heat gives a reader a reason to open one row rather than another, without
answering the question for them. It is shown as a mark on every row and is
deliberately *not* a sort or a filter — discovery is most of what this tool is
for, and a heat sort puts the same five seeds on page one forever.

There is also a measured reason sorting is the weaker move. Sorted
hottest-first, page 1 spans score 317 down to 166; page 5 spans 123 to 118 (10k,
0.34.1, D:8, 2026-08). Past two or three pages every row carries the same mark
and the sort conveys nothing. An unsorted 200-seed page, by contrast, shows a
genuine mix — roughly 10 / 31 / 48 / 111 across blazing / hot / warm / cold.

## The significance model

Four tiers on **one value axis**, not a taxonomy:

| Number | `Weight.Tier` | Anchor band | Meaning |
|---|---|---|---|
| 1 | `Run_defining` | 20–80 | A seed is worth playing for this alone. Potions of experience, acquirement, a demon blade. |
| 2 | `Strong` | 10–50 | Shifts the early game; more and earlier is better. Haste, invisibility, ring of slaying. |
| 3 | `Bulk` | 0–8 | Present nearly everywhere; no quantity is decisive. Curing, fog, most rings. |
| 4 | `Worthless` | -5–10 | Zero signal, or an active trap. Scroll of noise, potion of attraction. |

**The numbering runs best-to-worst: tier 1 is the good one.** That inverts the
convention most games use, where tier 4 is the endgame item, and getting it
backwards still runs a query — it just answers the opposite question. So the
*names* are what `Weight.Tier` exposes; the numbers appear only in
`Weight`'s own table. Prefer the name in prose and in a request for a query.

The anchor bands overlap deliberately: they are a sanity check on a
hand-authored weight, not a partition. `lib/corpus/weight.mli` declares them.

### Tier by the build that wants it

> **Tier an item by how good it is for the build that wants it — never by how
> likely the reader is to be playing that build.**

A demon blade is tier 1 because it is run-defining for a long-blades character,
not tier 3 because most characters are not one. The probability that *this*
reader wants it is a **search** question, and search already answers it; folding
it into the weight averages away the fact that makes the item worth surfacing.

This keeps the table honest about what a weight is: *how much this matters when
it matters*, a per-item constant. Everything situational lives elsewhere — build
in search, depth and quantity in `surprise`.

### Tier carries the ranking; weight refines it

Measured: the tier accounts for 86% of the resulting ranking (10k, 0.34.1, D:8,
2026-08). So when adding a row to `Weight`, place it in the right tier first
and price it second. A tier-3 row priced above a tier-2 row is a
disagreement with the axis doing most of the work, not a fine adjustment.

## Weight is hand-authored; surprise is derived

**The corpus must not set the weights.** Rarity and value are different
questions, and deriving weight from frequency makes the score say only "this
seed has unusual items", which `surprise` already says. A wand of digging is
common and matters; a scroll of noise is uncommon and does not.

**Surprise is derived, because hand-authoring it does not scale.** It is the
tail probability `P(count >= n)` over the eligible cohort — every seed filled at
or beyond the cap, counted only over levels within the cap. One curve, not two:
the tail does the work, so "three potions of experience" and "one potion of
experience" fall out of the same distribution without a separate quantity model.

Both terms are needed. Weight alone ranks by shopping list; surprise alone ranks
by oddity.

## The formula

```
contrib(item) = weight × -log10(max(P(count >= n), 1/N)) × depth_util(shallowest)
depth_util(d) = 0.5 + 0.5 × (cap - d + 1) / cap
score(seed)   = Σ over contribs sorted descending of  contrib_i × 0.6^i
```

`N` is the eligible population. The geometric decay over sorted contributions is
load-bearing: a plain sum measured *seed size* — a seed with many mediocre items
outscored one with a single run-defining artefact — and the decay makes the
score describe a seed's best few things rather than its inventory count.

`-log10` rather than a percentile, because percentile compresses exactly the
tail that carries the signal.

`book`, `gem` and `rune` contribute nothing through weights: `Weight.find`
returns `None` for them *by design*, which is a different claim from a weight of
0. Gems and runes are out of scope. Books are folded in separately.

### Books are one derived count, not weights

A book's value depends on the caster to a degree no weight table resolves, so
the book term is a single count of **distinct level-≤4 spells** available to the
seed across every source: a named book's contents (`book_spells`), a randart's
own `entry_spells`, and a parchment's `sub_type`. That count is fed through the
same surprise curve at a constant weight of 20 — the TSV's own anchor for
"shifts the early game", since availability of choices is a breadth claim of
that size, not a run-defining one.

The unit is the distinct spell, not the book: two books sharing Magic Dart offer
one option, not two. The level cap earns its place because a level-7 spell in a
D:3 book is not an early-game fact.

## The bands

Four, cut by **percentile against the eligible population** rather than by
absolute score, because the score's scale is arbitrary and shifts with every
weight-table edit. Measured (10k, 0.34.1, D:8, 2026-08):

| Band | Percentile | Score range | Seeds |
|---|---|---:|---:|
| blazing | p95–100 | 138–317 | 500 |
| hot | p80–95 | 98–138 | 1,499 |
| warm | p50–80 | 67–98 | 3,000 |
| cold | p0–50 | 18–67 | 5,000 |

Cut points are stored per `(version, cap)` alongside the surprise table, never
hardcoded. Half the corpus being cold is intended: the bands are a population
split, so the mark says *unusual for this corpus*, which is the only thing a
seed number can be unusual against.

Ties land in the same band, because banding is a threshold test rather than a
rank assignment — so the counts approximate the design's 500/1499/3000/5000
rather than hitting it on a discrete distribution.

**An absent `seed_scores` row is "unscored", never cold.** Absence is a claim
about the corpus (not yet rescored, or ineligible at this cap); `Cold` is a
claim about the seed.

## Scope and validity

- **A score is valid only within its `(version, cap)`.** Surprise and the band
  cut points are both population statistics over the cohort filled to at least
  that cap, so a D:8 score is not comparable to a `Swamp:4` one. This is why
  `seed_scores` is keyed on the cap rather than being a column on `seed_fills`.
- **The cap must be named in the interface.** A cap sets the denominator, so a
  seed marked cold at D:8 may be blazing at D:15; the cap is invisible in the
  data and cannot be inferred from the page. Naming it is correctness, not
  explanation.
- **The population is the random sample.** A seed a reader submitted
  (`seed_fills.origin = 'submit'`) is scored but never counted: it is outside
  the cohort behind `surprise`, the cut points and `n`. `rescore` scores it in
  the same pass as the sample and bands it against the sample's cuts; the
  generator scores a new one alone at job finish (`Db.score_seed`), against
  the `n` `rescore` stored in `heat_cohorts`, so both give it the same score.
  An early-spell count or item count no sample seed reached falls back the way
  any unseen count does in `surprise_lookup`, to the largest stored count
  below it.
- **Shop stock is excluded.** Surprise ranges over `entries` where `cost is
  null` — what the seed *gives* you, not what it sells you.
- **Depth is reach order.** `shallowest` is a `Depth.t`, never generation order;
  a portal ranks at its parent level's depth.

## What heat is not

- **Not build fit.** Whether a seed suits *your* character is a search question,
  and search answers it. Folding it into a score would require guessing the
  reader's build and would average away the items worth surfacing.
- **Not an artefact count.** Artefact count was tried as a proxy and rejected:
  most artefacts are unremarkable, and the count tracks fill depth as much as
  content.
- **Not a quality rating.** *Heat* is the reader-facing name and *score* the
  internal number, because temperature is honest about being fuzzy — nobody
  reads a temperature as a verdict. Calling it quality or rating would
  overclaim, and the build-fit axis it excludes means a seed hot for one
  character is not hot for another.
- **Not a reason to drop data.** The pruning cut line and the bottom of the
  significance model are the same table, but the failure modes are not
  symmetric: a wrong score is a bad sort, fixed by editing a table; a wrong
  prune is permanently absent data, fixed only by a refill. *Scoring zero is not
  a reason to drop.*

## The mark

The band mark is a **four-tick gauge** followed by the band's name in small
caps: a constant track of four hairline ticks with the first N filled — one for
cold, two for warm, three for hot, four for blazing. Heat is the listing's only
ordinal, and a constant track prints the whole scale on every row, so `warm`
reads as second of four without the reader having learned the vocabulary. The
emoji it replaced said *which* band but not *where in the scale*, rendered
differently on every reader's machine, and was the only full-colour object on an
ink-and-paper page.

The constraints it satisfies:

- **Not a number.** The score's scale is arbitrary, and printing it invites
  argument about a deliberately rough heuristic.
- **Not colour alone**, per `docs/style.md`. The band word is real text, so
  grayscale, print, and CVD readers get the meaning; the fill count carries the
  ordinal position independently of hue, and blazing is bold as well.
- **No seventh hue.** `--gold` already means *exceptional — the rarest thing on
  a level*; heat is that same semantic one level up. The cold end is quiet ink
  (`--ink-3` / `--ink-2`) and only the warm end reaches for `--ember` — blue
  belongs to navigation and red to danger, so a heat scale gets no hue of its
  own. Bands differentiate by fill and weight, not by four new colours.

The fill is `currentcolor` against `--rule-2` for the empty ticks, so the band
classes only ever set a text colour and the existing dark-mode token
redefinitions handle the theme; there is no `prefers-color-scheme` block for
heat. The 3px tick against an otherwise 0.5px-hairline design is deliberate, and
matches the 3px significance rule on `tr.mark-*`.

## Running it

Scoring is a separate binary (`bin/rescore.ml`), run after a fill completes, not
a side effect of ingest — `Db.recompute_surprise` documents why.

The weight table is `lib/corpus/weight.ml` and is edited directly; there is no
generation step and nothing to keep in sync. After a fill against a build the
corpus has not seen, check that every `(base_type, sub_type)` it produced
resolves through `Weight.find` — an unresolved pair scores its class at zero for
every seed, silently. See `docs/extraction.md`.
