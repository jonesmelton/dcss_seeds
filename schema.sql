-- Corpus of seed catalogs extracted by scripts/seed_dump_sexp.lua.
--
-- Seeds are only meaningful relative to a build, so the build is part of the
-- identity of every row: the same seed number on 0.33 and 0.35 describes two
-- unrelated dungeons. Rows carry `version_id`, not the version string.

pragma journal_mode = wal;

pragma foreign_keys = on;

-- Builds the corpus has been extracted from. Version strings from
-- crawl.version() do not sort meaningfully (0.33-a0-4444-g172805db8e), so
-- first_seen_at is what orders builds against each other.
--
-- `id` is what every other table stores. The version string is resolved once
-- per query (and once per ingest batch), so the ~20 bytes of build name are
-- not repeated across every one of a corpus's entries.
--
-- seed_levels references this table, so every ingest batch must start with
--   insert into versions (version) values (?) on conflict do nothing;
-- or its first seed_levels insert fails the foreign key.
create table versions (
    id integer primary key,
    version text not null unique,
    first_seen_at integer not null default (unixepoch())
) strict;

-- The string dictionary. Every repeated text value in the corpus -- level
-- names, item types, egos, feats, monster names, the irreducible display names
-- -- is stored once here and referenced by id.
--
-- Measured 2.36x smaller with every index built, over two corpora filled from
-- the same crawl build with byte-identical row counts (400 seeds, 0.34.1, D:8,
-- 2026-08-28, M-series laptop): 9,428,992 -> 3,997,696 bytes after vacuum. The
-- design pass projected 2.23x on a 1000-seed slice and the plan 1.94x. `name`
-- was the target because it was table payload *and* the largest index. 95% of
-- name rows are one of a few thousand repeated values, so interning is nearly
-- free on them; the singleton tail (artefact names) costs the same either way,
-- and most rows now store no name at all -- see entries.name_id.
--
-- References from entries/seed_levels are deliberately *not* declared as
-- foreign keys. Ingest enforces them by construction -- it inserts the string
-- before the row that names it -- and an enforced reference is an index probe
-- per row on the hot path for a constraint that cannot be violated.
--
-- The `unique` autoindex is not hygiene: id resolution rides it on the write
-- path, and Search's Name_like criterion is a `like` scan over this table
-- rather than over entries. That is the whole reason a substring search is now
-- cheap; see entries_search_name below.
create table strings (
    id integer primary key,
    val text not null unique
) strict;

-- parent_level_id is the level whose entrance held a portal: a Sewer reached
-- from D:5 is ("Sewer", parent "D:5"). It is a property of the level, not of
-- its rows, so it lives here rather than repeated across millions of entries.
-- Null for everything that is not a portal, and for portal rows ingested before
-- format 2, which is why the depth logic keeps a parentless fallback.
--
-- temple_altars is a bitmask over crawl's 22-god temple pool, set only on a
-- Temple level. Those gods' altar rows are not in `entries` at all: a Temple
-- holds 6-22 of them and they are 64% of every altar row in the corpus, while
-- the set of possible masks is bounded at 2^22 however many seeds are ingested.
-- The four vault-placed gods (Lugonu, Beogh, Jiyva, Ignis) and altar_ecumenical
-- are outside the pool, have no bit, and keep ordinary rows -- so a rare-god
-- query never touches bit logic. See lib/corpus/temple.mli.
--
-- level_id is a strings reference, so it carries no order of its own: string
-- ids are assigned in insertion order and mean nothing about depth. Ordering a
-- seed's levels is Depth's job, in the domain layer.
create table seed_levels (
    seed text not null,
    version_id integer not null,
    level_id integer not null,
    parent_level_id integer,
    temple_altars integer,
    -- gold is the summed quantity of every gold pile on the level. Crawl's own
    -- item filter drops the piles before the wire, so this cannot be recovered
    -- from a corpus filled without it; a pile is not a row because neither its
    -- position nor its individual size is a fact a reader asks for. It counts
    -- the floor only -- no monster drops, no Gozag -- so it is a lower bound on
    -- purchasing power and is labelled "floor gold" wherever it surfaces. Null
    -- on every level ingested before format 4.
    gold integer,
    format integer not null,
    ingested_at integer not null default (unixepoch()),
    primary key (seed, version_id, level_id),
    foreign key (version_id) references versions (id)
) strict, without rowid;

