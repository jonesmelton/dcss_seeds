-- Corpus of seed catalogs extracted by scripts/seed_dump_sexp.lua. A seed is
-- meaningful only relative to a build, so every row carries version_id, and
-- every repeated string is interned into `strings` and referenced by id.
--
-- Every entries_search_* index answers "which seeds have X". Each leads with
-- version_id, since a seed number without a build is not a question, and ends
-- with seed, which is what a search returns -- so the lookup is a covering
-- seek. Columns trailing `seed` keep it covering under a depth cap or count
-- threshold; uncovered, a common term costs a table lookup per matched row.

pragma journal_mode = wal;

pragma foreign_keys = on;

-- Version strings do not sort (0.33-a0-4444-g172805db8e); first_seen_at orders
-- builds. An ingest batch must insert its version here first or its first
-- seed_levels insert fails the foreign key.
create table versions (
    id integer primary key,
    version text not null unique,
    first_seen_at integer not null default (unixepoch())
) strict;

-- Append-only. Dropping seeds orphans entries rather than pruning them, which
-- is what makes strings_fts_state's high-water mark sound.
--
-- References from entries/seed_levels are deliberately not foreign keys: ingest
-- inserts the string before the row naming it, so the constraint cannot be
-- violated, and enforcing it costs an index probe per row on the hot path.
create table strings (
    id integer primary key,
    val text not null unique
) strict;

-- parent_level_id is the level whose entrance held a portal: a Sewer reached
-- from D:5 is ("Sewer", parent "D:5"). Null for non-portals and for portals
-- ingested before format 2 -- hence Depth's parentless fallback.
--
-- temple_altars is a bitmask over crawl's 22-god temple pool, set only on a
-- Temple level; those gods' altar rows are not in `entries` at all. The
-- vault-placed gods (Lugonu, Beogh, Jiyva, Ignis) and altar_ecumenical are
-- outside the pool and keep ordinary rows. See lib/corpus/temple.mli.
--
-- level_id is a strings id, so it carries no order: ordering a seed's levels is
-- Depth's job.
create table seed_levels (
    seed text not null,
    version_id integer not null,
    level_id integer not null,
    parent_level_id integer,
    temple_altars integer,
    -- Floor piles only -- no monster drops, no Gozag -- so a lower bound, and
    -- labelled "floor gold" wherever it surfaces. Null before format 4.
    gold integer,
    format integer not null,
    ingested_at integer not null default (unixepoch()),
    primary key (seed, version_id, level_id),
    foreign key (version_id) references versions (id)
) strict, without rowid;

-- `id` is a rowid alias so the child tables have something to reference;
-- (seed, version_id, level_id, name_id) is not unique. `cat` is an integer enum
-- (Record.Cat.to_int).
--
-- `name_id` is null exactly where Display_name.of_entry answers `Derived`. It
-- is set only for the irreducible tail -- artefacts, monsters, anything no
-- column determines. A null name_id on a row Display_name calls Irreducible is
-- corruption, and reads as an error rather than a guess.
--
-- `ego` is the enchantment's identity where `branded` is only its existence,
-- and is the wider of the two: `branded` is weapon/armour-only.
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
    -- Canonical type ("General Store"), not the display name a vault may give
    -- a shop. On enter_shop feature rows only, not on each stocked item.
    shop_type_id integer,
    -- The toll as crawl renders it; the structured table is unreachable through
    -- the lua marker API. On enter_trove feature rows only.
    toll_note_id integer,
    foreign key (seed, version_id, level_id) references seed_levels (seed, version_id, level_id) on delete cascade
) strict;

-- Randart book spells and artefact properties. A parchment's spell is derivable
-- from sub_type_id and a named book's set lives in book_spells, so neither is
-- here. The seed_levels foreign key is direct rather than a cascade through
-- entries, so re-ingest needs no extra delete logic.
create table entry_spells (
    entry_id integer not null references entries (id) on delete cascade,
    seed text not null,
    version_id integer not null,
    level_id integer not null,
    spell_id integer not null,
    foreign key (seed, version_id, level_id) references seed_levels (seed, version_id, level_id) on delete cascade
) strict;

