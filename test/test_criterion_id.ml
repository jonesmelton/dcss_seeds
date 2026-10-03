open! Core
module Criterion_id = Seed_corpus.Criterion_id
module Search = Seed_corpus.Search

let version = Or_error.ok_exn (Seed_corpus.Query.Version.of_string "0.34.1")

let show ?(version = version) criterion =
  match (Criterion_id.of_criterion ~version criterion : Criterion_id.t) with
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
    ((kind Floor_prop) (round_trip (Floor_prop)))
    ((kind Shop_prop) (round_trip (Shop_prop)))
    ((kind Floor_brand) (round_trip (Floor_brand)))
    ((kind Shop_brand) (round_trip (Shop_brand)))
    |}]
;;

(* Kind 2 was [Artefact]. The hole is deliberate: the integer is on-disk format
   and is retired rather than reused by the next kind. *)
let%expect_test "Kind.of_int leaves the removed artefact kind unassigned" =
  print_s [%sexp (Criterion_id.Kind.of_int 2 : Criterion_id.Kind.t option)];
  [%expect {| () |}]
;;

let%expect_test "Kind.of_int is None out of range" =
  print_s [%sexp (Criterion_id.Kind.of_int (-1) : Criterion_id.Kind.t option)];
  [%expect {| () |}];
  print_s [%sexp (Criterion_id.Kind.of_int 7 : Criterion_id.Kind.t option)];
  [%expect {| () |}]
;;

let brand ?(position = Search.Criterion.Floor) base_type sub_type word =
  Search.Criterion.Brand { base_type; sub_type = Some sub_type; word; position }
;;

(* The brand and the item are two keys: intersecting them is a superset, and
   [verify] re-checks that one entry carries both. The item key comes first so
   the shape is stable to read; the merge itself orders by list length. *)
let%expect_test "Brand is Narrowing, with the item key and the build's brand key" =
  show (brand "weapon" "quick blade" "distortion");
  [%expect
    {|
    (Narrowing
     (keys
      (((kind Floor_item) (a (weapon)) (b ("quick blade")))
       ((kind Floor_brand) (a (weapon)) (b (distort))))))
    |}]
;;

let%expect_test "a shop Brand narrows through the shop lists" =
  show (brand ~position:Search.Criterion.Shop "weapon" "quick blade" "distortion");
  [%expect
    {|
    (Narrowing
     (keys
      (((kind Shop_item) (a (weapon)) (b ("quick blade")))
       ((kind Shop_brand) (a (weapon)) (b (distort))))))
    |}]
;;

(* The word is the criterion's, the code is the build's: 0.34.1 capitalised
   eleven armour ego codes, and a key spelled the newer way would find no row
   in a 0.33.1 store and answer "no seeds" over a corpus that holds them. *)
let%expect_test "an armour brand's key is spelled as the build stores it" =
  let older = Or_error.ok_exn (Seed_corpus.Query.Version.of_string "0.33.1") in
  show ~version:older (brand "armour" "robe" "harm");
  [%expect
    {|
    (Narrowing
     (keys
      (((kind Floor_item) (a (armour)) (b (robe)))
       ((kind Floor_brand) (a (armour)) (b (harm))))))
    |}];
  show (brand "armour" "robe" "harm");
  [%expect
    {|
    (Narrowing
     (keys
      (((kind Floor_item) (a (armour)) (b (robe)))
       ((kind Floor_brand) (a (armour)) (b (Harm))))))
    |}]
;;

(* An unknown word is refused at the parse boundary; a directly constructed one
   narrows nothing, because there is no code to key a row by. *)
let%expect_test "a Brand whose word no table knows is unindexed" =
  show (brand "weapon" "quick blade" "no such brand");
  [%expect {| Unindexed |}]
;;

let%expect_test "a Brand with no sub type is exactly its brand list" =
  show
    (Search.Criterion.Brand
       { base_type = "weapon"
       ; sub_type = None
       ; word = "distortion"
       ; position = Search.Criterion.Floor
       });
  [%expect {| (Exact (keys (((kind Floor_brand) (a (weapon)) (b (distort)))))) |}]
;;
