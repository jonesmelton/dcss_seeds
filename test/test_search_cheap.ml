open! Core
module Search = Seed_corpus.Search
module Query = Seed_corpus.Query

let version = Or_error.ok_exn (Query.Version.of_string "0.34.1")
let haste_type = { Search.Item_type.base_type = "potion"; sub_type = "haste" }
let haste = Search.Criterion.Item (haste_type, Search.Criterion.Floor)
let is_cheap terms = Seed_web.search_is_cheap (Search.create ~version ~terms ())

(* [search_is_cheap] gates every detached-vs-inline decision in
   [Seed_web.run_search], so it decides whether a request ever reaches [Pool].
   Most indexed criteria are cheap regardless of shape; the exceptions are
   [Name_like] below the minimum fragment length and [Props] without a base
   type. [enter_shop] stands in for the altar feature this used to test, which
   search no longer reaches. *)
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

(* No [Name_like] is cheap, at any fragment length. The store declines every one
   of them ([Criterion_id.Unindexed]), so they all reach the SQL fallback, whose
   cost is the candidate set the dictionary hands on rather than the lookup. A
   selective fragment is fast today and is still the same unbounded shape: the
   corpus decides, not the query. Measured on prod (1.3M, 0.34.1, 2026-09-21,
   post-cutover): [name~the] 14.2s and ten concurrent fragments took index p99
   from 0.29s to 48.2s, inline on the scheduler thread with no 503 -- [Lwt.pick]
   arms its timer against an already-resolved promise, so the timeout cannot
   fire on this path at all. *)
let%expect_test "no Name_like is cheap, however long the fragment" =
  printf
    "%b\n"
    (is_cheap
       [ Search.Term.create
           (Search.Criterion.Name_like ("Throatcutter", Search.Criterion.Floor))
       ]);
  [%expect {| false |}];
  printf
    "%b\n"
    (is_cheap
       [ Search.Term.create (Search.Criterion.Name_like ("ab", Search.Criterion.Floor)) ]);
  [%expect {| false |}]
;;

(* A base type gives the query something to seek; without one it drives the
   whole build, and the page limit does not end it early because a rare property
   pair matches too few seeds to fill a page. So the bare form must detach --
   inline it would run on the scheduler thread, where the search timeout cannot
   fire. *)
let%expect_test "Props is cheap only with a base type" =
  let props ?base_type ?(position = Search.Criterion.Floor) props =
    Search.Term.create (Search.Criterion.Props { base_type; props; position })
  in
  printf "%b\n" (is_cheap [ props [ "Conj"; "Alch" ] ]);
  [%expect {| false |}];
  printf "%b\n" (is_cheap [ props ~base_type:"staff" [ "Conj"; "Alch" ] ]);
  [%expect {| true |}];
  (* Cheapness is a property of the whole search: one expensive term detaches
     it, whatever else it carries. *)
  printf "%b\n" (is_cheap [ props [ "Conj" ]; Search.Term.create haste ]);
  [%expect {| false |}];
  (* Position does not enter the cost: a shop term still seeks the same index
     with one more predicate on it. A [Props] shop term is expensive for the
     reason its floor twin is -- no base type to seek -- and cheap for the same
     reason once it has one. *)
  printf "%b\n" (is_cheap [ props ~position:Search.Criterion.Shop [ "Conj"; "Alch" ] ]);
  [%expect {| false |}];
  printf
    "%b\n"
    (is_cheap
       [ props ~base_type:"staff" ~position:Search.Criterion.Shop [ "Conj"; "Alch" ] ]);
  [%expect {| true |}];
  printf
    "%b\n"
    (is_cheap
       [ Search.Term.create (Search.Criterion.Item (haste_type, Search.Criterion.Shop)) ]);
  [%expect {| true |}]
;;
