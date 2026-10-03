open! Core
module Db = Seed_corpus.Db
module Depth = Seed_corpus.Depth
module Query = Seed_corpus.Query
module Reader = Seed_corpus.Reader
module Search = Seed_corpus.Search
module Criterion_id = Seed_corpus.Criterion_id

(* The equivalence suite: the seed-granular search store is a second
   implementation of a predicate semantics SQL already implements, and the
   only thing that makes it safe to serve is a test that says the two agree.
   [Test_search.corpus] and [Test_search.synth_db]/[Test_search.Synth] are
   reused directly -- nothing in test/ has an .mli, so their top-level values
   are visible as [Test_search.xxx]. *)

let version = Or_error.ok_exn (Query.Version.of_string "0.34.1")

let parse_records lines =
  List.map lines ~f:(fun line -> Or_error.ok_exn (Reader.parse_line line))
;;

(* Two databases from the same records: [sql_db] never gets a store, so every
   search takes the SQL predicate path; [idx_db] gets [Search_index.build] on
   top, so every search the store can answer takes the store path instead. *)
let fresh_pair records =
  let make () =
    let db = Db.open_ ":memory:" in
    Db.exec_script db (In_channel.read_all "../schema.sql");
    ignore (Db.write_batch db records : Db.Counts.t);
    Or_error.ok_exn (Db.rebuild_fts db);
    db
  in
  let sql_db = make () in
  let idx_db = make () in
  Or_error.ok_exn (Db.build_search_index idx_db ~version);
  sql_db, idx_db
;;

let corpus_pair () = fresh_pair (parse_records Test_search.corpus)

(* The 40-seed synthetic fixture from test_search.ml's query-shape-equivalence
   section: deliberately covers every combination of (floor haste, shop haste,
   digging, shop feature, scroll), which is exactly the diversity a
   driver/non-driver comparison needs. *)
let synth_pair () =
  let sql_db = Test_search.synth_db () in
  let idx_db = Test_search.synth_db () in
  Or_error.ok_exn (Db.build_search_index idx_db ~version);
  sql_db, idx_db
;;

(* {1 The harness} *)

let seed_set matches =
  String.Set.of_list (List.map matches ~f:(fun (m : Search.Match.t) -> m.seed))
;;

let sexp_of_seed_set s = Sexp.to_string_hum (String.Set.sexp_of_t s)
let hit_key (h : Search.Match.hit) = h.level, h.name, h.count, h.distinct

let hits_by_seed matches =
  List.map matches ~f:(fun (m : Search.Match.t) -> m.seed, List.map m.hits ~f:hit_key)
  |> String.Map.of_alist_exn
;;

(* Runs one search against both paths and prints a verdict. Seeds are compared
   as sets -- the store pages by ordinal, the SQL path by seed text, so an
   order comparison would fail for the right reason and hide the wrong ones.
   Hits are compared per seed since evidence ([term_hits] on both paths) must
   match exactly; a difference means the store admitted a seed SQL would not.
   Returns the two raw match lists (empty on any error, already reported) so a
   caller needing more -- e.g. a depth check under [Shallowest] -- can keep
   going without re-running the search. *)
let agree ?(rank = Search.Rank.default) ~label sql_db idx_db terms =
  let run db =
    let search =
      Search.create ~version ~terms ~page:(Query.Page.create ~limit:1000 ()) ()
    in
    Db.search_seeds db search ~rank
  in
  match run sql_db, run idx_db with
  | Error e, Ok _ ->
    printf "%s: sql path errored, store did not: %s\n" label (Error.to_string_hum e);
    [], []
  | Ok _, Error e ->
    printf "%s: store errored, sql path did not: %s\n" label (Error.to_string_hum e);
    [], []
  | Error e1, Error e2 ->
    printf
      "%s: both paths errored (sql=%s store=%s)\n"
      label
      (Error.to_string_hum e1)
      (Error.to_string_hum e2);
    [], []
  | Ok (m1, more1), Ok (m2, more2) ->
    let s1 = seed_set m1
    and s2 = seed_set m2 in
    if not (Set.equal s1 s2)
    then
      printf
        "%s: SEED MISMATCH sql_only=%s store_only=%s\n"
        label
        (sexp_of_seed_set (Set.diff s1 s2))
        (sexp_of_seed_set (Set.diff s2 s1))
    else (
      let h1 = hits_by_seed m1
      and h2 = hits_by_seed m2 in
      let mismatched =
        Set.filter s1 ~f:(fun seed ->
          not
            ([%equal: (string * string * int * int) list]
               (Map.find_exn h1 seed)
               (Map.find_exn h2 seed)))
      in
      if Set.is_empty mismatched
      then printf "%s: agree (%d seeds)\n" label (Set.length s1)
      else
        Set.iter mismatched ~f:(fun seed ->
          printf
            "%s: HITS MISMATCH seed=%s sql=%s store=%s\n"
            label
            seed
            (Sexp.to_string_hum
               ([%sexp_of: (string * string * int * int) list] (Map.find_exn h1 seed)))
            (Sexp.to_string_hum
               ([%sexp_of: (string * string * int * int) list] (Map.find_exn h2 seed)))));
    (match more1, more2 with
     | `More, `More | `End, `End -> ()
     | _ ->
       printf
         "%s: MORE MISMATCH sql=%s store=%s\n"
         label
         (match more1 with
          | `More -> "more"
          | `End -> "end")
         (match more2 with
          | `More -> "more"
          | `End -> "end"));
    m1, m2
;;

(* The shallowest depth over every hit of a match, the same fold
   [Search.rank_matches] and [Search_index.candidate_depth] both do -- min
   across every term's evidence, not just the driver's. *)
let match_depth (m : Search.Match.t) =
  List.fold m.hits ~init:Int.max_value ~f:(fun acc (h : Search.Match.hit) ->
    Int.min acc (Depth.of_level h.level))
;;

(* {1 The store is built on one corpus and not the other}

   Made explicit and early: a suite that silently compares the SQL path
   against itself is the one failure mode that looks like success. *)
let%expect_test "search_index_is_current tells the two databases apart" =
  let sql_db, idx_db = corpus_pair () in
  printf "sql_db (no store): %b\n" (Db.search_index_is_current sql_db ~version);
  printf "idx_db (store built): %b\n" (Db.search_index_is_current idx_db ~version);
  [%expect
    {|
    sql_db (no store): false
    idx_db (store built): true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 Equivalence, one term} *)