-- A named book's contents are compiled into the build, not rolled per seed, so
-- the set is stored once per version; the randart book keeps per-entry rows.
-- Filled by ingest on first sighting; a later sighting that disagrees is
-- rejected, since a released version is one build. See lib/corpus/book.mli.
create table book_spells (
    version_id integer not null,
    sub_type_id integer not null,
    spell_id integer not null,
    primary key (version_id, sub_type_id, spell_id),
    foreign key (version_id) references versions (id)
) strict, without rowid;

-- `value` is crawl's raw integer, not its spelling: rF+ and rF++ are 1 and 2.
-- The rendering table is not exposed to lua, and an artefact's stored name is
-- the only place it survives.
create table entry_props (
    entry_id integer not null references entries (id) on delete cascade,
    seed text not null,
    version_id integer not null,
    level_id integer not null,
    prop_id integer not null,
    value integer not null,
    foreign key (seed, version_id, level_id) references seed_levels (seed, version_id, level_id) on delete cascade
) strict;

-- How surprising a quantity of an item is. A whole-population aggregate, so it
-- is precomputed by bin/rescore.ml after a fill, never per request; without it
-- Heat.score has no source of surprise. Keys are interned ids, since rescore
-- joins them against entries'. Per (version, cap): a score at D:8 is not
-- comparable to one at Swamp:4.
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

-- Keyed (seed, version, cap) rather than carried on seed_fills: a seed filled
-- to Swamp:4 must still hold a D:8 score to stay in the shallow cohort's
-- percentile. Not a cache -- a band is a population percentile, so there is no
-- single-seed recompute to serve a miss. band is stored because deriving it
-- needs heat_bands and it cannot change without a rescore anyway.
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

-- Percentile cut points, stored rather than hardcoded: a weight-table edit
-- moves every score, and an absolute cut would drift out of meaning.
create table heat_bands (
    version_id integer not null,
    cap integer not null,
    band integer not null,
    min_score real not null,
    primary key (version_id, cap, band),
    foreign key (version_id) references versions (id)
) strict, without rowid;

-- The population size `surprise` and `heat_bands` were computed against, so a
-- seed scored alone later (a submitted one) uses the same `n` the cohort did. A
-- count taken at that later moment is a different population.
create table heat_cohorts (
    version_id integer not null,
    cap integer not null,
    seeds integer not null,
    primary key (version_id, cap),
    foreign key (version_id) references versions (id)
) strict, without rowid;

-- A seed is claimed by setting started_at, so an interrupted run leaves a
-- reclaimable row rather than a gap. Claims are taken under `begin immediate`
-- and check changes(), so the loser of a race picks another job. attempts
-- bounds the retry: a timestamp alone cannot stop a seed that reliably crashes
-- crawl from being reclaimed forever.
--
-- version_id is deliberately not an enforced foreign key, and neither is
-- generators': `versions` records what has been ingested, and a build tree
-- routinely exists for a version no seed has been filled for -- which is
-- exactly the first job of a new build.
create table ingest_jobs (
    seed text not null,
    version_id integer not null,
    depth text not null default 'Swamp:4',
    queued_at integer not null default (unixepoch()),
    started_at integer,
    finished_at integer,
    attempts integer not null default 0,
    error text,
    origin text not null default 'deepen' check (origin in ('deepen', 'submit')),
    primary key (seed, version_id)
) strict, without rowid;

-- The day's submissions, for the global daily cap.
create index ingest_jobs_submitted on ingest_jobs (queued_at) where origin = 'submit';

-- Which versions a generator can build. The web process cannot tell on its own:
-- it has no build tree, and `versions` records what was ingested, not what can
-- be built. So the generator declares it here on a timer and the enqueue
-- refuses a version with no recent heartbeat -- otherwise jobs nothing can
-- serve accumulate against the outstanding-jobs cap.
create table generators (
    generator_id text not null,
    version_id integer not null,
    heartbeat_at integer not null default (unixepoch()),
    primary key (generator_id, version_id)
) strict, without rowid;

create index generators_version on generators (version_id, heartbeat_at);

