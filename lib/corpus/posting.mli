open! Core

(** The seed-granular search store's unit and its format. Pure -- no SQLite, no
    corpus.

    A posting says that one seed satisfies one criterion, how shallowly, and how
    many. Membership is presence: there is no separate bitmap, and no
    [group by ... having] over rows to recover a fact that could have been
    stored. See lib/corpus/search_index.mli for what is built out of these. *)

type t =
  { ord : int (** the seed's ordinal; see [seed_ordinals] in schema.sql *)
  ; depth : Depth.t
    (** The shallowest level the criterion is satisfied at, by [Depth.of_level]
          -- parentless, matching [Db.group_term_hits], so a portal is
          [Depth.unknown] and sorts last. This is what makes [Rank.Shallowest]
          answerable without reaching [entries] at all. *)
  ; count : int
    (** [sum(coalesce(quantity, 1))] over the seed's matching entries, which
          is what [Term.min_count] compares against: it counts items, not rows,
          so a stack of three is one row and three items. *)
  }
[@@deriving compare, equal, sexp_of]

(** Postings per block.

    The store is cut into blocks rather than stored as one blob per criterion
    because paging seeks: [search_postings] is keyed [(criterion_id,
    first_ord)], so SQLite's b-tree descends to the block holding a cursor
    instead of the format carrying skip pointers of its own. Small enough that
    a probe decodes little, large enough that the per-row overhead of a
    [without rowid] table is amortised. *)
val block_size : int

(** Encode one block. Deltas are relative to the previous posting, so the input
    must be sorted by [ord], strictly ascending -- raises otherwise, since a
    mis-ordered block decodes to a different set rather than to an error.

    Raises on [count < 1] and on a [depth] that is neither [Depth.unknown] nor
    non-negative, for the same reason: both are unrepresentable rather than
    lossy. *)
val encode_block : t list -> string

val decode_block : string -> t array Or_error.t

(** The posting for [ord] in a decoded block, or [None]. Binary search: the
    caller probes one block per candidate per term, so this is the inner loop of
    every intersection. *)
val find : t array -> ord:int -> t option

(** The first index of [block] whose [ord] is at least [ord], or the block's
    length. For advancing a driver cursor to a page boundary. *)
val lower_bound : t array -> ord:int -> int