-- `id` exists so entry_spells and entry_props have something to reference:
-- (seed, version_id, level_id, name_id) is not unique, since a level can hold
-- two of the same item. It is an explicit alias for the rowid rather than a new
-- column, so it costs no extra storage.
--
-- `cat` is an integer enum (Record.Cat.to_int), not a string: three live states
-- repeated across every row.
--
-- `name_id` is *null* exactly where Display_name.of_entry answers `Derived` --
-- the row's display string is a function of the columns beside it (a feature's
-- feat, an item's base_type/sub_type/plus/ego/quantity) and storing it would
-- write the same fact twice. It is set only for the irreducible tail:
-- artefacts, monsters, and anything whose spelling no column determines. The
-- reader reconstructs the rest through Display_name; a null name_id on a row
-- Display_name calls Irreducible is corruption, and reads as an error rather
-- than a guess.
--
-- `ego` is the enchantment's identity where `branded` is only its existence,
-- and it is the wider of the two: `branded` is weapon/armour-only while `ego`
-- also covers jewellery.
create table entries (
    id integer primary key,
    seed text not null,
    version_id integer not null,
    level_id integer not null,
    cat integer not null,
    name_id integer,
    base_type_id integer,
    sub_type_id integer,
    quantity integer,
    artefact integer,
    branded integer,
    plus integer,
    cost integer,
    ego_id integer,
    feat_id integer,
    timeout_turns integer,
    unique_mons integer,
    native integer,
    type_name_id integer,
    x integer,
    y integer,
    carried_by_id integer,
    -- The canonical shop type ("General Store"), not the display name: a vault
    -- may name a shop anything ("Sanarr's Fire Supplies"), which leaves the
    -- type unrecoverable from the name. Set only on enter_shop feature rows --
    -- on the feature, not on each stocked item, which is 5.4x fewer rows for
    -- the same fact. Null on every build predating dgn.shop_type_at.
    shop_type_id integer,
    -- The trove's toll as crawl renders it ("give a scroll of acquirement"),
    -- interned like every other repeated string. It is the only thing telling
    -- one trove from another, and the structured toll table is not reachable
    -- through the lua marker API. Set only on enter_trove feature rows; no
    -- index, since a trove stands on 4.5% of seeds and a `like` over the
    -- dictionary is cheap at that count.
    toll_note_id integer,
    foreign key (seed, version_id, level_id) references seed_levels (seed, version_id, level_id) on delete cascade
) strict;

-- Spells in a randart book, and artefact properties. A parchment's single spell
-- and a named book's fixed set are *not* here: the first is derivable from
-- entries.sub_type_id and the second lives once per version in book_spells,
-- which together were 93% of this table. Both carry their own
-- foreign key to seed_levels rather than relying on a cascade through entries,
-- so re-ingesting a level cleans them up with no extra delete logic — the
-- existing "delete the seed_levels row, everything under it cascades"
-- idempotency story just gains two more children.
create table entry_spells (
    entry_id integer not null references entries (id) on delete cascade,
    seed text not null,
    version_id integer not null,
    level_id integer not null,
    spell_id integer not null,
    foreign key (seed, version_id, level_id) references seed_levels (seed, version_id, level_id) on delete cascade
) strict;

-- A named spellbook's contents ("book of Necromancy" -> its three spells) are
-- compiled into the build, not rolled per seed: verified 76 titles and 76
-- distinct (title, spell set) pairs over a 10k-seed corpus. Storing the set once
-- per version replaces 24,661 entry_spells rows with ~230, and the randart book
-- -- artefact = 1, sub_type "book of Fixed Theme" -- keeps its per-entry rows
-- because its contents genuinely are per seed.
--
-- Filled by ingest on first sighting of a title rather than by an extraction
-- pass: a title's spells are needed exactly when the title is in the corpus. A
-- later sighting that disagrees is rejected, since a released version is one
-- build. See lib/corpus/book.mli.
create table book_spells (
    version_id integer not null,
    sub_type_id integer not null,
    spell_id integer not null,
    primary key (version_id, sub_type_id, spell_id),
    foreign key (version_id) references versions (id)
) strict, without rowid;

