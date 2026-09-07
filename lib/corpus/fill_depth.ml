open! Core

type t = Depth.t [@@deriving compare, equal, sexp_of]

let shallow = Depth.of_level "D:8"

(* A portal ranks at its parent's depth, so it never extends a seed's reach --
   and one without a recorded parent ranks [unknown], which as a maximum would
   make every pre-format-2 seed look infinitely deep. *)
let of_levels levels =
  List.filter levels ~f:(fun level -> not (Depth.is_portal level))
  |> List.map ~f:Depth.of_level
  |> List.filter ~f:(fun d -> not (Depth.equal d Depth.unknown))
  |> List.max_elt ~compare:Depth.compare
  |> Option.value ~default:0
;;

let deep_cap = "Swamp:4"
let is_deep t = Depth.compare t shallow > 0
