open! Core

(** A level's contents split by what a reader asks of each part.

    [Level.t] carries one flat entry list because that is the shape storage
    returns. Items are scanned for the one artefact, uniques are a roll-call,
    features are positions to walk to, and a shop is a stock list -- so the
    split is a domain fact rather than a rendering convenience.

    Nothing is dropped: the four parts plus [Shop.stock] account for the whole
    level. *)

module Shop : sig
  (** A shop and its stock.

      Shop stock is flattened into [entries] alongside floor items -- [cost] is
      the only thing telling the two apart -- and carries the shop's own
      coordinates. So a shop is reassembled by position, which is exact rather
      than heuristic: two shops cannot occupy one square.

      [stock] is ordered dearest first. [total] and [artefacts] are what tell a
      twenty-artefact treasury from a shop of four wands; the row count does
      not.

      [shop_type] is crawl's classification and is not recoverable from [name]:
      a vault may call a jewellery shop "Sanarr's Fire Supplies". Absent on a
      corpus filled by an unpatched build, which has no [dgn.shop_type_at]. *)
  type t =
    { name : string
    ; shop_type : string option
    ; x : int option
    ; y : int option
    ; stock : Record.Entry.t list
    ; total : int
    ; artefacts : int
    }
  [@@deriving sexp_of, fields]
end

module Altar : sig
  (** One altar on a floor.

      A Temple's pool gods are a bitmask on [Level.temple_altars] while the four
      gods outside the pool and [altar_ecumenical] keep ordinary [entries] rows.
      Both arrive here as an [Altar.t].

      [in_pool] is false only for a god crawl will not place in a Temple --
      Lugonu, Beogh, Jiyva, Ignis -- which is the distinction worth weighting,
      since every other god is reachable in every seed's Temple. A pool god's
      altar still reaches a dungeon floor as an ordinary row.

      [altar_ecumenical] is outside crawl's pool but [in_pool = true] here: it
      is neither a god nor a rarity, standing on 59% of seeds. Listed as an
      altar, never weighted as a find. *)
  type t =
    { feat : string
    ; god : string
    ; in_pool : bool
    }
  [@@deriving compare, sexp_of, fields]
end

type t =
  { notable : Record.Entry.t list
  ; sundries : Record.Entry.t list
  ; monsters : Record.Entry.t list
  ; altars : Altar.t list
  ; ways_on : Record.Entry.t list
  ; features : Record.Entry.t list
  ; shops : Shop.t list
  }
[@@deriving sexp_of, fields]

(** Split a level's entries.

    [notable] is boons, artefacts, the enchanted, and books carrying a spell
    set their name does not state, in that order; [sundries] is the rest in
    storage order. Both exclude shop stock, which belongs to its [Shop.t].

    The book case is the one that is not a property of the item: a named book
    carries no artefact flag and no enchantment, but nothing in "Fen Folio" says
    what is in it. A parchment is not one of these -- its single spell is its
    name minus the prefix.

    [altars] unifies the Temple mask with the altar rows, gods outside the pool
    first then alphabetically. [ways_on] is the [enter_*] features other than
    shops. [features] is what is left. [monsters] is uniques in practice --
    ordinary monsters are not collected -- but filters on the rows present, not
    on [unique_mons]. *)
val of_level : Level.t -> t

(** An entry's name with the part its tile already says removed: the [sub_type]
    alone ("butterflies", "2 haste").

    Only potions and scrolls, and only when the name matches the one rebuilt
    from [base_type] and [sub_type] exactly -- anything of an unexpected shape
    is returned unchanged, which is what keeps this from eating an unrand's name
    on some future item class.

    Quantity always survives: it is the one part of a consumable's name no other
    column repeats, which is why the seed page has no [qty] column. A display
    trim, not an identity -- search still matches the full name. *)
val display_name : Record.Entry.t -> string

(** A floor's standing facts, as short phrases. Empty when there is nothing to
    say, which is itself the answer.

    Artefacts are reported with how many are for sale: a floor's worth behind a
    shop's prices is a different proposition from the same number on the ground.
    Altars are named on a dungeon floor and merely counted on a Temple, where
    they are the whole floor; a faded altar is never named, being a feature
    rather than a god to join.

    Floor gold is "floor gold", never "gold": it counts the piles on the ground
    and nothing a monster carries or Gozag makes, so it is a lower bound. *)
val standing_facts : t -> Level.t -> string list

module Entrance : sig
  (** A way off this seed's dungeon levels: a branch stair or portal entrance.

      [level] is where the entrance stands, [name] is crawl's description of the
      feature, and [timeout_turns] is a timed portal's generation-time roll.

      [toll_note] is a trove's price as crawl renders it, and is present only on
      [enter_trove]. Nothing else tells one trove from another: two troves on
      one seed are the same feature at different prices.

      [branch] is the entrance feature minus [enter_], capitalised -- derived
      from the feat rather than a table, so a branch this build does not yet
      know about still appears. [feat] is kept because crawl's art is keyed by
      it and the capitalised name cannot be turned back into one. *)
  type t =
    { branch : string
    ; feat : string
    ; level : string
    ; name : string
    ; x : int option
    ; y : int option
    ; timeout_turns : int option
    ; toll_note : string option
    }
  [@@deriving sexp_of, fields]

  (** The branch an [enter_*] feature leads to, capitalised, or [None] for a
      feature that is not an entrance.

      Crawl names most portal entrances for how they look rather than where they
      go -- [enter_ossuary] is "a sand-covered staircase" -- so the destination
      is a fact the name does not carry. *)
  val branch_of_feat : string -> string option
end

(** Every branch and portal entrance across a seed's levels, ordered by how
    early a player reaches the level holding it, then by branch name.

    Shops are excluded: a shop is a room on the level, not a way off it, and at
    two per seed would swamp the four entrances that matter.

    Ordering by [Depth.of_level_with_parent] rather than by level name is what
    makes this read as a route. An entrance standing on a portal level ranks at
    that portal's parent. *)
val entrances : Level.t list -> Entrance.t list

(** A seed's levels in the order a player walks them.

    Storage orders by name, which puts every portal and the Temple after D:8 and
    D:10 before D:2.

    The unit of ordering is a branch, not a floor. The Dungeon is the spine, and
    a branch is emitted at the floor whose stair leads to it -- a player dives
    Lair from D:11 and resumes at D:12. Everything hanging off a branch is a
    detour that gets cleared and left, so a sub-branch waits for its parent's
    whole run: Shoals follows the last floor of Lair rather than splitting it at
    Lair:2. A portal is the opposite case, one excursion off one floor, so it
    stays inline directly after that floor and a portal off a portal follows it
    there.

    A level's parent is [Level.parent_level] where format 2 recorded one, which
    covers portals. A branch level records none, so its parent is recovered from
    the entrance: the level whose entries hold the matching [enter_*] feature,
    derived from the branch name so the branch attaches whole at its first
    floor.

    An unplaceable branch is not moved on a guess -- it sorts among the roots by
    [Depth], and an unplaceable portal, having no depth of its own, goes
    last. *)
val in_reach_order : Level.t list -> Level.t list
