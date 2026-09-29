# dcss-seed-explorer

**Live at <https://dcss.garden>.**

Asks *what does this DCSS seed contain, and how early* (items, shops, altars,
portals) and lets you compare seeds against each other. An extraction pipeline
dumps seeds as s-expressions, those load into a SQLite corpus, and a web app
browses and searches it.

Seeds are only meaningful relative to a version, so each version gets its own
crawl build. `versions.conf` lists them; everything else is derived.

## Setup

The extraction pipeline needs a crawl clone, a C++ toolchain, python3, and
`lua`. The corpus and web app additionally need `opam`,
[`just`](https://github.com/casey/just), `curl`, `openssl`, and `pkg-config`:
`just deps` builds a pinned SQLite from source rather than using the system
one.

    git clone https://github.com/crawl/crawl ~/code/crawl

`provision` checks out release tags as worktrees of that clone, so it needs the
tags: a shallow or single-branch clone fails at `git worktree add`. The path
defaults to `~/code/crawl`; `CRAWL_REPO` overrides it.

    make provision          # build every version in versions.conf
    make provision-0.34.1   # or just one
    make versions           # what's configured, and what's built

The web app serves the versions in `lib/web/served.ml`, which is not everything
`versions.conf` can build — `trunk` is buildable and not served, so a corpus
filled against it has nowhere to show up. Start with a served version.

Each version takes a few minutes to compile. `provision` handles the tricky parts: submodules in worktrees, the system-zlib
workaround, the pyyaml venv, and the per-version des cache.

## Use

`tools/corpus-fill` runs crawl and pipes the dumps straight into the corpus; see
**Corpus** below. Depth defaults to `D:8`, roughly "the early game" and the stretch a player
sizes up before committing to a seed.

Depth is the dominant cost, so it's the first thing to raise or lower:
`D:15` is the whole main dungeon, `Lair:5` adds Lair, `Zot:5` is everything
worth generating. Portals (Sewer, Ossuary, Bazaar, …) always come along when
their entrance sits on a level within the cap.

## Speed

Single crawl process, 10 seeds, 8-core M-series. The shape of the depth curve:

| depth          | per seed | records |
|----------------|----------|---------|
| `D:4`          | 126ms    | 699     |
| **`D:8`**      | **276ms**| 1435    |
| `D:11`         | 434ms    | 1968    |
| `D:15`         | 673ms    | 2755    |
| `Lair:5`       | 1.01s    | 3676    |
| `Zot:5`        | 3.80s    | 12117   |
| `all` (+Hells) | 4.78s    | 14982   |

`all` adds the Hells for +26% and is rarely what you want; `Zot:5` is the
practical "everything".

Batched across 8 cores the per-seed cost drops roughly 4x. Process startup
dominates at shallow depths, so seeds are batched into one crawl process per
chunk, and chunk size adapts to core count so every core gets work.

Enumerating the whole seed space is out of scope (2^64), but backfilling seeds
from real games works well. At `D:8` on 8 cores the sustained rate is ~611
seeds/min wall, so 100k seeds is under three hours and a million is a bit over
a day — measured over a 27.3-hour continuous fill (0.34.1, prod, 2026-09).

## Notes

- Items come from player map knowledge, so each level is magic-mapped before
  scanning. Shop stock is read directly and needs no mapping.
- Items carried by **uniques** are collected by default (`holder` names the
  monster). Ordinary monsters are skipped: they account for ~70% of carried
  items but ~11% of carried artefacts — uniques carry artefacts roughly 19x as
  often. Pass `--mon-items` for every monster, `--no-uniques` for none. The cost
  either way is under 2%, since the scan already visits every cell.
- The default item filter is crawl's own `item_ignore_boring` — no plain gear,
  no missiles — with two exceptions layered on top: an **artefact** is always
  kept, and so is a **barding**. `item_ignore_boring` judges gear by plus and
  brand, which discards a +0 unbranded unrand, and it discards anything useless
  to the scanning character, which discards every barding.

## Corpus

`ingest` is an OCaml program that reads s-expression dumps and writes them
into SQLite (`schema.sql`). It backs querying across many seeds at once.

Sexps because the crawl lua sandbox ships no json library (and no `io`/`os`), so
every wire format is hand-written. Sexps are cheaper to emit correctly, and
OCaml parses them for free. The database is the queryable artifact, so the wire
format stays an implementation detail.

    cd builds/0.34.1/crawl-ref/source
    util/fake_pty ./crawl -dir ../../../../sandboxes/0.34.1 \
      -script seed_dump_sexp.lua -seed 1 -count 100 -depth D:8 2>&1 \
      | grep '^#SEED#' | ../../../../_build/default/bin/ingest.exe -db ../../../../corpus.db

Re-ingesting a (seed, version, level) replaces it rather than duplicating,
so reruns are safe.

`tools/corpus-fill` is the bulk path: it chunks a contiguous seed range across
cores and pipes each crawl process straight into `ingest`.

    tools/corpus-fill 0.32.1 -s 1 -n 10000 -d D:8 --db corpus.db

The OCaml side is one dune project at the repo root, driven by `just`
(`make` still owns the crawl side). It wants its own opam switch, in `_opam/`,
which the `just` recipes point at whether or not your shell has `opam env`
applied:

    opam switch create . 5.5.0 --no-install && just deps && just ci

## Web app

`just run` serves the corpus on port 8430 (`SEED_PORT` to override): a
paginated seed listing, a per-seed catalog page, and the search surface
("which seeds have X"), all version-scoped. Dream + TyXML + htmx, server
rendered.

    just run                # the web server
    just deepen             # generator: claim queued seeds and run crawl for them

See `docs/corpus.md` for the data model and `docs/architecture.md` for the
web app.

There are no accounts and no tracking. The reverse proxy's access log is the
only place client IPs are stored, and it keeps them for 30 days before they
roll off; the app itself sees only the proxy.

## Limits

Known tradeoffs, stated rather than left to be discovered:

- **Search has no negation.** You can ask which seeds *have* an unrand; there is
  no operator to ask which lack it. The seed page lists every unique, feature,
  and shop level by level, so the negative question is answerable by eye but not
  by query.
- **An item's unidentified appearance is not recorded.** Dumps carry the
  identified name (`potion of heal wounds`), never the seed-determined colour
  (`puce potion`). It is a pure function of the seed, but it is absent from the
  wire format, so surfacing it means a format bump and a full re-fill.
- **The item filter is crawl's own, with two holes plugged.** `item_ignore_boring`
  plus artefacts and bardings is what a fill keeps. It still drops anything
  useless to the scanning character, so scrolls of identify, potions of
  moonshine, large rocks, and corpses are never in the corpus — and that is a
  fill-time decision, not something a re-ingest can recover.

## Licence

MIT, except the vendored tile art: the PNGs under `static/tiles/` come from
Dungeon Crawl Stone Soup and stay under their own terms. `LICENSE.md` states the
scope and `static/tiles/ATTRIBUTION.md` records the provenance.
