open! Core

(** How a {!Search.Criterion.t} maps onto the search store's catalog, and which
    criteria the store can answer without reaching [entries]. Pure.

    The store is an inverted index over a *closed, small* vocabulary -- 1,431
    criteria over 10,000 seeds locally and the same order at 130x that (0.34.1,
    D:8, 2026-10-01; 1,294 before the brand lists, 2026-09-15, and the
    vocabulary gained two shop types between those two corpora, which is the
    whole drift). This module is where "closed" is decided: what
    gets a posting list, what only narrows, and what the store cannot help
    with. *)

module Kind : sig
  (** What a catalog row's two operands mean.

      Floor and shop are separate lists rather than one list and a filter,
      because the two positions partition the entries totally and the union is
      not expressible ({!Search.Criterion}). Deriving one from the other would
      be a merge, and nothing asks for it. *)
  type t =
    | Floor_item (** [a] base type, [b] sub type *)
    | Shop_item (** as [Floor_item] *)
    | Floor_prop
    (** [a] base type or [None] for any, [b] the property. Built by
            correlating at the *entry* level, so the list is exactly "a seed
            holding one item of this base type carrying this property" rather
            than the two facts separately. *)
    | Shop_prop (** as [Floor_prop] *)
    | Floor_brand
    (** [a] base type, [b] the ego code as the build stores it -- the word a
            reader types resolves through {!Search.Brand.code} first, since
            the code's spelling renamed across builds while the word did
            not. List semantics as [Floor_prop]: one item of this base type
            carrying this ego. *)
    | Shop_brand (** as [Floor_brand] *)
  [@@deriving compare, equal, enumerate, sexp_of]

  (** Stored in [search_criteria.kind]. Values are part of the on-disk format
      and never change meaning; a new kind takes the next integer. 2 held the
      removed [Artefact] and is retired, not reused. *)
  val to_int : t -> int

  val of_int : int -> t option
end

(** A catalog row's key, in strings rather than [strings] ids -- the builder
    interns, and nothing above it learns that ids exist. *)
type key =
  { kind : Kind.t
  ; a : string option
  ; b : string option
  }
[@@deriving compare, equal, sexp_of]

include Comparable.S_plain with type t := key

(** What the store can say about one criterion.

    [Exact keys] -- intersecting these lists gives exactly the criterion's
    member set, and their postings carry its depth and count. Everything with a
    single catalog row lands here.

    [Narrowing keys] -- intersecting them gives a *superset*, and the candidates
    must be re-checked against SQL. A multi-property [Props] and a [Brand] are
    the inhabitants, and the reason is not an implementation gap: the
    properties (or the item and its brand) must be carried by *one* item, and
    seed-granular membership cannot say whether two per-property lists agree
    on which item that was. Intersecting [props:Conj] with [props:Alch]
    matches a Conj ring beside an Alch staff -- precisely the leak
    {!Search.Criterion.Props} exists to prevent, and [Brand] has the same
    shape one level down. The store still narrows the corpus to a handful of
    candidates, which is the whole of its value here.

    [Unindexed] -- no catalog row, nothing narrowed. [Name_like] is here
    permanently: artefact names are the one unbounded vocabulary (24,858
    distinct names over 10,000 seeds, 0.34.1, D:8, 2026-09-11, and growing with
    the corpus), so there is no criterion id to give it. It does not become a
    filter over the store's candidates either: a query carrying one is declined
    whole and runs the SQL path, because the store's merge drives on its rarest
    list and a [name~] fragment is usually rarer than anything beside it --
    see {!Search_index.page}. [Feature] and [Unique] are here because the parse
    boundary rejects them, so a list would be built for nobody; a [Props] with
    no properties is here because it degenerates to "an artefact at this
    position", which no catalog row names. A [Brand] with a word no table
    knows is here for the same reason as an unknown property is refused at
    the parse boundary: there is no code to key a row by. *)
type t =
  | Exact of key list
  | Narrowing of key list
  | Unindexed

val of_criterion : version:Query.Version.t -> Search.Criterion.t -> t

(** Every key a build must produce a list for, given the criteria a corpus could
    be asked about. The builder enumerates the corpus instead -- this is the
    other direction, for asserting that the two agree. *)
val keys : t -> key list
