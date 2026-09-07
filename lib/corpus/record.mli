open! Core

module Cat : sig
  (** A category with no entries is omitted from the record entirely. *)
  type t =
    | Features
    | Items
    | Monsters
    | Vaults
  [@@deriving compare, equal, sexp_of, enumerate]

  val to_string : t -> string
  val of_string : string -> t option

  (** A stable numbering, which is what the corpus stores in [entries.cat].
      Deliberately not derived from constructor order, so reordering the type
      cannot silently reinterpret every row already written. *)
  val to_int : t -> int

  val of_int : int -> t option
end

module Prop : sig
  (** One artefact property: [Str+3] is [{ prop = "Str"; value = 3 }].

      [to_string] is a plain [name±value] form and is *not* crawl's spelling.
      Crawl renders a property three ways depending on a value-type table the
      lua bindings do not expose; [Entry.name] carries its own rendering. *)
  type t =
    { prop : string
    ; value : int
    }
  [@@deriving compare, sexp_of, fields]

  val to_string : t -> string
end

module Entry : sig
  (** A catalog entry, flattened. Fields are category-dependent.

      [carried_by] is [Some monster_name] for an item nested in a monster's
      inventory, which is what makes "something carries Wyrmbane" an indexed
      lookup. Set by [Record.entries], not by the parser -- nothing in the input
      carries it.

      [cost] is present only on shop items, and its presence is how a shop item
      is told from a floor item. [plus] is absent for non-enchantable base
      types.

      [ego] is the enchantment's identity where [branded] is only whether one
      exists, and is the wider of the two: [branded] is weapon/armour-only while
      [ego] also covers jewellery, so a ring of protection carries
      [ego = Some "AC"] with [branded = Some false].

      [timeout_turns] is a timed portal's generation-time roll, so it is
      seed-determined; its absence is how an untimed portal is told from a timed
      one.

      [toll_note] is crawl's own rendered toll on an [enter_trove] feature. The
      structured toll table is not reachable through the lua marker API, so this
      string is the whole of what a trove asks for.

      There is no [ood]. Crawl's out-of-depth flag needs [avg_local_depth >
      you.depth() + 5] and [avg_local_prob < 2] together, which cannot occur in
      the D:1-D:8 range this corpus is filled over: it fired on 0 of 15,336,469
      rows. Measured dead, not merely unused -- do not reintroduce it without
      widening the fill first.

      [props] and [spells] are empty rather than optional: carrying none is the
      common case, not a missing fact.

      There is no [text]. Features carry crawl's [text] and no [name], so the
      parser falls back to it -- after which the two are identical on every row.
      The fallback lives in [Reader]. *)
  type t =
    { cat : Cat.t
    ; name : string
    ; base_type : string option
    ; sub_type : string option
    ; quantity : int option
    ; artefact : bool option
    ; branded : bool option
    ; plus : int option
    ; cost : int option
    ; ego : string option
    ; feat : string option
    ; timeout_turns : int option
    ; shop_type : string option
    ; toll_note : string option
    ; unique_mons : bool option
    ; native : bool option
    ; type_name : string option
    ; x : int option
    ; y : int option
    ; carried_by : string option
    ; spells : string list
    ; props : Prop.t list
    }
  [@@deriving compare, sexp_of, fields]

  (** The entry's coordinate, when it is one worth printing.

      [None] for a monster and anything a monster carries, whatever [x] and [y]
      hold: a monster's position is where it spawned and it moves the moment the
      level is entered, and a carried item is that same stale number one step
      removed. Only what stays put has a position. *)
  val position : t -> (int * int) option
end

(** [items] on a monster entry stay nested in the parse and are flattened by
    [entries].

    [parent_level] is the level whose entrance held this one, present only on
    portals, and is what lets a portal be depth-ranked at all. Format 2 requires
    it on every portal record; format 1 has none, which is why the depth logic
    keeps a parentless fallback.

    [temple_altars] is [Temple.t] as an integer, set only on a Temple level:
    the pool gods whose altars stand there. Those rows are removed from
    [entries] in exchange; gods outside the pool stay as ordinary entries.

    [gold] is the level's summed floor gold, which crawl's own item filter drops
    before anything else sees it. A level fact rather than rows because a pile's
    position and individual size are not facts a reader asks for. It excludes
    monster drops and anything Gozag makes, so whatever surfaces it must say so.
    Absent before format 4. *)
type t =
  { format : int
  ; version : string
  ; seed : string
  ; level : string
  ; parent_level : string option
  ; temple_altars : int option
  ; gold : int option
  ; entries : Entry.t list
  }
[@@deriving compare, sexp_of, fields]
