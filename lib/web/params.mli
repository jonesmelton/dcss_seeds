open! Core

(** Turning query-string text into the corpus query vocabulary. Every failure is
    a bad request, not a server error: the values come from a URL. *)

(** The build named by the [:version] path segment.

    A seed number without a build is not a question, so the version is part of
    the address rather than a parameter on it -- there is no absent case to
    default. An unserved build is an error here, which is what makes it a 404
    instead of a listing that renders empty. *)
val served : Dream.request -> Served.t Or_error.t

val version : Dream.request -> Seed_corpus.Query.Version.t Or_error.t

(** A malformed [limit] is an error rather than a silent fallback, so a broken
    link is visible instead of quietly returning the wrong slice. *)
val page : Dream.request -> Seed_corpus.Query.Page.t Or_error.t

(** {1 Search}

    Terms arrive as repeated [?has=] parameters, each a compact string a reader
    can type and a link can carry:

    {v
    has=potion:haste            an item, by base type and sub type
    has=3x potion:haste         at least three of them
    has=shop potion:haste       in a shop rather than on the floor
    has=floor potion:haste      on the ground rather than for sale
    has=artefact                any artefact
    has=name~Throatcutter       a substring of the display name
    v}

    Search covers items only. Features and uniques parsed here until 2026-09-10
    and now report why they do not; see [criterion].

    The prefixes disambiguate, since an item is named by a pair and everything
    else by one string. Unparseable terms are a bad request rather than a
    dropped filter: silently ignoring a term would show a result set that does
    not answer the question asked. *)
val search
  :  version:Seed_corpus.Query.Version.t
  -> Dream.request
  -> Seed_corpus.Search.t Or_error.t

(** Set from SEED_DISABLE_SEARCH in {!Main}. Renders a placeholder instead of
    running any query. Temporary, pending fossil ticket 093f82b4a9. *)
val search_disabled : bool ref

(** Seconds a search may take before the handler abandons the wait and answers
    503. Set from SEED_SEARCH_TIMEOUT in {!Main}; a test may set it directly.

    Abandoning the wait does not stop the query: there is no [sqlite3_interrupt]
    binding, so the worker runs to completion still holding its connection.
    Generous by design -- it shed pathology, not slow-but-working searches. *)
val search_timeout : float ref

(** Exposed for testing the affix rules directly. *)
val term_of_string : string -> Seed_corpus.Search.Term.t Or_error.t

(** Empty strings dropped, count capped at [max_terms]: a search with more terms
    than that is a paste, not a query. *)
val max_terms : int

val terms_of_strings : string list -> Seed_corpus.Search.Term.t list Or_error.t

(** Removes the box a remove button names. [drop] is ["<index>:<term>"]: the
    index picks the box, so two boxes holding the same term are distinguishable,
    and the term is checked against what that box actually holds, so a replay
    against a changed list is a no-op rather than taking a bystander. htmx
    pushes the URL that carried the drop, which makes such a replay an ordinary
    reload. Index first because a term may contain a colon. *)
val without_dropped : drop:string option -> string list -> string list

val rank : Dream.request -> Seed_corpus.Search.Rank.t Or_error.t