-- `value` is crawl's raw integer, not its display spelling: rF+ and rF++ are 1
-- and 2 here, and rElec is 1. Crawl chooses between a bare name, a repeated
-- sign and a signed number using a table the lua bindings do not expose, and
-- the corpus no longer stores its rendering for a non-artefact row at all --
-- an artefact's stored name is the only place it survives.
create table entry_props (
    entry_id integer not null references entries (id) on delete cascade,
    seed text not null,
    version_id integer not null,
    level_id integer not null,
    prop_id integer not null,
    value integer not null,
    foreign key (seed, version_id, level_id) references seed_levels (seed, version_id, level_id) on delete cascade
) strict;

-- How surprising a quantity of an item is, at a depth cap, for a version. One
-- row per observed (base_type, sub_type, count): "3 potions of haste by D:8"
-- is looked up here, not computed at request time, because the tail
-- probability is a whole-population aggregate -- a full scan of entries -- and
-- nothing about serving a page can afford to run one. Recomputed by
-- bin/rescore.ml after a fill lands, never per batch and never per request.
-- Without this table Heat.score has nowhere to get surprise from and heat
-- cannot be computed at all.
--
-- The item key is interned like every other: rescore joins these ids against
-- entries' own, so a text key here would match nothing.
--
-- cap matches seed_fills.depth: a score at D:8 is not comparable to one at
-- Swamp:4, so the surprise table -- and the population it is derived from --
-- is per (version, cap), not per version alone.
create table surprise (
    version_id integer not null,
    cap integer not null,
    base_type_id integer not null,
    sub_type_id integer not null,
    count integer not null,
    tail_p real not null,
    primary key (version_id, cap, base_type_id, sub_type_id, count),
    foreign key (version_id) references versions (id)
) strict, without rowid;

-- One seed's heat at one depth cap. Not a column on seed_fills: a score is
-- keyed (seed, version, cap) while seed_fills is keyed (seed, version), and a
-- seed filled to Swamp:4 must still carry a D:8 score to remain a member of
-- the shallow cohort's percentile -- collapsing cap into fill depth would
-- silently drop it from every shallower comparison. Not a cache either: a
-- band is a population percentile, so there is no cheap single-seed recompute
-- to serve on a miss.
--
-- band is stored rather than derived at read time -- deriving it needs the
-- cut points in heat_bands, a second lookup per page for something that
-- cannot change without a rescore anyway.
create table seed_scores (
    seed text not null,
    version_id integer not null,
    cap integer not null,
    score real not null,
    band integer not null,
    scored_at integer not null default (unixepoch()),
    primary key (seed, version_id, cap),
    foreign key (version_id) references versions (id)
) strict, without rowid;

-- The percentile cut points a rescore produced, per (version, cap): band 0's
-- min_score is the population minimum (or 0), and each higher band's
-- min_score is the score at that percentile. Stored rather than hardcoded,
-- because a weight-table edit moves every score and an absolute cut would
-- silently drift out of meaning -- the percentile is what a cut point is
-- supposed to hold onto.
create table heat_bands (
    version_id integer not null,
    cap integer not null,
    band integer not null,
    min_score real not null,
    primary key (version_id, cap, band),
    foreign key (version_id) references versions (id)
) strict, without rowid;

