open! Core

module Cat = struct
  type t =
    | Features
    | Items
    | Monsters
    | Vaults
  [@@deriving compare, equal, sexp_of, enumerate]

  let to_string = function
    | Features -> "features"
    | Items -> "items"
    | Monsters -> "monsters"
    | Vaults -> "vaults"
  ;;

  let of_string = function
    | "features" -> Some Features
    | "items" -> Some Items
    | "monsters" -> Some Monsters
    | "vaults" -> Some Vaults
    | _ -> None
  ;;

  (* A stable numbering, not an ordinal: the corpus stores these integers. Vaults
     keeps its number even though ingest prunes the category, since an older
     corpus may hold rows carrying it. *)
  let to_int = function
    | Features -> 0
    | Items -> 1
    | Monsters -> 2
    | Vaults -> 3
  ;;

  let of_int = function
    | 0 -> Some Features
    | 1 -> Some Items
    | 2 -> Some Monsters
    | 3 -> Some Vaults
    | _ -> None
  ;;
end

module Prop = struct
  type t =
    { prop : string
    ; value : int
    }
  [@@deriving compare, sexp_of, fields]

  (* Not crawl's spelling. Crawl picks between a bare name (rElec), a repeated
     sign (rF+) and a signed number (Str+3) using artp_data's value_types, which
     the lua bindings do not expose. [name] already carries crawl's rendering. *)
  let to_string { prop; value } = sprintf "%s%+d" prop value
end

module Entry = struct
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

  (* A monster's coordinate is where it spawned and it wanders as soon as the
     level is entered, so the number is stale before anyone reads it. An item in
     its inventory is recorded on its carrier's square and is stale for the same
     reason. Floor items, altars, stairs and shops do not move. *)
  let position t =
    match t.unique_mons, t.carried_by with
    | Some true, _ | _, Some _ -> None
    | _ ->
      (match t.x, t.y with
       | Some x, Some y -> Some (x, y)
       | _ -> None)
  ;;
end

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
