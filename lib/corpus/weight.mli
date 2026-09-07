open! Core

(** Item significance: how much one of a thing changes a run. See
    [docs/heat.md] for the model; edit [table] to change it.

    This module is the whole source of truth -- the table was converted once
    from a TSV no longer carried here, so there is nothing to keep in sync.

    [find] returning [None] means the class carries no weight *by design*
    ([book], [gem], [rune]), which is not the same claim as a weight of 0. *)

module Tier : sig
  (** The value axis a weight is priced against: [Run_defining] (worth playing
      the seed for alone), [Strong] (shifts the early game), [Bulk] (present
      everywhere, no quantity decisive), [Worthless] (zero signal or an active
      trap). The *reason* for a weight, not derived from it.

      Each tier has an anchor band -- [Run_defining] 20..80, [Strong] 10..50,
      [Bulk] 0..8, [Worthless] -5..10 -- which is a sanity check rather than a
      partition; they deliberately overlap.

      The tier accounts for 86% of the resulting ranking and the weight only
      nudges rows within one, so place a new row in the right tier first and
      price it second. *)
  type t =
    | Run_defining
    | Strong
    | Bulk
    | Worthless
  [@@deriving compare, equal, sexp_of]

  val to_string : t -> string
end

type t =
  { tier : Tier.t
  ; weight : int
  }
[@@deriving compare, equal, sexp_of]

(** An exact [(base_type, sub_type)] match wins over the [(base_type, "*")]
    wildcard for that class; there is no third case. [None] is by design for
    [book], [gem] and [rune]; for anything else it means the vocabulary has
    outgrown the table, and the item contributes nothing to heat until a row is
    added. *)
val find : base_type:string -> sub_type:string -> t option

(** Exposed so a test can pin it, catching a row lost or duplicated. *)
val row_count : int

(** Exposed only so a test can assert no key repeats. *)
val keys : (string * string) list
