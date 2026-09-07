open! Core
module Heat = Seed_corpus.Heat

let no_signal ~base_type:_ ~sub_type:_ ~count:_ = 1.0
let show score = printf "%.4f\n" score

let%expect_test "a single scorable item is the whole score (book term is zero)" =
  (* potion/haste is weight 30. p = 0.1, n = 1000, d = 1, cap = 8: depth_util(1)
     = 1.0, contrib = 30 * -log10(0.1) = 30.0. The book term gets surprise 1.0,
     so its contrib is 0: score = 30.0*0.6^0 + 0*0.6^1 = 30.0. *)
  let surprise ~base_type ~sub_type ~count:_ =
    match base_type, sub_type with
    | "potion", "haste" -> 0.1
    | _ -> 1.0
  in
  show
    (Heat.score
       ~surprise
       ~n:1000
       ~cap:8
       ~early_spells:0
       [ { base_type = "potion"; sub_type = "haste"; count = 3; shallowest = 1 } ]);
  [%expect {| 30.0000 |}]
;;

let%expect_test "decay ordering: larger contribution first, 0.6^i applied" =
  (* potion/haste (w=30), p=0.1, d=1: contrib 30.0.
     potion/experience (w=60), p=0.5, d=8: du=0.5625, contrib ~= 10.1598.
     Sorted descending, score = 30.0 + 10.1598*0.6 = 36.0959. *)
  let surprise ~base_type ~sub_type ~count:_ =
    match base_type, sub_type with
    | "potion", "haste" -> 0.1
    | "potion", "experience" -> 0.5
    | _ -> 1.0
  in
  show
    (Heat.score
       ~surprise
       ~n:1000
       ~cap:8
       ~early_spells:0
       [ { base_type = "potion"; sub_type = "haste"; count = 3; shallowest = 1 }
       ; { base_type = "potion"; sub_type = "experience"; count = 1; shallowest = 8 }
       ]);
  [%expect {| 36.0959 |}]
;;

let%expect_test "depth_util at d=1 is 1.0, at d=cap is 0.5 + 0.5/cap" =
  (* Same item at the two ends of an 8-cap, the book term held at surprise 1.0 so
     it never outranks it. d=1: du = 1.0, contrib 30.0. d=8: du = 0.5625,
     contrib 16.875. *)
  let surprise ~base_type ~sub_type ~count:_ =
    if String.equal base_type "potion" && String.equal sub_type "haste" then 0.1 else 1.0
  in
  show
    (Heat.score
       ~surprise
       ~n:1000
       ~cap:8
       ~early_spells:0
       [ { base_type = "potion"; sub_type = "haste"; count = 1; shallowest = 1 } ]);
  [%expect {| 30.0000 |}];
  show
    (Heat.score
       ~surprise
       ~n:1000
       ~cap:8
       ~early_spells:0
       [ { base_type = "potion"; sub_type = "haste"; count = 1; shallowest = 8 } ]);
  [%expect {| 16.8750 |}]
;;

let%expect_test "P = 0 is floored at 1/N, not -infinity" =
  (* scroll/"unlisted scroll" has no exact row, so it falls to the scroll/"*"
     wildcard, weight 3. tail = max(0.0, 1/100), contrib = 3 * 2.0 * 1.0 =
     6.0. *)
  let surprise ~base_type ~sub_type ~count:_ =
    if String.equal base_type "scroll" && String.equal sub_type "some unlisted scroll"
    then 0.0
    else 1.0
  in
  show
    (Heat.score
       ~surprise
       ~n:100
       ~cap:8
       ~early_spells:0
       [ { base_type = "scroll"
         ; sub_type = "some unlisted scroll"
         ; count = 1
         ; shallowest = 1
         }
       ]);
  [%expect {| 6.0000 |}]
;;

let%expect_test "the book term contributes through early_spells at the reserved key" =
  (* No item observations. early_spells = 30 under book_surprise_key with
     surprise 0.05: contrib = 20 * -log10(0.05) ~= 26.0206, sole
     contributor. *)
  let base_type, sub_type = Heat.book_surprise_key in
  let surprise ~base_type:b ~sub_type:s ~count:_ =
    if String.equal b base_type && String.equal s sub_type then 0.05 else 1.0
  in
  show (Heat.score ~surprise ~n:1000 ~cap:8 ~early_spells:30 []);
  [%expect {| 26.0206 |}]
;;

let%expect_test "an item with no Weight row (book, gem, rune) contributes nothing" =
  (* base_type "gem" has no Weight.find row, so the observation is dropped before
     scoring; only the zero book term remains. *)
  let surprise ~base_type:_ ~sub_type:_ ~count:_ = 1.0 in
  show
    (Heat.score
       ~surprise
       ~n:1000
       ~cap:8
       ~early_spells:0
       [ { base_type = "gem"; sub_type = "gem of gluttony"; count = 1; shallowest = 1 } ]);
  [%expect {| 0.0000 |}]
;;
