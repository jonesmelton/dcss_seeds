open! Core

(** The vocabulary a corpus query is phrased in. Pure -- no SQL, no I/O. *)

module Version : sig
  (** The build a seed is meaningful relative to. Required at every call site
      rather than defaulted: the same seed number on 0.33 and 0.35 describes two
      unrelated dungeons. *)
  type t = private string [@@deriving compare, equal, sexp_of]

  val of_string : string -> t Or_error.t

  (** Whether this names a released build rather than a moving tag.

      The corpus ingests releases only. Trunk is a new build most days, so it
      identifies no fixed compile, and the facts stored once per version -- a
      named book's spells, the temple god pool -- would describe whichever build
      was checked out when a seed was filled. *)
  val is_released : t -> bool

  val to_string : t -> string
end

module Page : sig
  (** One slice of a listing, ordered by seed.

      **Seed order is a paging mechanism, not a ranking.** A seed is an opaque
      64-bit key and adjacent seeds describe unrelated dungeons, so no order
      over them means anything to a reader. Paging needs only a *total* order,
      and seed is the one every row already has.

      That order is lexicographic, not numeric: a crawl seed can exceed
      SQLite's signed integer range, so it is stored as text and "1025" sorts
      between "10101" and "10447". Not a defect -- numeric order would cost a
      padded sort key and buy an order implying structure the data lacks.

      There is no "unordered" option: an unspecified order in SQL is arbitrary
      *and unstable*, which lets pages repeat and skip rows.

      Keyset, not offset: [after] is the last seed of the previous slice.
      [offset n] counts and discards [n] rows first, which at a hundred thousand
      seeds is the difference between flat and linear. *)
  type t =
    { after : string option
    ; limit : int
    }
  [@@deriving sexp_of]

  val default_limit : int

  (** Clamps [limit] to [1, max_limit] so a hand-edited query string cannot ask
      for the whole corpus. *)
  val create : ?after:string -> limit:int -> unit -> t

  val first : t
end
