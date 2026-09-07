# A single writer process

**Status: thinking, not decided.** Nothing here is committed to and none of it
is planned in detail. It records why the idea came up, what makes it attractive,
and what would have to be true before it is worth building — so that the next
person to hit a `BUSY` burst does not re-derive it from scratch.

## What prompted it

Ticket `b45ccc70b3`: `seed-deepen` logging `pass failed: exec_script failed:
BUSY` in bursts, five of them across 2026-09-02/03, the longest ~7.5 minutes.
The generator survives each one — `Deepen.guard` catches, the pass is skipped,
the loop continues, the heartbeat holds — so nothing was lost. The complaint is
that the corpus has contention at all, and that a burst is expensive to diagnose
after the fact.

## The invariant we assert and do not enforce

Three places in the tree say the corpus has one writer:

- `tools/corpus-fill` — "The corpus has one writer, and a fill is eight of them."
- `db.ml` — "a fill runs eight ingest processes against the single writer".
- `db.ml` — "The generator is also the only writer, so it is the only thing that
  can keep `sqlite_stat1` current."

None of them is enforced, and when this was written at least the third was
false. Two leaks were found; **one has since been closed.**

- **`pragma optimize` from every connection — fixed.** `close` ran it, writing
  `sqlite_stat1`, on *every* connection including the web process's, wrapped in
  `try ... with Failure _ -> ()` so contention failed silently and left nothing
  in any log. `Db.open_`/`Db.close` now take `?readonly`, and a read-only handle
  skips the pragma outright rather than relying on the error path — measurement
  showed this build of SQLite returns OK on a read-only connection without
  performing the write, so the failure the handler was written to absorb does
  not reliably fire. The web process and every pooled reader are out of the
  writer set. The comment at `db.ml`'s `close` — the third assertion above —
  was corrected with it: the generator is the only writer *between fills*, and a
  fill is eight more.
- **The fill's advisory lock — still open.** `tools/corpus-fill` uses `flock(1)`
  and no-ops entirely on a platform without it (macOS), while both readers of
  that lock (`bin/deepen.ml`, `lib/web`) use `Core_unix.flock`, which works
  everywhere. The writer degrades; the readers do not. So the protocol still has
  one side that can never answer.

The BUSY bursts are the gap between the asserted invariant and the real one.
That gap is the actual finding here, independent of what we do about it — and
it is now half the size it was.

## The idea

One process owns the only write connection to the corpus. Extraction stays
parallel — it is where the time goes — but the workers stop opening SQLite.
They emit extracted records on stdout and a single writer batches and commits
them.

Two things make this less of a leap than it first sounds:

- **The wire format is free.** `ingest` already parses crawl's output into typed
  records, and the corpus already speaks sexp end to end (crawl's dumper emits
  sexp; `Reader.parse_line` reads it). Emitting records as sexp instead of
  writing rows is a smaller change than inventing a protocol. It also makes a
  chunk's extracted data replayable — today a failed chunk's work is simply
  gone.
- **The writer would be idle.** Measured on the 100k fill (0.34.1, D:8,
  2026-09-02): 250 seeds per chunk in ~195s across 8 workers, ~76 seeds/min
  aggregate, ~400-490 entries per seed. That is on the order of 500 rows/sec
  arriving at the writer. Batched SQLite inserts in WAL are orders of magnitude
  above that. Serializing writes costs nothing we can measure; generation is the
  bottleneck by a wide margin and stays so.

The appeal is not throughput. It is that "one writer" stops being a comment
asserting something the code does not enforce and becomes true by construction —
which kills both leaks at once without fixing either individually, and makes
`busy_timeout = 30000` and `begin immediate` vestigial rather than load-bearing.

## What argues against it, or at least for waiting

- **It is a large change to enforce an invariant two small ones also enforce.**
  Making `pragma optimize` conditional removes the web process from the writer
  set; replacing the shell `flock` with a helper that behaves the same on both
  platforms fixes the fill. Neither needs a wire format. **The first has landed**
  (see above), so this argument is now half-tested rather than hypothetical: if
  the second lands and the corpus goes quiet, the case for a broker is much
  weaker. Whether it has gone quiet is unmeasured — no burst has been observed
  through the new extended-result-code message yet, which is the next thing to
  find out and is listed below.
- **It does not obviously address the short-interval failures.** The bursts show
  two cadences. The ~32s one is fully explained — `begin immediate` waiting out
  the 30s `busy_timeout` plus the 2s poll — but the ~7s one means something
  returned BUSY without honouring the timeout, which is what `BUSY_SNAPSHOT`
  does. If that is what it is, it is a read-snapshot problem, and the web
  process's *read* transactions survive a broker untouched.
- **A broker holding a write transaction across batches is a WAL-growth risk**,
  and WAL growth is already unhealthy: 122 MB against a 1.35 GB corpus, not
  checkpointing down (app host, 2026-09-03). At the 200M-seed target, on-disk
  size is the binding constraint. This wants measuring before it is designed.
- **The governing ethic is fewer moving parts** (`architecture.md`). A broker is
  one more process, one more failure mode, one more thing to supervise. It has
  to buy more than it costs.

## What we would want to know first

- **The extended result code on a real burst.** `exec_script` now carries the
  extended code and sqlite's message, so the next burst distinguishes plain
  `BUSY` (5, waited out the timeout, retryable) from `BUSY_SNAPSHOT` (517,
  refused at once, never resolved by waiting). These want different fixes and
  the old message could not tell them apart. Nothing else should be designed
  until a burst has been observed through the new message.
- **Whether the deepen claim needs the write lock when there is nothing to
  claim.** `begin immediate` takes the lock up front by design — the two
  generators racing on one unclaimed row is exactly what it is for. But the
  queue was empty during the 01:30 burst, which means the generator was
  contending for a lock it had no work for. A cheap read-snapshot probe before
  the immediate transaction may remove most of the contention without touching
  the architecture.
- **Where the WAL growth comes from**, since it constrains any design that holds
  transactions open longer.

## Non-goals

Not proposing to remove the parallelism. Eight ingest processes exist because
extraction is CPU-bound (~2.5s in crawl per seed, ~0.6s startup amortised by
chunking); a single writer serialises the writes, not the extraction, and the
fan-in has to be built rather than assumed away.

Not proposing a durable write queue. A broker would make one easy, and if we
wanted writes to survive a fill killed mid-chunk that is where it would live —
but the fill-progress TSV shows `ok` on every chunk of the 100k fill, so there
is no evidence we have that problem.
