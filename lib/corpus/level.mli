open! Core

(** A level as read back out of the corpus, as distinct from [Record.t], which
    is what a [#SEED#] line parses into. A record carries a [format] to check
    and a seed and version on every one, because it arrives alone; a level read
    back has been validated and belongs to a seed the caller already named. *)
type t =
  { level : string
  ; parent_level : string option
  ; temple_altars : int option
  ; gold : int option
  ; entries : Record.Entry.t list
  }
[@@deriving sexp_of, fields]

module Info : sig
  type t =
    { level : string
    ; parent_level : string option
    ; temple_altars : int option
    ; gold : int option
    }
  [@@deriving sexp_of, fields]
end

(** [parent_level] is the dungeon level a portal was entered from, [None] for
    everything else. Format 2 records it at extraction time.

    For levels ingested before that it is derived instead: a portal is stored
    under its own name and the corpus holds its entrance as a feature row, so
    the parent is the level whose entries contain the matching [enter_*]
    feature. That derivation is only as good as the entrance row and the name
    mapping -- [enter_necropolis] already breaks the latter. *)

(** Groups flattened entries by level.

    [infos] is the level list from storage and decides which levels exist. Not
    optional in practice: a level whose contents were entirely encoded away -- a
    Temple holding only pool-god altars -- has no entry rows at all, so deriving
    the list from entries would silently drop it. Omitting [infos] recovers a
    list in first-seen order, correct only where every level has entries.

    Entries come back ordered by category then rendered display name. Imposed
    here rather than by storage, which holds nothing it could order on:
    [entries.cat] is an integer enum and the display name is interned behind an
    insertion-ordered id.

    [gold] is the level's floor gold and a lower bound on what a player can
    spend: it counts the piles on the ground and nothing else, so anything
    displaying it says "floor gold". [None] before format 4. *)
val of_rows : ?infos:Info.t list -> (string * Record.Entry.t) list -> t list

module Summary : sig
  (** One row of a seed listing: enough to render a line without reading the
      seed's entries.

      None of these is a row count. A level count is [9 + portals] at the
      current extraction depth and an entry count is 83% items, so both spend a
      column to say almost nothing.

      [temple] is the dungeon level holding the Temple entrance, [None] when it
      is deeper than the extraction horizon -- every seed has a Temple, so
      [None] means unknown rather than absent.

      [artefacts] counts floor artefacts only. Counting shop stock too ranks
      shops rather than seeds: the corpus's top seed by raw count holds 33, of
      which 32 are priced stock on one level.

      [rare_altars] is the four gods outside crawl's temple pool, as their
      [entries.feat] spellings. [altar_ecumenical] is deliberately absent -- at
      65% of seeds it is not a highlight.

      [portals] pairs a portal's level name with its entrance's dungeon level,
      [None] before format 2.

      [boons] is floor boons (see [Boon]) with quantity. Shop stock excluded.

      [heat] is [None] both for a seed not yet scored at the listing's cap and
      for one ineligible at that cap. Neither is a claim about the seed, so
      neither renders as [Cold]. *)
  type t =
    { seed : string
    ; temple : string option
    ; artefacts : int
    ; rare_altars : string list
    ; portals : (string * string option) list
    ; boons : (Boon.t * int) list
    ; heat : Heat.Band.t option
    }
  [@@deriving sexp_of, fields]
end