-- Work queue for the background generator. A seed is claimed by setting
-- started_at, so an interrupted run leaves a row that can be reclaimed rather
-- than a gap in the corpus. The default deep cap is Swamp:4, which reaches
-- through the Lair branch set without generating the late game.
--
-- queued_at orders the queue. A claim is taken under `begin immediate` and
-- checks changes(): two generators serialize, and the loser updates no rows and
-- picks another job rather than proceeding on one it does not hold.
--
-- attempts bounds the retry. A claim outstanding past the reclaim window means
-- the generator died -- a job runs for ~2.5s -- so started_at is cleared and the
-- job is retried; a timestamp alone cannot stop a seed that reliably crashes
-- crawl from being reclaimed forever. A job at the limit records error and
-- stays claimed, so it leaves the queue instead of consuming it.
--
-- `depth` and `error` stay text: the queue is bounded by the outstanding-jobs
-- cap, so there is nothing here for a dictionary to compress.
--
-- version_id references versions but is deliberately not an enforced foreign
-- key, and neither is generators'. `versions` records what has been *ingested*;
-- a generator declares what it can *build*, and a build tree routinely exists
-- for a version no seed has been filled for yet -- which is the case a queue is
-- for. Enforcing the reference would refuse exactly the first job of a new
-- build. The id is registered by the enqueue and heartbeat paths instead, so
-- the row still resolves.
create table ingest_jobs (
    seed text not null,
    version_id integer not null,
    depth text not null default 'Swamp:4',
    queued_at integer not null default (unixepoch()),
    started_at integer,
    finished_at integer,
    attempts integer not null default 0,
    error text,
    primary key (seed, version_id)
) strict, without rowid;

-- Which versions a generator can actually build, and when it last said so.
--
-- A job names a version and the generator needs the matching build tree, so a
-- generator serves only what it was provisioned for and leaves the rest
-- unclaimed -- another generator may serve them. That leaks: an unclaimable job
-- is indistinguishable from a queued one, so a version nothing serves fills the
-- queue with rows that never retire, and the outstanding-jobs cap starts
-- refusing requests that would have succeeded.
--
-- The web process cannot tell on its own. It has no build tree, so it cannot
-- look for builds/<version>, and `versions` records what was *ingested*, not
-- what can be built -- a corpus routinely outlives the build tree that filled
-- it. So the generator declares it here on startup and on a timer, and the
-- enqueue refuses a version with no recent heartbeat. A static list in the web
-- config would be a second place to edit at provision time and would go stale
-- silently in exactly the case that matters, which is a generator that stopped.
create table generators (
    generator_id text not null,
    version_id integer not null,
    heartbeat_at integer not null default (unixepoch()),
    primary key (generator_id, version_id)
) strict, without rowid;

-- "can anyone serve this version, recently" -- the enqueue's admission check,
-- and the sweep that fails jobs whose version no longer has a generator.
create index generators_version on generators (version_id, heartbeat_at);

-- How deep each seed was extracted. Until deep generation existed every seed
-- was filled to the same depth, so completeness could be inferred from the
-- level list and nothing had to record it. Once one seed stops at D:8 and its
-- neighbour reaches Swamp:4, that inference breaks *silently*: "no Wyrmbane
-- here" and "not searched deep enough to know" become indistinguishable, and a
-- population statistic drawn across both measures extraction effort as much as
-- dungeon content. Measured over 200 deep seeds against 10,000 shallow ones,
-- 100% of the deep held an artefact against 86.7% of the shallow, entirely
-- because the deep ones were searched further.
--
-- `depth` is a Depth.t -- reach order, the depth of the shallowest D-level a
-- level can be reached from -- not a level name, so cohort comparison is an
-- integer test. It is *derived* from the levels a seed holds rather than
-- carried on the wire, which is what makes it backfillable: an existing corpus
-- is evidence of its own fill depth and needs no re-extraction.
--
-- Per-seed, so it is its own table rather than a column repeated across every
-- one of a seed's levels. See lib/corpus/fill_depth.mli.
create table seed_fills (
    seed text not null,
    version_id integer not null,
    depth integer not null,
    filled_at integer not null default (unixepoch()),
    primary key (seed, version_id),
    foreign key (version_id) references versions (id)
) strict, without rowid;

-- "every seed in this version filled at least this deep" -- the cohort scan a
-- depth-scoped statistic makes. Leads with version like every other index here,
-- and ends with seed, which is what a cohort query returns.
create index seed_fills_cohort on seed_fills (version_id, depth, seed);

-- seed_levels' primary key leads with seed, so a version-scoped listing can
-- only search on seed and filters version row by row. Every query is
-- version-scoped, so the listing order (version_id, seed) needs its own index.
create index seed_levels_version_seed on seed_levels (version_id, seed);

