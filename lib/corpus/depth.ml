open! Core

type t = int [@@deriving compare, equal, sexp_of]

let unknown = Int.max_value

(* Crawl's own branch-data.h `mindepth`. Only branches shallow enough to appear
   in an early-game corpus are listed; anything else falls to [unknown]. *)
let branch_entrance =
  String.Map.of_alist_exn
    [ "D", 0
    ; "Temple", 4
    ; "Orc", 9
    ; "Lair", 8
    ; "Vaults", 8
    ; "Depths", 15
    ; "Elf", 11
    ; "Crypt", 10
    ; "Snake", 10
    ; "Spider", 10
    ; "Shoals", 10
    ; "Swamp", 10
    ; "Slime", 12
    ; "Zot", 19
    ]
;;

(* Paired with the entrance feature because crawl abbreviates level names
   ("IceCv") but spells features out ([enter_ice_cave]). One table so the
   set and the mapping cannot drift. *)
let portal_feats =
  String.Map.of_alist_exn
    [ "Sewer", "enter_sewer"
    ; "Ossuary", "enter_ossuary"
    ; "IceCv", "enter_ice_cave"
    ; "Volcano", "enter_volcano"
    ; "Bailey", "enter_bailey"
    ; "Gauntlet", "enter_gauntlet"
    ; "Bazaar", "enter_bazaar"
    ; "WizLab", "enter_wizlab"
    ; "Desolation", "enter_desolation"
    ; "Trove", "enter_trove"
    ]
;;

let portals = Map.key_set portal_feats
let feat_of_portal level = Map.find portal_feats level
let is_portal level = Set.mem portals level

let of_level level =
  if is_portal level
  then unknown
  else (
    match String.lsplit2 level ~on:':' with
    | Some (branch, n) ->
      (match Map.find branch_entrance branch, Int.of_string_opt n with
       | Some entrance, Some n -> entrance + n
       | _ -> unknown)
    | None ->
      (match Map.find branch_entrance level with
       | Some entrance -> entrance
       | None -> unknown))
;;

(* A portal is reached from its parent, so it ranks at the parent's depth: a
   Sewer off D:5 is D:5, not the shallowest depth a Sewer can generate at. *)
let of_level_with_parent ~level ~parent =
  match parent with
  | Some parent when is_portal level -> of_level parent
  | _ -> of_level level
;;
