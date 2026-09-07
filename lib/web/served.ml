open! Core

type t =
  | V0_34_1
  | V0_33_1
  | V0_32_1
[@@deriving compare, equal, sexp_of]

let all = [ V0_34_1; V0_33_1; V0_32_1 ]
let current = V0_34_1

let to_string = function
  | V0_34_1 -> "0.34.1"
  | V0_33_1 -> "0.33.1"
  | V0_32_1 -> "0.32.1"
;;

let of_string s =
  match List.find all ~f:(fun t -> String.equal (to_string t) s) with
  | Some t -> Ok t
  | None -> Or_error.errorf "no such version: %S" s
;;

let to_version t = Or_error.ok_exn (Seed_corpus.Query.Version.of_string (to_string t))