-- "which seeds have a Sewer off D:5" — and the lookup a depth-filtered search
-- makes when it needs a portal's real depth.
create index seed_levels_parent on seed_levels (version_id, parent_level_id, seed) where parent_level_id is not null;

-- entries_name (name, level), entries_feat (feat) and entries_artefact (name)
-- used to live here and were dropped: every query the app issues is
-- version-scoped, so the entries_search_* indexes below are strictly better
-- prefixes and the planner never chose these. Measured on the 100k corpus they
-- cost 592 + 63 + 14 = 669 MB, 16% of the database, and removing them changed
-- no result and no timing. Do not add a non-version-leading index back without
-- a query that needs one.
create index entries_seed on entries (seed, version_id, level_id);

-- The generator's claim scan: oldest unclaimed job for a version it can build.
create index ingest_jobs_pending on ingest_jobs (version_id, queued_at) where finished_at is null;

-- Search indexes: "which seeds have X". Every one leads with version_id, since
-- a seed number without a build is not a question, and ends with seed, which is
-- what a search returns — so the lookup is a covering seek that never touches
-- the table.
--
-- (base_type_id, sub_type_id) is the searchable vocabulary and name_id is the
-- display string: a name embeds enchantment and brand (`+3 greatsling "Punk"
-- {acid, rCorr}`), so it has ~18x the cardinality and almost every artefact
-- name is distinct. The type pair is what makes "any potion of haste" a seek.
--
-- sub_type is the bare type ("haste", not "potion of haste"), so base_type is
-- what disambiguates it. No two base types currently share a sub_type, but
-- that is a property of the data rather than a guarantee, so the pair is the
-- key.
-- level_id and quantity trail the key columns so a term carrying a depth cap or
-- a count threshold stays *covering*. Without them the seek is still
-- index-driven but every matching row costs a random table lookup to read the
-- extra column, and a common term matches millions: measured over a 100k-seed
-- corpus, the altar_trog + "by D:3" lookup runs 7.6s uncovered against 8ms
-- covered.
--
-- cost is appended last, after seed, for Floor_item's `cost is null` test.
-- Earlier in the key it would have been an improvement for that one criterion
-- and a regression for the other two: the search SQL is keyset pagination
-- (`select seed from (... intersect ...) where seed > ? order by seed limit
-- ?`), which depends on each arm emitting seeds in sorted order within a
-- (version_id, base_type_id, sub_type_id) seek so `distinct` streams and
-- `limit` terminates early -- and cost ahead of seed breaks exactly that
-- ordering for Item and Shop_item, the two common shapes, to speed up the
-- rarer Floor_item. Appended after seed it costs nothing for Item and
-- Shop_item (neither tests it) and turns Floor_item's test into an in-index
-- filter: still volume-bound -- 423k floor rows for potion:haste in 0.34.1
-- against 27.2M total rows matching the partial predicate -- but no longer a
-- table lookup per row. Measured floor potion:haste 4.65s uncovered against
-- 0.08s for the bare Item shape (300k seeds, 0.34.1, 2026-09-03, warm, prod).
create index entries_search_type on entries (version_id, base_type_id, sub_type_id, seed, level_id, quantity, cost) where sub_type_id is not null;

