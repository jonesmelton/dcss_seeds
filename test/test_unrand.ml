open! Core
module Unrand = Seed_corpus.Unrand

let%expect_test "an unknown build suggests nothing rather than another build's items" =
  print_s [%sexp (Unrand.names ~version:"0.31.0" : string list option)];
  [%expect {| () |}]
;;

let%expect_test "the roster is version-scoped and really does move" =
  let names version = Option.value_exn (Unrand.names ~version) in
  let older = String.Set.of_list (names "0.32.1") in
  let newer = String.Set.of_list (names "0.34.1") in
  print_s [%sexp (Set.diff newer older |> Set.to_list : string list)];
  [%expect
    {|
    ("crown of vainglory" "fungal fisticloak" "justicar's regalia"
     "skull of Zonguldrok" "sword of the Dread Knight")
    |}];
  print_s [%sexp (Set.diff older newer |> Set.to_list : string list)];
  [%expect {| ("sword of Power" "sword of Zonguldrok" "sword of the Doom Knight") |}]
;;

(* An unrand is reachable only through [name~], so a suggestion has to be the
   affixed form: the bare name parses as an item and fails. *)
let%expect_test "a suggested unrand parses back to the criterion that finds it" =
  let suggestion =
    "name~" ^ List.hd_exn (Option.value_exn (Unrand.names ~version:"0.34.1"))
  in
  print_endline suggestion;
  [%expect {| name~Black Knight's barding |}];
  (match
     Seed_web.Params.term_of_string
       ~version:(Or_error.ok_exn (Seed_corpus.Query.Version.of_string "0.34.1"))
       suggestion
   with
   | Ok term -> print_endline (Seed_corpus.Search.Term.to_query_string term)
   | Error err -> print_endline (Error.to_string_hum err));
  [%expect {| name~Black Knight's barding |}]
;;

let%expect_test "every roster is sorted, unique, and free of the enum's padding" =
  List.iter Unrand.versions ~f:(fun version ->
    let names = Option.value_exn (Unrand.names ~version) in
    let sorted = List.is_sorted names ~compare:String.compare in
    let unique = List.contains_dup names ~compare:String.compare |> not in
    let clean =
      List.for_all names ~f:(fun n ->
        (not (String.is_prefix n ~prefix:"DUMMY")) && not (String.is_empty n))
    in
    printf "%s sorted=%b unique=%b clean=%b\n" version sorted unique clean);
  [%expect
    {|
    0.32.1 sorted=true unique=true clean=true
    0.33.1 sorted=true unique=true clean=true
    0.34.1 sorted=true unique=true clean=true
    |}]
;;
