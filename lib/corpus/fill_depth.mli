open! Core

(** How deep a seed was extracted: the difference between "this seed has no
    Wyrmbane" and "this seed was not searched deep enough to know".

    Once a seed can be filled to [Swamp:4] while its neighbours stop at [D:8],
    a population statistic drawn across both measures extraction effort as much
    as dungeon content -- measured, 100% of 200 deep seeds held an artefact
    against 86.7% of 10,000 shallow ones, entirely for that reason.

    Cohorts fix it, and deep generation being a strict prefix extension of
    shallow is what makes one sound: verified row-for-row, a deep seed's
    [D:1]-[D:8] rows are byte-identical to a shallow fill of the same seed. So
    a deep seed is a valid member of the shallow cohort, counted over the levels
    within the cap, rather than something to quarantine out of it. *)

type t = Depth.t [@@deriving compare, equal, sexp_of]

(** The fill depth implied by the levels a seed holds: its deepest level.

    Derived rather than recorded on the wire, which is what makes it
    backfillable -- an existing corpus needs no re-extraction.

    Portals are skipped: a portal ranks at its parent's depth so it can never be
    the deepest thing in a seed, and a parentless one ranks [unknown], which as
    a maximum would make every pre-format-2 seed look infinitely deep. *)
val of_levels : string list -> t

(** The standard shallow extraction ([D:8]), which every seed ingested before
    deep generation was filled to. The backfill value. *)
val shallow : t

(** Whether a seed has been searched past the shallow cap, and so has nothing
    left to ask a generator for.

    Two-valued because extraction has one deep cap and one shallow one. The
    moment a second deep cap exists this stops being a predicate: a fill that
    reached [Swamp:4] covers no Vaults at any depth, so "deeper" is not a
    scalar. *)
val is_deep : t -> bool

(** The deep cap a request asks for, as the depth flag crawl is given. One cap,
    fixed: choosing your own requires knowing branch generation order well
    enough to know that [Depths:4] generates Zot. *)
val deep_cap : string