-- The exact-name seek, and the second half of a substring search.
--
-- A substring match used to be the one criterion no index could serve: `name
-- like '%Wyrmbane%'` had to read every row's text. Interning splits it in two.
-- The `like` runs against `strings` -- the vocabulary, ~378k names on a
-- 100k-seed corpus, not 13.7M entries -- and yields a set of ids; this index
-- turns each of those into a covering seek (measured 16.9s -> 0.10s).
--
-- Interning moved that first stage off `entries` but left it a scan of the
-- whole dictionary, which stopped being cheap as the vocabulary grew: 3.15s at
-- 2.99M names. strings_fts makes it a lookup. This index is the second stage
-- either way, and is unaffected by which serves the first.
--
-- The plan did not call for this index; the measurement did. Without it the
-- two-stage query has ids and nothing to seek with, and scans entries anyway --
-- which would have left step 4's claim false while every test still passed.
--
-- Partial on `name_id is not null` because a derivable name is not stored: the
-- index covers exactly the irreducible tail, which is the only thing a name
-- search can match. That is also the criterion's *narrowing* -- a name the
-- columns imply is no longer matchable by substring, and `Item` is the
-- criterion for that question. See lib/corpus/search.mli.
--
-- `unique_mons` trails the index (after `quantity`, last) so the Unique
-- criterion is covering here too, not just on entries_search_unique below.
-- After a fresh `analyze` on the 300k-seed prod corpus, sqlite_stat1 put this
-- index's average rows per (version_id, name_id) at 4 -- true across the
-- 746k-name dictionary, wildly wrong for a unique monster's name, which is a
-- heavy hitter (Sigmund: 98,156 rows). The planner trusted the 4-row estimate
-- and picked this index over entries_search_unique for `unique:Sigmund`,
-- turning what should have been an index-only scan into 98k uncovered table
-- lookups: measured 3.61s, against 0.033s before the stats refresh (300k
-- seeds, 0.34.1, prod, 2026-09-03). Widening the index is a structural fix for
-- a statistical problem: whichever index the planner picks for a Unique
-- search, the test no longer leaves the index.
create index entries_search_name on entries (version_id, name_id, seed, level_id, quantity, unique_mons) where name_id is not null;

create index entries_search_feat on entries (version_id, feat_id, seed, level_id) where feat_id is not null;

-- Shop stock is told from floor loot only by cost being present, so the
-- "in a shop" filter is a partial index rather than a column test.
create index entries_search_shop on entries (version_id, base_type_id, sub_type_id, seed, level_id, quantity) where cost is not null;

-- "which seeds have a distillery by D:4". Mirrors the other search indexes:
-- version-leading, seed-trailing, covering. Partial on the ~2% of rows that
-- are shops, so it costs nothing on the rest.
create index entries_search_shop_type on entries (version_id, shop_type_id, seed, level_id) where shop_type_id is not null;

-- Searching for *any* artefact needs the version-scoped ordering, not a
-- name lookup: without this the search falls back to entries_search_name and
-- sorts the whole version's rows in a temp b-tree.
create index entries_search_artefact on entries (version_id, seed, level_id, name_id) where artefact = 1;

-- A monster criterion looks up uniques by name; ordinary monsters are not
-- catalogued, so the partial index covers the whole searchable set. This is
-- the better plan when the planner can see it -- smaller than
-- entries_search_name and partial on `unique_mons = 1` rather than scanning
-- past it -- but "better" used to also mean "load-bearing": without it, a
-- Unique search fell back to entries_search_name, which did not carry
-- `unique_mons`, so the seek was covering but the predicate test was a table
-- lookup per row. Steering the planner onto this index (an `indexed by`
-- hint) was rejected -- sqlite_stat1 estimates rows per
-- (version_id, name_id) at 4 on average across the 746k-name dictionary, and
-- a unique's name is nowhere near average (Sigmund: 98,156 rows on the
-- 300k-seed prod corpus), so a fresh `analyze` can and did retarget the
-- fallback onto entries_search_name regardless of this index's presence
-- (measured 3.61s, 2026-09-03). entries_search_name now carries `unique_mons`
-- too, so the fallback is covering: whichever index the planner picks for a
-- Unique search, the predicate never leaves the index. This index remains
-- worth keeping for its size and selectivity, not as the only safe choice.
create index entries_search_unique on entries (version_id, name_id, seed, level_id) where unique_mons = 1;

-- Enchantment identity: "any weapon with the distortion brand". Mirrors
-- entries_search_type's shape so the seek stays covering.
create index entries_search_ego on entries (version_id, ego_id, seed, level_id, quantity) where ego_id is not null;

-- The child tables are read two ways: forward, to render one entry's spells or
-- properties on the seed page, and backward, to search for seeds carrying a
-- property. Rendering is a join from entries, so it leads with entry_id;
-- searching leads with version and ends with seed, covering like the others.
create index entry_spells_entry on entry_spells (entry_id);

create index entry_spells_search on entry_spells (version_id, spell_id, seed, level_id);

create index entry_props_entry on entry_props (entry_id);

