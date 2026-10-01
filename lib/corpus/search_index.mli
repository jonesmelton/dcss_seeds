open! Core

(** The seed-granular search store: one posting list per criterion, keyed by a
    dense seed ordinal, answering "which seeds contain X" without touching
    [entries].

    Search is set membership over a closed vocabulary against a large seed
    count, which is the shape an inverted index exists for and the opposite of
    the shape [entries] has. Everything slow on the SQL path comes from
    recovering one bit of membership per seed by scanning, grouping and
    [distinct]-ing rows: 1,299,999 seeds against 135,537,055 [entries] rows
    (0.34.1, D:8, prod, 2026-09-15).

    Derived and rebuildable wholesale. Nothing above {!Db} learns that ordinals
    exist. See docs/plans/seed-search-index.md. *)

(** What a build landed, for a tool to report. Read back out of the corpus
    rather than returned by {!build}, so it describes the store as stored. *)
module Stats : sig
  type t =
    { seeds : int
    ; criteria : int
    ; blocks : int
    ; postings : int
    ; bytes : int
    }

  val zero : t
end

(** Assign any missing ordinals, then rebuild the catalog and every posting list
    for [version], and move the currency mark.

    One transaction, so a rebuild is never visible half-written and a reader
    pages across it on WAL's old snapshot. The mark is read before the build and
    committed with it, the order {!Db.rebuild_fts} establishes: taken after, a
    row ingested while the build ran would be recorded as covered. *)
val build : Sqlite3.db -> version:Query.Version.t -> unit Or_error.t

(** Whether the store covers every seed the corpus holds.

    Seeds, not rows. A deepen re-ingests one seed's levels and mints ~457 fresh
    [entries] ids doing it (measured: 205 deepened seeds, 93,655 rows, prod,
    2026-09-16), so a high-water mark over [entries.id] reports stale after
    every deepen job -- and at ~20 jobs a day the store would be current only
    between a fill and breakfast. The seed count does not move, and what
    deepening did change is covered by the overlay inside {!page} instead.

    [false] for a corpus never built, for one filled since, and for one seeds
    were dropped from -- the direction the row mark could not see at all, since
    a drop lowers [max(id)] while the mark stands still. [tools/corpus-drop-seeds]
    deletes the state row outright rather than relying on the arithmetic.

    The count is read from [seed_fill_counts], kept by trigger, rather than
    counted: counting [seed_fills] was 88ms at 1,299,999 seeds (0.34.1, prod,
    2026-09-16, warm) and linear in the corpus, against the store's own
    single-digit milliseconds.

    A [false] here is not an error: the SQL predicate path answers the same
    question more slowly.

    A vocabulary change is invisible to this mark, because the mark is a seed
    count. Removing a criterion moves no seed, so a store built before the
    removal still reports current and the rebuild is a hygiene step rather than
    a correctness one: the store looks criteria up by [(kind, a, b)]
    ([search_criteria_key]), so a leftover row for a removed criterion is never
    read, and the only visible cost is a stale catalog count and datalist. The
    same blind spot would be a correctness bug for a change that *renames* a
    criterion rather than removing one. *)
val is_current : Sqlite3.db -> version:Query.Version.t -> bool

(** The largest deep cohort {!page} will re-derive rather than decline over. *)
val max_overlay_cohort : int

(** The seeds {!page} would re-derive from SQL rather than read from postings,
    or [None] past {!max_overlay_cohort}, where {!page} declines outright. *)
val cohort : Sqlite3.db -> version:Query.Version.t -> string list option Or_error.t

(** Every [base:sub] item pair the build holds, floor and shop, for the search
    form's datalist: the catalog's item rows, plus whatever the deep cohort's
    own entries add. [None] when the store is stale or the cohort is past
    {!max_overlay_cohort}. *)
val item_pairs : Sqlite3.db -> version:Query.Version.t -> string list option Or_error.t

(** {!item_pairs} without the deep cohort's additions: the catalog alone, ~850
    rows, so cheap enough to read on the request path. A pair found only below
    D:8 on a deepened seed is missing, which costs a bare word its resolution
    and nothing else. [None] when the store is stale. *)
val catalog_item_pairs
  :  Sqlite3.db
  -> version:Query.Version.t
  -> string list option Or_error.t

(** The most seeds a [name~] fragment may resolve to before {!page} declines.
    97.5% of fragment occurrences in human searches resolve to at most this
    many (315 distinct fragments, access log 2026-09-09 to 2026-09-26, resolved
    against 1.3M, 0.34.1, D:8, prod, 2026-09-26); resolution near it costs
    ~0.5s. *)
val max_name_seeds : int

