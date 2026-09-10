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

(* One [min_count > 1] term is cheap: [driver_select] renders it as the driver's
   own flat group-by (fixed 2026-09-05). A second one cannot also be the driver,
   so it compiles to the correlated scalar-sum that the 2026-09-09 decorrelation
   left untouched -- the branch it rewrote is [min_count <= 1] only. Measured on
   prod (1.3M, 0.34.1, 2026-09-10, box contended): one such term 0.20s, two of
   them 23.2s, inline on the scheduler thread where the search timeout cannot
   fire. So the count of them, not their presence, is what decides. *)
let%expect_test "one min_count above 1 is cheap; two are not" =
  printf "%b\n" (is_cheap [ Search.Term.create ~min_count:3 haste ]);
  [%expect {| true |}];
  printf
    "%b\n"
    (is_cheap
       [ Search.Term.create ~min_count:3 haste
       ; Search.Term.create ~min_count:3 Search.Criterion.Artefact
       ]);
  [%expect {| false |}];
  (* A [min_count > 1] term beside an ordinary one stays cheap: the counted term
     takes the driver slot and the plain one is an ordinary uncorrelated
     [exists]. *)
  printf
    "%b\n"
    (is_cheap
       [ Search.Term.create ~min_count:3 haste
       ; Search.Term.create Search.Criterion.Artefact
       ]);
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
