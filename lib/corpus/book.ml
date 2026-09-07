open! Core

let parchment_prefix = "parchment of "
let manual_prefix = "manual of "

let spells_of_sub_type sub_type =
  match String.chop_prefix sub_type ~prefix:parchment_prefix with
  | Some spell -> Some [ spell ]
  | None -> None
;;

let spells_are_derivable ~sub_type =
  match sub_type with
  | None -> false
  | Some sub_type -> Option.is_some (spells_of_sub_type sub_type)
;;

(* The randart book carries artefact = 1 under the single sub_type "book of
   Fixed Theme", so the flag alone separates generated books from designed ones.
   Manuals are excluded because they carry no spells to fix. *)
let spells_are_fixed ~sub_type ~artefact =
  match artefact with
  | Some true -> false
  | Some false | None ->
    (match sub_type with
     | None -> false
     | Some sub_type ->
       (not (String.is_prefix sub_type ~prefix:parchment_prefix))
       && not (String.is_prefix sub_type ~prefix:manual_prefix))
;;
