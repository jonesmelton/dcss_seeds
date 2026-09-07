# What the schema drops, and why

The corpus is a lossy compressor (`what-the-corpus-is.md`); this document
records what it drops, what it keeps, and the test a proposed drop has to pass.
Read it before proposing any change that removes or reshapes stored data.

## The test: bounded by construction, not small in the sample

Some facts are drawn from a bounded vocabulary and asked as **set membership**
rather than exact position. Those saturate: past some corpus size the set of
distinct values stops growing and storage cost goes flat. Everything else grows
with the corpus.

The test is **effective entropy**, not whether the space is finite:

| Fact | Effective states | Saturates at |
|---|---:|---|
| exclusion groups | 2,938 of 3,888 | already |
| Temple altar set | 4.19M | ~1B seeds |
| pre-Temple altar set | 134,196,874 ceiling | **never** — grows N^0.81 |
| altars with exact depth | 6.26 × 10¹¹ | never |

"Bounded vocabulary" must mean *bounded by construction*, not *small in the
sample we measured*. The pre-Temple altar set looked bounded at 100k seeds and
in fact grows without limit; the difference shows up only on a growth curve,
never in a row count. Measure the curve, not the count.

The corollary: **coarse position saturates; exact position does not.** Adding
exact depth to an altar set costs ~17 bits, 131,072× more space — enough that a
billion seeds never collide. That is exactly the trade to be suspicious of,
because coarse position saturates *only because it has thrown the position
away*.

## What was dropped

Each of these is a live invariant; the details are in `AGENTS.md` and
`docs/corpus.md`.

- **The whole `vaults` category** — 23.6% of rows. Level-generation scaffolding;
  `uniq_*` vaults are redundant against `unique_mons`. Dropped at ingest, in
  `Reader.drop_entry`.
- **`runed_clear_door`** — records that a vault exists without recording what is
  in it.
- **Temple altars** — 8.8%. The 22 pool gods become a bitmask on
  `seed_levels.temple_altars`; they were 64% of every altar row. The four
  excluded gods and `altar_ecumenical` keep ordinary rows, so a rare-god query
  needs no bit logic.
- **`text` and `kind` columns** — `text` was byte-identical to `name` on all
  15,336,469 rows; `kind` was `cat` minus the plural, 1:1 on every row. Both are
  still *required* on the wire, where they validate a record's shape; neither is
  stored.
- **`name` for derivable rows** — 92% of rows store no name. `entries.name_id`
  is null exactly where `Display_name.of_entry` answers `Derived`.
- **Named-book spell lists** — 93% of `entry_spells`. A named book's set is a
  build fact stored once per version in `book_spells`; a parchment's one spell
  is its `sub_type`. `entry_spells` holds randart books only.
- **Three non-version-leading indexes** — `entries_name`, `entries_feat`,
  `entries_artefact`. 669 MB, 16% of the database, with no change to results or
  timings; the `entries_search_*` indexes are strictly better prefixes and the
  planner never chose the dropped ones.

Repeated strings are **interned** into `strings` rather than dropped: measured
2.36× smaller with every index built, on identical row counts (400 seeds,
0.34.1, D:8, 2026-08-28, M-series laptop).

## What was proposed and rejected

Both of these looked like the Temple bitmask and are not, which is why they are
worth keeping on the record.

### Pre-Temple altar sets — it does not saturate

The proposal was to collapse each seed's altars above the Temple into one set
id. Measured against the 100k corpus, distinct sets against seeds ingested:

| Seeds | Distinct sets | New sets per seed |
|---:|---:|---:|
| 1,000 | 665 | 0.665 |
| 10,000 | 4,901 | 0.435 |
| 50,000 | 19,381 | 0.342 |
| 100,000 | 34,113 | 0.284 |

