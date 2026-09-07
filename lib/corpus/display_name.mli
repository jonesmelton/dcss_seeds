open! Core

(** Crawl's display string for an entry, rebuilt from the columns the corpus
    stores, so [entries.name] need not be stored where it carries nothing the
    other columns do.

    The standard is close and obvious, not byte-equality. Three divergences are
    deliberate, since no column records them:

    - {b Weapon reskins.} [mace]/[hammer] and [halberd]/[scythe] are per-item
      cosmetic rolls; the canonical base renders.
    - {b Ice cave tier.} [enter_ice_cave] is the only non-shop feature whose
      name is not a function of [feat]; both tiers render as "a frozen archway".
    - {b Shopkeepers.} The keeper is dropped and the shop renders from
      [shop_type].

    Everything else is reproduced byte-for-byte or reported as [Irreducible]. *)

(** [Irreducible] is the answer for artefacts, monsters, and anything whose
    spelling is not a function of the stored columns -- those rows keep a stored
    name. A distinct constructor rather than [None] because "this row needs its
    name" is the fact callers act on. *)
type t =
  | Derived of string
  | Irreducible
[@@deriving compare, equal, sexp_of]

val to_string_opt : t -> string option

(** Pure and total: every input yields an answer, and none raises. *)
val of_entry : Record.Entry.t -> t

val render : Record.Entry.t -> string