let%expect_test "a broad floor term agrees between the two paths" =
  let sql_db, idx_db = corpus_pair () in
  ignore
    (agree
       ~label:"potion:haste"
       sql_db
       idx_db
       [ Search.Term.create (Test_search.floor Test_search.haste) ]
     : Search.Match.t list * Search.Match.t list);
  [%expect {| potion:haste: agree (6 seeds) |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* The shop position must not recover the union a bare term used to return:
   only seed 6 carries haste behind a counter, so this is also the pin that
   the store's [Shop_item] list isn't secretly [Floor_item]'s. *)
let%expect_test "the shop position agrees, and does not recover the union" =
  let sql_db, idx_db = corpus_pair () in
  let _, idx_matches =
    agree
      ~label:"shop potion:haste"
      sql_db
      idx_db
      [ Search.Term.create (Test_search.shop Test_search.haste) ]
  in
  Test_search.expect_same
    ~label:"store: shop potion:haste"
    (Int.Set.of_list [ 6 ])
    (Int.Set.of_list
       (List.map idx_matches ~f:(fun (m : Search.Match.t) -> Int.of_string m.seed)));
  [%expect
    {|
    shop potion:haste: agree (1 seeds)
    store: shop potion:haste: match (1 seeds)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* The store has no catalog row for the removed [artefact] kind, and a store
   that carries a leftover one still answers everything else. A catalog row is
   only ever read through [search_criteria_key]'s [(kind, a, b)] lookup, and
   nothing maps onto kind 2, so the row is inert rather than a wrong answer. *)
let%expect_test "the store builds no catalog row for the removed artefact kind" =
  let _sql_db, idx_db = corpus_pair () in
  let rows =
    match Db.query idx_db "select count(*) from search_criteria where kind = 2" with
    | [ n ] -> n
    | _ -> failwith "count failed"
  in
  printf "kind=2 rows: %s\n" rows;
  [%expect {| kind=2 rows: 0 |}];
  Db.close _sql_db;
  Db.close idx_db
;;

let%expect_test "a leftover artefact catalog row does not disturb the store" =
  let sql_db, idx_db = corpus_pair () in
  let version_id =
    match Db.query idx_db "select id from versions where version = '0.34.1'" with
    | [ id ] -> id
    | _ -> failwith "version not found"
  in
  Db.exec_script
    idx_db
    (sprintf
       "insert into search_criteria (version_id, kind, a_id, b_id, card) values (%s, 2, \
        null, null, 999999)"
       version_id);
  printf "store current: %b\n" (Db.search_index_is_current idx_db ~version);
  ignore
    (agree
       ~label:"an item, with a leftover artefact row in the store"
       sql_db
       idx_db
       [ Search.Term.create (Test_search.floor Test_search.haste) ]
     : Search.Match.t list * Search.Match.t list);
  [%expect
    {|
    store current: true
    an item, with a leftover artefact row in the store: agree (6 seeds)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* [name~] has no catalog row; the store resolves it to seeds instead. Pinned
   against the literal answer test_search.ml established, including the floor
   rule that keeps the only Wyrmbane, a shop's, out of a floor search. *)
let%expect_test "name_like has no catalog row, and the store still answers right" =
  let _sql_db, idx_db = corpus_pair () in
  Test_search.run idx_db [ Search.Term.create (Test_search.named "Wyrmbane") ];
  [%expect
    {|
    seeds on 0.34.1 with named like "Wyrmbane"
      [end]
    |}];
  Test_search.run
    idx_db
    [ Search.Term.create (Search.Criterion.Name_like ("Wyrmbane", Search.Criterion.Shop))
    ];
  [%expect
    {|
    seeds on 0.34.1 with named like "Wyrmbane" in a shop
      21: +8 Wyrmbane {holy, slay+4} x1 on D:4
      [end]
    |}];
  Db.close idx_db
;;

let%expect_test "a typed single-property term agrees" =
  let sql_db, idx_db = corpus_pair () in
  let _, idx_matches =
    agree
      ~label:"staff props:Conj"
      sql_db
      idx_db
      [ Search.Term.create (Test_search.props ~base_type:"staff" [ "Conj" ]) ]
  in
  Test_search.expect_same
    ~label:"store: staff props:Conj"
    (Int.Set.of_list [ 30; 31 ])
    (Int.Set.of_list
       (List.map idx_matches ~f:(fun (m : Search.Match.t) -> Int.of_string m.seed)));
  [%expect
    {|
    staff props:Conj: agree (2 seeds)
    store: staff props:Conj: match (2 seeds)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

let%expect_test "a bare single-property term agrees" =
  let sql_db, idx_db = corpus_pair () in
  let _, idx_matches =
    agree
      ~label:"props:Conj"
      sql_db
      idx_db
      [ Search.Term.create (Test_search.props [ "Conj" ]) ]
  in
  Test_search.expect_same
    ~label:"store: props:Conj"
    (Int.Set.of_list [ 30; 31; 32 ])
    (Int.Set.of_list
       (List.map idx_matches ~f:(fun (m : Search.Match.t) -> Int.of_string m.seed)));
  [%expect
    {|
    props:Conj: agree (3 seeds)
    store: props:Conj: match (3 seeds)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* An item type the fixture never interned: the store answers this exactly
   ("a key with no catalog row is a true answer about this build") rather than
   declining, which is a different code path from [name~]'s decline and worth
   its own case. *)
let%expect_test "a term matching nothing agrees" =
  let sql_db, idx_db = corpus_pair () in
  ignore
    (agree
       ~label:"scroll:teleportation"
       sql_db
       idx_db
       [ Search.Term.create
           (Search.Criterion.Item
              ( { Search.Item_type.base_type = "scroll"; sub_type = "teleportation" }
              , Search.Criterion.Floor ))
       ]
     : Search.Match.t list * Search.Match.t list);
  [%expect {| scroll:teleportation: agree (0 seeds) |}];
  Db.close sql_db;
  Db.close idx_db
;;

let%expect_test "the empty search agrees" =
  let sql_db, idx_db = corpus_pair () in
  ignore
    (agree ~label:"empty search" sql_db idx_db []
     : Search.Match.t list * Search.Match.t list);
  [%expect {| empty search: agree (19 seeds) |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 The multi-property case}

   The single most important test in the file. Seed 30 carries Conj and Alch
   on one staff; seed 31 splits the same two properties across a staff and a
   ring. If the store's [Narrowing] verify pass is broken, seed 31 leaks back
   in -- exactly the leak [Props] exists to prevent -- so this pins the exact
   member set rather than only checking cross-path agreement. *)
let%expect_test "Props demands every property on the same item, with a base type" =
  let sql_db, idx_db = corpus_pair () in
  let _, idx_matches =
    agree
      ~label:"staff props:Conj,Alch"
      sql_db
      idx_db
      [ Search.Term.create (Test_search.props ~base_type:"staff" [ "Conj"; "Alch" ]) ]
  in
  Test_search.expect_same
    ~label:"store: staff props:Conj,Alch"
    (Int.Set.of_list [ 30 ])
    (Int.Set.of_list
       (List.map idx_matches ~f:(fun (m : Search.Match.t) -> Int.of_string m.seed)));
  [%expect
    {|
    staff props:Conj,Alch: agree (1 seeds)
    store: staff props:Conj,Alch: match (1 seeds)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

let%expect_test "Props demands every property on the same item, without a base type" =
  let sql_db, idx_db = corpus_pair () in
  let _, idx_matches =
    agree
      ~label:"props:Conj,Alch"
      sql_db
      idx_db
      [ Search.Term.create (Test_search.props [ "Conj"; "Alch" ]) ]
  in
  Test_search.expect_same
    ~label:"store: props:Conj,Alch"
    (Int.Set.of_list [ 30; 32 ])
    (Int.Set.of_list
       (List.map idx_matches ~f:(fun (m : Search.Match.t) -> Int.of_string m.seed)));
  [%expect
    {|
    props:Conj,Alch: agree (2 seeds)
    store: props:Conj,Alch: match (2 seeds)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 Count thresholds}

   Seed 6 has two potions of haste on the floor and one behind a counter --
   three by a union the vocabulary no longer spells -- and must answer neither
   [3x potion:haste] nor [3x shop potion:haste]. The store must reproduce that
   exact break rather than recovering the union via its own [count] field. *)
let%expect_test "3x potion:haste excludes seed 6 on both positions, in the store too" =
  let sql_db, idx_db = corpus_pair () in
  let _, idx_floor =
    agree
      ~label:"3x potion:haste"
      sql_db
      idx_db
      [ Search.Term.create ~min_count:3 (Test_search.floor Test_search.haste) ]
  in
  let _, idx_shop =
    agree
      ~label:"3x shop potion:haste"
      sql_db
      idx_db
      [ Search.Term.create ~min_count:3 (Test_search.shop Test_search.haste) ]
  in
  let has_seed matches seed =
    List.exists matches ~f:(fun (m : Search.Match.t) ->
      String.equal m.Search.Match.seed seed)
  in
  printf "seed 6 answers 3x floor haste: %b\n" (has_seed idx_floor "6");
  printf "seed 6 answers 3x shop haste: %b\n" (has_seed idx_shop "6");
  [%expect
    {|
    3x potion:haste: agree (4 seeds)
    3x shop potion:haste: agree (0 seeds)
    seed 6 answers 3x floor haste: false
    seed 6 answers 3x shop haste: false
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* The synthetic fixture's residues put [min_count] on both sides of the
   driver choice ([driver_rank] pushes any [min_count > 1] term to the back),
   so this exercises the store's per-criterion [count] threshold the same way
   test_search.ml's naive-reference tests do for the SQL rewrite, but against
   the store instead. *)
let%expect_test "min_count thresholds agree, alone and together" =
  let sql_db, idx_db = synth_pair () in
  ignore
    (agree
       ~label:"3x potion:haste"
       sql_db
       idx_db
       [ Search.Term.create ~min_count:3 (Test_search.floor Test_search.haste) ]
     : Search.Match.t list * Search.Match.t list);
  ignore
    (agree
       ~label:"2x shop potion:haste"
       sql_db
       idx_db
       [ Search.Term.create ~min_count:2 (Test_search.shop Test_search.haste) ]
     : Search.Match.t list * Search.Match.t list);
  ignore
    (agree
       ~label:"3x potion:haste & 2x shop potion:haste"
       sql_db
       idx_db
       [ Search.Term.create ~min_count:3 (Test_search.floor Test_search.haste)
       ; Search.Term.create ~min_count:2 (Test_search.shop Test_search.haste)
       ]
     : Search.Match.t list * Search.Match.t list);
  [%expect
    {|
    3x potion:haste: agree (10 seeds)
    2x shop potion:haste: agree (12 seeds)
    3x potion:haste & 2x shop potion:haste: agree (3 seeds)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 Conjunctions} *)

let%expect_test "two- and three-term conjunctions agree" =
  let sql_db, idx_db = synth_pair () in
  ignore
    (agree
       ~label:"potion:haste & enter_shop"
       sql_db
       idx_db
       [ Search.Term.create (Test_search.floor Test_search.haste)
       ; Search.Term.create (Search.Criterion.Feature "enter_shop")
       ]
     : Search.Match.t list * Search.Match.t list);
  ignore
    (agree
       ~label:"digging & scroll:acquirement & potion:haste"
       sql_db
       idx_db
       [ Search.Term.create (Test_search.floor Test_search.digging)
       ; Search.Term.create (Test_search.floor Test_search.acquirement)
       ; Search.Term.create (Test_search.floor Test_search.haste)
       ]
     : Search.Match.t list * Search.Match.t list);
  [%expect
    {|
    potion:haste & enter_shop: agree (10 seeds)
    digging & scroll:acquirement & potion:haste: agree (1 seeds)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* The store picks its driver by measured [card], not by term order -- unlike
   the SQL path's static [driver_rank] heuristic -- so typing the rare term
   second must not change the answer. *)
let%expect_test "conjunction order does not change the answer, in either path" =
  let sql_db, idx_db = synth_pair () in
  let rare_first =
    [ Search.Term.create (Test_search.floor Test_search.digging)
    ; Search.Term.create (Test_search.floor Test_search.haste)
    ]
  in
  let common_first =
    [ Search.Term.create (Test_search.floor Test_search.haste)
    ; Search.Term.create (Test_search.floor Test_search.digging)
    ]
  in
  let _, rare_first_idx =
    agree ~label:"digging & potion:haste" sql_db idx_db rare_first
  in
  let _, common_first_idx =
    agree ~label:"potion:haste & digging" sql_db idx_db common_first
  in
  printf
    "store order-independent: %b\n"
    (Set.equal (seed_set rare_first_idx) (seed_set common_first_idx));
  [%expect
    {|
    digging & potion:haste: agree (6 seeds)
    potion:haste & digging: agree (6 seeds)
    store order-independent: true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* A [name~] beside a store term, in both orders: only seed 3 carries both
   floor haste and a name containing "Throatcutter". *)
let%expect_test "a store term beside name~ still agrees, in both term orders" =
  let sql_db, idx_db = corpus_pair () in
  let name_first =
    [ Search.Term.create (Test_search.named "Throatcutter")
    ; Search.Term.create (Test_search.floor Test_search.haste)
    ]
  in
  let item_first =
    [ Search.Term.create (Test_search.floor Test_search.haste)
    ; Search.Term.create (Test_search.named "Throatcutter")
    ]
  in
  let _, idx_name_first =
    agree ~label:"name~Throatcutter & potion:haste" sql_db idx_db name_first
  in
  ignore
    (agree ~label:"potion:haste & name~Throatcutter" sql_db idx_db item_first
     : Search.Match.t list * Search.Match.t list);
  Test_search.expect_same
    ~label:"store: name~Throatcutter & potion:haste"
    (Int.Set.of_list [ 3 ])
    (Int.Set.of_list
       (List.map idx_name_first ~f:(fun (m : Search.Match.t) -> Int.of_string m.seed)));
  [%expect
    {|
    name~Throatcutter & potion:haste: agree (1 seeds)
    potion:haste & name~Throatcutter: agree (1 seeds)
    store: name~Throatcutter & potion:haste: match (1 seeds)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 Rank.Shallowest} *)

let%expect_test "Shallowest ranking agrees, single term" =
  let sql_db, idx_db = corpus_pair () in
  let sql_matches, idx_matches =
    agree
      ~rank:Search.Rank.Shallowest
      ~label:"potion:haste"
      sql_db
      idx_db
      [ Search.Term.create (Test_search.floor Test_search.haste) ]
  in
  printf
    "store depths non-decreasing: %b\n"
    (List.is_sorted (List.map idx_matches ~f:match_depth) ~compare:Int.compare);
  printf
    "depth multisets equal: %b\n"
    (List.equal
       Int.equal
       (List.sort (List.map sql_matches ~f:match_depth) ~compare:Int.compare)
       (List.sort (List.map idx_matches ~f:match_depth) ~compare:Int.compare));
  [%expect
    {|
    potion:haste: agree (6 seeds)
    store depths non-decreasing: true
    depth multisets equal: true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* Depth is stored per criterion, so the store answers [Shallowest] without
   reaching [entries] -- [candidate_depth] takes the min over every term's
   posting, not just the driver's own. This is the fixture that would catch a
   regression to "the driver's own depth": digging is rarer than haste, so the
   store drives on it, but seed 501's shallowest evidence is haste's, seven
   levels above where its own digging sits. Seeds 502-504 carry haste alone,
   just to inflate haste's card enough that digging stays the smaller list. *)
let%expect_test
    "Shallowest ranking agrees when a non-driver's hit is shallower than the driver's"
  =
  let lines =
    [ {|#SEED#((format 4)(version "0.34.1")(seed "500")(level "D:3")(cats (items (((base_type "wand")(kind "item")(name "wand of digging")(quantity 1)(sub_type "digging")(text "wand of digging"))))))|}
    ; {|#SEED#((format 4)(version "0.34.1")(seed "500")(level "D:5")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
    ; {|#SEED#((format 4)(version "0.34.1")(seed "501")(level "D:7")(cats (items (((base_type "wand")(kind "item")(name "wand of digging")(quantity 1)(sub_type "digging")(text "wand of digging"))))))|}
    ; {|#SEED#((format 4)(version "0.34.1")(seed "501")(level "D:1")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
    ; {|#SEED#((format 4)(version "0.34.1")(seed "502")(level "D:2")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
    ; {|#SEED#((format 4)(version "0.34.1")(seed "503")(level "D:4")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
    ; {|#SEED#((format 4)(version "0.34.1")(seed "504")(level "D:6")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
    ]
  in
  let sql_db, idx_db = fresh_pair (parse_records lines) in
  let sql_matches, idx_matches =
    agree
      ~rank:Search.Rank.Shallowest
      ~label:"digging & potion:haste"
      sql_db
      idx_db
      [ Search.Term.create (Test_search.floor Test_search.digging)
      ; Search.Term.create (Test_search.floor Test_search.haste)
      ]
  in
  printf
    "store depths, in order: %s\n"
    (Sexp.to_string_hum ([%sexp_of: int list] (List.map idx_matches ~f:match_depth)));
  printf
    "store depths non-decreasing: %b\n"
    (List.is_sorted (List.map idx_matches ~f:match_depth) ~compare:Int.compare);
  printf
    "depth multisets equal: %b\n"
    (List.equal
       Int.equal
       (List.sort (List.map sql_matches ~f:match_depth) ~compare:Int.compare)
       (List.sort (List.map idx_matches ~f:match_depth) ~compare:Int.compare));
  [%expect
    {|
    digging & potion:haste: agree (2 seeds)
    store depths, in order: (1 3)
    store depths non-decreasing: true
    depth multisets equal: true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* Before [declines] released it, a narrowing term sent every [Shallowest]
   search to SQL, so the store was never the path that ranked one. The fallback
   hides that: [search_seeds_store] is the observable, since [search_seeds]
   degrades to SQL silently. *)
let%expect_test "a narrowing term no longer declines under Shallowest" =
  let sql_db, idx_db = corpus_pair () in
  let search =
    Search.create
      ~version
      ~terms:[ Search.Term.create (Test_search.props [ "Conj"; "Alch" ]) ]
      ~page:(Query.Page.create ~limit:1000 ())
      ()
  in
  printf
    "store answers: %b\n"
    (Option.is_some
       (Or_error.ok_exn
          (Db.search_seeds_store idx_db search ~rank:Search.Rank.Shallowest)));
  [%expect {| store answers: true |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* A multi-property term's per-property posting lists dip shallower than the
   item carrying both. Seed 700's Conj staff sits on D:2 and its Alch ring on
   D:3, but nothing carries both until D:6; the min over the two lists is 2, the
   answer is 6. Seed 701's item is at D:5 and seed 702's at D:3. [verify]
   supplies the same-item depth, and this pins it: the store's order must equal
   SQL's, and its depths must be the hit depths. *)
let%expect_test "Shallowest ranks a narrowing term by its same-item depth" =
  let lines =
    [ {|#SEED#((format 4)(version "0.34.1")(seed "700")(level "D:2")(cats (items (((artefact t)(artprops ((Conj 1)))(base_type "staff")(kind "item")(name "staff \"A\" {Conj}")(quantity 1)(sub_type "fire")(text "staff A"))))))|}
    ; {|#SEED#((format 4)(version "0.34.1")(seed "700")(level "D:3")(cats (items (((artefact t)(artprops ((Alch 1)))(base_type "jewellery")(kind "item")(name "ring \"B\" {Alch}")(quantity 1)(sub_type "ring")(text "ring B"))))))|}
    ; {|#SEED#((format 4)(version "0.34.1")(seed "700")(level "D:6")(cats (items (((artefact t)(artprops ((Conj 1)(Alch 1)))(base_type "armour")(kind "item")(name "+1 robe of C {Conj Alch}")(plus 1)(quantity 1)(sub_type "robe")(text "+1 robe of C"))))))|}
    ; {|#SEED#((format 4)(version "0.34.1")(seed "701")(level "D:5")(cats (items (((artefact t)(artprops ((Conj 1)(Alch 1)))(base_type "armour")(kind "item")(name "+0 robe of D {Conj Alch}")(quantity 1)(sub_type "robe")(text "+0 robe of D"))))))|}
    ; {|#SEED#((format 4)(version "0.34.1")(seed "702")(level "D:3")(cats (items (((artefact t)(artprops ((Conj 1)(Alch 1)))(base_type "armour")(kind "item")(name "+0 robe of E {Conj Alch}")(quantity 1)(sub_type "robe")(text "+0 robe of E"))))))|}
    ]
  in
  let sql_db, idx_db = fresh_pair (parse_records lines) in
  let terms = [ Search.Term.create (Test_search.props [ "Conj"; "Alch" ]) ] in
  let search =
    Search.create ~version ~terms ~page:(Query.Page.create ~limit:1000 ()) ()
  in
  let store_matches =
    match
      Or_error.ok_exn (Db.search_seeds_store idx_db search ~rank:Search.Rank.Shallowest)
    with
    | Some (matches, _) -> matches
    | None -> failwith "the store declined a narrowing Shallowest search"
  in
  let sql_matches =
    fst (Or_error.ok_exn (Db.search_seeds_sql sql_db search ~rank:Search.Rank.Shallowest))
  in
  let seeds matches = List.map matches ~f:(fun (m : Search.Match.t) -> m.seed) in
  let depths matches = List.map matches ~f:match_depth in
  printf "store seeds: %s\n" (String.concat ~sep:"," (seeds store_matches));
  printf "sql seeds:   %s\n" (String.concat ~sep:"," (seeds sql_matches));
  printf
    "store order equals sql order: %b\n"
    ([%equal: string list] (seeds store_matches) (seeds sql_matches));
  printf
    "store depths: %s\n"
    (Sexp.to_string_hum ([%sexp_of: int list] (depths store_matches)));
  printf
    "store depths non-decreasing: %b\n"
    (List.is_sorted (depths store_matches) ~compare:Int.compare);
  [%expect
    {|
    store seeds: 702,701,700
    sql seeds:   702,701,700
    store order equals sql order: true
    store depths: (3 5 6)
    store depths non-decreasing: true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* Known gap: [Search.Rank.sort_limit] is 5,000, so "[Shallowest] is uncapped
   on the store path" cannot be demonstrated on a fixture this size without
   ingesting 5,001 seeds into an expect test, which is the wrong trade. To
   test it for real would need a fixture at or beyond [sort_limit], run
   against the store, showing it still returns a fully sorted result rather
   than refusing the way the SQL path's [search_seeds_ranked] does at that same
   threshold -- i.e. that the store's cap (if any) is a different, larger, or
   absent bound rather than the same 5,000. Not attempted here. *)

(* {1 Paging} *)

(* Mints the next cursor exactly as lib/web/views.ml does: [Rank.Seed] pages by
   keyset (the last match's own seed), any other rank by an offset into the
   ranked order (previously consumed count plus this page's length). *)
let next_cursor ~rank ~prev_after ~(matches : Search.Match.t list) =
  if Search.Rank.equal rank Search.Rank.Seed
  then (List.last_exn matches).Search.Match.seed
  else (
    let consumed =
      Option.value_map prev_after ~default:0 ~f:(fun s ->
        Option.value (Int.of_string_opt s) ~default:0)
    in
    Int.to_string (consumed + List.length matches))
;;

let collect_pages db terms ~rank ~limit =
  let rec loop after acc =
    let search =
      Search.create ~version ~terms ~page:(Query.Page.create ?after ~limit ()) ()
    in
    let matches, more = Or_error.ok_exn (Db.search_seeds db search ~rank) in
    let acc = acc @ matches in
    match more with
    | `End -> acc
    | `More -> loop (Some (next_cursor ~rank ~prev_after:after ~matches)) acc
  in
  loop None []
;;

let%expect_test "paging follows the web layer's cursor exactly, both ranks, both paths" =
  let sql_db, idx_db = corpus_pair () in
  let terms = [ Search.Term.create (Test_search.floor Test_search.haste) ] in
  let whole db rank =
    let search =
      Search.create ~version ~terms ~page:(Query.Page.create ~limit:1000 ()) ()
    in
    match Or_error.ok_exn (Db.search_seeds db search ~rank) with
    | matches, `End -> seed_set matches
    | _, `More -> failwith "fixture too small a claim; whole-set page truncated"
  in
  List.iter [ Search.Rank.Seed; Search.Rank.Shallowest ] ~f:(fun rank ->
    let expected_sql = whole sql_db rank in
    let expected_idx = whole idx_db rank in
    List.iter [ 1; 2 ] ~f:(fun limit ->
      List.iter
        [ "sql", sql_db, expected_sql; "store", idx_db, expected_idx ]
        ~f:(fun (which, db, expected) ->
          let paged = collect_pages db terms ~rank ~limit in
          let seeds =
            List.map paged ~f:(fun (m : Search.Match.t) -> m.Search.Match.seed)
          in
          let no_dupes =
            List.length seeds
            = List.length (List.dedup_and_sort seeds ~compare:String.compare)
          in
          let matches_whole = Set.equal (String.Set.of_list seeds) expected in
          printf
            "%s rank=%-10s limit=%d %-5s no_dupes=%b matches_whole=%b\n"
            which
            (Search.Rank.to_string rank)
            limit
            which
            no_dupes
            matches_whole)));
  [%expect
    {|
    sql rank=seed       limit=1 sql   no_dupes=true matches_whole=true
    store rank=seed       limit=1 store no_dupes=true matches_whole=true
    sql rank=seed       limit=2 sql   no_dupes=true matches_whole=true
    store rank=seed       limit=2 store no_dupes=true matches_whole=true
    sql rank=shallowest limit=1 sql   no_dupes=true matches_whole=true
    store rank=shallowest limit=1 store no_dupes=true matches_whole=true
    sql rank=shallowest limit=2 sql   no_dupes=true matches_whole=true
    store rank=shallowest limit=2 store no_dupes=true matches_whole=true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 Round-trip cardinality}

   Already verified once by hand against the 10,000-seed 0.34.1 corpus.db, so
   this is the small in-fixture version, guarding against a regression rather
   than covering new ground: for every catalog row, [card] must equal the sum
   of its posting blocks' lengths and the count of distinct seeds the same
   criterion finds through the SQL path. *)
let string_of_id db id_str =
  match Db.query db (sprintf "select val from strings where id = %s" id_str) with
  | [ v ] -> v
  | _ -> failwith (sprintf "strings id %s not found" id_str)
;;

(* A brand row is a (base type, ego) superset list, not a criterion: the
   criterion always carries the item, so no single criterion has this row's
   member set. Its card is checked against a direct SQL count instead. *)
let criterion_of_row (kind : Criterion_id.Kind.t) a b : Search.Criterion.t option =
  match kind with
  | Criterion_id.Kind.Floor_item ->
    Some
      (Search.Criterion.Item
         ( { Search.Item_type.base_type = Option.value_exn a
           ; sub_type = Option.value_exn b
           }
         , Search.Criterion.Floor ))
  | Criterion_id.Kind.Shop_item ->
    Some
      (Search.Criterion.Item
         ( { Search.Item_type.base_type = Option.value_exn a
           ; sub_type = Option.value_exn b
           }
         , Search.Criterion.Shop ))
  | Criterion_id.Kind.Floor_prop ->
    Some
      (Search.Criterion.Props
         { base_type = a
         ; props = [ Option.value_exn b ]
         ; position = Search.Criterion.Floor
         })
  | Criterion_id.Kind.Shop_prop ->
    Some
      (Search.Criterion.Props
         { base_type = a
         ; props = [ Option.value_exn b ]
         ; position = Search.Criterion.Shop
         })
  | Criterion_id.Kind.Floor_brand | Criterion_id.Kind.Shop_brand -> None
;;

let brand_seed_count db ~version_id kind a b =
  let position =
    match kind with
    | Criterion_id.Kind.Floor_brand -> "is null"
    | Criterion_id.Kind.Shop_brand -> "is not null"
    | _ -> failwith "not a brand kind"
  in
  sprintf
    "select count(distinct e.seed) from entries e where e.version_id = %s and \
     e.base_type_id = (select id from strings where val = '%s') and e.ego_id = (select \
     id from strings where val = '%s') and e.cost %s"
    version_id
    (Option.value_exn a)
    (Option.value_exn b)
    position
  |> Db.query db
  |> List.hd_exn
  |> Int.of_string
;;

let%expect_test "card, postings, and an independent SQL count agree for every catalog row"
  =
  let sql_db, idx_db = corpus_pair () in
  let version_id =
    match Db.query idx_db "select id from versions where version = '0.34.1'" with
    | [ id ] -> id
    | _ -> failwith "version not found"
  in
  let rows =
    Db.query
      idx_db
      (sprintf
         "select id, kind, a_id, b_id, card from search_criteria where version_id = %s \
          order by id"
         version_id)
  in
  let mismatches =
    List.filter_map rows ~f:(fun row ->
      match String.split row ~on:'|' with
      | [ id; kind; a_id; b_id; card ] ->
        let criterion_id = Int.of_string id in
        let kind = Option.value_exn (Criterion_id.Kind.of_int (Int.of_string kind)) in
        let a = if String.is_empty a_id then None else Some (string_of_id idx_db a_id) in
        let b = if String.is_empty b_id then None else Some (string_of_id idx_db b_id) in
        let card = Int.of_string card in
        let posting_n =
          Db.query
            idx_db
            (sprintf
               "select coalesce(sum(n), 0) from search_postings where criterion_id = %d"
               criterion_id)
          |> List.hd_exn
          |> Int.of_string
        in
        let label, independent =
          match criterion_of_row kind a b with
          | None ->
            ( Sexp.to_string_hum (Criterion_id.Kind.sexp_of_t kind)
            , brand_seed_count idx_db ~version_id kind a b )
          | Some criterion ->
            let search =
              Search.create
                ~version
                ~terms:[ Search.Term.create criterion ]
                ~page:(Query.Page.create ~limit:1000 ())
                ()
            in
            ( Search.Criterion.to_string criterion
            , (match
                 Or_error.ok_exn (Db.search_seeds sql_db search ~rank:Search.Rank.Seed)
               with
               | matches, `End -> List.length matches
               | _, `More ->
                 failwith "fixture too large for a single page; raise the test limit") )
        in
        if card = posting_n && card = independent
        then None
        else
          Some
            (sprintf
               "%s: card=%d postings=%d independent=%d"
               label
               card
               posting_n
               independent)
      | _ -> failwith "malformed search_criteria row")
  in
  printf "checked %d catalog rows\n" (List.length rows);
  if List.is_empty mismatches
  then print_endline "0 mismatches"
  else List.iter mismatches ~f:print_endline;
  [%expect
    {|
    checked 31 catalog rows
    0 mismatches
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 Brands}

   A brand term is the second [Narrowing] criterion: the item's own list and the
   brand's, intersected, then re-checked against SQL. The leak case is seed 41
   (a plain quick blade and a distortion dagger, on different levels) -- the
   store's intersection admits it, and [verify] is what removes it. *)

let%expect_test "a Brand agrees between the two paths, leak case included" =
  let sql_db, idx_db = corpus_pair () in
  let _, idx_matches =
    agree
      ~label:"weapon:quick blade ego:distortion"
      sql_db
      idx_db
      [ Search.Term.create (Test_search.brand "weapon" "quick blade" "distortion") ]
  in
  Test_search.expect_same
    ~label:"store: quick blade of distortion"
    (Int.Set.of_list [ 45; 49 ])
    (Int.Set.of_list
       (List.map idx_matches ~f:(fun (m : Search.Match.t) -> Int.of_string m.seed)));
  Db.close sql_db;
  Db.close idx_db;
  [%expect
    {|
    weapon:quick blade ego:distortion: agree (2 seeds)
    store: quick blade of distortion: match (2 seeds)
    |}]
;;

let%expect_test "a Brand with no sub type agrees between the two paths" =
  let sql_db, idx_db = corpus_pair () in
  ignore
    (agree
       ~label:"weapon ego:distortion"
       sql_db
       idx_db
       [ Search.Term.create
           (Search.Criterion.Brand
              { base_type = "weapon"
              ; sub_type = None
              ; word = "distortion"
              ; position = Search.Criterion.Floor
              })
       ]);
  Db.close sql_db;
  Db.close idx_db;
  [%expect {| weapon ego:distortion: agree (3 seeds) |}]
;;

let%expect_test "a shop Brand agrees between the two paths" =
  let sql_db, idx_db = corpus_pair () in
  ignore
    (agree
       ~label:"shop weapon:quick blade ego:distortion"
       sql_db
       idx_db
       [ Search.Term.create
           (Test_search.brand
              ~position:Search.Criterion.Shop
              "weapon"
              "quick blade"
              "distortion")
       ]
     : Search.Match.t list * Search.Match.t list);
  [%expect {| shop weapon:quick blade ego:distortion: agree (1 seeds) |}];
  Db.close sql_db;
  Db.close idx_db
;;

let%expect_test "an armour Brand agrees between the two paths" =
  let sql_db, idx_db = corpus_pair () in
  ignore
    (agree
       ~label:"armour:robe ego:fire resistance"
       sql_db
       idx_db
       [ Search.Term.create (Test_search.brand "armour" "robe" "fire resistance") ]
     : Search.Match.t list * Search.Match.t list);
  [%expect {| armour:robe ego:fire resistance: agree (1 seeds) |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* The store built before brand lists existed. Its currency mark is a seed
   count, which a vocabulary addition does not move, so it reports current
   while holding no row for the new kind -- and a missing row used to mean
   "the build holds none", which would answer a page of nothing (or of only
   the deep cohort) over a corpus that holds the blades. The store declines
   instead, and the SQL path answers. *)
let%expect_test "a store with no brand rows declines rather than answering from absence" =
  let sql_db, idx_db = corpus_pair () in
  Db.exec_script
    idx_db
    "delete from search_postings where criterion_id in (select id from search_criteria \
     where kind in (5, 6))";
  Db.exec_script idx_db "delete from search_criteria where kind in (5, 6)";
  printf "store current: %b\n" (Db.search_index_is_current idx_db ~version);
  let search =
    Search.create
      ~version
      ~terms:
        [ Search.Term.create (Test_search.brand "weapon" "quick blade" "distortion") ]
      ()
  in
  printf
    "store path declined: %b\n"
    (Or_error.ok_exn (Db.search_seeds_store idx_db search ~rank:Search.Rank.Seed)
     |> Option.is_none);
  ignore
    (agree
       ~label:"weapon:quick blade ego:distortion, no brand rows"
       sql_db
       idx_db
       [ Search.Term.create (Test_search.brand "weapon" "quick blade" "distortion") ]
     : Search.Match.t list * Search.Match.t list);
  Db.close sql_db;
  Db.close idx_db;
  [%expect
    {|
    store current: true
    store path declined: true
    weapon:quick blade ego:distortion, no brand rows: agree (2 seeds)
    |}]
;;

(* {1 Staleness and fallback} *)

let%expect_test "an ingest after the build stales the store, and the fallback is right" =
  let idx_db = Test_search.fresh_db () in
  Or_error.ok_exn (Db.build_search_index idx_db ~version);
  let extra =
    parse_records
      [ {|#SEED#((format 4)(version "0.34.1")(seed "40")(level "D:2")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
      ]
  in
  ignore (Db.write_batch idx_db extra : Db.Counts.t);
  printf
    "search_index_is_current after the ingest: %b\n"
    (Db.search_index_is_current idx_db ~version);
  let sql_db = Test_search.fresh_db () in
  ignore (Db.write_batch sql_db extra : Db.Counts.t);
  let _, idx_matches =
    agree
      ~label:"potion:haste, after a fill the store missed"
      sql_db
      idx_db
      [ Search.Term.create (Test_search.floor Test_search.haste) ]
  in
  printf
    "new seed 40 present: %b\n"
    (List.exists idx_matches ~f:(fun (m : Search.Match.t) ->
       String.equal m.Search.Match.seed "40"));
  [%expect
    {|
    search_index_is_current after the ingest: false
    potion:haste, after a fill the store missed: agree (7 seeds)
    new seed 40 present: true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 Rebuild is idempotent} *)

let%expect_test "rebuilding the store twice reproduces the same ordinals and results" =
  let db = Test_search.fresh_db () in
  Or_error.ok_exn (Db.build_search_index db ~version);
  let ordinals () = Db.query db "select seed, ord from seed_ordinals order by seed" in
  let before_ordinals = ordinals () in
  let before_matches =
    Test_search.matched_set
      db
      [ Search.Term.create (Test_search.floor Test_search.haste) ]
  in
  Or_error.ok_exn (Db.build_search_index db ~version);
  let after_ordinals = ordinals () in
  let after_matches =
    Test_search.matched_set
      db
      [ Search.Term.create (Test_search.floor Test_search.haste) ]
  in
  printf
    "ordinals byte-identical: %b\n"
    (List.equal String.equal before_ordinals after_ordinals);
  printf "results unchanged: %b\n" (Set.equal before_matches after_matches);
  [%expect
    {|
    ordinals byte-identical: true
    results unchanged: true
    |}];
  Db.close db
;;

(* {1 A fill appends} *)

(* Seed "0" sorts before every existing seed numerically ([length, seed]
   order); seed "400" sorts after all of them. Both must still take ordinals
   above the old maximum -- an ascending fill is an append in ordinal terms
   even when, as with "0", it is not an append in seed-number terms. *)
let%expect_test "a fill appends new seeds without moving existing ordinals" =
  let db = Test_search.fresh_db () in
  Or_error.ok_exn (Db.build_search_index db ~version);
  let existing_seeds =
    List.map Test_search.corpus ~f:(fun line -> Or_error.ok_exn (Reader.parse_line line))
    |> List.map ~f:(fun (r : Seed_corpus.Record.t) -> r.seed)
    |> List.dedup_and_sort ~compare:String.compare
  in
  let ordinal_of seed =
    match
      Db.query
        db
        (sprintf
           "select ord from seed_ordinals where seed = '%s' and version_id = (select id \
            from versions where version = '0.34.1')"
           seed)
    with
    | [ ord ] -> Int.of_string ord
    | _ -> failwith (sprintf "seed %s has no ordinal" seed)
  in
  let before = List.map existing_seeds ~f:(fun seed -> seed, ordinal_of seed) in
  let max_before =
    List.fold before ~init:Int.min_value ~f:(fun acc (_, ord) -> Int.max acc ord)
  in
  let extra =
    parse_records
      [ {|#SEED#((format 4)(version "0.34.1")(seed "0")(level "D:1")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
      ; {|#SEED#((format 4)(version "0.34.1")(seed "400")(level "D:1")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
      ]
  in
  ignore (Db.write_batch db extra : Db.Counts.t);
  Or_error.ok_exn (Db.build_search_index db ~version);
  let unchanged = List.for_all before ~f:(fun (seed, ord) -> ordinal_of seed = ord) in
  let new_ords = List.map [ "0"; "400" ] ~f:ordinal_of in
  printf "existing ordinals unchanged: %b\n" unchanged;
  printf
    "new ordinals above the old max: %b\n"
    (List.for_all new_ords ~f:(fun ord -> ord > max_before));
  [%expect
    {|
    existing ordinals unchanged: true
    new ordinals above the old max: true
    |}];
  Db.close db
;;

(* {1 Deepening: the overlay}

   A deepen is not a fill. It re-ingests a seed the store already covers, at
   levels the build never saw, and leaves the seed count untouched -- which is
   why currency counts seeds and not [entries] rows, and why the store then has
   to make up the difference for the deepened cohort itself.

   The fixture deepens two of the 14 corpus seeds past [Fill_depth.shallow]:

   - seed 1 gains a floor long sword (a criterion with a catalog row it was not
     in) and two more potions of haste (pushing its floor-haste count from 1 to
     3);
   - seed 4 gains a floor wand of digging -- a criterion with *no* catalog row
     in this build, since the only digging in the base corpus is behind seed
     2's counter -- and another potion of haste, which must not disturb the
     [D:1] its shallowest haste already sits on.

   Everything the base corpus answers must keep its answer; everything the deep
   levels add must appear. *)

let deep_records =
  [ {|#SEED#((format 4)(version "0.34.1")(seed "1")(level "Lair:3")(cats (items (((artefact t)(base_type "weapon")(kind "item")(name "+3 Fooblade {holy}")(plus 3)(quantity 1)(sub_type "long sword")(text "+3 Fooblade"))((base_type "potion")(kind "item")(name "2 potions of haste")(quantity 2)(sub_type "haste")(text "2 potions of haste"))))))|}
  ; {|#SEED#((format 4)(version "0.34.1")(seed "4")(level "Lair:2")(cats (items (((base_type "wand")(kind "item")(name "wand of digging (3)")(quantity 1)(sub_type "digging")(text "wand of digging (3)"))((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
  ]
;;

(* The store is built *before* the deep levels land, which is the whole point:
   [idx_db] holds a build that predates them, [sql_db] holds none at all. *)
let deepened_pair () =
  let sql_db, idx_db = corpus_pair () in
  List.iter [ sql_db; idx_db ] ~f:(fun db ->
    ignore (Db.write_batch db (parse_records deep_records) : Db.Counts.t);
    Or_error.ok_exn (Db.rebuild_fts db));
  sql_db, idx_db
;;

let cohort_size db =
  match
    Db.query
      db
      (sprintf
         "select count(*) from seed_fills where depth > %d and version_id = (select id \
          from versions where version = '0.34.1')"
         Seed_corpus.Fill_depth.shallow)
  with
  | [ n ] -> Int.of_string n
  | _ -> failwith "cohort count failed"
;;

(* {2 Currency} *)

let%expect_test "a deepen leaves the store current; a fill and a drop do not" =
  let _sql_db, idx_db = corpus_pair () in
  printf "after the build: %b\n" (Db.search_index_is_current idx_db ~version);
  ignore (Db.write_batch idx_db (parse_records deep_records) : Db.Counts.t);
  printf "deep cohort: %d seeds\n" (cohort_size idx_db);
  printf "after a deepen: %b\n" (Db.search_index_is_current idx_db ~version);
  ignore
    (Db.write_batch
       idx_db
       (parse_records
          [ {|#SEED#((format 4)(version "0.34.1")(seed "41")(level "D:2")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
          ])
     : Db.Counts.t);
  printf "after a fill: %b\n" (Db.search_index_is_current idx_db ~version);
  [%expect
    {|
    after the build: true
    deep cohort: 2 seeds
    after a deepen: true
    after a fill: false
    |}];
  Db.close idx_db
;;

let counted_and_actual db =
  Db.query
    db
    "select (select coalesce(sum(seeds), 0) from seed_fill_counts) || ' ' || (select \
     count(*) from seed_fills)"
;;

let%expect_test "the seed counter tracks a fill, a deepen and a drop" =
  let _sql_db, idx_db = corpus_pair () in
  printf !"after the fill: %{sexp: string list}\n" (counted_and_actual idx_db);
  ignore (Db.write_batch idx_db (parse_records deep_records) : Db.Counts.t);
  printf !"after a deepen: %{sexp: string list}\n" (counted_and_actual idx_db);
  Db.exec_script
    idx_db
    "delete from seed_fills where seed = '5' and version_id = (select id from versions \
     where version = '0.34.1');";
  printf !"after a drop: %{sexp: string list}\n" (counted_and_actual idx_db);
  [%expect
    {|
    after the fill: ("19 19")
    after a deepen: ("19 19")
    after a drop: ("18 18")
    |}];
  Db.close idx_db
;;

(* Dropping seeds is the direction the old high-water mark got wrong: it lowers
   [max(entries.id)] while the mark stands still, so the store reported current
   while holding postings for seeds that no longer exist -- a false *positive*,
   the one direction this mechanism exists to rule out. *)
let%expect_test "dropping seeds stales the store" =
  let _sql_db, idx_db = corpus_pair () in
  printf "after the build: %b\n" (Db.search_index_is_current idx_db ~version);
  Db.exec_script
    idx_db
    "pragma foreign_keys = on;\n\
     delete from seed_levels where seed = '5' and version_id = (select id from versions \
     where version = '0.34.1');\n\
     delete from seed_fills where seed = '5' and version_id = (select id from versions \
     where version = '0.34.1');";
  printf "after a drop: %b\n" (Db.search_index_is_current idx_db ~version);
  [%expect
    {|
    after the build: true
    after a drop: false
    |}];
  Db.close idx_db
;;

(* A redundant re-derivation returns the same page, so the cohort itself is the
   only thing that tells a rebuild that absorbed it from one that did not. *)
let overlaid_seeds db =
  match Or_error.ok_exn (Db.search_index_cohort db ~version) with
  | None -> failwith "cohort past the cap"
  | Some seeds -> List.sort seeds ~compare:String.compare
;;

let%expect_test "a rebuild absorbs the deep cohort; a later deepen reopens it" =
  let _sql_db, idx_db = corpus_pair () in
  ignore (Db.write_batch idx_db (parse_records deep_records) : Db.Counts.t);
  printf !"deepened since the build: %{sexp: string list}\n" (overlaid_seeds idx_db);
  Or_error.ok_exn (Db.build_search_index idx_db ~version);
  printf !"after a rebuild: %{sexp: string list}\n" (overlaid_seeds idx_db);
  ignore
    (Db.write_batch
       idx_db
       (parse_records
          [ {|#SEED#((format 4)(version "0.34.1")(seed "1")(level "Lair:5")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
          ])
     : Db.Counts.t);
  printf
    !"deepened again after the rebuild: %{sexp: string list}\n"
    (overlaid_seeds idx_db);
  [%expect
    {|
    deepened since the build: (1 4)
    after a rebuild: ()
    deepened again after the rebuild: (1)
    |}];
  Db.close idx_db
;;

(* {2 The overlay answers}

   Each of these runs through [Db.search_seeds], so a [false] currency answer
   would silently route to the SQL path and make the comparison vacuous. The
   currency test above is what keeps that honest. *)

let%expect_test "a deepened seed is found through a criterion it gained deep" =
  let sql_db, idx_db = deepened_pair () in
  printf "store current: %b\n" (Db.search_index_is_current idx_db ~version);
  let _, idx_matches =
    agree
      ~label:"a floor long sword, after a deepen"
      sql_db
      idx_db
      [ Search.Term.create
          (Test_search.floor
             { Search.Item_type.base_type = "weapon"; sub_type = "long sword" })
      ]
  in
  printf
    "deepened seed 1 present: %b\n"
    (List.exists idx_matches ~f:(fun (m : Search.Match.t) -> String.equal m.seed "1"));
  [%expect
    {|
    store current: true
    a floor long sword, after a deepen: agree (3 seeds)
    deepened seed 1 present: true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* The trap the early return at [Search_index.page]'s "a true answer about this
   build" hides: the only floor wand of digging in this corpus arrives on a
   level the build never saw, so there is no catalog row for the criterion at
   all. The store's silence about a key is no longer proof of absence. *)
let%expect_test "a deepened seed is found through a criterion with no catalog row" =
  let sql_db, idx_db = deepened_pair () in
  let _, idx_matches =
    agree
      ~label:"wand:digging, no catalog row"
      sql_db
      idx_db
      [ Search.Term.create (Test_search.floor Test_search.digging) ]
  in
  Test_search.expect_same
    ~label:"store: wand:digging"
    (Int.Set.of_list [ 4 ])
    (Int.Set.of_list
       (List.map idx_matches ~f:(fun (m : Search.Match.t) -> Int.of_string m.seed)));
  [%expect
    {|
    wand:digging, no catalog row: agree (1 seeds)
    store: wand:digging: match (1 seeds)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

let%expect_test "a min_count the deep levels are what satisfy" =
  let sql_db, idx_db = deepened_pair () in
  let _, idx_matches =
    agree
      ~label:"3x potion:haste, after a deepen"
      sql_db
      idx_db
      [ Search.Term.create ~min_count:3 (Test_search.floor Test_search.haste) ]
  in
  printf
    "deepened seed 1 present: %b\n"
    (List.exists idx_matches ~f:(fun (m : Search.Match.t) -> String.equal m.seed "1"));
  [%expect
    {|
    3x potion:haste, after a deepen: agree (5 seeds)
    deepened seed 1 present: true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* Re-derivation, not union: seed 4's shallowest haste is [D:1], and its new
   [Lair:2] haste must not become its rank. A subtract-then-re-add that only
   looked at the deep levels would report 10 here. *)
let%expect_test "Shallowest takes the shallowest depth, not the deepened one" =
  let sql_db, idx_db = deepened_pair () in
  let sql_matches, idx_matches =
    agree
      ~rank:Search.Rank.Shallowest
      ~label:"potion:haste ranked, after a deepen"
      sql_db
      idx_db
      [ Search.Term.create (Test_search.floor Test_search.haste) ]
  in
  let depth_of matches seed =
    List.find_map matches ~f:(fun (m : Search.Match.t) ->
      Option.some_if (String.equal m.seed seed) (match_depth m))
  in
  printf
    "seed 4 depth: store=%s sql=%s\n"
    (Sexp.to_string ([%sexp_of: int option] (depth_of idx_matches "4")))
    (Sexp.to_string ([%sexp_of: int option] (depth_of sql_matches "4")));
  printf
    "store depths non-decreasing: %b\n"
    (List.is_sorted (List.map idx_matches ~f:match_depth) ~compare:Int.compare);
  printf
    "depth multisets equal: %b\n"
    (List.equal
       Int.equal
       (List.sort (List.map sql_matches ~f:match_depth) ~compare:Int.compare)
       (List.sort (List.map idx_matches ~f:match_depth) ~compare:Int.compare));
  [%expect
    {|
    potion:haste ranked, after a deepen: agree (6 seeds)
    seed 4 depth: store=(1) sql=(1)
    store depths non-decreasing: true
    depth multisets equal: true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {2 Paging across the cohort}

   Overlay seeds interleave with stored ones by ordinal, so a page boundary can
   fall on either side of one. A limit of 1 walks every boundary there is. *)
let%expect_test "paging across the deep cohort repeats and skips nothing" =
  let sql_db, idx_db = deepened_pair () in
  let terms = [ Search.Term.create (Test_search.floor Test_search.haste) ] in
  let whole db rank =
    let search =
      Search.create ~version ~terms ~page:(Query.Page.create ~limit:1000 ()) ()
    in
    match Or_error.ok_exn (Db.search_seeds db search ~rank) with
    | matches, `End -> seed_set matches
    | _, `More -> failwith "fixture too small a claim; whole-set page truncated"
  in
  List.iter [ Search.Rank.Seed; Search.Rank.Shallowest ] ~f:(fun rank ->
    let expected = whole sql_db rank in
    printf
      "rank=%-10s store whole-set matches sql: %b\n"
      (Search.Rank.to_string rank)
      (Set.equal (whole idx_db rank) expected);
    List.iter [ 1; 2; 3 ] ~f:(fun limit ->
      let seeds =
        List.map (collect_pages idx_db terms ~rank ~limit) ~f:(fun (m : Search.Match.t) ->
          m.Search.Match.seed)
      in
      printf
        "rank=%-10s limit=%d no_dupes=%b matches_whole=%b\n"
        (Search.Rank.to_string rank)
        limit
        (List.length seeds
         = List.length (List.dedup_and_sort seeds ~compare:String.compare))
        (Set.equal (String.Set.of_list seeds) expected)));
  [%expect
    {|
    rank=seed       store whole-set matches sql: true
    rank=seed       limit=1 no_dupes=true matches_whole=true
    rank=seed       limit=2 no_dupes=true matches_whole=true
    rank=seed       limit=3 no_dupes=true matches_whole=true
    rank=shallowest store whole-set matches sql: true
    rank=shallowest limit=1 no_dupes=true matches_whole=true
    rank=shallowest limit=2 no_dupes=true matches_whole=true
    rank=shallowest limit=3 no_dupes=true matches_whole=true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {2 Equivalence over the deepened fixture}

   The base suite's shapes, re-run against a corpus whose store is a build
   behind on two seeds. Nothing above may change its answer. *)
let%expect_test "every query shape agrees over a corpus with a deep cohort" =
  let sql_db, idx_db = deepened_pair () in
  let ignore_agree ?rank ~label terms =
    ignore
      (agree ?rank ~label sql_db idx_db terms : Search.Match.t list * Search.Match.t list)
  in
  ignore_agree
    ~label:"potion:haste"
    [ Search.Term.create (Test_search.floor Test_search.haste) ];
  ignore_agree
    ~label:"shop potion:haste"
    [ Search.Term.create (Test_search.shop Test_search.haste) ];
  ignore_agree
    ~label:"weapon:long sword"
    [ Search.Term.create
        (Test_search.floor
           { Search.Item_type.base_type = "weapon"; sub_type = "long sword" })
    ];
  ignore_agree
    ~label:"staff props:Conj,Alch"
    [ Search.Term.create (Test_search.props ~base_type:"staff" [ "Conj"; "Alch" ]) ];
  ignore_agree ~label:"props:Conj" [ Search.Term.create (Test_search.props [ "Conj" ]) ];
  ignore_agree
    ~label:"wand:digging & potion:haste"
    [ Search.Term.create (Test_search.floor Test_search.digging)
    ; Search.Term.create (Test_search.floor Test_search.haste)
    ];
  ignore_agree
    ~label:"weapon:long sword & potion:haste"
    [ Search.Term.create
        (Test_search.floor
           { Search.Item_type.base_type = "weapon"; sub_type = "long sword" })
    ; Search.Term.create (Test_search.floor Test_search.haste)
    ];
  ignore_agree
    ~rank:Search.Rank.Shallowest
    ~label:"weapon:long sword ranked"
    [ Search.Term.create
        (Test_search.floor
           { Search.Item_type.base_type = "weapon"; sub_type = "long sword" })
    ];
  ignore_agree ~label:"empty search" [];
  ignore_agree
    ~label:"scroll:teleportation"
    [ Search.Term.create
        (Search.Criterion.Item
           ( { Search.Item_type.base_type = "scroll"; sub_type = "teleportation" }
           , Search.Criterion.Floor ))
    ];
  [%expect
    {|
    potion:haste: agree (6 seeds)
    shop potion:haste: agree (1 seeds)
    weapon:long sword: agree (3 seeds)
    staff props:Conj,Alch: agree (1 seeds)
    props:Conj: agree (3 seeds)
    wand:digging & potion:haste: agree (1 seeds)
    weapon:long sword & potion:haste: agree (2 seeds)
    weapon:long sword ranked: agree (3 seeds)
    empty search: agree (19 seeds)
    scroll:teleportation: agree (0 seeds)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 The datalist vocabulary} *)

let%expect_test "the datalist agrees between the catalog and the scan" =
  List.iter
    [ "corpus", corpus_pair (); "synth", synth_pair (); "deepened", deepened_pair () ]
    ~f:(fun (label, (sql_db, idx_db)) ->
      let scan = Or_error.ok_exn (Db.distinct_criteria sql_db ~version) in
      let catalog = Or_error.ok_exn (Db.distinct_criteria idx_db ~version) in
      printf
        "%s: %s (%d options)\n"
        label
        (if [%equal: string list] scan catalog then "agree" else "DISAGREE")
        (List.length scan);
      Db.close sql_db;
      Db.close idx_db);
  [%expect
    {|
    corpus: agree (21 options)
    synth: agree (3 options)
    deepened: agree (21 options)
    |}]
;;

(* Deleting a pair's rows behind a current store is the only way to tell which
   source answered: the scan loses the pair, the catalog keeps it. *)
let%expect_test "a current store answers the datalist from its catalog" =
  let _sql_db, idx_db = corpus_pair () in
  Db.exec_script
    idx_db
    "delete from entries where base_type_id = (select id from strings where val = \
     'wand');";
  printf "store current: %b\n" (Db.search_index_is_current idx_db ~version);
  printf
    "wand:digging offered: %b\n"
    (List.mem
       (Or_error.ok_exn (Db.distinct_criteria idx_db ~version))
       "wand:digging"
       ~equal:String.equal);
  [%expect
    {|
    store current: true
    wand:digging offered: true
    |}];
  Db.close idx_db
;;

(* Reaping is randart-only, so a build holding it still offers no word for it.
   0.33.1 stores armour's harm as "harm", 0.34.1 as "Harm"; each build's own
   spelling must resolve to the one word. *)
let%expect_test "the datalist offers the brands each build holds, as words" =
  let brand_record ~version ~seed ~base_type ~sub_type ~ego ~artefact =
    sprintf
      {|#SEED#((format 4)(version "%s")(seed "%s")(level "D:2")(cats (items ((%s(base_type "%s")(branded t)(ego "%s")(kind "item")(name "x")(plus 0)(quantity 1)(sub_type "%s")(text "x"))))))|}
      version
      seed
      (if artefact then "(artefact t)" else "")
      base_type
      ego
      sub_type
  in
  let records =
    parse_records
      [ brand_record
          ~version:"0.34.1"
          ~seed:"1"
          ~base_type:"weapon"
          ~sub_type:"dagger"
          ~ego:"distort"
          ~artefact:false
      ; brand_record
          ~version:"0.34.1"
          ~seed:"2"
          ~base_type:"weapon"
          ~sub_type:"scythe"
          ~ego:"reap"
          ~artefact:true
      ; brand_record
          ~version:"0.34.1"
          ~seed:"3"
          ~base_type:"armour"
          ~sub_type:"robe"
          ~ego:"Harm"
          ~artefact:false
      ; brand_record
          ~version:"0.33.1"
          ~seed:"1"
          ~base_type:"armour"
          ~sub_type:"robe"
          ~ego:"harm"
          ~artefact:false
      ]
  in
  let old = Or_error.ok_exn (Query.Version.of_string "0.33.1") in
  let sql_db, idx_db = fresh_pair records in
  Or_error.ok_exn (Db.build_search_index idx_db ~version:old);
  List.iter
    [ "sql", sql_db; "store", idx_db ]
    ~f:(fun (label, db) ->
      List.iter [ version; old ] ~f:(fun version ->
        Or_error.ok_exn (Db.distinct_criteria db ~version)
        |> List.filter ~f:(String.is_substring ~substring:" ego:")
        |> String.concat ~sep:", "
        |> printf "%s %s: %s\n" label (Query.Version.to_string version)));
  [%expect
    {|
    sql 0.34.1: weapon ego:distortion, armour ego:harm
    sql 0.33.1: armour ego:harm
    store 0.34.1: weapon ego:distortion, armour ego:harm
    store 0.33.1: armour ego:harm
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 The SQL path alone, over a store-built corpus} *)

let%expect_test "search_seeds_sql answers from SQL even where a store is current" =
  let sql_db, idx_db = deepened_pair () in
  let terms = [ Search.Term.create (Test_search.floor Test_search.haste) ] in
  List.iter [ Search.Rank.Seed; Search.Rank.Shallowest ] ~f:(fun rank ->
    let search =
      Search.create ~version ~terms ~page:(Query.Page.create ~limit:200 ()) ()
    in
    let reference, _ = Or_error.ok_exn (Db.search_seeds sql_db search ~rank) in
    let forced, _ = Or_error.ok_exn (Db.search_seeds_sql idx_db search ~rank) in
    printf
      "%s: same seeds in the same order: %b\n"
      (Search.Rank.to_string rank)
      ([%equal: string list]
         (List.map reference ~f:(fun (m : Search.Match.t) -> m.seed))
         (List.map forced ~f:(fun (m : Search.Match.t) -> m.seed))));
  [%expect
    {|
    seed: same seeds in the same order: true
    shallowest: same seeds in the same order: true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 [name~] beside the store}

   A [name~] fragment resolves to a bounded seed set, and that set joins the
   merge as a posting list of its own. The shapes are the ones production
   traffic sends: a selective unrand name next to an item or property term. *)

let named_records =
  let hood =
    {|((artefact t)(base_type "armour")(kind "item")(name "+0 hood of the Assassin {Stlth+}")(quantity 1)(sub_type "hat")(text "+0 hood of the Assassin"))|}
  in
  let vines =
    {|((artefact t)(base_type "armour")(kind "item")(name "+0 robe of Vines {rPois}")(quantity 1)(sub_type "robe")(text "+0 robe of Vines"))|}
  in
  let conj_ring =
    {|((artefact t)(artprops ((Conj 1)))(base_type "jewellery")(kind "item")(name "ring \"Pewt\" {Conj}")(quantity 1)(sub_type "ring")(text "ring Pewt"))|}
  in
  let conj_staff =
    {|((artefact t)(artprops ((Conj 1)))(base_type "staff")(kind "item")(name "staff \"Olm\" {Conj}")(quantity 1)(sub_type "fire")(text "staff Olm"))|}
  in
  let haste =
    {|((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))|}
  in
  let shop_hood =
    {|((artefact t)(base_type "armour")(cost 900)(kind "item")(name "+0 hood of the Assassin {Stlth+}")(quantity 1)(sub_type "hat")(text "+0 hood of the Assassin"))|}
  in
  let level seed level items =
    sprintf
      {|#SEED#((format 4)(version "0.34.1")(seed "%d")(level "%s")(cats (items (%s))))|}
      seed
      level
      (String.concat items)
  in
  [ level 50 "D:2" [ hood ]
  ; level 50 "D:3" [ conj_ring ]
  ; level 51 "D:4" [ hood ]
  ; level 52 "D:1" [ vines ]
  ; level 52 "D:5" [ conj_staff ]
  ; level 53 "D:3" [ vines ]
  ; level 53 "D:6" [ hood ]
  ; level 54 "D:2" [ conj_ring; haste ]
  ; level 55 "D:2" [ hood ]
  ; level 55 "D:5" [ hood ]
  ; level 55 "D:7" [ haste ]
  ; level 56 "D:3" [ shop_hood; haste ]
  ; level 57 "D:2" [ haste ]
  ; level 57 "D:4" [ vines ]
  ]
;;

let named_pair () = fresh_pair (parse_records named_records)

let store_answers ?name_cap idx_db terms ~rank =
  let search =
    Search.create ~version ~terms ~page:(Query.Page.create ~limit:1000 ()) ()
  in
  Option.is_some (Or_error.ok_exn (Db.search_seeds_store ?name_cap idx_db search ~rank))
;;

(* Seeds agree as sets under both ranks, and under [Shallowest] the depth
   sequence agrees too: ties at one depth order by ordinal on the store and by
   seed text on SQL, so the depths are what the two must share. *)
let agree_both_ranks ~label sql_db idx_db terms =
  List.iter [ Search.Rank.Seed; Search.Rank.Shallowest ] ~f:(fun rank ->
    let label = sprintf "%s [%s]" label (Search.Rank.to_string rank) in
    let sql_matches, idx_matches = agree ~rank ~label sql_db idx_db terms in
    printf "  store answered: %b\n" (store_answers idx_db terms ~rank);
    if Search.Rank.equal rank Search.Rank.Shallowest
    then
      printf
        "  depths agree: %b\n"
        ([%equal: int list]
           (List.map sql_matches ~f:match_depth)
           (List.map idx_matches ~f:match_depth)))
;;

let hood = Test_search.named "hood of the Assassin"
let vines = Test_search.named "robe of Vines"

let%expect_test "name~ beside an item term, a property term, and another name~" =
  let sql_db, idx_db = named_pair () in
  agree_both_ranks
    ~label:"name~hood & jewellery props:Conj"
    sql_db
    idx_db
    [ Search.Term.create hood
    ; Search.Term.create (Test_search.props ~base_type:"jewellery" [ "Conj" ])
    ];
  agree_both_ranks
    ~label:"name~Vines & props:Conj"
    sql_db
    idx_db
    [ Search.Term.create vines; Search.Term.create (Test_search.props [ "Conj" ]) ];
  agree_both_ranks
    ~label:"potion:haste & name~Vines"
    sql_db
    idx_db
    [ Search.Term.create (Test_search.floor Test_search.haste); Search.Term.create vines ];
  agree_both_ranks
    ~label:"name~hood & name~Vines"
    sql_db
    idx_db
    [ Search.Term.create hood; Search.Term.create vines ];
  agree_both_ranks
    ~label:"2x name~hood"
    sql_db
    idx_db
    [ Search.Term.create ~min_count:2 hood ];
  agree_both_ranks ~label:"name~hood alone" sql_db idx_db [ Search.Term.create hood ];
  agree_both_ranks
    ~label:"name~nowhere & potion:haste"
    sql_db
    idx_db
    [ Search.Term.create (Test_search.named "nowhere")
    ; Search.Term.create (Test_search.floor Test_search.haste)
    ];
  [%expect
    {|
    name~hood & jewellery props:Conj [seed]: agree (1 seeds)
      store answered: true
    name~hood & jewellery props:Conj [shallowest]: agree (1 seeds)
      store answered: true
      depths agree: true
    name~Vines & props:Conj [seed]: agree (1 seeds)
      store answered: true
    name~Vines & props:Conj [shallowest]: agree (1 seeds)
      store answered: true
      depths agree: true
    potion:haste & name~Vines [seed]: agree (1 seeds)
      store answered: true
    potion:haste & name~Vines [shallowest]: agree (1 seeds)
      store answered: true
      depths agree: true
    name~hood & name~Vines [seed]: agree (1 seeds)
      store answered: true
    name~hood & name~Vines [shallowest]: agree (1 seeds)
      store answered: true
      depths agree: true
    2x name~hood [seed]: agree (1 seeds)
      store answered: true
    2x name~hood [shallowest]: agree (1 seeds)
      store answered: true
      depths agree: true
    name~hood alone [seed]: agree (4 seeds)
      store answered: true
    name~hood alone [shallowest]: agree (4 seeds)
      store answered: true
      depths agree: true
    name~nowhere & potion:haste [seed]: agree (0 seeds)
      store answered: true
    name~nowhere & potion:haste [shallowest]: agree (0 seeds)
      store answered: true
      depths agree: true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

let%expect_test "name~ paging follows the web layer's cursor, both ranks" =
  let sql_db, idx_db = named_pair () in
  let terms = [ Search.Term.create hood ] in
  List.iter [ Search.Rank.Seed; Search.Rank.Shallowest ] ~f:(fun rank ->
    List.iter [ 1; 2 ] ~f:(fun limit ->
      let seeds db =
        collect_pages db terms ~rank ~limit
        |> List.map ~f:(fun (m : Search.Match.t) -> m.seed)
      in
      let sql = seeds sql_db
      and store = seeds idx_db in
      printf
        "rank=%-10s limit=%d no_dupes=%b same_set=%b\n"
        (Search.Rank.to_string rank)
        limit
        (not (List.contains_dup store ~compare:String.compare))
        (Set.equal (String.Set.of_list sql) (String.Set.of_list store))));
  [%expect
    {|
    rank=seed       limit=1 no_dupes=true same_set=true
    rank=seed       limit=2 no_dupes=true same_set=true
    rank=shallowest limit=1 no_dupes=true same_set=true
    rank=shallowest limit=2 no_dupes=true same_set=true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* [name~hood] matches four seeds on the floor, so a cap of four serves it and a
   cap of three declines; the decline still answers through [search_seeds]. *)
let%expect_test "a fragment over the cap declines to SQL" =
  let sql_db, idx_db = named_pair () in
  let terms =
    [ Search.Term.create hood; Search.Term.create (Test_search.props [ "Conj" ]) ]
  in
  List.iter [ Search.Rank.Seed; Search.Rank.Shallowest ] ~f:(fun rank ->
    printf
      "%s: cap 4 answers: %b, cap 3 answers: %b\n"
      (Search.Rank.to_string rank)
      (store_answers ~name_cap:4 idx_db terms ~rank)
      (store_answers ~name_cap:3 idx_db terms ~rank));
  ignore
    (agree ~label:"name~hood & props:Conj" sql_db idx_db terms
     : Search.Match.t list * Search.Match.t list);
  [%expect
    {|
    seed: cap 4 answers: true, cap 3 answers: false
    shallowest: cap 4 answers: true, cap 3 answers: false
    name~hood & props:Conj: agree (1 seeds)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* A deepen interns names without moving the seed count, so the store stays
   current while the trigram index goes stale; the refusal has to come first. *)
let%expect_test "a stale trigram index still refuses name~ on the store path" =
  let _sql_db, idx_db = named_pair () in
  ignore
    (Db.write_batch
       idx_db
       (parse_records
          [ {|#SEED#((format 4)(version "0.34.1")(seed "51")(level "Lair:2")(cats (items (((artefact t)(base_type "weapon")(kind "item")(name "+2 Quuxblade {holy}")(plus 2)(quantity 1)(sub_type "long sword")(text "+2 Quuxblade"))))))|}
          ])
     : Db.Counts.t);
  printf "store current: %b\n" (Db.search_index_is_current idx_db ~version);
  let search =
    Search.create
      ~version
      ~terms:
        [ Search.Term.create hood
        ; Search.Term.create (Test_search.floor Test_search.haste)
        ]
      ()
  in
  (match Db.search_seeds_store idx_db search ~rank:Search.Rank.Seed with
   | Ok _ -> print_endline "served"
   | Error e ->
     printf
       "refused as stale: %b\n"
       (String.is_prefix (Error.to_string_hum e) ~prefix:Search.stale_index_tag));
  [%expect
    {|
    store current: true
    refused as stale: true
    |}];
  Db.close idx_db
;;

(* Seed 1's only Fooblade sits on Lair:3, a level the build never saw, and the
   seed is in the deep cohort; its haste is on D:1. *)
let%expect_test "name~ reaches a deepened seed through a deep-only name" =
  let sql_db, idx_db = deepened_pair () in
  let fooblade = Test_search.named "Fooblade" in
  agree_both_ranks
    ~label:"name~Fooblade & potion:haste"
    sql_db
    idx_db
    [ Search.Term.create fooblade
    ; Search.Term.create (Test_search.floor Test_search.haste)
    ];
  agree_both_ranks
    ~label:"name~Fooblade alone"
    sql_db
    idx_db
    [ Search.Term.create fooblade ];
  [%expect
    {|
    name~Fooblade & potion:haste [seed]: agree (1 seeds)
      store answered: true
    name~Fooblade & potion:haste [shallowest]: agree (1 seeds)
      store answered: true
      depths agree: true
    name~Fooblade alone [seed]: agree (1 seeds)
      store answered: true
    name~Fooblade alone [shallowest]: agree (1 seeds)
      store answered: true
      depths agree: true
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 The count ceiling}

   [Db.count_ceiling_store] is [None] when the store declines, which is how
   these tests tell the store branch from the SQL fallback. *)

let store_ceiling db criterion =
  Or_error.ok_exn (Db.count_ceiling_store db ~version criterion)
  |> [%sexp_of: int option option]
  |> Sexp.to_string
;;

let%expect_test "the store's ceiling agrees with SQL's, and declines what it cannot say" =
  let sql_db, idx_db = corpus_pair () in
  List.iter
    [ "floor haste", Test_search.floor Test_search.haste
    ; "shop haste", Test_search.shop Test_search.haste
    ; "floor digging", Test_search.floor Test_search.digging
    ; "props:Conj", Test_search.props [ "Conj" ]
    ; "props:Conj,Alch", Test_search.props [ "Conj"; "Alch" ]
    ]
    ~f:(fun (label, criterion) ->
      printf
        "%-16s sql=%s store=%s stale=%s\n"
        label
        (Test_search.ceiling_sql sql_db criterion)
        (store_ceiling idx_db criterion)
        (store_ceiling sql_db criterion));
  [%expect
    {|
    floor haste      sql=(3) store=((3)) stale=()
    shop haste       sql=(1) store=((1)) stale=()
    floor digging    sql=() store=(()) stale=()
    props:Conj       sql=(1) store=((1)) stale=()
    props:Conj,Alch  sql=(1) store=() stale=()
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* Seed 4's posting still says three; its deepened [Lair:2] potion makes four.
   Reading the postings alone would tell a reader asking for 4x that none
   exists -- the one direction a ceiling must never err in. *)
let%expect_test "a deepened seed raises the store's ceiling above its posting" =
  let sql_db, idx_db = deepened_pair () in
  let haste = Test_search.floor Test_search.haste in
  printf "sql   %s\n" (Test_search.ceiling sql_db haste);
  printf "store %s\n" (store_ceiling idx_db haste);
  printf "db    %s\n" (Test_search.ceiling idx_db haste);
  [%expect
    {|
    sql   (4)
    store ((4))
    db    (4)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

(* {1 Submitted seeds}

   A reader-submitted seed is deep and lands without an ordinal. Until a
   rebuild takes it in, both paths must hide it -- the SQL path by a filter,
   the store by its absence -- or the fallback shows it first and the two
   disagree. Seed 50 would lead every haste search and every ceiling here if
   either leaked. *)

let submitted_records =
  [ {|#SEED#((format 4)(version "0.34.1")(seed "50")(level "D:1")(cats (items (((base_type "potion")(kind "item")(name "9 potions of haste")(quantity 9)(sub_type "haste")(text "9 potions of haste"))))))|}
  ; {|#SEED#((format 4)(version "0.34.1")(seed "50")(level "Swamp:4")(cats (items (((artefact t)(base_type "weapon")(kind "item")(name "+2 Barblade")(plus 2)(quantity 1)(sub_type "long sword")(text "+2 Barblade"))))))|}
  ]
;;

let submitted_pair () =
  let sql_db, idx_db = corpus_pair () in
  List.iter [ sql_db; idx_db ] ~f:(fun db ->
    ignore
      (Db.write_batch ~requested:true db (parse_records submitted_records) : Db.Counts.t);
    Or_error.ok_exn (Db.rebuild_fts db));
  sql_db, idx_db
;;

let path_seeds db ~sql terms ~rank =
  let search =
    Search.create ~version ~terms ~page:(Query.Page.create ~limit:1000 ()) ()
  in
  let matches, _ =
    Or_error.ok_exn
      (if sql
       then Db.search_seeds_sql db search ~rank
       else Db.search_seeds db search ~rank)
  in
  List.map matches ~f:(fun (m : Search.Match.t) -> m.seed)
  |> List.sort ~compare:String.compare
  |> String.concat ~sep:" "
;;

let%expect_test "a submitted seed is hidden from both paths until a rebuild" =
  let sql_db, idx_db = submitted_pair () in
  printf "store current: %b\n" (Db.search_index_is_current idx_db ~version);
  let haste = [ Search.Term.create (Test_search.floor Test_search.haste) ] in
  let barblade = [ Search.Term.create (Test_search.named "Barblade") ] in
  agree_both_ranks ~label:"potion:haste" sql_db idx_db haste;
  agree_both_ranks ~label:"name~Barblade" sql_db idx_db barblade;
  let floor_haste = Test_search.floor Test_search.haste in
  printf
    "ceiling sql=%s store=%s\n"
    (Test_search.ceiling sql_db floor_haste)
    (store_ceiling idx_db floor_haste);
  [%expect
    {|
    store current: true
    potion:haste [seed]: agree (6 seeds)
      store answered: true
    potion:haste [shallowest]: agree (6 seeds)
      store answered: true
      depths agree: true
    name~Barblade [seed]: agree (0 seeds)
      store answered: true
    name~Barblade [shallowest]: agree (0 seeds)
      store answered: true
      depths agree: true
    ceiling sql=(3) store=((3))
    |}];
  Or_error.ok_exn (Db.build_search_index idx_db ~version);
  printf
    "store current after a rebuild: %b\n"
    (Db.search_index_is_current idx_db ~version);
  printf !"deep cohort: %{sexp: string list}\n" (overlaid_seeds idx_db);
  List.iter [ Search.Rank.Seed; Search.Rank.Shallowest ] ~f:(fun rank ->
    List.iter
      [ "potion:haste", haste; "name~Barblade", barblade ]
      ~f:(fun (label, terms) ->
        printf
          "%s [%s] store=%s sql=%s\n"
          label
          (Search.Rank.to_string rank)
          (path_seeds idx_db ~sql:false terms ~rank)
          (path_seeds idx_db ~sql:true terms ~rank)));
  printf
    "ceiling store=%s sql=%s\n"
    (store_ceiling idx_db floor_haste)
    (Test_search.ceiling_sql idx_db floor_haste);
  [%expect
    {|
    store current after a rebuild: true
    deep cohort: ()
    potion:haste [seed] store=1 2 3 4 5 50 6 sql=1 2 3 4 5 50 6
    name~Barblade [seed] store=50 sql=50
    potion:haste [shallowest] store=1 2 3 4 5 50 6 sql=1 2 3 4 5 50 6
    name~Barblade [shallowest] store=50 sql=50
    ceiling store=((9)) sql=(9)
    |}];
  Db.close sql_db;
  Db.close idx_db
;;

let%expect_test "submitting a seed does not stale the store; a fill reaching it does" =
  let _sql_db, idx_db = submitted_pair () in
  printf "after a submission: %b\n" (Db.search_index_is_current idx_db ~version);
  ignore
    (Db.write_batch idx_db (parse_records [ List.hd_exn submitted_records ])
     : Db.Counts.t);
  printf "after a fill reaches it: %b\n" (Db.search_index_is_current idx_db ~version);
  printf
    "found by the fallback: %s\n"
    (path_seeds
       idx_db
       ~sql:false
       [ Search.Term.create (Test_search.named "Barblade") ]
       ~rank:Search.Rank.Seed);
  [%expect
    {|
    after a submission: true
    after a fill reaches it: false
    found by the fallback: 50
    |}];
  Db.close idx_db
;;