-- Without this, "no Wyrmbane here" and "not searched deep enough to know" are
-- indistinguishable, and a statistic across mixed depths measures extraction
-- effort as much as dungeon content. `depth` is a Depth.t -- reach order, not a
-- level name -- derived from the levels a seed holds rather than carried on the
-- wire, which is what makes it backfillable. See lib/corpus/fill_depth.mli.
--
-- `origin` separates the random sample ('fill') from seeds a reader named
-- ('submit'). A named seed was chosen because something about it caught
-- someone's interest, so it never counts toward a population statistic, the
-- seed count, or a listing; a fill that later reaches it makes it 'fill'.
-- `indexed_at` is set by the search store build that took a submitted seed in;
-- until then both search paths hide it. Null on every 'fill' row.
create table seed_fills (
    seed text not null,
    version_id integer not null,
    depth integer not null,
    filled_at integer not null default (unixepoch()),
    origin text not null default 'fill' check (origin in ('fill', 'submit')),
    indexed_at integer,
    primary key (seed, version_id),
    foreign key (version_id) references versions (id)
) strict, without rowid;

create index seed_fills_cohort on seed_fills (version_id, depth, seed);

create index seed_fills_pending on seed_fills (version_id, seed) where origin = 'submit' and indexed_at is null;

create index seed_fills_indexed on seed_fills (version_id) where origin = 'submit' and indexed_at is not null;

-- The sample's size per version -- seed_fills rows with origin 'fill' -- kept
-- by trigger so the search store's currency check is a primary-key read rather
-- than a covering-index scan (88ms at 1,299,999 seeds, prod, 2026-09-16, on
-- every store-served search). Submitted seeds are left out so a submission does
-- not stale the store for the whole build. A deepen upserts through `on conflict
-- do update`, which fires neither insert nor delete trigger; a fill upgrading a
-- submitted seed fires the update one. An `insert or replace` would count
-- twice, since delete triggers do not fire on a replace; tools/corpus-check
-- compares this with count(*).
create table seed_fill_counts (
    version_id integer primary key,
    seeds integer not null,
    foreign key (version_id) references versions (id)
) strict;

create trigger seed_fills_sample_counted after insert on seed_fills when new.origin = 'fill'
begin
    insert into seed_fill_counts (version_id, seeds)
         values (new.version_id, 1)
    on conflict (version_id) do update set seeds = seeds + 1;
end;

create trigger seed_fills_sample_uncounted after delete on seed_fills when old.origin = 'fill'
begin
    update seed_fill_counts set seeds = seeds - 1 where version_id = old.version_id;
end;

create trigger seed_fills_sample_joined after update of origin on seed_fills when old.origin = 'submit' and new.origin = 'fill'
begin
    insert into seed_fill_counts (version_id, seeds)
         values (new.version_id, 1)
    on conflict (version_id) do update set seeds = seeds + 1;
end;

create index seed_levels_version_seed on seed_levels (version_id, seed);

create index seed_levels_parent on seed_levels (version_id, parent_level_id, seed) where parent_level_id is not null;

-- Non-version-leading entries indexes (name, feat, artefact) were dropped: the
-- entries_search_* indexes are strictly better prefixes for every query the app
-- issues, the planner never chose the others, and they cost 16% of the
-- database. Do not add one back without a query that needs it.
create index entries_seed on entries (seed, version_id, level_id);

create index ingest_jobs_pending on ingest_jobs (version_id, queued_at) where finished_at is null;

-- (base_type_id, sub_type_id) is the searchable vocabulary; name_id is the
-- display string, which embeds enchantment and brand. sub_type is the bare type
-- ("haste"), so base_type disambiguates it -- no two base types share one
-- today, but that is a property of the data, not a guarantee.
--
-- cost trails `seed` for the `Floor` position's `cost is null` test, which every
-- unqualified item term carries since shop stock stopped being a default
-- (2026-09-15). Earlier in the key it would break the sorted-seed order keyset
-- pagination needs for `distinct` to stream and `limit` to terminate early.
create index entries_search_type on entries (version_id, base_type_id, sub_type_id, seed, level_id, quantity, cost) where sub_type_id is not null;

