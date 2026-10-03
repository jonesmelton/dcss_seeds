open! Core

(** The SQLite writer for the seed corpus (schema in schema.sql).

    Reads return [Or_error.t]; the write path raises. Ingest is a batch program
    that should die on a broken database, a web handler must not.

    Read accessors are index-backed and safe on the Lwt scheduler thread unless
    their own comment says otherwise. Anything added here that is not
    index-backed is not. *)

type t

(** [readonly] opens with SQLite's [`READONLY] mode; pass it to [close] too, so
    a read-only handle does not attempt [pragma optimize]. *)
val open_ : ?readonly:bool -> string -> t

val close : ?readonly:bool -> t -> unit
val with_db : string -> f:(t -> 'a) -> 'a

(** Raises [Failure] on the first failing statement, carrying the primary code,
    the extended code, sqlite's message, and the statement itself -- enough to
    tell BUSY (5) from BUSY_SNAPSHOT (517), which want different operator
    responses, and to say which statement took the lock. *)
val exec_script : t -> string -> unit

(** Not reentrant. *)
val with_txn : t -> f:(t -> 'a) -> 'a

(** A query's column list: generates the SQL, resolves the reader's offsets, and
    numbers the writer's binds. Exposed only for {!Columns.check_header}'s
    test. *)
module Columns : sig
  type t

  (** Raises on a duplicate name. A qualified reference ([e.level]) is keyed by
      its bare name, which is what the statement's header reports. *)
  val of_list : string list -> t

  (** Raises if the list has no such column, so a rename fails at first use. *)
  val at : t -> string -> int

  (** Verify a prepared statement's own header against the list, so a column
      list edited apart from its SQL errors instead of reading a shifted row. *)
  val check_header : t -> Sqlite3.stmt -> unit Or_error.t
end

(** Columns joined by ['|'], NULLs as the empty string. For inspecting a corpus
    from the outside; anything structured gets a typed accessor. *)
val query : t -> string -> string list

(** One page of the seeds present for [version], ordered by seed.

    Reads [limit + 1] and discards the surplus, which is what distinguishes a
    full last page from a full page with more behind it without a count. *)
val list_seeds
  :  t
  -> version:Query.Version.t
  -> page:Query.Page.t
  -> (Level.Summary.t list * [ `More | `End ]) Or_error.t

(** Up to [limit] seeds drawn at random. [limit] is an upper bound: draws are
    independent, so duplicates are dropped.

    Not uniform -- see the wrap-around bias in the implementation -- so this is
    for browsing, never for a sample that has to be statistically sound. *)
val sample_seeds
  :  t
  -> version:Query.Version.t
  -> limit:int
  -> (Level.Summary.t list * [ `More | `End ]) Or_error.t

(** Summaries for exactly [seeds], in the order given, dropping any the corpus
    does not hold for [version].

    A seed read from outside the corpus -- the feedback file outlives the file a
    flag was made against -- may not be in the build being served, and
    {!sample_seeds}'s summary shape would otherwise render it as an empty row
    linking to a 404. *)
val summarize_seeds
  :  t
  -> version:Query.Version.t
  -> seeds:string list
  -> Level.Summary.t list Or_error.t

(** Every level of one seed on one build, ordered by level, entries ordered by
    category then name. An empty list means the seed is not ingested for that
    version; the corpus does not distinguish that from an ingested seed with no
    entries, because nothing produces the latter. *)
val seed_levels : t -> version:Query.Version.t -> seed:string -> Level.t list Or_error.t

(** Test hook. Runs partway through {!seed_levels}, between the reads that build
    the spell and property tables and the read of the entries they key into.
    Those tables are keyed by [entries.id], which a re-ingest reassigns, so a
    commit landing here without the enclosing transaction yields entries whose
    ids the tables have never seen. Not for production use. *)
val between_reads : (unit -> unit) ref

module Counts : sig
  (** [entries] counts flattened rows, so it exceeds the catalog-record count by
      the number of carried items. *)
  type t =
    { levels : int
    ; entries : int
    ; rejected : int
    }
  [@@deriving sexp_of, fields]

  val zero : t
  val to_string : t -> string
end

(** Write one batch in a single immediate transaction -- the batch reads before
    it writes, and a deferred transaction that loses the upgrade race unwinds
    the tail of a chunk rather than the whole of it.

    Registers each record's [version] first ([seed_levels] has a foreign key to
    [versions]). Re-ingesting a [(seed, version, level)] replaces it: the
    [seed_levels] row is deleted and [entries] cascades.

    [requested] (default false) is a write for a job a reader asked for: a seed
    it adds is outside the random sample ([seed_fills.origin = 'submit']), and a
    seed already present keeps the origin it has. A fill, [requested = false],
    adds sample seeds and takes a submitted seed it reaches into the sample. *)
val write_batch : ?requested:bool -> t -> Record.t list -> Counts.t

(** Lines that fail to parse are counted in [Counts.rejected] and reported to
    [on_reject] rather than aborting -- a crawl crash mid-level truncates a
    line. *)
val ingest_channel
  :  ?requested:bool
  -> t
  -> In_channel.t
  -> batch_size:int
  -> on_reject:(int -> Error.t -> unit)
  -> Counts.t

(** Rebuild the trigram substring index over [strings] and record the
    dictionary id it reached, so {!search_seeds} can tell a current index from a
    stale one.

    Not run by ingest: an external-content fts5 table has no triggers unless
    written, so a filled corpus carries a stale index until this runs, and
    [search_seeds] refuses a [Name_like] search for as long as it does. Run it
    after every fill, and before the corpus serves. *)
val rebuild_fts : t -> unit Or_error.t

(** Whether the substring index covers the whole dictionary. False for a corpus
    predating the index, and for any error: refusing a search that could have
    been served beats serving wrong answers from a partial index. *)
val fts_is_current : t -> bool

(** Index the names interned since the last rebuild or catch-up, and advance the
    mark to match, in one transaction.

    For the deepen generator, which interns names on every seed it deepens and
    would otherwise withdraw [Name_like] search for the whole corpus until
    someone ran {!rebuild_fts} by hand. Proportional to what was added rather
    than to the dictionary, and skips the [analyze] a full rebuild does, so it
    is cheap enough to run per job.

    Not a substitute for {!rebuild_fts} after a fill: correct, but a row at a
    time is the wrong shape for millions of them. *)
val catch_up_fts : t -> unit Or_error.t

(** Whether the search store covers every seed the corpus holds. False for a
    corpus that has never had one built, for one filled since, and for one seeds
    were dropped from; {b true} across a deepen, which changes no seed count and
    is covered by {!Search_index.page}'s overlay instead. A false answer is not
    an error: search falls back to the SQL predicate path.

    For a tool reporting on a store. {!search_seeds} does not call it --
    {!Search_index.page} asks it itself, once its free decline tests have
    passed. *)
val search_index_is_current : t -> version:Query.Version.t -> bool

(** Rebuild the search store for one build; see {!Search_index.build}.

    Here rather than reached through [Search_index] directly because [t] is
    abstract outside this library, and {!Search_index} takes the raw connection
    -- it cannot depend on this module, since [search_seeds] calls into it. *)
val build_search_index : t -> version:Query.Version.t -> unit Or_error.t

(** The item pairs in the store's catalog; see {!Search_index.catalog_item_pairs}. *)
val catalog_item_pairs : t -> version:Query.Version.t -> string list option Or_error.t

(** The deep cohort the store overlays for one build; see
    {!Search_index.cohort}. *)
val search_index_cohort : t -> version:Query.Version.t -> string list option Or_error.t

(** What the store holds for one build. A typed accessor rather than a
    {!query} string, because {!query} has no binds and this is a feature, not
    an inspection. *)
val search_index_stats : t -> version:Query.Version.t -> Search_index.Stats.t Or_error.t

val search_seeds
  :  t
  -> Search.t
  -> rank:Search.Rank.t
  -> (Search.Match.t list * [ `More | `End ]) Or_error.t

(** {!search_seeds} with no fallback: [None] when the store declines, including
    when it is stale. [name_cap] overrides {!Search_index.max_name_seeds}, so a
    fixture can reach the over-cap decline. *)
val search_seeds_store
  :  ?name_cap:int
  -> t
  -> Search.t
  -> rank:Search.Rank.t
  -> (Search.Match.t list * [ `More | `End ]) option Or_error.t

(** {!search_seeds} with the store never consulted: the SQL predicate path, for
    checking the store against it on a corpus where the store is current. *)
val search_seeds_sql
  :  t
  -> Search.t
  -> rank:Search.Rank.t
  -> (Search.Match.t list * [ `More | `End ]) Or_error.t

(** The largest count of [criterion] any one seed of the build holds: the
    number a [Search.Term.min_count] on it can reach and no higher, or [None]
    when no seed holds it at all. Explains an empty search; see
    {!Search.ceiling_term}.

    The same predicate as {!search_seeds} -- [criterion_where], summed per seed
    across levels with a null quantity as one -- because a ceiling over any
    other predicate answers a different question. [None] without a query for a
    criterion {!Search.Criterion.has_count_ceiling} rejects.

    {b Cost.} The store answers when it can ({!Search_index.ceiling}). The SQL
    fallback is the search's own [group by] over the whole matching range, and
    the search stops early only once a page of groups {i passes} its
    [having], so on an empty SQL search it costs about what the search did
    (1.00-1.11x, 10k, 0.34.1, D:8, local, warm, 2026-09-30). The store is not
    an optimisation: a store-answered search walks seeds where this walks
    rows. Never run it speculatively -- a satisfiable count lets the search
    stop at one page, and this never stops early. *)
val count_ceiling
  :  t
  -> version:Query.Version.t
  -> Search.Criterion.t
  -> int option Or_error.t

(** {!count_ceiling} with the store never consulted, for timing the fallback
    on a corpus where the store is current. Ignores
    {!Search.Criterion.has_count_ceiling}. *)
val count_ceiling_sql
  :  t
  -> version:Query.Version.t
  -> Search.Criterion.t
  -> int option Or_error.t

(** {!count_ceiling} from the store alone: [None] when it declines. *)
val count_ceiling_store
  :  t
  -> version:Query.Version.t
  -> Search.Criterion.t
  -> int option option Or_error.t

(** The level names present for a build, in [seed_levels] order. The vocabulary
    depends on the depth the corpus was extracted at. *)
val version_levels : t -> version:Query.Version.t -> string list Or_error.t

(** The search vocabulary as the tokens a term uses -- item type pairs
    ([base:sub]) followed by artefact properties ([props:Conj]), each group
    sorted. Feature names went with the criterion in 2026-09-10: search covers
    items, so suggesting a feature suggested a term that errors. Properties
    {!Search.Prop.searchable} rejects are left out for the same reason.

    A temp b-tree over every entry of the build: seconds, not milliseconds, so
    callers cache per process. The corpus only grows, so a stale value is a
    missing suggestion, never a wrong one. The property half is milliseconds and
    rides along on that cache rather than earning one of its own. *)
val distinct_criteria : t -> version:Query.Version.t -> string list Or_error.t

(** {1 The deepen queue}

    The web process enqueues; the generator claims, runs crawl, and finishes.
    No broker -- the corpus is already the coordination point. See [Job].

    Every write here takes [begin immediate], which matters most for the claim:
    two generators reading the same unclaimed row is the race. *)

(** The job for one seed, if ever requested. Finished and failed jobs are kept,
    so this is also how a page learns a deepen was tried and did not work. *)
val job_for_seed : t -> version:Query.Version.t -> seed:string -> Job.t option Or_error.t

(** Unfinished, unfailed jobs; of one [origin] when given, which is what each
    origin's cap counts. *)
val outstanding_jobs : ?origin:Job.Origin.t -> t -> int Or_error.t

(** How many jobs are ahead of one queued seed, or [None] if it is not waiting.

    Counted by exactly the rule [claim_job] works through -- this version only,
    unclaimed, unfinished, unfailed, deepens before submissions, oldest first -- because a position shown to
    a reader is only honest if it is the one that will be worked through. A
    generator claims per version, so a job on another build is not ahead.

    Order is [(queued_at, seed)]: [queued_at] is whole seconds, so a burst
    collides routinely and needs the total order.

    Index-driven but not covering, so cost grows with rows seeked. Safe on the
    scheduler thread only because the outstanding-jobs cap bounds them; raising
    that cap materially would end that.

    [None] rather than [Some 0] for anything not queued -- zero reads as "next
    up". *)
val queue_position : t -> version:Query.Version.t -> seed:string -> int option Or_error.t

(** Versions some generator has claimed it can build since [since].

    A job for any other version sits unclaimed forever, indistinguishable from a
    queued one, filling the queue against the cap. The web process cannot answer
    this itself: [versions] records what was *ingested*, not what can be
    built. *)
val servable_versions : t -> since:int -> string list Or_error.t

(** The builds this corpus holds any seed for, unordered -- [versions] has no
    comparison order and nothing may acquire one, so the caller imposes the
    order it wants.

    An existence seek per version rather than a count: [seed_fills_cohort]
    leads with [version_id], so the [exists] stops at the first matching row.
    That is what keeps it cheap enough to run on every [/health] request as the
    corpus grows. *)
val populated_versions : t -> string list Or_error.t

(** Request a deep fill of one seed: a deepen of a seed the corpus holds, or a
    reader's submission of one it does not.

    [`Already_queued] returns the existing job, which makes a double submission
    free. [cap] bounds outstanding jobs of [origin] only. [daily = (n, since)]
    refuses with [`Daily_cap] once [n] submissions have been queued at or after
    [since] -- finished ones included, since it bounds how much of the
    generator is given away rather than how much is waiting. Every refusal is
    decided inside the write transaction: reading a cap outside it lets two
    simultaneous requests past a cap of one. *)
val enqueue
  :  ?daily:int * int
  -> t
  -> version:Query.Version.t
  -> seed:string
  -> origin:Job.Origin.t
  -> cap:int
  -> servable_since:int
  -> [ `Queued | `Already_queued of Job.t | `Queue_full | `Daily_cap | `No_generator ]
       Or_error.t

(** Take the next unclaimed job for [version] -- the oldest deepen, else the
    oldest submission -- sweeping abandoned claims
    first.

    A claim unrefreshed within [Job.reclaim_after] is presumed dead and cleared
    for retry. A reclaim costs no attempt; it indicates a worker vanished, not
    failed work.

    [None] also covers another generator winning the race: the claim checks
    [changes()] rather than assuming the update landed. *)
val claim_job : t -> version:Query.Version.t -> now:int -> Job.t option Or_error.t

(** Say the claim taken at [started_at] is still alive, moving it to [now].

    [started_at] is a liveness signal, not a start time, which is what keeps
    [Job.reclaim_after] from being a bet on machine load. Successive refreshes
    chain through their own timestamps.

    [`Lost] means the row no longer names this claim. The worker must kill its
    child and abandon the pass rather than finish work the row says is not its
    own. Worth logging: it means the window is mis-tuned. *)
val refresh_claim
  :  t
  -> version:Query.Version.t
  -> seed:string
  -> started_at:int
  -> now:int
  -> [ `Held | `Lost ] Or_error.t

(** Record the outcome of the claim taken at [started_at].

    [error = None] resets [attempts] to 0, which is what makes
    [Job.max_attempts] a bound on *consecutive* failures.

    Both statements match on [started_at]: without it a worker whose claim was
    reclaimed writes [finished_at] over a job another worker is running. Only
    the bookkeeping is discarded on [`Lost] -- levels the lost worker committed
    are real, and [seed_fills] records them. *)
val finish_job
  :  t
  -> version:Query.Version.t
  -> seed:string
  -> started_at:int
  -> now:int
  -> error:string option
  -> [ `Recorded | `Lost ] Or_error.t

(** Called on startup and on a timer; read back by [servable_versions]. *)
val heartbeat
  :  t
  -> generator_id:string
  -> versions:Query.Version.t list
  -> now:int
  -> unit Or_error.t

(** {1 Heat}

    Heat is a population statistic: the surprise table and the score cut points
    describe a whole [(version, cap)] cohort, not one seed. [recompute_surprise]
    and [rescore] are full scans of [entries] and {b must never run in a Dream
    handler}; they are for [bin/rescore.ml], after a fill. [heat_marks] is the
    only one index-backed enough for a request path.

    Scoring cannot hang off [write_batch] for a second reason: [corpus-fill]
    runs ingests in parallel, and a surprise table computed mid-fill describes a
    partial population -- a wrong statistic, not a weaker one.

    [seed_scores] is keyed [(version_id, seed, cap)] rather than being a column
    on [seed_fills], because a seed filled to [Swamp:4] is a valid member of
    every shallower cohort and must carry a [D:8] score as well as its own. It
    is not a cache: a band is a percentile over the population, so a miss cannot
    be served on demand.

    See [docs/heat.md] and [docs/corpus-scaling.md], "Rescore". *)

(** How many seeds the corpus holds for [version], at any fill depth.

    A covering seek on [seed_fills_cohort], which holds one row per seed --
    counting [seed_levels] or [entries] answers the same question with a scan.

    But a covering seek that {e counts} is linear in what it counts: 43ms at
    1.3M (0.34.1, D:8, 2026-09-05, server), inline and undetached. Hence
    [Seed_web.served_builds] caching it for the life of the process. *)
val seed_count : t -> version:Query.Version.t -> int Or_error.t

(** Every distinct [seed_fills.depth] a version holds, ascending: the caps
    [bin/rescore.ml] scores that version at. Index-backed. *)
val fill_caps : t -> version:Query.Version.t -> int list Or_error.t

(** Delete heat rows for caps [version] no longer holds any seed at.

    [rescore] takes its caps from [fill_caps], so a cap that stops existing is
    never visited and its rows are never collected. That happens when the last
    seed at a depth is deleted -- most often repairing a truncated fill, which
    invents a cap only it occupies. Run before rescoring. *)
val drop_stale_caps : t -> version:Query.Version.t -> unit Or_error.t

(** Recompute and store [surprise] for [(version, cap)]: delete-then-insert, so
    a re-run after a fill is idempotent.

    Ranges over [entries] where [cost is null] -- floor and monster-carried
    items, never shop stock -- over seeds with [seed_fills.depth >= cap],
    counted only over levels within [cap] (the same portal-exclusion discipline
    [search_seeds] uses, so a portal admits by its parent's depth). Quantity is
    summed per [(seed, base_type, sub_type)], a null quantity counting as 1.

    Also stores the book row under [Heat.book_surprise_key]: each seed's count
    of distinct level-<=4 spells across all three sources ([entry_spells],
    [book_spells], parchment [sub_type]), the same reunification [seed_levels]
    does. *)
val recompute_surprise : t -> version:Query.Version.t -> cap:Depth.t -> unit

(** Score every seed eligible for [(version, cap)] into [seed_scores] and
    [heat_bands]: delete-then-insert, idempotent. Requires [recompute_surprise]
    for the same [(version, cap)] first -- it reads [surprise].

    Cut points are percentiles ([Heat.Band]'s p50/p80/p95) stored as each band's
    [min_score]. Ties land in the same band, so counts approximate rather than
    hit the design's targets on a discrete distribution.

    [shards] splits the scoring scan into that many seed ranges, bounding peak
    memory rather than reducing work. It is {b not} an approximation: scores are
    byte-identical at any [shards], since [Heat.score] reads one seed's
    observations plus [surprise] and [n], both fixed before the loop. Anything
    else is a bug. Shard bounds must be data-derived and closed at both ends;
    see [docs/corpus-scaling.md] for why either mistake is fatal. *)
val rescore : ?shards:int -> t -> version:Query.Version.t -> cap:Depth.t -> unit

(** Score one seed at every cap it reaches that a rescore has stored a cohort
    for -- [heat_bands] and its [n] in [heat_cohorts] -- against that stored
    population, and return those caps. For a seed a reader submitted, at job
    finish: it is scored but never counted, so the cohort it is judged against
    must be the one [rescore] measured, not a count taken now.

    One seed's rows and the per-cap [surprise] table: index-backed, but a
    write, so it belongs to the generator and never to a Dream handler. *)
val score_seed : t -> version:Query.Version.t -> seed:string -> int list Or_error.t

(** [seeds]' bands at [(version, cap)] -- a covering seek on [seed_scores]'
    primary key. A seed with no row (unscored, or ineligible at this cap) is
    absent; render that as unscored, never as [Cold]. Absence is a claim about
    the corpus, cold is a claim about the seed. *)
val heat_marks
  :  t
  -> version:Query.Version.t
  -> cap:Depth.t
  -> seeds:string list
  -> Heat.Band.t String.Map.t Or_error.t
