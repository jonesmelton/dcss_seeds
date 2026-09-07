open! Core

type t =
  { level : string
  ; parent_level : string option
  ; temple_altars : int option
  ; gold : int option
  ; entries : Record.Entry.t list
  }
[@@deriving sexp_of, fields]

module Info = struct
  type t =
    { level : string
    ; parent_level : string option
    ; temple_altars : int option
    ; gold : int option
    }
  [@@deriving sexp_of, fields]
end

(* A portal is stored under its own name alone, so the level its entrance sat
   on is recovered from that entrance's feature row. The mapping only runs
   level -> feat; backwards would invent levels the corpus does not hold, since
   `enter_necropolis` appears on ~9k levels while Necropolis is not in
   explorer.portal_order and so is never itself catalogued. *)
let parent_of ~level ~rows =
  match Depth.feat_of_portal level with
  | None -> None
  | Some feat ->
    List.find_map rows ~f:(fun (holder, (entry : Record.Entry.t)) ->
      match entry.feat with
      | Some f when String.equal f feat -> Some holder
      | _ -> None)
;;

(* Storage cannot order a level's entries: [cat] is an integer enum and the
   display name is interned behind an insertion-ordered id, so `order by cat,
   name` in SQL sorts by neither. The reader's order is a domain fact. *)
let sort_entries entries =
  List.sort entries ~compare:(fun (a : Record.Entry.t) (b : Record.Entry.t) ->
    match Record.Cat.compare a.cat b.cat with
    | 0 -> String.compare (Display_name.render a) (Display_name.render b)
    | c -> c)
;;

(* [infos] decides which levels exist: a level whose contents were entirely
   encoded away -- a Temple holding only pool-god altars -- has no entry rows,
   and building the list from [rows] would silently drop it. *)
let of_rows ?infos rows =
  let entries_by_level = Hashtbl.of_alist_multi (module String) rows in
  let of_info (info : Info.t) =
    { level = info.level
    ; parent_level =
        (match info.parent_level with
         | Some _ as parent -> parent
         (* The fallback for levels ingested before format 2 stored a parent. *)
         | None -> parent_of ~level:info.level ~rows)
    ; temple_altars = info.temple_altars
    ; gold = info.gold
    ; entries = Hashtbl.find_multi entries_by_level info.level |> List.rev |> sort_entries
    }
  in
  match infos with
  | Some infos -> List.map infos ~f:of_info
  | None ->
    (* No level list: recover one from the entries, preserving first-seen order.
       Levels with no entries cannot arise in the pure tests that use this. *)
    let order = Hashtbl.create (module String) in
    List.iteri rows ~f:(fun i (level, _) ->
      Hashtbl.update order level ~f:(Option.value ~default:i));
    Hashtbl.to_alist entries_by_level
    |> List.map ~f:(fun (level, _) ->
      of_info { Info.level; parent_level = None; temple_altars = None; gold = None })
    |> List.sort ~compare:(fun a b ->
      Int.compare (Hashtbl.find_exn order a.level) (Hashtbl.find_exn order b.level))
;;

module Summary = struct
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