That is **N^0.81** — sublinear but not saturating, and the log-log slope barely
moves (0.877 over 1k–5k, 0.810 over 75k–100k). Extrapolated to 1B seeds the
dictionary holds ~59M rows to compress ~3.5B altar rows, growing nearly as fast
as the corpus it compresses.

Two reasons it fails the test the Temple bitmask passes:

- **The vocabulary is 27, not 22.** The window is D-levels, where the four
  vault-placed gods and `altar_ecumenical` also appear. The space is
  `Σ C(27,k)` for k=0..22 = 134,196,874, not 2²². At 100k seeds we have seen
  0.025% of it.
- **The cutoff is per-seed.** Temple depth varies D:4–D:7, so the same dungeon
  yields a different set depending on where its Temple landed. That variability
  multiplies with the god combinations rather than truncating them.

It also cost the thing the corpus is for: at most 3.44% of rows, in exchange for
exact depth on every early altar. "altar_trog by D:2" and "by D:5" were different
questions and both answerable when this was written; under this change they
collapse to one bit. (Search-level depth caps were since removed — 2026-09-03,
see `docs/architecture.md` — but the stored depth they read is still what heat
caps and shallowest-ranking use, so the argument stands on that.)

A sound fact recorded along the way: all 100,000 seeds have exactly one
`enter_temple` row, never ambiguous, on D:4 (24,832) / D:5 (24,719) / D:6
(25,096) / D:7 (25,353).

### Exclusion groups — real, but not a storage change

The exclusivity is confirmed: across 100k seeds, no seed holds two members of
any of the seven groups. Zero violations. But encoding it removes no rows — the
318,882 rows involved (2.08%) each carry per-instance data (level, position,
quantity, shop cost), and the group identity is already derivable from the
`sub_type` they store. A mask would be a *new* column beside them, not a
replacement. The state count was also near-saturated rather than collapsed:
2,938 distinct combinations of 3,888 possible, because the groups are
independent.

So it shipped as a **comparison feature**, derived at read time in
`lib/corpus/exclusion.ml` and shown on the seed page, with nothing added to the
schema. "Which member did this seed draw" is a stable per-seed fact with a
uniform split, which makes it a legitimate fingerprint axis.

### Dropping portal levels — premise no longer holds

617,940 rows (Ossuary 225,215, Bailey 203,338, Sewer 189,387). The
justification was that portals could not be depth-ranked; format 2 fixed that.
Portals record `parent_level`, rank at their parent's depth, and filter
correctly under a depth cap — measured 6,082 → 5,635 matches on `altar_trog by
D:3`, closing the 7.35% over-admission exactly. Dropping them would discard that
and take their 6,261 altar first-appearances with it. Keep them unless the space
is genuinely needed.

## What none of this touches

Items are **56% of the corpus** and no change above affects them:

| Class | Rows |
|---|---:|
| scrolls | 2,271,064 |
| potions | 2,099,395 |
| books | 1,718,434 |
| shop items | 1,152,901 |
| branded gear (non-artefact) | 747,618 |
| jewellery | 582,614 |
| artefacts (any type) | 268,076 |
| plain gear (unbranded, non-artefact) | 98,535 |

(100k, 0.34.1, D:8, 2026-08.)

Plain unbranded gear is 0.6% of the corpus, so dropping it buys nothing — the
gear mass is *branded* gear, which is searchable. A consumable filter is the
only remaining lever on that 56%, and two questions have to be settled with it:
whether the bounded-set pattern applies ("potion of haste available before
Lair" may compress the way "altar before Temple" did), and whether the filter
applies to shop stock — a shop potion is a different fact from a floor potion,
since it costs gold but is guaranteed and identified.

## The asymmetry that governs all of it

A wrong encoding is fixed by a re-ingest. A wrong drop is **permanently absent
data**, fixed only by a refill, which stops being available well before the
target scale. So a drop must clear a higher bar than a re-encoding, and
low-value is not by itself a reason to drop: *scoring zero is not a reason to
drop* (`docs/heat.md`).