-- Exact-name seek, and the second stage of a substring search (strings_fts
-- resolves the fragment to ids). Partial because a derivable name is not
-- stored, so it covers exactly the irreducible tail -- which is also the
-- criterion's narrowing: a name the columns imply is matched by `Item`, not by
-- substring. See lib/corpus/search.mli.
--
-- `unique_mons` trails the key so a Unique search stays covering here too: an
-- `analyze` can retarget one off entries_search_unique onto this index at any
-- time, since sqlite_stat1 averages 4 rows per (version_id, name_id) and a
-- unique's name is nowhere near average (Sigmund: ~98k rows).
create index entries_search_name on entries (version_id, name_id, seed, level_id, quantity, unique_mons) where name_id is not null;

create index entries_search_feat on entries (version_id, feat_id, seed, level_id) where feat_id is not null;

-- Shop stock is told from floor loot only by cost being present, so "in a shop"
-- is a partial index rather than a column test.
create index entries_search_shop on entries (version_id, base_type_id, sub_type_id, seed, level_id, quantity) where cost is not null;

create index entries_search_shop_type on entries (version_id, shop_type_id, seed, level_id) where shop_type_id is not null;

-- Searching for *any* artefact needs the version-scoped ordering, not a name
-- lookup: without this the search sorts the version's rows in a temp b-tree.
create index entries_search_artefact on entries (version_id, seed, level_id, name_id) where artefact = 1;

-- Ordinary monsters are not catalogued, so this covers the whole searchable
-- set. Kept for size and selectivity, not as the only safe choice -- see
-- entries_search_name for why the fallback must stay covering.
create index entries_search_unique on entries (version_id, name_id, seed, level_id) where unique_mons = 1;

create index entries_search_ego on entries (version_id, ego_id, seed, level_id, quantity) where ego_id is not null;

-- The child tables are read forward (render one entry's spells or props: lead
-- with entry_id) and backward (search seeds carrying one: version-leading,
-- seed-trailing).
create index entry_spells_entry on entry_spells (entry_id);

create index entry_spells_search on entry_spells (version_id, spell_id, seed, level_id);

create index entry_props_entry on entry_props (entry_id);

create index entry_props_search on entry_props (version_id, prop_id, value, seed, level_id);

-- Re-ingest deletes a seed_levels row and cascades; without these SQLite scans
-- the whole child table per deleted level.
create index entry_spells_level on entry_spells (seed, version_id, level_id);

create index entry_props_level on entry_props (seed, version_id, level_id);

-- Turns a leading-wildcard `like` over the dictionary into an index lookup.
--
-- The content-column mapping is positional and implicit: fts5 takes its single
-- column from the first non-rowid column of `strings`. That is `val` only
-- because `strings` is (id, val); a column inserted before `val` would silently
-- repoint this index at it. `content='strings(val)'` is not fts5 syntax, so
-- this comment is the guard.
--
-- Not populated here, and not by a trigger: an external-content fts5 table has
-- none unless written, so a fresh corpus carries an empty index and `name~` is
-- refused until tools/corpus-fts-rebuild runs.
create virtual table strings_fts using fts5(
    val,
    content='strings',
    content_rowid='id',
    tokenize='trigram'
);

-- The index's high-water mark, written by the rebuild in its transaction. It
-- cannot be derived from the fts table: every probe reads through to the
-- content table and reports the content's health, not the index's.
--
-- Staleness is silent -- a name added since the rebuild is absent, so a search
-- returns "no such seed" rather than an error. The read path compares this
-- against `max(id) from strings` and refuses a name search when they disagree
-- rather than falling back to the dictionary scan, which reads 129 MB per
-- request on a public endpoint from a query parameter.
--
-- Sound only because `strings` is append-only: a row rewritten below the mark
-- would be stale while the mark still read as current.
create table strings_fts_state (
    id integer primary key check (id = 1),
    built_through integer not null
) strict;

-- The seed-granular search store. Derived from `entries` and rebuildable
-- wholesale, like strings_fts -- but unlike it, a stale store is not refused:
-- search falls back to the SQL predicate path, which is the same semantics
-- implemented twice rather than a dictionary scan. See
-- docs/plans/seed-search-index.md and lib/corpus/search_index.mli.

