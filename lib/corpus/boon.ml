open! Core

type t =
  | Experience
  | Acquirement
[@@deriving compare, equal, enumerate, sexp_of]

let label = function
  | Experience -> "xp"
  | Acquirement -> "acq"
;;

let name = function
  | Experience -> "potion of experience"
  | Acquirement -> "scroll of acquirement"
;;

let base_type = function
  | Experience -> "potion"
  | Acquirement -> "scroll"
;;

let sub_type = function
  | Experience -> "experience"
  | Acquirement -> "acquirement"
;;

let of_entry (e : Record.Entry.t) =
  match e.cost, e.base_type, e.sub_type with
  | None, Some base, Some sub ->
    List.find all ~f:(fun t ->
      String.equal (base_type t) base && String.equal (sub_type t) sub)
  | _ -> None
;;
