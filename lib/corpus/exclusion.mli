open! Core

(** The mutually exclusive item groups, and which member a seed drew.

    Crawl draws some items once per game from a group whose members exclude one
    another: a seed that can generate a wand of charming cannot generate a wand
    of paralysis anywhere, at any depth. Measured over 100k seeds, no seed holds
    two members of any of the seven groups, and the pick is uniform within a
    group.

    That makes a seed's draw a stable fingerprint of seven independent axes.

    {1 Absence is not exclusion}

    A group is [None] when no member was found in the extracted floors, which is
    the common case -- a seed can simply generate no member this shallow. Only
    co-occurrence is evidence. So [None] means "not seen this deep", never
    "excluded", and the display has to say so.

    Derived from a seed's entries rather than stored: the group identity is
    already recoverable from the [sub_type] those rows carry. *)

module Group : sig
  (** [members] is in crawl's own spelling of [sub_type] -- the bare type
      ("iceblast", not "wand of iceblast"), the same key a search term uses. *)
  type t =
    { name : string
    ; base_type : string
    ; members : string list
    }
  [@@deriving compare, sexp_of, fields]
end

val groups : Group.t list

(** What a seed drew from one group.

    [Conflict] cannot happen if the exclusivity holds, and exists so that it
    fails visibly if it ever stops: returning one arbitrary member of a
    contradicting pair would launder a broken model into a plausible display. *)
module Draw : sig
  type t =
    | Unseen
    | Drew of string
    | Conflict of string list
  [@@deriving compare, sexp_of]
end

(** Every group is present, including ones with no member: dropping the row
    would leave a reader unable to tell an unanswered axis from a forgotten one.

    Shop stock and a unique's inventory both count -- the exclusion is on
    generation, not on reachability. *)
val draws : Level.t list -> (Group.t * Draw.t) list