(** One page of matching seeds, or [None] when the store declines the search.

    The store declines rather than degrades, and the caller runs the SQL path
    instead. It declines when:

    - {!is_current} is [false]. Tested after the catalog-row rule below, which
      costs nothing, and before [name~] resolution, which costs the most.
    - a term other than [name~] has no catalog row. Driving on the store and
      re-checking such a term per candidate batch inverts the selectivity: the
      re-check runs once per batch of the driver's whole list.
    - a [name~] fragment resolves to more than [name_cap] seeds (default
      {!max_name_seeds}). Under the cap the fragment is resolved first -- the
      same two-stage [strings_fts]-then-[like] lookup [criterion_where] builds,
      floor or shop as the criterion says -- into an in-memory posting list per
      seed, with the builder's depth ([Depth.of_level] of the level name) and
      count, and that list joins the merge as an exact term. In real traffic it
      is almost always the rarest term, so it drives. Over the cap the
      resolution alone costs seconds and the search keeps the SQL path, which
      is right for a lone broad fragment and no worse than before for a broad
      one beside other terms.

      A stale [strings_fts] is refused before this is reached ({!Db}'s
      [refuse_stale_trigram]), and a deepened seed matching only on a deep
      level is answered by the overlay below, which evaluates [name~] through
      SQL like any other term.
    - the [Seed] cursor names a seed with no ordinal, which is a corpus
      ingested into since the build. {!is_current} has already ruled that out,
      so it is a belt-and-braces decline rather than a live path.

    {b Order.} [Rank.Seed] pages by ordinal, which is the store's own order and
    not the seed-text order the SQL path returns. Both are "the corpus's own
    order", which the listing caption already declines to promise; the invariant
    that matters is that one served generation pages without repeating or
    skipping, and append-order ordinals give it. Ordinals track ascending seed
    *number*, so this is if anything the less surprising of the two.

    {b Cursors.} Unchanged from the SQL path, and deliberately so: [Rank.Seed]
    still pages by the last seed's own text, which this maps to its ordinal by
    primary key. The web layer mints the cursor from the rendered page and does
    not learn which path served it. [Rank.Shallowest] keeps the integer offset
    into the ranked order.

    A cursor therefore survives the store going stale mid-run with a change of
    *order* rather than a change of kind -- the reader can see a seed twice, or
    not at all, across that one boundary. Both orders are "the corpus's own",
    and this is the whole exposure of not promising one.

    {b [verify] and [verify_depth].} A multi-property [Props] is the only
    criterion that reaches either: the store narrows through each property's
    own posting list, and the candidates are re-checked against SQL in batches
    as they come off the merge, because seed-granular membership cannot say
    whether two per-property lists agree on which item. Both answer which of
    [seeds] satisfy every one of [terms], criterion and [min_count] alike;
    [verify_depth] additionally supplies each survivor's shallowest depth,
    since the min over a narrowing term's own per-property lists is the
    shallowest level any one property appears, not the level the single item
    carrying all of them does.

    The two are separate rather than one depth-carrying callback because their
    callers pay for depth differently. [seed_page] is bounded by page size, so
    [verify]'s cost is proportional to what a page actually needs. [ranked_page]
    walks and verifies the *entire* matched set before any page is cut --
    [Rank.Shallowest] needs every candidate's depth to sort by it, not just one
    page's worth -- so [verify_depth]'s cost there is proportional to the
    matched set, the same O(matched) shape {!page}'s own doc for [Shallowest]
    already carries elsewhere in this codebase, not to the page. A single
    callback that always computed depth would tax [seed_page] with a query it
    throws away.

    [name~] never arrives at either -- it is resolved exactly, above. Both stay
    general because the next criterion the
    store can only narrow should not have to re-derive this.

    {b [cohort_matches].} The deep cohort -- seeds deepened past the depth the
    last build recorded for them -- is subtracted from the posting stream and answered
    from SQL instead, because deepening re-ingests levels no build covers. It
    answers which of [seeds] satisfy every one of [terms] {i and} at what
    shallowest depth. A seed it omits is a seed that does not match.

    The overlay makes the store's silence about a criterion stop meaning
    absence: a deepened level can mint one the build never saw, so a query
    whose terms have no catalog row at all is a page of overlay rather than a
    page of nothing. It is also why subtraction is not a union -- a stale
    posting is a genuine posting, carrying a depth that is merely too deep and
    a count that is merely too low, so a union would double-emit under
    [Rank.Seed] and misrank under [Rank.Shallowest].

    Sound because deepening is a strict prefix extension: {!Fill_depth} records
    that a deep seed's [D:1]-[D:8] rows are byte-identical to a shallow fill of
    the same seed, so re-deriving a cohort member is always at least as correct
    as reading it. Declines outright past {!max_overlay_cohort}; a rebuild
    empties the cohort, so it grows only between builds. *)
val page
  :  ?name_cap:int
  -> Sqlite3.db
  -> Search.t
  -> rank:Search.Rank.t
  -> criterion_where:(Search.Criterion.t -> alias:string -> string * Sqlite3.Data.t list)
  -> verify:(seeds:string list -> terms:Search.Term.t list -> Set.M(String).t Or_error.t)
  -> verify_depth:
       (seeds:string list
        -> terms:Search.Term.t list
        -> (string * Depth.t) list Or_error.t)
  -> cohort_matches:
       (seeds:string list
        -> terms:Search.Term.t list
        -> (string * Depth.t) list Or_error.t)
  -> (string list * [ `More | `End ]) option Or_error.t
