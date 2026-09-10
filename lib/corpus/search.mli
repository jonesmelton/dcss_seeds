open! Core

(** What it means for a seed to *contain* something, and how such questions
    compose. Pure -- no SQL, no I/O. See [Db.search_seeds]. *)

module Item_type : sig
  (** An item identified by its type rather than its name.

      [name] is a display string carrying enchantment, brand and artefact
      epithet, so it has roughly eighteen times the cardinality of the type and
      nearly every artefact name is distinct -- searching it exactly finds one
      seed or none. The type pair is what "a seed with a wand of digging" means.

      [sub_type] is the bare type (["haste"]); [base_type] disambiguates it. *)
  type t =
    { base_type : string
    ; sub_type : string
    }
  [@@deriving compare, equal, sexp_of]

  val to_string : t -> string
end

module Criterion : sig
  (** One atomic containment question. No partial credit, which is what lets
      conjunction be a set intersection rather than a scoring pass.

      [Item], [Shop_item] and [Floor_item] differ only in where the item sits;
      [cost] being present is the only thing telling shop stock from floor loot.
      [Item] is the union and the weaker question. The other two partition it
      totally.

      The partition applies to [min_count], which is the subtlety: an
      unqualified [Item] with [min_count = 3] is satisfied by two potions on the
      floor and a third behind a counter, where [Floor_item] demands three on
      the floor. A floor search is therefore not the shop hits struck off an
      [Item] result -- it can match strictly fewer seeds.

      [Name_like] is the escape hatch for what the type vocabulary cannot name:
      an unrand is identified by a substring of its display name, its
      enchantment prefix varying. Since interning it matches only the
      irreducible tail -- artefacts, unrands, monsters -- and no longer reaches
      a name the columns imply. [Name_like "potion of haste"] finds nothing;
      [Item {base_type = "potion"; sub_type = "haste"}] is that question. *)
  type t =
    | Item of Item_type.t
    | Shop_item of Item_type.t
    | Floor_item of Item_type.t
    | Name_like of string
    | Feature of string
    | Artefact
    | Unique of string
  [@@deriving compare, sexp_of]

  (** A short human-readable rendering, for echoing a query back. *)
  val to_string : t -> string

  (** The noun for counting several matches, where one reads naturally. [None]
      for criteria that name no category -- a name fragment, a unique, an item
      type whose plural depends on the stack name crawl rendered. *)
  val plural_noun : t -> string option

  (** Whether an index can serve this criterion.

      Constantly [true] since names were interned: the substring match that was
      the sole exception now runs over the dictionary, through a trigram index.
      Kept, with {!partition_terms}, because it names a distinction a future
      criterion could reintroduce. *)
  val is_indexed : t -> bool

  (** Whether this criterion is cheap enough to run on the Lwt scheduler thread.

      Every criterion is a single covering-index seek except [Name_like] below
      {!min_name_like_length}, which cannot use the trigram index at all and
      falls back to scanning the whole string dictionary -- seconds at corpus
      scale, on the scheduler thread.

      At or above the threshold [Name_like] is a trigram lookup and usually
      milliseconds, but it stays "not cheap": cost scales with how much of the
      dictionary the fragment matches, so a common one is still far too slow to
      run inline. *)
  val is_cheap : t -> bool

  (** Minimum fragment length accepted for [Name_like]. Enforced at the parse
      boundary in [Params]; this constant is the source of truth. *)
  val min_name_like_length : int
end

module Term : sig
  (** A criterion plus the thresholds that qualify it.

      [min_count] counts *items*, not rows: a stack of three potions is one
      [entries] row with [quantity = 3] and satisfies [min_count = 3]. A row
      with no quantity counts as one.

      A term carries no depth cap -- the corpus's own fill depth bounds every
      result; see {!Fill_depth}. *)
  type t =
    { criterion : Criterion.t
    ; min_count : int
    }
  [@@deriving compare, sexp_of]

  (** Clamps [min_count] to at least 1: a term demanding zero of something is not
      a containment question and would match every seed. *)
  val create : ?min_count:int -> Criterion.t -> t

  val to_string : t -> string

  (** The inverse of the web layer's [has=] syntax, so a term round-trips through
      a link. [to_string] is prose and does not. *)
  val to_query_string : t -> string
end

(** A search: every term must hold, of one build, one page at a time.

    Disjunction is deliberately absent -- "seeds with a shop or Sigmund" is two
    searches, and supporting it inside one query would cost the set-intersection
    shape that makes conjunction an index merge.

    An empty [terms] is a listing, and every seed of the version satisfies
    it. *)
type t =
  { version : Query.Version.t
  ; terms : Term.t list
  ; page : Query.Page.t
  }
[@@deriving sexp_of]

val create
  :  version:Query.Version.t
  -> ?terms:Term.t list
  -> ?page:Query.Page.t
  -> unit
  -> t

val is_empty : t -> bool

(** Terms an index can serve, then terms it cannot. Storage evaluates the
    indexed ones first so the rest run against a narrowed set.

    The second list is currently always empty -- see {!Criterion.is_indexed} --
    so the ordering is a no-op today, kept for the criterion that needs it
    next. *)
val partition_terms : t -> Term.t list * Term.t list

val to_string : t -> string

module Match : sig
  (** One seed that satisfied a search, with the evidence.

      [hits] names, per term, what was found and the shallowest level it sits
      on -- the difference between a Trog altar on D:2 and one on D:8.

      [name] is one exemplar: the shallowest matching item. [count] totals
      quantity across every matching row on the seed, and [distinct] counts how
      many differently-named items that total is spread over. They are only the
      same fact when [distinct = 1]; a term like [Artefact] matches unrelated
      items, so attributing [count] to [name] would claim sixteen of one storm
      bow. *)
  type hit =
    { term : Term.t
    ; level : string
    ; name : string
    ; count : int
    ; distinct : int
    }
  [@@deriving sexp_of]

  type t =
    { seed : string
    ; hits : hit list
    }
  [@@deriving sexp_of]
end

module Rank : sig
  (** How a result set is ordered.

      [Seed] is the corpus's own order and the only one that paginates by
      keyset, so it is the default and stays flat at a hundred thousand seeds.
      [Shallowest] is the question a player actually asks, but must sort the
      whole matched set before paging, so storage caps it. *)
  type t =
    | Seed
    | Shallowest
  [@@deriving compare, equal, sexp_of, enumerate]

  val to_string : t -> string
  val of_string : string -> t option
  val default : t

  (** The largest match set [Shallowest] will sort. Beyond it the caller is told
      to narrow rather than served a slow query. *)
  val sort_limit : int

  (** Whether an error came from exceeding {!sort_limit} -- a bad request the
      reader can act on, not a fault. *)
  val is_too_broad : Error.t -> bool

  val too_broad_tag : string
end

(** Whether an error came from searching a name substring while the trigram
    index is mid-rebuild -- like {!Rank.is_too_broad}, a state the reader can
    act on (by retrying later) rather than a fault.

    [Name_like] is refused outright in that window rather than served from the
    dictionary scan it replaced: the scan is correct but costs seconds of disk
    per request on a public endpoint, so falling back would leave an
    amplification factor reachable from a query parameter. Every other criterion
    is unaffected. *)
val is_index_rebuilding : Error.t -> bool

val stale_index_tag : string

(** [Seed] is already the order storage returns, so this is a no-op for it;
    [Shallowest] compares by earliest hit, breaking ties by seed so the order is
    total and pagination stable. *)
val rank_matches
  :  Match.t list
  -> rank:Rank.t
  -> depth_of_level:(string -> int)
  -> Match.t list
