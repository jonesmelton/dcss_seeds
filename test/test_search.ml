open! Core
module Db = Seed_corpus.Db
module Depth = Seed_corpus.Depth
module Query = Seed_corpus.Query
module Reader = Seed_corpus.Reader
module Search = Seed_corpus.Search

let version = Or_error.ok_exn (Query.Version.of_string "0.34.1")

(* Three seeds with overlapping contents, so a conjunction has something to
   exclude: seed 1 has the shop and one haste, seed 2 has the shop and three
   haste, seed 3 has three haste and no shop. [enter_shop] stands in for the
   altar feature this fixture used to use, since altar features no longer reach
   search. *)
let corpus =
  [ {|#SEED#((format 4)(version "0.34.1")(seed "1")(level "D:2")(cats (features (((feat "enter_shop")(kind "feature")(shop_type "General Store")(text "a shop"))))(items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
  ; {|#SEED#((format 4)(version "0.34.1")(seed "2")(level "D:5")(cats (features (((feat "enter_shop")(kind "feature")(shop_type "General Store")(text "a shop"))))(items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 3)(sub_type "haste")(text "potion of haste"))((base_type "wand")(cost 200)(kind "item")(name "wand of digging (4)")(quantity 1)(sub_type "digging")(text "wand of digging (4)"))))))|}
  ; {|#SEED#((format 4)(version "0.34.1")(seed "3")(level "D:1")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 3)(sub_type "haste")(text "potion of haste"))((artefact t)(base_type "weapon")(kind "item")(name "+7 Throatcutter {drain, coup de grace}")(plus 7)(quantity 1)(sub_type "long sword")(text "+7 Throatcutter"))))))|}
  ; {|#SEED#((format 4)(version "0.34.1")(seed "4")(level "D:1")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
  ; {|#SEED#((format 4)(version "0.34.1")(seed "4")(level "D:3")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
  ; {|#SEED#((format 4)(version "0.34.1")(seed "4")(level "D:6")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
  ; {|#SEED#((format 4)(version "0.34.1")(seed "5")(level "D:2")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
  ; {|#SEED#((format 4)(version "0.34.1")(seed "5")(level "D:6")(cats (items (((base_type "potion")(kind "item")(name "2 potions of haste")(quantity 2)(sub_type "haste")(text "2 potions of haste"))))))|}
    (* A name carrying literal `%` and `_`. Under wildcard semantics
       "100%_pure" would also be matched by the fragment "100%pure", which is
       what the escape exists to prevent. *)
  ; {|#SEED#((format 4)(version "0.34.1")(seed "7")(level "D:2")(cats (items (((artefact t)(base_type "weapon")(kind "item")(name "+2 Blade of 100%_pure {holy}")(plus 2)(quantity 1)(sub_type "long sword")(text "+2 Blade of 100%_pure"))))))|}
    (* Two on the floor and a third behind a counter: three by the unqualified
       count, two by the floor count. *)
  ; {|#SEED#((format 4)(version "0.34.1")(seed "6")(level "D:4")(cats (items (((base_type "potion")(kind "item")(name "2 potions of haste")(quantity 2)(sub_type "haste")(text "2 potions of haste"))((base_type "potion")(cost 120)(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
  ]
;;

(* Builds the trigram index; [Name_like] is refused against a stale one. *)
let fresh_db () =
  let db = Db.open_ ":memory:" in
  Db.exec_script db (In_channel.read_all "../schema.sql");
  let records =
    List.map corpus ~f:(fun line -> Or_error.ok_exn (Reader.parse_line line))
  in
  ignore (Db.write_batch db records : Db.Counts.t);
  Or_error.ok_exn (Db.rebuild_fts db);
  db
;;

let haste = { Search.Item_type.base_type = "potion"; sub_type = "haste" }
let digging = { Search.Item_type.base_type = "wand"; sub_type = "digging" }

let run ?(rank = Search.Rank.default) db terms =
  let search = Search.create ~version ~terms () in
  match Db.search_seeds db search ~rank with
  | Error err -> print_endline (Error.to_string_hum err)
  | Ok (matches, more) ->
    print_endline (Search.to_string search);
    List.iter matches ~f:(fun (m : Search.Match.t) ->
      let hits =
        List.map m.hits ~f:(fun (h : Search.Match.hit) ->
          sprintf "%s x%d on %s" h.name h.count h.level)
        |> String.concat ~sep:"; "
      in
      printf "  %s: %s\n" m.seed hits);
    printf
      "  [%s]\n"
      (match more with
       | `More -> "more"
       | `End -> "end")
;;

let%expect_test "a single term finds every seed containing it" =
  let db = fresh_db () in
  run db [ Search.Term.create (Search.Criterion.Item haste) ];
  [%expect
    {|
    seeds on 0.34.1 with potion of haste
      1: potion of haste x1 on D:2
      2: 3 potions of haste x3 on D:5
      3: 3 potions of haste x3 on D:1
      4: potion of haste x3 on D:1
      5: potion of haste x3 on D:2
      6: potion of haste x3 on D:4
      [end]
    |}];
  Db.close db
;;

(* min_count sums quantity rather than counting rows, so one stack of three
   satisfies "3+". *)
let%expect_test "min_count sums quantity, not rows" =
  let db = fresh_db () in
  run db [ Search.Term.create ~min_count:3 (Search.Criterion.Item haste) ];
  [%expect
    {|
    seeds on 0.34.1 with 3+ potion of haste
      2: 3 potions of haste x3 on D:5
      3: 3 potions of haste x3 on D:1
      4: potion of haste x3 on D:1
      5: potion of haste x3 on D:2
      6: potion of haste x3 on D:4
      [end]
    |}];
  Db.close db
;;

let%expect_test "terms are conjunctive" =
  let db = fresh_db () in
  run
    db
    [ Search.Term.create (Search.Criterion.Feature "enter_shop")
    ; Search.Term.create ~min_count:3 (Search.Criterion.Item haste)
    ];
  [%expect
    {|
    seeds on 0.34.1 with a shop, 3+ potion of haste
      2: a General Store x1 on D:5; 3 potions of haste x3 on D:5
      [end]
    |}];
  Db.close db
;;

(* cost being present is the only thing telling a shop item from a floor item,
   so Shop_item is a distinct criterion rather than a modifier. *)
let%expect_test "shop items are distinguished by cost being present" =
  let db = fresh_db () in
  run db [ Search.Term.create (Search.Criterion.Shop_item digging) ];
  [%expect
    {|
    seeds on 0.34.1 with wand of digging in a shop
      2: wand of digging (0) x1 on D:5
      [end]
    |}];
  run db [ Search.Term.create (Search.Criterion.Item digging) ];
  [%expect
    {|
    seeds on 0.34.1 with wand of digging
      2: wand of digging (0) x1 on D:5
      [end]
    |}];
  Db.close db
;;

(* The floor half of the same partition. Seed 2's only wand of digging is shop
   stock, so a floor term must find nothing there while the unqualified term
   still finds it -- which keeps this from passing vacuously. *)
let%expect_test "floor items exclude shop stock" =
  let db = fresh_db () in
  run db [ Search.Term.create (Search.Criterion.Floor_item digging) ];
  [%expect
    {|
    seeds on 0.34.1 with wand of digging on the floor
      [end]
    |}];
  run db [ Search.Term.create (Search.Criterion.Floor_item haste) ];
  [%expect
    {|
    seeds on 0.34.1 with potion of haste on the floor
      1: potion of haste x1 on D:2
      2: 3 potions of haste x3 on D:5
      3: 3 potions of haste x3 on D:1
      4: potion of haste x3 on D:1
      5: potion of haste x3 on D:2
      6: 2 potions of haste x2 on D:4
      [end]
    |}];
  Db.close db
;;

(* min_count counts across the floor/shop boundary unless the term says
   otherwise, so the floor form can match strictly fewer seeds than filtering an
   unqualified result set would suggest. *)
let%expect_test "a floor term counts only floor stock" =
  let db = fresh_db () in
  run db [ Search.Term.create ~min_count:3 (Search.Criterion.Floor_item haste) ];
  [%expect
    {|
    seeds on 0.34.1 with 3+ potion of haste on the floor
      2: 3 potions of haste x3 on D:5
      3: 3 potions of haste x3 on D:1
      4: potion of haste x3 on D:1
      5: potion of haste x3 on D:2
      [end]
    |}];
  Db.close db
;;

(* An unrand's display name carries a varying enchantment prefix, so it is
   findable only by substring. *)
let%expect_test "name_like finds an unrand through its enchantment prefix" =
  let db = fresh_db () in
  run db [ Search.Term.create (Search.Criterion.Name_like "Throatcutter") ];
  [%expect
    {|
    seeds on 0.34.1 with named like "Throatcutter"
      3: +7 Throatcutter {drain, coup de grace} x1 on D:1
      [end]
    |}];
  Db.close db
;;

let%expect_test "artefact is its own criterion" =
  let db = fresh_db () in
  run db [ Search.Term.create Search.Criterion.Artefact ];
  [%expect
    {|
    seeds on 0.34.1 with an artefact
      3: +7 Throatcutter {drain, coup de grace} x1 on D:1
      7: +2 Blade of 100%_pure {holy} x1 on D:2
      [end]
    |}];
  Db.close db
;;

let%expect_test "an empty search lists every seed of the version" =
  let db = fresh_db () in
  run db [];
  [%expect
    {|
    all seeds on 0.34.1
      1:
      2:
      3:
      4:
      5:
      6:
      7:
      [end]
    |}];
  Db.close db
;;

(* A wildcard in a fragment must be escaped, or "100%" matches everything
   beginning with "100". *)
let%expect_test "like wildcards in a fragment are escaped" =
  let db = fresh_db () in
  run db [ Search.Term.create (Search.Criterion.Name_like "%") ];
  [%expect
    {|
    seeds on 0.34.1 with named like "%"
      7: +2 Blade of 100%_pure {holy} x1 on D:2
      [end]
    |}];
  Db.close db
;;

(* The trigram index reads `%` and `_` as live wildcards, so the fragment
   "100%pure" would match "100%_pure" through the index alone. The escaped
   re-check against `strings` is what restores the literal reading; delete it
   and this test matches seed 7. *)
let%expect_test "a wildcard in a fragment matches only itself, literally" =
  let db = fresh_db () in
  run db [ Search.Term.create (Search.Criterion.Name_like "100%pure") ];
  [%expect
    {|
    seeds on 0.34.1 with named like "100%pure"
      [end]
    |}];
  Db.close db
;;

let%expect_test "a literal wildcard is found by its own escaped fragment" =
  let db = fresh_db () in
  run db [ Search.Term.create (Search.Criterion.Name_like "100%_pure") ];
  [%expect
    {|
    seeds on 0.34.1 with named like "100%_pure"
      7: +2 Blade of 100%_pure {holy} x1 on D:2
      [end]
    |}];
  Db.close db
;;

(* An underscore is the other live wildcard: "100%_pure" must not be reachable
   by "100%Xpure"-shaped fragments through the index. *)
let%expect_test "an underscore in a fragment is literal too" =
  let db = fresh_db () in
  run db [ Search.Term.create (Search.Criterion.Name_like "0%_pu") ];
  [%expect
    {|
    seeds on 0.34.1 with named like "0%_pu"
      7: +2 Blade of 100%_pure {holy} x1 on D:2
      [end]
    |}];
  Db.close db
;;

(* Everything above ran against a corpus whose trigram index was never built,
   so [Name_like] took the dictionary-scan fallback. These re-run the same
   fragments against a rebuilt index: the two paths must agree exactly, or the
   fast one is returning a different answer than the correct one.

   The wildcard cases are the point. Against the index `%` and `_` are live
   wildcards -- "100%pure" reaches fts5 as a pattern that *does* match
   "100%_pure" -- and only the escaped re-check against `strings` narrows it
   back to the literal reading. Drop that stage and the first of these fails
   while every fallback-path test above keeps passing. *)
let%expect_test "trigram path agrees with the scan on a literal wildcard" =
  let db = fresh_db () in
  run db [ Search.Term.create (Search.Criterion.Name_like "100%pure") ];
  [%expect
    {|
    seeds on 0.34.1 with named like "100%pure"
      [end]
    |}];
  run db [ Search.Term.create (Search.Criterion.Name_like "100%_pure") ];
  [%expect
    {|
    seeds on 0.34.1 with named like "100%_pure"
      7: +2 Blade of 100%_pure {holy} x1 on D:2
      [end]
    |}];
  run db [ Search.Term.create (Search.Criterion.Name_like "0%_pu") ];
  [%expect
    {|
    seeds on 0.34.1 with named like "0%_pu"
      7: +2 Blade of 100%_pure {holy} x1 on D:2
      [end]
    |}];
  Db.close db
;;

let%expect_test "trigram path finds an unrand through its enchantment prefix" =
  let db = fresh_db () in
  run db [ Search.Term.create (Search.Criterion.Name_like "Throatcutter") ];
  [%expect
    {|
    seeds on 0.34.1 with named like "Throatcutter"
      3: +7 Throatcutter {drain, coup de grace} x1 on D:1
      [end]
    |}];
  Db.close db
;;

(* Trigram is case-insensitive by default and SQLite's `like` is
   ASCII-case-insensitive, so the two stages agree on folding. *)
let%expect_test "trigram substring match folds case like the scan" =
  let db = fresh_db () in
  run db [ Search.Term.create (Search.Criterion.Name_like "THROATCUTTER") ];
  [%expect
    {|
    seeds on 0.34.1 with named like "THROATCUTTER"
      3: +7 Throatcutter {drain, coup de grace} x1 on D:1
      [end]
    |}];
  Db.close db
;;

(* A name added after the rebuild is refused, not silently missed. *)
let%expect_test "a fill after the rebuild refuses rather than losing rows" =
  let db = fresh_db () in
  let line =
    {|#SEED#((format 4)(version "0.34.1")(seed "8")(level "D:1")(cats (items (((artefact t)(base_type "weapon")(kind "item")(name "+3 Gnarlfang {venom}")(plus 3)(quantity 1)(sub_type "whip")(text "+3 Gnarlfang"))))))|}
  in
  ignore (Db.write_batch db [ Or_error.ok_exn (Reader.parse_line line) ] : Db.Counts.t);
  run db [ Search.Term.create (Search.Criterion.Name_like "Gnarlfang") ];
  [%expect
    {| search-index-rebuilding: the name substring index is being rebuilt; searching by name is unavailable until it finishes |}];
  (* Served once the index covers the new name. *)
  Or_error.ok_exn (Db.rebuild_fts db);
  run db [ Search.Term.create (Search.Criterion.Name_like "Gnarlfang") ];
  [%expect
    {|
    seeds on 0.34.1 with named like "Gnarlfang"
      8: +3 Gnarlfang {venom} x1 on D:1
      [end]
    |}];
  Db.close db
;;

let%expect_test "a stale index does not refuse searches that do not use it" =
  let db = fresh_db () in
  let line =
    {|#SEED#((format 4)(version "0.34.1")(seed "9")(level "D:1")(cats (items (((artefact t)(base_type "weapon")(kind "item")(name "+1 Sniggerfoil {pain}")(plus 1)(quantity 1)(sub_type "dagger")(text "+1 Sniggerfoil"))))))|}
  in
  ignore (Db.write_batch db [ Or_error.ok_exn (Reader.parse_line line) ] : Db.Counts.t);
  run db [ Search.Term.create (Search.Criterion.Item haste) ];
  [%expect
    {|
    seeds on 0.34.1 with potion of haste
      1: potion of haste x1 on D:2
      2: 3 potions of haste x3 on D:5
      3: 3 potions of haste x3 on D:1
      4: potion of haste x3 on D:1
      5: potion of haste x3 on D:2
      6: potion of haste x3 on D:4
      [end]
    |}];
  Db.close db
;;

(* The tag is what the web layer keys on to distinguish refusal from fault. *)
let%expect_test "a stale-index refusal is recognisable to the caller" =
  let db = Db.open_ ":memory:" in
  Db.exec_script db (In_channel.read_all "../schema.sql");
  let records =
    List.map corpus ~f:(fun line -> Or_error.ok_exn (Reader.parse_line line))
  in
  ignore (Db.write_batch db records : Db.Counts.t);
  let search =
    Search.create
      ~version
      ~terms:[ Search.Term.create (Search.Criterion.Name_like "Throatcutter") ]
      ()
  in
  (match Db.search_seeds db search ~rank:Search.Rank.default with
   | Ok _ -> print_endline "served"
   | Error err ->
     printf
       "refused: index_rebuilding=%b too_broad=%b\n"
       (Search.is_index_rebuilding err)
       (Search.Rank.is_too_broad err));
  [%expect {| refused: index_rebuilding=true too_broad=false |}];
  Db.close db
;;

let%expect_test "depth ranks by reach order, not generation order" =
  (* Temple is generated before D:1 but reached around D:5, so ranking by
     crawl's generation order would call it the shallowest thing in a seed. *)
  List.iter [ "D:1"; "D:5"; "Temple"; "D:8"; "Orc:1" ] ~f:(fun level ->
    printf "%-8s %d\n" level (Depth.of_level level));
  [%expect
    {|
    D:1      1
    D:5      5
    Temple   4
    D:8      8
    Orc:1    10
    |}]
;;

(* Without a parent a portal cannot be ranked, so it sorts last. The
   pre-format-2 fallback, which still decides ordering on the seed page. *)
let%expect_test "a parentless portal is unranked" =
  printf "is_portal Sewer: %b\n" (Depth.is_portal "Sewer");
  printf "Sewer ranks last: %b\n" (Depth.of_level "Sewer" = Depth.unknown);
  [%expect
    {|
    is_portal Sewer: true
    Sewer ranks last: true
    |}]
;;

(* With a parent recorded, a portal ranks at the depth it was reached from. *)
let%expect_test "a portal with a parent ranks at its parent's depth" =
  let rank parent = Depth.of_level_with_parent ~level:"Sewer" ~parent:(Some parent) in
  printf "Sewer off D:3: %d\n" (rank "D:3");
  printf "Sewer off D:6: %d\n" (rank "D:6");
  (* The parent only applies to portals: a real branch keeps its own depth. *)
  printf
    "Temple with a stray parent: %d\n"
    (Depth.of_level_with_parent ~level:"Temple" ~parent:(Some "D:1"));
  [%expect
    {|
    Sewer off D:3: 3
    Sewer off D:6: 6
    Temple with a stray parent: 4
    |}]
;;

let%expect_test "min_count below one is clamped, so a term cannot match everything" =
  let term = Search.Term.create ~min_count:0 (Search.Criterion.Item haste) in
  print_s [%sexp (term.min_count : int)];
  [%expect {| 1 |}]
;;

(* Every criterion is indexed since names were interned, so the partition puts
   nothing in the second list and preserves the caller's order in the first. A
   future unindexed criterion has to land in the second list, and this is what
   would catch it not doing so. *)
let%expect_test "partition_terms leaves nothing unindexed" =
  let search =
    Search.create
      ~version
      ~terms:
        [ Search.Term.create (Search.Criterion.Name_like "Throatcutter")
        ; Search.Term.create (Search.Criterion.Item haste)
        ]
      ()
  in
  let indexed, unindexed = Search.partition_terms search in
  printf
    "indexed: %s | unindexed: %s\n"
    (List.map indexed ~f:Search.Term.to_string |> String.concat ~sep:", ")
    (List.map unindexed ~f:Search.Term.to_string |> String.concat ~sep:", ");
  [%expect {| indexed: named like "Throatcutter", potion of haste | unindexed: |}]
;;

(* Shallowest ranking is the question a player actually asks, but it must sort
   the whole match set, so it is the ranking that does not paginate by
   keyset. *)
let%expect_test "shallowest ranking orders by the earliest evidence" =
  let db = fresh_db () in
  let terms = [ Search.Term.create (Search.Criterion.Item haste) ] in
  let show rank =
    let search = Search.create ~version ~terms () in
    let matches, _ = Or_error.ok_exn (Db.search_seeds db search ~rank) in
    List.map matches ~f:(fun (m : Search.Match.t) ->
      let level =
        List.hd m.hits |> Option.value_map ~default:"-" ~f:(fun h -> h.Search.Match.level)
      in
      sprintf "%s@%s" m.seed level)
    |> String.concat ~sep:" "
    |> printf "%-12s %s\n" (Search.Rank.to_string rank)
  in
  show Search.Rank.Seed;
  show Search.Rank.Shallowest;
  [%expect
    {|
    seed         1@D:2 2@D:5 3@D:1 4@D:1 5@D:2 6@D:4
    shallowest   3@D:1 4@D:1 1@D:2 5@D:2 6@D:4 2@D:5
    |}];
  Db.close db
;;

(* A seed can satisfy a count threshold by accumulating across levels. The
   evidence must not understate that by reporting only the shallowest level's
   share, or the reader cannot see why it matched. *)
let%expect_test "evidence totals a count that accumulates across levels" =
  let db = fresh_db () in
  run db [ Search.Term.create ~min_count:3 (Search.Criterion.Item haste) ];
  [%expect
    {|
    seeds on 0.34.1 with 3+ potion of haste
      2: 3 potions of haste x3 on D:5
      3: 3 potions of haste x3 on D:1
      4: potion of haste x3 on D:1
      5: potion of haste x3 on D:2
      6: potion of haste x3 on D:4
      [end]
    |}];
  Db.close db
;;

(* Without a [distinct] the subquery yields a row per entry, which duplicates
   the seed and silently shrinks the keyset page. *)
let%expect_test "a seed matching a term several times appears once" =
  let db = fresh_db () in
  run db [ Search.Term.create (Search.Criterion.Item haste) ];
  [%expect
    {|
    seeds on 0.34.1 with potion of haste
      1: potion of haste x1 on D:2
      2: 3 potions of haste x3 on D:5
      3: 3 potions of haste x3 on D:1
      4: potion of haste x3 on D:1
      5: potion of haste x3 on D:2
      6: potion of haste x3 on D:4
      [end]
    |}];
  Db.close db
;;

(* Crawl renders a stack with a pluralised name, so one sub_type reaches the
   corpus under several names. Evidence grouped by name would split one term's
   evidence in two. *)
let%expect_test "evidence totals across crawl's pluralised stack names" =
  let db = fresh_db () in
  run db [ Search.Term.create ~min_count:3 (Search.Criterion.Item haste) ];
  [%expect
    {|
    seeds on 0.34.1 with 3+ potion of haste
      2: 3 potions of haste x3 on D:5
      3: 3 potions of haste x3 on D:1
      4: potion of haste x3 on D:1
      5: potion of haste x3 on D:2
      6: potion of haste x3 on D:4
      [end]
    |}];
  Db.close db
;;

(* Shallowest ranking pages by offset, not keyset: the ranked order is not the
   seed order a keyset cursor assumes, so page two must continue the ranking
   rather than restart it at a seed value. *)
let%expect_test "shallowest ranking pages by offset and stays ordered" =
  let db = fresh_db () in
  let terms = [ Search.Term.create (Search.Criterion.Item haste) ] in
  let show after =
    let search =
      Search.create ~version ~terms ~page:(Query.Page.create ?after ~limit:2 ()) ()
    in
    let matches, more =
      Or_error.ok_exn (Db.search_seeds db search ~rank:Search.Rank.Shallowest)
    in
    printf
      "after=%-4s %s [%s]\n"
      (Option.value after ~default:"-")
      (List.map matches ~f:(fun (m : Search.Match.t) ->
         let level =
           List.hd m.hits
           |> Option.value_map ~default:"-" ~f:(fun h -> h.Search.Match.level)
         in
         sprintf "%s@%s" m.seed level)
       |> String.concat ~sep:" ")
      (match more with
       | `More -> "more"
       | `End -> "end")
  in
  show None;
  show (Some "2");
  show (Some "4");
  [%expect
    {|
    after=-    3@D:1 4@D:1 [more]
    after=2    1@D:2 5@D:2 [more]
    after=4    6@D:4 2@D:5 [end]
    |}];
  Db.close db
;;

(* Beyond the cap the search is refused rather than answered: ranking needs the
   whole matched set, and an order holding only within a page is worse than a
   refusal. The fixture is far below the real cap, so the boundary is checked by
   arithmetic rather than by ingesting thousands of seeds. *)
let%expect_test "ranking refuses a match set larger than the sort limit" =
  let db = fresh_db () in
  let search =
    Search.create ~version ~terms:[ Search.Term.create (Search.Criterion.Item haste) ] ()
  in
  let matches, _ =
    Or_error.ok_exn (Db.search_seeds db search ~rank:Search.Rank.Shallowest)
  in
  printf
    "sort_limit=%d matched=%d refused=%b\n"
    Search.Rank.sort_limit
    (List.length matches)
    (List.length matches > Search.Rank.sort_limit);
  [%expect {| sort_limit=5000 matched=6 refused=false |}];
  Db.close db
;;

(* A short Name_like fragment is indexed but not cheap: the leading-wildcard
   like scans the whole dictionary. The minimum length is enforced at the parse
   boundary; this tests the predicate that keeps such queries off the scheduler
   thread. *)
let%expect_test "is_cheap rejects short name_like fragments" =
  let show criterion =
    printf
      "%-30s -> cheap=%b\n"
      (Search.Criterion.to_string criterion)
      (Search.Criterion.is_cheap criterion)
  in
  List.iter
    ~f:show
    [ Search.Criterion.Name_like "ab"
    ; Search.Criterion.Name_like "abc"
    ; Search.Criterion.Name_like "Throatcutter"
    ; Search.Criterion.Item haste
    ; Search.Criterion.Artefact
    ; Search.Criterion.Unique "Sigmund"
    ];
  [%expect
    {|
    named like "ab"                -> cheap=false
    named like "abc"               -> cheap=true
    named like "Throatcutter"      -> cheap=true
    potion of haste                -> cheap=true
    an artefact                    -> cheap=true
    Sigmund                        -> cheap=true
    |}]
;;

(* Query-shape equivalence.

   [search_seeds_sql] was rewritten from an [intersect] of [distinct] subqueries
   under an outer [order by ... limit] into a flat query: one term as driver,
   the rest as correlated [exists]/[not exists]. The property that has to
   survive is that the *set of matching seeds* is unchanged.

   The reference is a from-scratch, non-SQL computation over the same assignment
   table the fixture is built from -- "naive" as in sharing no code with the
   thing under test, not as in a simplified copy of the SQL. *)

(* A synthetic seed's contents, deliberately not a 1:1 mirror of
     Record.Entry.t -- it carries only what the reference computation reads. *)
module Synth = struct
  type t =
    { seed : int
    ; haste_floor_qty : int (* 0 means "no floor haste stack" *)
    ; haste_shop_qty : int (* 0 means "no shop haste stack" *)
    ; digging : bool (* one floor wand of digging *)
    ; has_shop_feature : bool (* an unrelated feature term can drive/probe on *)
    ; artefact : bool
    }

  (* 40 seeds, deterministic from the index. The residues are chosen so every
     combination of (floor haste, shop haste, digging, shop feature, artefact)
     appears at least once, which is what makes the multi-term intersections and
     the min_count-as-driver-vs-non-driver cases exercise a boundary rather than
     vacuously pass. *)
  let all =
    List.init 40 ~f:(fun i ->
      let seed = 1000 + i in
      { seed
      ; haste_floor_qty = i % 4 (* 0,1,2,3 potions on the floor *)
      ; haste_shop_qty = i / 4 % 3 (* 0,1,2 potions behind a counter *)
      ; digging = i % 5 = 0
      ; has_shop_feature = i % 3 = 0
      ; artefact = i % 7 = 0
      })
  ;;
end

let synth_line (s : Synth.t) =
  let feature =
    if s.Synth.has_shop_feature
    then
      {|((feat "enter_shop")(kind "feature")(shop_type "General Store")(text "a shop"))|}
    else ""
  in
  let potion ~qty ~cost =
    if qty = 0
    then ""
    else (
      let cost =
        match cost with
        | None -> ""
        | Some c -> sprintf "(cost %d)" c
      in
      let name =
        if qty > 1 then sprintf "%d potions of haste" qty else "potion of haste"
      in
      sprintf
        {|((base_type "potion")%s(kind "item")(name "%s")(quantity %d)(sub_type "haste")(text "%s"))|}
        cost
        name
        qty
        name)
  in
  let digging =
    if s.Synth.digging
    then
      {|((base_type "wand")(kind "item")(name "wand of digging")(quantity 1)(sub_type "digging")(text "wand of digging"))|}
    else ""
  in
  let artefact =
    if s.Synth.artefact
    then
      sprintf
        {|((artefact t)(base_type "weapon")(kind "item")(name "+3 seed %d's blade")(plus 3)(quantity 1)(sub_type "dagger")(text "+3 seed %d's blade"))|}
        s.Synth.seed
        s.Synth.seed
    else ""
  in
  let items =
    String.concat
      [ potion ~qty:s.Synth.haste_floor_qty ~cost:None
      ; potion ~qty:s.Synth.haste_shop_qty ~cost:(Some 100)
      ; digging
      ; artefact
      ]
  in
  sprintf
    {|#SEED#((format 4)(version "0.34.1")(seed "%d")(level "D:3")(cats (features (%s))(items (%s))))|}
    s.Synth.seed
    feature
    items
;;

let synth_db () =
  let db = Db.open_ ":memory:" in
  Db.exec_script db (In_channel.read_all "../schema.sql");
  let records =
    List.map Synth.all ~f:(fun s -> Or_error.ok_exn (Reader.parse_line (synth_line s)))
  in
  ignore (Db.write_batch db records : Db.Counts.t);
  db
;;

(* A page large enough that the 40-seed fixture never paginates -- the property
   under test is the matched *set*, and a truncated page would make a correct
   rewrite look wrong. *)
let matched_set db terms =
  let search =
    Search.create ~version ~terms ~page:(Query.Page.create ~limit:1000 ()) ()
  in
  let matches, more =
    Or_error.ok_exn (Db.search_seeds db search ~rank:Search.Rank.Seed)
  in
  (match more with
   | `End -> ()
   | `More -> failwith "fixture too large for a single page; raise the test limit");
  List.map matches ~f:(fun (m : Search.Match.t) -> Int.of_string m.seed)
  |> Int.Set.of_list
;;

(* Storage computes [min_count] by summing [quantity], not counting rows;
   mirrored here rather than reduced to "any qty > 0", since that is exactly the
   distinction a driver-vs-non-driver regression would hide. *)
let seeds_where synth ~f =
  List.filter_map synth ~f:(fun (s : Synth.t) -> if f s then Some s.Synth.seed else None)
  |> Int.Set.of_list
;;

let expect_same ~label expected actual =
  let missing = Set.diff expected actual in
  let extra = Set.diff actual expected in
  if Set.is_empty missing && Set.is_empty extra
  then printf "%s: match (%d seeds)\n" label (Set.length expected)
  else
    printf
      "%s: MISMATCH missing=%s extra=%s\n"
      label
      (Int.Set.sexp_of_t missing |> Sexp.to_string_hum)
      (Int.Set.sexp_of_t extra |> Sexp.to_string_hum)
;;

(* A single indexed term, no min_count: the simplest driver-only shape. *)
let%expect_test "single term matches the naive reference" =
  let db = synth_db () in
  let expected =
    seeds_where Synth.all ~f:(fun s -> s.haste_floor_qty + s.haste_shop_qty > 0)
  in
  expect_same
    ~label:"potion:haste"
    expected
    (matched_set db [ Search.Term.create (Search.Criterion.Item haste) ]);
  Db.close db;
  [%expect {| potion:haste: match (36 seeds) |}]
;;

(* Two-term intersection: the shape the rewrite turns from [intersect] into a
   driver plus one correlated [exists]. *)
let%expect_test "two-term intersection matches the naive reference" =
  let db = synth_db () in
  let expected =
    seeds_where Synth.all ~f:(fun s ->
      s.haste_floor_qty + s.haste_shop_qty > 0 && s.has_shop_feature)
  in
  expect_same
    ~label:"potion:haste & enter_shop"
    expected
    (matched_set
       db
       [ Search.Term.create (Search.Criterion.Item haste)
       ; Search.Term.create (Search.Criterion.Feature "enter_shop")
       ]);
  Db.close db;
  [%expect {| potion:haste & enter_shop: match (10 seeds) |}]
;;

(* Three-term intersection mixing a rare criterion (digging, 1/5 seeds) with
   two common ones -- what the rare-first driver heuristic is meant to help,
   though correctness must not depend on which arm is chosen. *)
let%expect_test "three-term intersection matches the naive reference" =
  let db = synth_db () in
  let expected =
    seeds_where Synth.all ~f:(fun s ->
      s.digging && s.artefact && s.haste_floor_qty + s.haste_shop_qty > 0)
  in
  expect_same
    ~label:"digging & artefact & potion:haste"
    expected
    (matched_set
       db
       [ Search.Term.create (Search.Criterion.Item digging)
       ; Search.Term.create Search.Criterion.Artefact
       ; Search.Term.create (Search.Criterion.Item haste)
       ]);
  Db.close db;
  [%expect {| digging & artefact & potion:haste: match (1 seeds) |}]
;;

(* min_count as the sole term, so it is necessarily the driver. *)
let%expect_test "min_count as driver matches the naive reference" =
  let db = synth_db () in
  let expected_item =
    seeds_where Synth.all ~f:(fun s -> s.haste_floor_qty + s.haste_shop_qty >= 3)
  in
  let expected_floor = seeds_where Synth.all ~f:(fun s -> s.haste_floor_qty >= 3) in
  expect_same
    ~label:"3x potion:haste"
    expected_item
    (matched_set db [ Search.Term.create ~min_count:3 (Search.Criterion.Item haste) ]);
  expect_same
    ~label:"3x floor potion:haste"
    expected_floor
    (matched_set
       db
       [ Search.Term.create ~min_count:3 (Search.Criterion.Floor_item haste) ]);
  Db.close db;
  [%expect
    {|
    3x potion:haste: match (19 seeds)
    3x floor potion:haste: match (10 seeds)
    |}]
;;

(* min_count as a *non-driver*: paired with a rare criterion the ordering picks
   instead, so it is evaluated as the correlated scalar-sum predicate rather
   than the grouped driver shape. Both must agree with the same reference. *)
let%expect_test "min_count as non-driver matches the naive reference" =
  let db = synth_db () in
  let expected =
    seeds_where Synth.all ~f:(fun s ->
      s.digging && s.haste_floor_qty + s.haste_shop_qty >= 3)
  in
  expect_same
    ~label:"digging & 3x potion:haste"
    expected
    (matched_set
       db
       [ Search.Term.create (Search.Criterion.Item digging)
       ; Search.Term.create ~min_count:3 (Search.Criterion.Item haste)
       ]);
  Db.close db;
  [%expect {| digging & 3x potion:haste: match (4 seeds) |}]
;;

(* Two [min_count > 1] terms: [driver_rank] pushes both into the back class,
   so one is still forced into the driver's [group by ... having] role.
   Exercises the [`Group_by] driver composing with a correlated scalar-sum
   predicate rather than a bare [exists]. *)
let%expect_test
    "two min_count terms together: the group-by driver still composes with a correlated \
     scalar-sum predicate"
  =
  let db = synth_db () in
  let expected =
    seeds_where Synth.all ~f:(fun s ->
      s.haste_floor_qty + s.haste_shop_qty >= 3 && s.haste_floor_qty >= 2)
  in
  expect_same
    ~label:"3x potion:haste & 2x floor potion:haste"
    expected
    (matched_set
       db
       [ Search.Term.create ~min_count:3 (Search.Criterion.Item haste)
       ; Search.Term.create ~min_count:2 (Search.Criterion.Floor_item haste)
       ]);
  Db.close db;
  [%expect {| 3x potion:haste & 2x floor potion:haste: match (16 seeds) |}]
;;

(* Several matching entries on one seed must still yield the seed once. The
   reference is set-valued by construction, so duplication in storage's output
   shows as a raw match count exceeding the set size. *)
let%expect_test "a seed with several matching entries appears once" =
  let db = synth_db () in
  let search =
    Search.create
      ~version
      ~terms:[ Search.Term.create (Search.Criterion.Item haste) ]
      ~page:(Query.Page.create ~limit:1000 ())
      ()
  in
  let matches, _ = Or_error.ok_exn (Db.search_seeds db search ~rank:Search.Rank.Seed) in
  let seeds = List.map matches ~f:(fun (m : Search.Match.t) -> m.seed) in
  printf
    "rows=%d distinct=%d multi_entry_seeds=%d\n"
    (List.length seeds)
    (List.length (List.dedup_and_sort seeds ~compare:String.compare))
    (List.count Synth.all ~f:(fun s -> s.haste_floor_qty > 0 && s.haste_shop_qty > 0));
  [%expect {| rows=36 distinct=36 multi_entry_seeds=18 |}];
  Db.close db
;;

(* Keyset paging across a boundary: two half-pages, joined, must equal the
   single-page whole-set match, with no seed lost or duplicated at the join. *)
let%expect_test "keyset paging across a boundary matches the naive reference" =
  let db = synth_db () in
  let expected =
    seeds_where Synth.all ~f:(fun s -> s.haste_floor_qty + s.haste_shop_qty > 0)
  in
  let page ~after ~limit =
    let search =
      Search.create
        ~version
        ~terms:[ Search.Term.create (Search.Criterion.Item haste) ]
        ~page:(Query.Page.create ?after ~limit ())
        ()
    in
    Or_error.ok_exn (Db.search_seeds db search ~rank:Search.Rank.Seed)
  in
  let rec collect after acc =
    let matches, more = page ~after ~limit:3 in
    let acc =
      acc @ List.map matches ~f:(fun (m : Search.Match.t) -> Int.of_string m.seed)
    in
    match more with
    | `End -> acc
    | `More -> collect (Some (List.last_exn matches).Search.Match.seed) acc
  in
  let paged = Int.Set.of_list (collect None []) in
  expect_same ~label:"paged potion:haste" expected paged;
  (* The last seed of page one must not reappear as the first of page two. *)
  let first_page, _ = page ~after:None ~limit:3 in
  let second_page, _ =
    page ~after:(Some (List.last_exn first_page).Search.Match.seed) ~limit:3
  in
  let overlap =
    Set.inter
      (String.Set.of_list (List.map first_page ~f:(fun (m : Search.Match.t) -> m.seed)))
      (String.Set.of_list (List.map second_page ~f:(fun (m : Search.Match.t) -> m.seed)))
  in
  printf "boundary overlap: %s\n" (String.Set.sexp_of_t overlap |> Sexp.to_string_hum);
  [%expect
    {|
    paged potion:haste: match (36 seeds)
    boundary overlap: ()
    |}];
  Db.close db
;;

(* Empty search: the flattened keyset listing path, no wrapper, no
   compound. *)
let%expect_test "empty search matches every synthetic seed" =
  let db = synth_db () in
  let expected = Int.Set.of_list (List.map Synth.all ~f:(fun s -> s.seed)) in
  expect_same ~label:"empty search" expected (matched_set db []);
  Db.close db;
  [%expect {| empty search: match (40 seeds) |}]
;;

(* Altar features are rejected at the criterion layer, in
   [Seed_web.Params.criterion] -- [Search.Criterion.Feature] itself still
   accepts any string, since the type does not know crawl's feat vocabulary.
   See test/test_params.ml for the parser-level rejection.

   This instead pins that storage no longer special-cases a pool god's Temple
   mask: a raw [Feature "altar_trog"], if constructed directly, finds only
   ordinary [entries] rows. *)
let%expect_test "a raw Feature altar criterion no longer reads the Temple mask" =
  let db = Db.open_ ":memory:" in
  Db.exec_script db (In_channel.read_all "../schema.sql");
  let records =
    List.map
      [ (* Temple mask only, no ordinary altar_trog row: what a Temple-generated
           seed looks like once the pool gods are collapsed into the bitmask. *)
        {|#SEED#((format 4)(version "0.34.1")(seed "9001")(level "Temple")(cats (features (((feat "altar_trog")(kind "feature")(text "a bloodstained altar of Trog"))((feat "altar_zin")(kind "feature")(text "a glowing silver altar of Zin"))))))|}
        (* An ordinary D-level altar row, which Feature search has always read
           regardless of the mask question. *)
      ; {|#SEED#((format 4)(version "0.34.1")(seed "9002")(level "D:3")(cats (features (((feat "altar_trog")(kind "feature")(text "a bloodstained altar of Trog"))))))|}
      ]
      ~f:(fun line -> Or_error.ok_exn (Reader.parse_line line))
  in
  ignore (Db.write_batch db records : Db.Counts.t);
  let matched =
    matched_set db [ Search.Term.create (Search.Criterion.Feature "altar_trog") ]
  in
  printf "%s\n" (Int.Set.sexp_of_t matched |> Sexp.to_string_hum);
  [%expect {| (9002) |}];
  Db.close db
;;
