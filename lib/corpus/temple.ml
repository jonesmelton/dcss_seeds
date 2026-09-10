open! Core

type t = int [@@deriving compare, equal, sexp_of]

(* crawl's temple_god_list() is _is_temple_god over every god -- everything
   except Lugonu, Beogh, Jiyva and Ignis (religion.cc) -- sorted by name. Held
   in that order so a mask stays comparable across corpus rebuilds: adding a god
   to the middle renumbers every bit, so a pool change is a format change. *)
let pool =
  [ "altar_ashenzari"
  ; "altar_cheibriados"
  ; "altar_dithmenos"
  ; "altar_elyvilon"
  ; "altar_fedhas"
  ; "altar_gozag"
  ; "altar_hepliaklqana"
  ; "altar_kikubaaqudgha"
  ; "altar_makhleb"
  ; "altar_nemelex_xobeh"
  ; "altar_okawaru"
  ; "altar_qazlal"
  ; "altar_ru"
  ; "altar_sif_muna"
  ; "altar_the_shining_one"
  ; "altar_trog"
  ; "altar_uskayaw"
  ; "altar_vehumet"
  ; "altar_wu_jian"
  ; "altar_xom"
  ; "altar_yredelemnul"
  ; "altar_zin"
  ]
;;

let bit_of_feat =
  List.mapi pool ~f:(fun i feat -> feat, i) |> Map.of_alist_exn (module String)
;;

let of_feat feat = Map.find bit_of_feat feat
let empty = 0

let add t feat =
  match of_feat feat with
  | None -> t
  | Some bit -> t lor (1 lsl bit)
;;

let mem t feat =
  match of_feat feat with
  | None -> false
  | Some bit -> t land (1 lsl bit) <> 0
;;

let to_feats t = List.filteri pool ~f:(fun i _ -> t land (1 lsl i) <> 0)

(* Crawl's internal name for the faded altar is "ecumenical", a word the game
   never shows the player -- it only ever prints "faded altar". *)
let god_name = function
  | "altar_ecumenical" -> "Faded"
  | feat ->
    String.chop_prefix feat ~prefix:"altar_"
    |> Option.value ~default:feat
    |> String.split ~on:'_'
    |> List.map ~f:String.capitalize
    |> String.concat ~sep:" "
;;

let to_int t = t
let of_int t = t
