open! Core
module Weight = Seed_corpus.Weight

let show w =
  print_s
    [%message
      ""
        ~tier:(Option.map w ~f:(fun (x : Weight.t) -> x.tier) : Weight.Tier.t option)
        ~weight:(Option.map w ~f:(fun (x : Weight.t) -> x.weight) : int option)]
;;

let%expect_test "an exact pair wins over the class wildcard" =
  show (Weight.find ~base_type:"potion" ~sub_type:"haste");
  [%expect {| ((tier (Strong)) (weight (30))) |}];
  show (Weight.find ~base_type:"potion" ~sub_type:"some unlisted potion");
  [%expect {| ((tier (Bulk)) (weight (3))) |}]
;;

let%expect_test "book, gem, and rune carry no weight by design" =
  show (Weight.find ~base_type:"book" ~sub_type:"Necromancy");
  [%expect {| ((tier ()) (weight ())) |}];
  show (Weight.find ~base_type:"gem" ~sub_type:"gem of gluttony");
  [%expect {| ((tier ()) (weight ())) |}];
  show (Weight.find ~base_type:"rune" ~sub_type:"barnacled rune");
  [%expect {| ((tier ()) (weight ())) |}]
;;

let%expect_test "a run-defining consumable and a weightless one" =
  show (Weight.find ~base_type:"potion" ~sub_type:"experience");
  [%expect {| ((tier (Run_defining)) (weight (60))) |}];
  show (Weight.find ~base_type:"bauble" ~sub_type:"*");
  [%expect {| ((tier (Worthless)) (weight (0))) |}]
;;

let%expect_test "gold is a real base_type and its weight is 0, not absent" =
  show (Weight.find ~base_type:"\xc2\xa4" ~sub_type:"anything");
  [%expect {| ((tier (Bulk)) (weight (0))) |}]
;;

let%expect_test "an unknown base_type has no fallback at all" =
  show (Weight.find ~base_type:"nonexistent class" ~sub_type:"*");
  [%expect {| ((tier ()) (weight ())) |}]
;;

let%expect_test "the table row count is pinned, and no key repeats" =
  print_s [%message (Weight.row_count : int)];
  [%expect {| (Weight.row_count 186) |}];
  let sorted = List.sort Weight.keys ~compare:[%compare: string * string] in
  let deduped = List.dedup_and_sort sorted ~compare:[%compare: string * string] in
  print_s [%message (List.length sorted : int) (List.length deduped : int)];
  [%expect {| (("List.length sorted" 186) ("List.length deduped" 186)) |}]
;;
