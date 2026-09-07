open! Core

module Group = struct
  type t =
    { name : string
    ; base_type : string
    ; members : string list
    }
  [@@deriving compare, sexp_of, fields]
end

module Draw = struct
  type t =
    | Unseen
    | Drew of string
    | Conflict of string list
  [@@deriving compare, sexp_of]
end

let groups =
  [ { Group.name = "wand A"; base_type = "wand"; members = [ "charming"; "paralysis" ] }
  ; { Group.name = "wand B"
    ; base_type = "wand"
    ; members = [ "iceblast"; "roots"; "warping" ]
    }
  ; { Group.name = "wand C"
    ; base_type = "wand"
    ; members = [ "acid"; "light"; "quicksilver" ]
    }
  ; { Group.name = "scroll"
    ; base_type = "scroll"
    ; members = [ "butterflies"; "summoning" ]
    }
  ; { Group.name = "evoker A"
    ; base_type = "miscellaneous"
    ; members = [ "condenser vane"; "tin of tremorstones" ]
    }
  ; { Group.name = "evoker B"
    ; base_type = "miscellaneous"
    ; members = [ "Gell's gravitambourine"; "phial of floods" ]
    }
  ; { Group.name = "evoker C"
    ; base_type = "miscellaneous"
    ; members = [ "box of beasts"; "sack of spiders" ]
    }
  ]
;;

(* [base_type] disambiguates the member: a sub_type is a bare word another base
   type may reuse. *)
let member_of (e : Record.Entry.t) =
  match e.base_type, e.sub_type with
  | Some base_type, Some sub_type -> Some (base_type, sub_type)
  | _ -> None
;;

let draws levels =
  let seen =
    List.concat_map levels ~f:(fun (l : Level.t) -> l.entries)
    |> List.filter_map ~f:member_of
    |> Hash_set.of_list
         (module struct
           type t = string * string [@@deriving compare, hash, sexp_of]
         end)
  in
  List.map groups ~f:(fun (g : Group.t) ->
    let drawn =
      List.filter g.members ~f:(fun m -> Hash_set.mem seen (g.base_type, m))
      |> List.sort ~compare:String.compare
    in
    ( g
    , match drawn with
      | [] -> Draw.Unseen
      | [ m ] -> Draw.Drew m
      | conflicting -> Draw.Conflict conflicting ))
;;
