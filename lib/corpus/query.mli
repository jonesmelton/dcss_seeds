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

  (** Release order over the numeric prefix, for questions like "did this
      build have the capitalised armour ego codes" (see {!Search.Brand}).
      [compare] is plain string order, which sorts ["0.10.1"] before
      ["0.9.1"]; this parses the dotted numbers instead. An unreleased build
      (trunk) compares as later than every release, since trunk carries
      changes no release has taken. Equal for two strings that name the same
      release by different spellings of the numeric prefix.

      Generalised by the [Rename] module the renames plan calls for; this is
      its smallest consumer. *)
  val release_compare : t -> t -> int

  val to_string : t -> string
end

(** A seed as the corpus keys it: the decimal text of an unsigned 64-bit
    integer, with no sign, no leading zero, and not [0]. Crawl either rolls a random
    game for [0] or would file one under a label naming none; which was not
    worth finding out. A leading zero would make [007] a second key for [7]. Text rather than an integer because a seed can
    exceed SQLite's signed range. *)
module Seed : sig
  (** The text unchanged, or an error a reader can act on. *)
  val of_string : string -> string Or_error.t
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
