open! Core

(** How interesting a seed looks at a given depth cap -- a rough exploration
    mark, not a verdict. Pure domain: the surprise curve and the population size
    are supplied by the caller, which is what keeps this free of storage. See
    [docs/heat.md]. *)

module Band : sig
  (** The four-way population split a score is reduced to for display:
      [Cold] (p0-50), [Warm] (p50-80), [Hot] (p80-95), [Blazing] (p95-100).
      Percentile against the eligible population, never an absolute score -- the
      score's scale is arbitrary and shifts with the weight table. *)
  type t =
    | Cold
    | Warm
    | Hot
    | Blazing
  [@@deriving compare, equal, sexp_of]

  val to_string : t -> string

  (** Ordinal encoding for [seed_scores.band]. *)
  val to_int : t -> int

  (** [None] for anything outside 0-3; storage should treat that as a corrupt row
      rather than guess. *)
  val of_int : int -> t option
end

(** One seed's contribution at a single [(base_type, sub_type)]: total quantity
    across the seed (floor and monster-carried only -- shop stock is excluded
    upstream, where [cost] is understood) and the shallowest level holding any
    of it, by reach order. *)
type observation =
  { base_type : string
  ; sub_type : string
  ; count : int
  ; shallowest : Depth.t
  }

(** The reserved pair the book term is looked up under. Storage must key the
    surprise table's book row with this same pair, so neither side hardcodes a
    string the other might drift from. *)
val book_surprise_key : string * string

(** The book term's weight: constant, not looked up in [Weight], because a
    book's value depends on the caster to a degree no weight table resolves.
    20 is the table's anchor for "shifts the early game". *)
val book_weight : int

(** [score ~surprise ~n ~cap ~early_spells observations] is the seed's heat: an
    arbitrary-scale, unbounded-above number comparable only against other seeds
    at the same [(version, cap)].

    [surprise ~base_type ~sub_type ~count] is [P(count' >= count)] over the
    eligible population; [score] applies the [1. /. float n] floor itself, so a
    caller may pass the raw probability. [early_spells] is the seed's count of
    distinct level-<=4 spells across every source -- computing it is storage's
    job.

    An observation whose pair has no [Weight.find] row (book, gem, rune, or an
    unrecognised class) is dropped before scoring: book's value is folded in
    separately through [early_spells], and gem/rune are out of scope. *)
val score
  :  surprise:(base_type:string -> sub_type:string -> count:int -> float)
  -> n:int
  -> cap:Depth.t
  -> early_spells:int
  -> observation list
  -> float
