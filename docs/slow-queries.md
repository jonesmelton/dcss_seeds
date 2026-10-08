# Slow queries, as users hit them

A field log of searches that were slow or rejected in production, written from
the access log rather than from a profiler. Each entry is what someone was
trying to find out, what the site did, and how long they waited.

The engine-level account of *why* these are slow is `AGENTS.md`, "Search cost is
linear in a term's matched rows" — the `distinct` nested under a sort. This
document does not repeat it. It exists because that analysis names query shapes, and the thing
to fix is a question a person asked. A shape that is expensive but nobody types
is not urgent; a shape three different people reached for in one afternoon is,
whatever it costs.

All observations 0.34.1, 1.3M corpus, prod, 2026-09-10 UTC, taken from the Caddy
access log over a 12-hour window. Durations are end to end over HTTP, so they
include queueing.

## The slow ones

### "Which staff has both these schools on it?"

The worst thing on the site. Two people found it independently in one afternoon.

| Query | Result | Waited |
|---|---|---|
| `staff props:Conj,Alch` | 200 | 25.6s |
| `staff props: Conj, Alch` | 200 | 24.0s |
| `staff props: Conj, Alch` | **abandoned** | 7.6s |
| `staff props: Conj, Earth, Ice` | 200 | 40.9s |
| `staff props:Conj, Fire, Alch` | 200 | 28.4s |
| `props:Alch` (one school, no `staff`) | 200 | 1.2s |

The question is a real one and it is the reason prop search exists: an
enhancer staff is only worth detouring for if it boosts a school you are
actually going to cast, and two useful schools on one staff is the thing worth
knowing a seed for. It works — all but one returned results — but at 24 to 41
seconds, and one person closed the tab mid-request and retried.

Note the shape: one school is 1.2s, two schools is 24s+. The cost is in the
conjunction, not in prop search as such. Whatever gets built here, the
single-prop case is already usable and the multi-prop case is the feature.

### "Show me a seed with a big pile of acquirement"

`9x artefact` — **503 after 30.0s**, the only 503 in the window. (`artefact`
was removed as a search term 2026-10; the reader was reaching for
`9x scroll:acquirement` through a proxy, and the direct term answers in 0.55ms
(10,000 seeds, 0.34.1, D:8, local).)

That is the search timeout firing, which is the honest failure, but the reader
asked a reasonable question and got nothing. `artefact` alone returned in 22ms;
the count is what kills it.

Someone else spent 20:04–20:05 walking `10x → 9x → 8x → 7x scroll:acquirement`
at 160–200ms each, plainly hunting for the largest count that still returns
rows. That is a person doing binary search by hand because the tool will not
tell them where the ceiling is. Both of these want the same thing — *how high
can this number go and still match* — and neither can ask it.

Answered 2026-10: an empty search whose one counted term is out of reach now
says the most any seed in the build holds, and links to that count
(`Db.count_ceiling`, fossil ticket bcc9e65f53).

### Name search on unrands

`name~Elemental Staff` 184ms and 270ms, `name~pair of quick blades "Gyre" and
"Gimble"` 66–227ms across seven requests, `name~crown of vainglory` 159ms,
`name~Storm Queen's Shield` 90ms, `name~storm bow` 28ms.

Not slow yet, listed because it is the shape AGENTS.md measures at 7.02s for a
long name and because these are common queries — hunting a specific unrand is
one of the two or three things people obviously come here to do. The ones
observed were fast. Watch it as the corpus grows.

## The rejections

400s are the app declining to answer. Each of these is a person who typed
something reasonable, so each is a UI question before it is a parser question.

### Prop syntax beyond a bare school name

`props:Conj, Int+6` → 400. `props: Conj, F+, C+` → 400. `props:*Noise` → 400.

Bare `Conj` and `Alch` parse; magnitudes (`Int+6`), resistances (`F+`, `C+`),
and drawbacks (`*Noise`) do not. Someone tried all three within four minutes of
successfully running a two-school query, which is exactly what you would expect:
the syntax taught them that props are searchable, and they generalised.

`*Noise` is worth singling out. It is the drawback that actually matters, so a
reader asking to *avoid* it is asking the sharpest available question and being
told no.

### `floor` combined with `name~`

`floor name~elemental staff` → 400. `floor name~Elemental Staff` → 400.
`floor name~pair of quick blades "Gyre" and "Gimble"` → 400.

Three rejections, two different people, hours apart. `floor` composes with
`weapon:`, `armour:`, `talisman:` and `potion:` all over this window, so a
reader who has learned it reasonably expects it to compose with `name~` too.
"Is the unrand lying on the floor or in a vault I have to fight for" is a
sensible thing to want, and the qualifier that answers it everywhere else is
refused here.

### Bare terms with no category

`dragon-coil` → 400, then `talisman:dragon-coil` → 200 and the reader continued.
`broad` → 400, then `weapon:broad axe` → 200.

Both recovered within a minute, so the error message is doing its job. Recorded
because both people's first instinct was to type the item name alone, and both
had to be taught the prefix by a failure.

Since 2026-09-29 a bare word is looked up rather than refused: `broad` and
`dragon-coil` are offered the pairs they are a word of, and a word naming
exactly one pair runs as that pair. See *A rejected search hands the form back* in `docs/architecture.md`.

### Spelling, and pasting results back in

One reader spent 13:59–14:00 on: `3x scroll of aquirement` → 400, then
`3x scroll:aquirement `, `3x scroll:aquiremen`, `3x scroll:aquirement`,
finally `3x scroll:acquirement` → 200.

Four attempts, all 200s after the first because `aquirement` is a *valid parse*
that matches nothing — the misspelling fails as an empty result set, not as an
error, so nothing told them the word was wrong. Then, twice:

    3x sscroll of acquirement ×3 on D:1croll:acquirement

which is result text pasted into the middle of the query box. Whatever the
result page offers as copyable, someone took it for a query.

## What this suggests, in the order the log argues for it

1. **Multi-prop conjunction is the one real performance bug.** 24–41s, hit by
   two independent people the same afternoon, on the feature's headline
   question.
2. **A count with no matches should fail fast, not time out.** `9x artefact`
   spending 30s to return a 503 is the worst version of no.
   The timeout half was fixed 2026-09-05 (`Db.driver_select`); the empty
   answer now names the ceiling (bcc9e65f53).
3. **`floor` + `name~` is a composition gap**, cheap to judge and asked three
   times.
4. **A term that parses but matches nothing should say so differently than one
   that matches nothing legitimately.** `aquirement` cost a reader four
   attempts because a typo and a genuinely empty result look identical.
