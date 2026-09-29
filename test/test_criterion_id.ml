open! Core
module Criterion_id = Seed_corpus.Criterion_id
module Search = Seed_corpus.Search

let show criterion =
  match (Criterion_id.of_criterion criterion : Criterion_id.t) with
  | Exact keys -> print_s [%message "Exact" (keys : Criterion_id.key list)]
  | Narrowing keys -> print_s [%message "Narrowing" (keys : Criterion_id.key list)]
  | Unindexed -> print_s [%message "Unindexed"]
;;

let item base_type sub_type = { Search.Item_type.base_type; sub_type }

let%expect_test "Item on the floor is Floor_item" =
  show (Search.Criterion.Item (item "wand" "digging", Floor));
  [%expect {| (Exact (keys (((kind Floor_item) (a (wand)) (b (digging)))))) |}]
;;

let%expect_test "Item in a shop is Shop_item" =
  show (Search.Criterion.Item (item "wand" "digging", Shop));
  [%expect {| (Exact (keys (((kind Shop_item) (a (wand)) (b (digging)))))) |}]
;;

let%expect_test "Artefact has no operands" =
  show Search.Criterion.Artefact;
  [%expect {| (Exact (keys (((kind Artefact) (a ()) (b ()))))) |}]
;;

let%expect_test "Name_like is unindexed" =
  show (Search.Criterion.Name_like ("cer", Floor));
  [%expect {| Unindexed |}];
  show (Search.Criterion.Name_like ("cer", Shop));
  [%expect {| Unindexed |}]
;;

let%expect_test "Feature is unindexed" =
  show (Search.Criterion.Feature "altar_trog");
  [%expect {| Unindexed |}]
;;

let%expect_test "Unique is unindexed" =
  show (Search.Criterion.Unique "Sigmund");
  [%expect {| Unindexed |}]
;;

let%expect_test "a single-property Props with a base type is one Floor_prop key" =
  show
    (Search.Criterion.Props
       { base_type = Some "staff"; props = [ "Conj" ]; position = Floor });
  [%expect {| (Exact (keys (((kind Floor_prop) (a (staff)) (b (Conj)))))) |}]
;;

let%expect_test "the same property with no base type is a different key" =
  show (Search.Criterion.Props { base_type = None; props = [ "Conj" ]; position = Floor });
  [%expect {| (Exact (keys (((kind Floor_prop) (a ()) (b (Conj)))))) |}]
;;

let%expect_test "a single-property Props in a shop is Shop_prop" =
  show
    (Search.Criterion.Props
       { base_type = Some "staff"; props = [ "Conj" ]; position = Shop });
  [%expect {| (Exact (keys (((kind Shop_prop) (a (staff)) (b (Conj)))))) |}]
;;

let%expect_test "a two-property Props narrows, keys in property order" =
  show
    (Search.Criterion.Props
       { base_type = Some "staff"; props = [ "Conj"; "Alch" ]; position = Floor });
  [%expect
    {|
    (Narrowing
     (keys
      (((kind Floor_prop) (a (staff)) (b (Conj)))
       ((kind Floor_prop) (a (staff)) (b (Alch))))))
    |}]
;;

let%expect_test "a three-property Props narrows, keys in property order" =
  show
    (Search.Criterion.Props
       { base_type = None; props = [ "rF"; "rC"; "rN" ]; position = Shop });
  [%expect
    {|
    (Narrowing
     (keys
      (((kind Shop_prop) (a ()) (b (rF))) ((kind Shop_prop) (a ()) (b (rC)))
       ((kind Shop_prop) (a ()) (b (rN)))))) |}]
;;

let%expect_test "an empty-property Props is unindexed" =
  show (Search.Criterion.Props { base_type = Some "staff"; props = []; position = Floor });
  [%expect {| Unindexed |}]
;;

let%expect_test "Kind.to_int and of_int round-trip over Kind.all" =
  List.iter Criterion_id.Kind.all ~f:(fun kind ->
    let round_trip = Criterion_id.Kind.of_int (Criterion_id.Kind.to_int kind) in
    print_s
      [%message "" (kind : Criterion_id.Kind.t) (round_trip : Criterion_id.Kind.t option)]);
  [%expect
    {|
    ((kind Floor_item) (round_trip (Floor_item)))
    ((kind Shop_item) (round_trip (Shop_item)))
    ((kind Artefact) (round_trip (Artefact)))
    ((kind Floor_prop) (round_trip (Floor_prop)))
    ((kind Shop_prop) (round_trip (Shop_prop)))
    |}]
;;

let%expect_test "Kind.of_int is None out of range" =
  print_s [%sexp (Criterion_id.Kind.of_int (-1) : Criterion_id.Kind.t option)];
  [%expect {| () |}];
  print_s [%sexp (Criterion_id.Kind.of_int 5 : Criterion_id.Kind.t option)];
  [%expect {| () |}]
;;
