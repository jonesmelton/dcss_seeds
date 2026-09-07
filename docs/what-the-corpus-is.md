# What the corpus is: a lossy compressor for seeds

The reasoning behind every decision about what the corpus stores. Written down
separately from [`schema-decisions.md`](schema-decisions.md), which records the
decisions themselves, because the model applies to product questions well
beyond storage.

## The observation

Crawl is already an optimal compressor. A 64-bit seed regenerates an entire
dungeon exactly — that is the smallest possible representation, and no schema
will beat it.

So the corpus is not a compressor competing with crawl. It is an **inverse
index**: a structure that answers questions about dungeons without running
crawl to find out. An index is necessarily larger than the thing it indexes,
because it is optimised for lookup rather than for size.

That reframes every storage decision. The question is never "how do we store
this smaller." It is:

> **Which questions stay answerable, and what does each one cost?**

Storage is a consequence of that answer, not an independent goal.

## Why entropy is the unit

Compression and prediction are the same thing: the cost of a symbol is
−log₂ P(symbol), so a better model of the source is literally a smaller
encoding. Every "effective states" figure in `schema-decisions.md` is entropy
under a model of crawl's generator:

| Fact | Model | Entropy | States |
|---|---|---:|---:|
| exclusion groups | one pick per group | ~7.2 bits | 143 |
| pre-Temple altars | 22 gods, skewed count (mean 3.76) | 14.17 bits | 18,493 |
| Temple altars | 22 gods x Bernoulli(0.61) | ~22 bits | 4.19M |
| altars with exact depth | 22 gods x 9 values | 39.2 bits | 6.26e11 |

The pre-Temple case is the clearest illustration. The raw space is the same 22
bits as the Temple case, but the count distribution is skewed toward 1-4
altars, so the entropy is 14.17 bits. **That 8-bit gap is the compression, and
it is exactly the predictability of "most seeds have few pre-Temple altars."**
Nothing was thrown away to get it.

Contrast the depth case, where 17 bits were added by recording exact position.
2^17 = 131,072x more space, which is why a billion seeds never collide there.

## Three things this buys

### 1. A stopping rule

Entropy says when to stop optimising. Pre-Temple sets need
ceil(log2(18,493)) = 15 bits; the plan spends 2 bytes. One bit of slack, so
there is nothing left to win and the search ends.

Without the entropy figure, there is no way to tell a good encoding from one
that merely looks clever, and no way to know when to stop looking.

### 2. Triage before measurement

The rule that fell out of the altar work:

> **Coarse position saturates. Exact position does not.**

A bounded vocabulary asked as set membership has small entropy and stops
growing once the corpus covers the space. The same vocabulary with exact depth
attached costs ~17 more bits and never saturates at any corpus size.

This predicts which encodings will work *before* running a query. "Potion of
haste available before Lair" will compress; "potion of haste on D:4" will not.
Ideas can be triaged on the model and only survivors measured.

Note the test is **effective entropy, not finiteness**. 2^22 saturates at a
billion seeds; 2^39 is equally finite and never saturates. "Bounded" is not
the criterion — small is.

### 3. Lossiness becomes an explicit product decision

Calling the corpus a lossy compressor names the real tradeoff. Dropping altar
depth is not "saving space" — it is discarding 17 bits that answer *which floor
exactly*, in exchange for keeping the bits that answer *which gods before
Temple*.

That is a product decision wearing a storage costume. It should be argued on
whether players ask the question, and it was: pre-Temple availability is the
conversion decision; exact floor rarely matters. The storage win followed from
getting the product question right, not the other way round.

The general form: **every compression choice here is a choice about which
questions to keep.** When those two framings disagree, the product question
wins, because a smaller corpus that cannot answer the question is worth
nothing.

## Why items are the hard case

Altars compress well because the underlying decision is simple: for most runs,
which gods are available before Temple is close to the whole question. Low
decision complexity means low entropy means a small encoding.

Items resist because the player decision is genuinely more complex. Which
consumables matter depends on class, build, current threats, and what else the
seed offered — so the useful fact is not a small set-membership question with
an obvious coarse form. 8.6M item rows are high-entropy under any model, and
the only way to shrink them is to answer fewer questions.

That is why item pruning is deferred rather than solved: it needs the product
question answered first — *which item questions are worth keeping* — and that
is real design work, not a measurement. The measurements are ready when the
answer is.

## The rule, stated once

1. Storage size is downstream of which questions stay answerable.
2. Entropy under a model of crawl's generator is the unit, and the stopping
   rule.
3. Coarse position saturates; exact position does not.
4. When compression and product disagree, product wins.

## Which questions are ours

Everything above bounds what a question *costs*. It does not bound which
questions belong here at all, and that is a separate axis: a fact can be cheap,
seed-determined and perfectly indexable, and still not be ours to store.

The line is the **build commitment**. The corpus answers questions upstream of
the decision of what character to commit to on this seed — what is available,
how early, and what that forecloses. Once a run is underway, how to route
through it is a different kind of question, and answering it is strategy-guide
territory this project deliberately avoids.

Applied to the topology features considered for format 4 — shafts, escape
hatches, stone arches, traps, teleporters: all seed-determined, all cheap
(~+240 rows per 160 levels), and all rejected. No one picks a species or a
god because of where a shaft is. It is route optimisation inside a run already
committed to, so it fails the test on relevance rather than on cost.

Two cases sit close enough to the line to be worth naming, because the
principle is easier to apply from its near misses than its clear cases:

- **Portal and shop positions.** Already stored, and they would be a harder
  argument today. What keeps them: missing a timed portal can close off builds
  *within* a seed, so their presence and depth is upstream of commitment even
  though their exact position is not. The `x`/`y` columns are the part that
  predates the distinction rather than following from it.
- **Altars.** A real argument exists for storing depth, and it is already
  answered by the coarse form above: the rare ones are what the corpus keeps,
  and the rest are guaranteed early enough that exact placement is not a
  commitment input. Same conclusion, reached on entropy rather than on scope —
  the two axes agreeing here is the reason altars read as settled.

The failure mode this guards against is a corpus that grows toward being a
walkthrough. Each individual actionable-looking fact is cheap; the aggregate is
a different product.
