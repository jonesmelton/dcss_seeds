open! Core
module Fill_depth = Seed_corpus.Fill_depth

let show levels = print_s [%sexp (Fill_depth.of_levels levels : Fill_depth.t)]

let%expect_test "a shallow fill's depth is its deepest dungeon level" =
  show [ "Temple"; "D:1"; "D:2"; "D:3"; "D:4"; "D:5"; "D:6"; "D:7"; "D:8" ];
  [%expect {| 8 |}];
  print_s [%sexp (Fill_depth.shallow : Fill_depth.t)];
  [%expect {| 8 |}]
;;

(* Swamp:4 is the deep extraction's cap: it reaches through the Lair branch set
   without generating the late game. D:15 is what every deep seed's depth
   actually comes from -- the branch cap ranks 14 and so never sets it -- which
   is why the cohort is homogeneous despite each seed rolling a different two of
   Shoals/Snake/Spider/Swamp. *)
let%expect_test "a deep fill reaches Swamp:4" =
  show [ "Temple"; "D:1"; "Lair:6"; "Swamp:4" ];
  [%expect {| 14 |}];
  (* D:15 is generated too, and is what the recorded depth comes from. *)
  show [ "Temple"; "D:1"; "D:15"; "Lair:6"; "Swamp:4" ];
  [%expect {| 15 |}]
;;

(* A portal ranks at its parent's depth, so it cannot be the deepest thing in a
   seed; one with no recorded parent ranks [unknown], and taking that as the
   maximum would call every pre-format-2 seed infinitely deep. *)
let%expect_test "portals never set the fill depth" =
  (* Temple ranks 4 -- its entrance depth -- so it, not D:2, is the deepest
     thing reached here. *)
  show [ "Temple"; "D:1"; "D:2"; "Sewer" ];
  [%expect {| 4 |}];
  show [ "Temple"; "D:1"; "D:2"; "Bazaar"; "WizLab"; "Desolation" ];
  [%expect {| 4 |}];
  show [ "D:1"; "D:2"; "Sewer"; "Bazaar" ];
  [%expect {| 2 |}]
;;

let%expect_test "an unknown branch does not inflate the depth" =
  show [ "D:1"; "D:2"; "Nemelex:3" ];
  [%expect {| 2 |}];
  show [];
  [%expect {| 0 |}]
;;
