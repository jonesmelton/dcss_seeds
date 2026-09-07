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
    has=enter_shop              a feature, by crawl's own name (altars excluded)
    has=artefact                any artefact
    has=unique:Sigmund          a unique monster
    has=name~Throatcutter       a substring of the display name
    v}

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

(** Exposed for testing the affix rules directly. *)
val term_of_string : string -> Seed_corpus.Search.Term.t Or_error.t

(** Empty strings dropped, count capped at [max_terms]: a search with more terms
    than that is a paste, not a query. *)
val max_terms : int

val terms_of_strings : string list -> Seed_corpus.Search.Term.t list Or_error.t
val rank : Dream.request -> Seed_corpus.Search.Rank.t Or_error.t
