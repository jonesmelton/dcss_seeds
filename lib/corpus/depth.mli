open! Core

(** How early in a game a level is reached, which is what "shallowest first"
    ranking and heat's depth cap both ask. Pure.

    Deliberately *not* crawl's [explorer.generation_order], which puts Temple
    first because Temple is generated before D:1 -- a player reaches it around
    D:5. Ordering by generation index would report the Temple's altars as the
    shallowest thing in every seed. *)

type t = int [@@deriving compare, equal, sexp_of]

(** The depth of the shallowest D-level from which [level] can be reached.

    Unknown level names sort last rather than raising: the corpus can hold
    levels from a build this table predates, and a search must not fail because
    a new branch appeared. *)
val of_level : string -> t

val unknown : t

(** {1 Portals}

    A portal is placed by .des chance clauses rather than branch data, so its
    own name carries no depth and ranking one means knowing the level its
    entrance sat on. Format 2 records that at extraction time; a portal without
    it stays [unknown] and sorts last. *)
val is_portal : string -> bool

(** The [enter_*] feature for this portal level, or [None]. Not derivable from
    the level name: crawl abbreviates levels ("IceCv") but spells features out
    ([enter_ice_cave]). *)
val feat_of_portal : string -> string option

(** For a portal with a known parent this is the parent's depth; for anything
    else it is [of_level]. *)
val of_level_with_parent : level:string -> parent:string option -> t