create index entry_props_search on entry_props (version_id, prop_id, value, seed, level_id);

-- Re-ingest deletes a seed_levels row and cascades. Without an index leading
-- with the referencing columns, SQLite scans the whole child table per deleted
-- level to find the rows to cascade to.
create index entry_spells_level on entry_spells (seed, version_id, level_id);

create index entry_props_level on entry_props (seed, version_id, level_id);

-- Substring search, first stage. `name~` is the only criterion that is not a
-- covering seek: it resolves a fragment to name ids through the `strings`
-- dictionary, and a leading-wildcard `like` there reads all 129 MB of it
-- (measured 3.15s at 1.3M seeds / 2.99M strings, prod, 0.34.1, 2026-09-06 --
-- flat regardless of how selective the fragment is, since the cost is the
-- scan, not the match). Trigram turns that into an index lookup: the same
-- `%Wyrmbane%` is 0.003s against a byte-exact local replica of that dictionary.
--
-- External content, not contentless: `strings` already *is* the content table,
-- so there is no duplicated copy to save -- both forms measured at the same
-- 766,959,616 bytes -- and contentless would break `strings` as a readable
-- table for nothing. Costs +432 MB, ~2.7% of the 15.8 GB prod database.
--
-- The content-column mapping is positional and implicit: fts5 takes its single
-- declared column from the first non-rowid column of `strings`. That is `val`
-- only because `strings` is (id, val); a column inserted before `val` would
-- silently repoint this index at it. There is no explicit-mapping syntax to
-- defend with -- `content='strings(val)'` is not fts5 syntax -- so this comment
-- is the guard.
--
-- Not populated here, and not by a trigger: an external-content fts5 table has
-- no triggers unless written, so a fresh corpus carries an empty index and
-- `name~` is refused until tools/corpus-fts-rebuild runs. See
-- strings_fts_state.
create virtual table strings_fts using fts5(
    val,
    content='strings',
    content_rowid='id',
    tokenize='trigram'
);

-- The index's own high-water mark, written by the rebuild.
--
-- Staleness here is silent and one-directional: a name added to `strings` after
-- the last rebuild is simply absent from the index, so a search for it returns
-- "no such seed" rather than an error. That is the one failure this corpus must
-- not have -- it is indistinguishable from a true negative, which is exactly
-- what seed_fills exists to prevent one layer up.
--
-- It cannot be derived from the fts table. Every obvious probe reads *through*
-- to the content table and reports the content's health, not the index's:
-- against a `strings` holding rows the index has never seen, both
-- `select max(rowid) from strings_fts` and `select count(*) from strings_fts`
-- return the content table's values while an actual search returns nothing
-- (verified, 3.53.2). fts5vocab('row') distinguishes empty from populated but
-- yields a term count, not a row high-water mark, so it cannot say "stale by N".
--
-- So the mark is ours, written explicitly in the same transaction as the
-- rebuild. The read path compares it against `select max(id) from strings` and
-- *refuses* a name search when they disagree, rather than falling back to the
-- dictionary scan this index replaced. The scan is correct, but it reads all
-- 129 MB per request on a public endpoint with no account behind it -- an
-- amplification factor reachable from a query parameter. A refusal costs
-- readers one criterion for as long as a rebuild takes; a fallback costs
-- everyone the box. Both are honest about not knowing the answer, which is the
-- part a stale trigram index otherwise hides.
--
-- The rebuild follows fills, not deploys: this index is derived from `strings`,
-- which only a fill appends to, so shipping code cannot make it stale. Run it
-- after every fill, and once before the index first serves. See AGENTS.md,
-- ops/fill.rb and ops/update.rb.
--
-- This is sound only because `strings` is append-only. Nothing deletes or
-- updates a row here -- dropping seeds leaves its dictionary entries orphaned
-- rather than pruning them -- so a name the index has seen can never change
-- underneath it, and a high-water mark is enough. Pruning the dictionary would
-- break that: a row rewritten below the mark would be stale while the mark
-- still read as current, which is the one direction this cannot fail in.
create table strings_fts_state (
    id integer primary key check (id = 1),
    built_through integer not null
) strict;