-- A seed's position in the store's own order, which is what lets a posting be a
-- small integer. Assigned by the index builder, never by ingest: a build
-- appends `max(ord) + 1` over the seeds that lack one, in (length(seed), seed)
-- order, so an ordinal once assigned never moves and a rebuild reproduces the
-- assignment rather than guessing at it. Ingest is parallel, so insert order is
-- timing-dependent and could not have been that rule.
--
-- (length(seed), seed) is numeric order for the decimal strings crawl emits, so
-- append order tracks ascending seed number -- which is what makes an ascending
-- fill an append rather than an insertion into the middle.
--
-- `built_depth` is the seed's `seed_fills.depth` as of the last build, so the
-- overlay re-derives only seeds deepened past what their postings cover. Null
-- on a store built before the column existed, which reads as deepened.
create table seed_ordinals (
    version_id integer not null,
    seed text not null,
    ord integer not null,
    built_depth integer,
    primary key (version_id, seed),
    foreign key (version_id) references versions (id)
) strict, without rowid;

-- Not declared unique, though it is: `tools/corpus-reindex` replays schema.sql
-- by grepping `create index`, and a `create unique index` would be invisible to
-- the one tool whose job is adding what a corpus is missing. Uniqueness comes
-- from the assignment rule (append max(ord) + 1) rather than from a constraint,
-- and SQLite's unique indexes treat NULLs as distinct anyway, which makes the
-- same declaration on search_criteria half a guarantee.
create index seed_ordinals_ord on seed_ordinals (version_id, ord);

-- The criterion catalog: the closed vocabulary search is over -- 1,294 rows for
-- 0.34.1 (10,000 seeds, D:8, local, 2026-09-15), and the same order at 130x the
-- seeds, which is what makes the id space safe to bake into the format. `kind` is Criterion_id.Kind.to_int and decides what a_id and b_id
-- mean; both are `strings` ids. `card` is the list's total postings, which is
-- what picks the driver -- postings merge shortest-list-first, so selectivity
-- is read here rather than guessed at by a static rank table.
create table search_criteria (
    id integer primary key,
    version_id integer not null,
    kind integer not null,
    a_id integer,
    b_id integer,
    card integer not null,
    foreign key (version_id) references versions (id)
) strict;

create index search_criteria_key on search_criteria (version_id, kind, a_id, b_id);

-- One criterion's postings, cut into blocks of Posting.block_size and sorted by
-- ordinal. `first_ord` leads the key after criterion_id, so seeking a paging
-- cursor is a b-tree descent: SQLite's index is the skip list the format does
-- not have to carry. `postings` is Posting.encode_block output; `n` is its
-- length, kept for the round-trip check against search_criteria.card.
create table search_postings (
    criterion_id integer not null,
    first_ord integer not null,
    n integer not null,
    postings blob not null,
    primary key (criterion_id, first_ord)
) strict, without rowid;

-- The store's currency marks, read before the build and written inside its
-- transaction -- the order strings_fts_state establishes, and for the same
-- reason: a mark taken after the build records seeds ingested during it as
-- covered.
--
-- `built_seeds` is the currency mark and `built_through` is diagnostic only.
-- Counting seeds rather than rows is what makes deepening survivable: a deepen
-- re-ingests one seed's levels, minting ~457 fresh `entries` ids and moving
-- `max(id)`, while the seed count stands still -- so a row mark reports stale
-- after every job and a seed mark reports stale only after a fill. The seeds
-- deepening did change are covered by the overlay in `Search_index.page`, not
-- by this mark. The count also moves *down* when seeds are dropped, which the
-- high-water mark could not see at all: `max(id)` falls while the mark stands,
-- reporting current over postings for seeds that no longer exist.
--
-- The default of -1 is what an `alter table` on a corpus built by an older
-- writer lands (`tools/corpus-reindex`): no seed count is -1, so such a store
-- reads as stale until it is rebuilt.
create table search_index_state (
    version_id integer primary key,
    built_through integer not null,
    built_seeds integer not null default -1,
    built_at integer not null default (unixepoch())
) strict, without rowid;
