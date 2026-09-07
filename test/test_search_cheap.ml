open! Core
module Search = Seed_corpus.Search
module Query = Seed_corpus.Query

let version = Or_error.ok_exn (Query.Version.of_string "0.34.1")
let haste = Search.Criterion.Item { base_type = "potion"; sub_type = "haste" }
let is_cheap terms = Seed_web.search_is_cheap (Search.create ~version ~terms ())

(* [search_is_cheap] gates every detached-vs-inline decision in
   [Seed_web.run_search], so it decides whether a request ever reaches [Pool].
   Every indexed criterion is cheap regardless of shape; [Name_like] below the
   minimum fragment length is the sole exception. [enter_shop] stands in for the
   altar feature this used to test, which search no longer reaches. *)
let%expect_test "Feature is cheap now that altar features are gone from search" =
  printf "%b\n" (is_cheap [ Search.Term.create (Search.Criterion.Feature "enter_shop") ]);
  [%expect {| true |}]
;;

let%expect_test "a bare Item term is cheap" =
  printf "%b\n" (is_cheap [ Search.Term.create haste ]);
  [%expect {| true |}]
;;

let%expect_test "min_count above 1 is cheap now that the driver's group-by streams" =
  printf "%b\n" (is_cheap [ Search.Term.create ~min_count:3 haste ]);
  [%expect {| true |}]
;;

let%expect_test "an empty search (a plain listing) is cheap" =
  printf "%b\n" (is_cheap []);
  [%expect {| true |}]
;;

let%expect_test "Artefact is cheap (was a false-cheap hazard under the old query shape)" =
  printf "%b\n" (is_cheap [ Search.Term.create Search.Criterion.Artefact ]);
  [%expect {| true |}]
;;

let%expect_test "a long Name_like fragment is cheap; a short one is not" =
  printf
    "%b\n"
    (is_cheap [ Search.Term.create (Search.Criterion.Name_like "Throatcutter") ]);
  [%expect {| true |}];
  printf "%b\n" (is_cheap [ Search.Term.create (Search.Criterion.Name_like "ab") ]);
  [%expect {| false |}]
;;
