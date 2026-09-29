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

(** Set from SEED_DISABLE_SEARCH in {!Main}. Renders a placeholder instead of
    running any query. Temporary, pending fossil ticket 093f82b4a9. *)
val search_disabled : bool ref

(** Set from SEED_DISABLE_DEEPEN in {!Main}. Withdraws the deepen offer and
    refuses the POST. Required rather than redundant with the fill lock:
    {!Seed_corpus.Deepen.fill_lock_path} derives the lock's path from the
    database path, so a process reading a frozen *copy* of the corpus watches
    a lock file the live fill never touches, sees no lock, and enqueues
    happily. Fossil ticket 0c6422bfc2. *)
val deepen_disabled : bool ref

(** Seconds a search may take before the handler abandons the wait and answers
    503. Set from SEED_SEARCH_TIMEOUT in {!Main}; a test may set it directly.

    Abandoning the wait does not stop the query: there is no [sqlite3_interrupt]
    binding, so the worker runs to completion still holding its connection.
    Generous by design -- it shed pathology, not slow-but-working searches. *)
val search_timeout : float ref

(** {1 Search}

    Terms arrive as repeated [?has=] parameters, each a compact string a reader
    can type and a link can carry:

    {v
    has=potion:haste            an item, by base type and sub type, on the floor
    has=3x potion:haste         at least three of them, all on the floor
    has=shop potion:haste       the same item, for sale
    has=floor potion:haste      accepted; identical to the bare form
    has=artefact                any artefact, floor and shop alike; any case,
                                and "artifact" is the same term
    has=name~Throatcutter       a substring of the display name, on the floor
    has=props:Conj,Alch         one floor artefact carrying every property listed
    has=staff props:Conj,Alch   and that artefact is a staff
    has=shop props:Conj,Alch    the same artefact, for sale
    has=shop staff props:Conj   position leads the base type, not the other way
    v}

    Shop stock is excluded unless a term asks for it, as of 2026-09-15. [Floor]
    and [Shop] partition the union rather than filtering it, so [3x
    potion:haste] wants three on the floor and is not satisfied by two plus one
    behind a counter.

    Four things are deliberately not expressible. The union itself has no
    prefix, so the pre-2026-09-15 reading of a bare term cannot be spelled at
    all. [shop name~] is refused: gold binds the early game, so an unrand you
    can afford in a shop is one you could have afforded off the floor.
    [shop artefact] and [floor artefact] are refused because [artefact] spans
    both and carries no colon for a prefix to lead. And a term takes one
    position, so [shop floor potion:haste] is an error rather than a
    last-one-wins.

    Search covers items only. Features and uniques parsed here until 2026-09-10
    and now report why they do not; see [criterion].

    Properties are comma-separated because ["+Blink"] and ["+Inv"] are property
    names, so a ["+"] separator would spell a set holding one as
    ["Conj++Blink"]. Names are matched case-insensitively against a closed
    vocabulary and an unknown one is rejected: [Dream.queries] decodes a raw
    ["+"] to a space, so ["props:Conj+Alch"] arrives as a single property named
    ["Conj Alch"], and searching it would report that the build holds no such
    artefact rather than that the term was malformed.

    The prefixes disambiguate, since an item is named by a pair and everything
    else by one string. Unparseable terms are a bad request rather than a
    dropped filter: silently ignoring a term would show a result set that does
    not answer the question asked. *)
val term_of_string : string -> Seed_corpus.Search.Term.t Or_error.t

(** Empty strings dropped, count capped at [max_terms]: a search with more terms
    than that is a paste, not a query. *)
val max_terms : int

val terms_of_strings : string list -> Seed_corpus.Search.Term.t list Or_error.t

(** What became of one search box, for the handler to either run or hand back
    with the reader's text intact. *)
module Box : sig
  type offer =
    { prompt : string (** Introduces the terms, as in "Did you mean:". *)
    ; terms : string list (** Whole terms, as they would be typed into the box. *)
    }

  type outcome =
    | Parsed of Seed_corpus.Search.Term.t
    | Resolved of Seed_corpus.Search.Term.t
    (** A bare word naming exactly one thing in the vocabulary. Run, and echoed
        so the reader learns the spelling. *)
    | Rejected of
        { message : string
        ; offer : offer option
        }

  type t =
    { typed : string
    ; outcome : outcome
    }
end

(** {!term_of_string}, except that a bare word -- no colon, no [name~] -- is
    looked up rather than refused. Unprefixed words were a tenth of human search
    terms in September 2026, in three intents: a name fragment ([hat],
    [spectral]), a bare base type ([talisman]), and a misspelled sub type
    ([aquirement]).

    One exact match is {!Box.Resolved}. Several, a near miss, or none are
    {!Box.Rejected} with offers; with none, the offer is [name~<word>]. An exact
    match is a sub type, a base type, crawl's rendering ([potion of haste]), the
    tail after "of" ([flight] for [ring of flight]), or a property.

    [vocabulary] is item pairs as the datalist spells them, [None] when there
    is none to consult; it is forced only for a bare word. With [None] nothing
    resolves, properties included: [fire] is [staff:fire] as well as
    [props:Fire], and a property matched alone could hide the collision. *)
val box : vocabulary:string list option Lazy.t -> string -> Box.t

(** Blank boxes dropped; an error only past {!max_terms}. *)
val boxes : vocabulary:string list option Lazy.t -> string list -> Box.t list Or_error.t

(** [None] if any box was rejected. *)
val terms_of_boxes : Box.t list -> Seed_corpus.Search.Term.t list option

(** Removes the box a remove button names. [drop] is ["<index>:<term>"]: the
    index picks the box, so two boxes holding the same term are distinguishable,
    and the term is checked against what that box actually holds, so a replay
    against a changed list is a no-op rather than taking a bystander. htmx
    pushes the URL that carried the drop, which makes such a replay an ordinary
    reload. Index first because a term may contain a colon. *)
val without_dropped : drop:string option -> string list -> string list

(** The log line for a search whose first page came back empty: the version and
    each term by criterion kind. Reader-supplied text is escaped, so a term
    cannot split or forge a log line. *)
val empty_search_line : Seed_corpus.Search.t -> string

val rank : Dream.request -> Seed_corpus.Search.Rank.t Or_error.t
