open! Core
module Db = Seed_corpus.Db
module Reader = Seed_corpus.Reader
module Query = Seed_corpus.Query
module Heat = Seed_corpus.Heat

let fresh_db () =
  let db = Db.open_ ":memory:" in
  Db.exec_script db (In_channel.read_all "../schema.sql");
  db
;;

let show db sql = List.iter (Db.query db sql) ~f:print_endline

(* A level carrying [n] potions of haste as one floor stack, so the surprise
   count for (potion, haste) at this level is exactly [n]. potion/haste is
   weight 30, tier Strong -- an ordinary exact-match row, not a wildcard or an
   unweighted class. *)
let haste_level ~seed ~version ~level ~n =
  sprintf
    {|#SEED#((format 4)(version "%s")(seed "%s")(level "%s")(cats (items (((base_type "potion")(kind "item")(name "%d potions of haste")(quantity %d)(sub_type "haste")(text "%d potions of haste")(x 3)(y 4))))))|}
    version
    seed
    level
    n
    n
    n
;;

(* A level with no items, so a seed can be filled to a depth without
   contributing any haste observation -- the "count of 0" case. *)
let empty_level ~seed ~version ~level =
  sprintf
    {|#SEED#((format 4)(version "%s")(seed "%s")(level "%s")(cats))|}
    version
    seed
    level
;;

let version = Query.Version.of_string "0.34.1" |> Or_error.ok_exn

let write db lines =
  let records =
    List.map lines ~f:(fun line -> Reader.parse_line line |> Or_error.ok_exn)
  in
  ignore (Db.write_batch db records : Db.Counts.t)
;;

(* Three seeds filled to D:8: "1" holds 1 haste on D:1, "2" holds 3 on D:3, "3"
   holds none. A D:8 fill needs D:1..D:8 present for Fill_depth.of_levels to
   read back 8, hence the chain of empty levels. *)
let d8_levels ?(version = "0.34.1") ~seed ~haste_on ~n () =
  List.init 8 ~f:(fun i ->
    let level = sprintf "D:%d" (i + 1) in
    if String.equal level haste_on
    then haste_level ~seed ~version ~level ~n
    else empty_level ~seed ~version ~level)
;;

let setup () =
  let db = fresh_db () in
  write db (d8_levels ~seed:"1" ~haste_on:"D:1" ~n:1 ());
  write db (d8_levels ~seed:"2" ~haste_on:"D:3" ~n:3 ());
  write db (d8_levels ~seed:"3" ~haste_on:"" ~n:0 ());
  db
;;

let%expect_test "recompute_surprise: tail_p over a 3-seed cohort, by hand" =
  let db = setup () in
  show db "select seed, depth from seed_fills order by seed";
  [%expect
    {|
    1|8
    2|8
    3|8
    |}];
  Db.recompute_surprise db ~version ~cap:8;
  (* Population is 3. Two of three seeds hold >=1 haste, so tail_p(1) = 2/3; one
     of three holds >=3, so tail_p(3) = 1/3. No row for the book term's count 0,
     since every seed here holds zero early spells. *)
  show
    db
    "select s_base.val, s_sub.val, sp.count, printf('%.6f', sp.tail_p) from surprise sp \
     join strings s_base on s_base.id = sp.base_type_id join strings s_sub on s_sub.id = \
     sp.sub_type_id order by s_base.val, s_sub.val, sp.count";
  [%expect
    {|
    book|#early-spells|0|1.000000
    potion|haste|1|0.666667
    potion|haste|3|0.333333
    |}];
  Db.close db
;;

let%expect_test
    "recompute_surprise is idempotent: a second run replaces rather than doubles"
  =
  let db = setup () in
  Db.recompute_surprise db ~version ~cap:8;
  Db.recompute_surprise db ~version ~cap:8;
  show db "select count(*) from surprise";
  [%expect {| 3 |}];
  Db.close db
;;

let%expect_test
    "rescore: seed 2 (3 haste, D:3) outranks seed 1 (1 haste, D:1 -- shallower, but \
     fewer)"
  =
  let db = setup () in
  Db.recompute_surprise db ~version ~cap:8;
  Db.rescore db ~version ~cap:8;
  show db "select seed, printf('%.4f', score), band from seed_scores order by seed";
  [%expect
    {|
    1|5.2827|1
    2|12.5244|2
    3|0.0000|0
    |}];
  (* score = weight(30) x -log10(tail_p) x depth_util(cap=8, d). Books contribute
     0, since every seed holds 0 early spells and -log10(1.0) = 0.

     Cut points: with 3 seeds, p50/p80/p95 index into [0.; 5.2827; 12.5244] via
     [percentile]'s [floor(pct * len)] -- indices 1, 2, 2. Hot and Blazing tie
     at seed 2's score, and [band_of_score]'s [max_elt] keeps the first band
     reached on a tie, so seed 2 reads Hot. This is the discrete-distribution
     approximation the design accepts; the real bands are calibrated against
     thousands of seeds. *)
  show db "select band, printf('%.4f', min_score) from heat_bands order by band";
  [%expect
    {|
    0|0.0000
    1|5.2827
    2|12.5244
    3|12.5244
    |}];
  Db.close db
;;

let%expect_test "rescore is idempotent" =
  let db = setup () in
  Db.recompute_surprise db ~version ~cap:8;
  Db.rescore db ~version ~cap:8;
  Db.rescore db ~version ~cap:8;
  show db "select count(*) from seed_scores";
  [%expect {| 3 |}];
  show db "select count(*) from heat_bands";
  [%expect {| 4 |}];
  Db.close db
;;

let%expect_test
    "heat_marks returns bands for a scored page, and nothing for an unscored seed"
  =
  let db = setup () in
  Db.recompute_surprise db ~version ~cap:8;
  Db.rescore db ~version ~cap:8;
  let marks =
    Db.heat_marks db ~version ~cap:8 ~seeds:[ "1"; "2"; "3"; "999" ] |> Or_error.ok_exn
  in
  Map.iteri marks ~f:(fun ~key ~data -> printf "%s: %s\n" key (Heat.Band.to_string data));
  [%expect
    {|
    1: warm
    2: hot
    3: cold
    |}];
  Db.close db
;;

(* Apportation (level 1) on D:1, Blink (level 2) on D:10: two early-castable
   spells, one within a D:8 cap and one beyond. At cap 8 the seed shows 1 early
   spell; at cap 15 it shows 2. *)
let book_level_named ~seed ~version ~level ~name ~sub_type =
  sprintf
    {|#SEED#((format 4)(version "%s")(seed "%s")(level "%s")(cats (items (((base_type "book")(kind "item")(name "%s")(quantity 1)(sub_type "%s")(text "%s")(x 3)(y 4))))))|}
    version
    seed
    level
    name
    sub_type
    name
;;

let swamp4_two_spells ~seed =
  List.init 15 ~f:(fun i ->
    let level = sprintf "D:%d" (i + 1) in
    match level with
    | "D:1" ->
      book_level_named
        ~seed
        ~version:"0.34.1"
        ~level
        ~name:"parchment of Apportation"
        ~sub_type:"parchment of Apportation"
    | "D:10" ->
      book_level_named
        ~seed
        ~version:"0.34.1"
        ~level
        ~name:"parchment of Blink"
        ~sub_type:"parchment of Blink"
    | level -> empty_level ~seed ~version:"0.34.1" ~level)
;;

(* Two rows land under base_type "book": the reserved #early-spells key and an
   ordinary per-item surprise row for the parchment. recompute_surprise's item
   pass has no Weight.find filter, so it stores a tail for every observed pair
   regardless of whether Heat.score's item path consults it. *)
let%expect_test "a below-cap book does not count: cap 8 sees 1 early spell, cap 15 sees 2"
  =
  let db = fresh_db () in
  write db (swamp4_two_spells ~seed:"4");
  show db "select seed, depth from seed_fills";
  [%expect {| 4|15 |}];
  Db.recompute_surprise db ~version ~cap:8;
  show
    db
    "select sp.count, sp.tail_p from surprise sp join strings s_base on s_base.id = \
     sp.base_type_id join strings s_sub on s_sub.id = sp.sub_type_id where sp.cap = 8 \
     and s_base.val = 'book' and s_sub.val = '#early-spells'";
  [%expect {| 1|1.0 |}];
  Db.recompute_surprise db ~version ~cap:15;
  show
    db
    "select sp.count, sp.tail_p from surprise sp join strings s_base on s_base.id = \
     sp.base_type_id join strings s_sub on s_sub.id = sp.sub_type_id where sp.cap = 15 \
     and s_base.val = 'book' and s_sub.val = '#early-spells'";
  [%expect {| 2|1.0 |}];
  Db.close db
;;

(* (version, cap) isolation: a rescore for one must not leak surprise rows,
   scores, or bands into another. The same seed number on two builds is two
   unrelated dungeons, and heat has to honour that. *)
let%expect_test "surprise, seed_scores, and heat_marks are scoped per (version, cap)" =
  let db = fresh_db () in
  (* Seed "1" filled only to D:8 is eligible at cap 8 but not at cap 15. *)
  write db (d8_levels ~seed:"1" ~haste_on:"D:1" ~n:1 ());
  write db (d8_levels ~seed:"2" ~haste_on:"D:3" ~n:3 ());
  Db.recompute_surprise db ~version ~cap:8;
  Db.rescore db ~version ~cap:8;
  show
    db
    "select sc.seed from seed_scores sc join versions v on v.id = sc.version_id where \
     v.version = '0.34.1' and sc.cap = 8 order by sc.seed";
  [%expect
    {|
    1
    2
    |}];
  (* cap 15 has never been rescored: no seed is eligible, and heat_marks must
     return nothing rather than reusing the cap-8 rows. *)
  let marks_cap_15 =
    Db.heat_marks db ~version ~cap:15 ~seeds:[ "1"; "2" ] |> Or_error.ok_exn
  in
  print_s [%sexp (Map.is_empty marks_cap_15 : bool)];
  [%expect {| true |}];
  (* Seed "1" reused on a second version with a different haste count. If
     surprise leaked across versions, 0.35.0's "5 haste" would be looked up
     against 0.34.1's tail, which has no row for n=5 at all, instead of against
     its own one-seed population. The 0.34.1 row for count 1 also changes shape
     here -- tail_p(1) = 2/2, not 2/3 -- which is itself evidence nothing was
     pulled in from a population of another size. *)
  let other_version = Query.Version.of_string "0.35.0" |> Or_error.ok_exn in
  write db (d8_levels ~version:"0.35.0" ~seed:"1" ~haste_on:"D:1" ~n:5 ());
  Db.recompute_surprise db ~version:other_version ~cap:8;
  Db.rescore db ~version:other_version ~cap:8;
  show
    db
    "select v.version, s_base.val, s_sub.val, sp.count, sp.tail_p from surprise sp join \
     versions v on v.id = sp.version_id join strings s_base on s_base.id = \
     sp.base_type_id join strings s_sub on s_sub.id = sp.sub_type_id where s_base.val = \
     'potion' order by v.version, sp.count";
  [%expect
    {|
    0.34.1|potion|haste|1|1.0
    0.34.1|potion|haste|3|0.5
    0.35.0|potion|haste|5|1.0
    |}];
  (* Each version's surprise table only ever sees the counts its own cohort
     produced. *)
  show
    db
    "select v.version, sc.seed, printf('%.4f', sc.score) from seed_scores sc join \
     versions v on v.id = sc.version_id order by v.version, sc.seed";
  [%expect
    {|
    0.34.1|1|0.0000
    0.34.1|2|7.9020
    0.35.0|1|0.0000
    |}];
  (* Both seed-1 scores land at 0.0000 for unrelated reasons: 0.34.1's is the
     median of a two-seed population, 0.35.0's is the sole member of its own.
     The decisive test of isolation is the surprise table above; these matching
     scores are confirmatory. *)
  let marks_0341 = Db.heat_marks db ~version ~cap:8 ~seeds:[ "1" ] |> Or_error.ok_exn in
  let marks_0350 =
    Db.heat_marks db ~version:other_version ~cap:8 ~seeds:[ "1" ] |> Or_error.ok_exn
  in
  print_s [%sexp (Map.find_exn marks_0341 "1" : Heat.Band.t)];
  [%expect {| Cold |}];
  print_s [%sexp (Map.find_exn marks_0350 "1" : Heat.Band.t)];
  [%expect {| Cold |}];
  Db.close db
;;

(* A cap disappears when the last seed at that depth is deleted -- which is
   what repairing a truncated fill does, since a fill cut short records a short
   depth and so invents a cap of its own. rescore enumerates caps from
   seed_fills, so a cap that no longer exists is never visited and its rows are
   unreachable and immortal. *)
let%expect_test "a cap with no seeds left keeps no heat rows" =
  let db = fresh_db () in
  write db (d8_levels ~seed:"1" ~haste_on:"D:1" ~n:1 ());
  write db (d8_levels ~seed:"2" ~haste_on:"D:3" ~n:3 ());
  (* A truncated seed: three levels, and a fill depth of its own. Set directly
     because the point is the short seed_fills row, which a well-formed
     extraction never produces. *)
  write
    db
    (List.init 3 ~f:(fun i ->
       empty_level ~seed:"9" ~version:"0.34.1" ~level:(sprintf "D:%d" (i + 1))));
  Db.exec_script db "update seed_fills set depth = 3 where seed = '9'";
  let rescore_all () =
    Db.drop_stale_caps db ~version |> Or_error.ok_exn;
    List.iter
      (Db.fill_caps db ~version |> Or_error.ok_exn)
      ~f:(fun cap ->
        Db.recompute_surprise db ~version ~cap;
        Db.rescore db ~version ~cap)
  in
  rescore_all ();
  show db "select 'caps before: ' || group_concat(distinct cap) from seed_scores";
  (* Repair it the way tools/corpus-drop-seeds does. *)
  Db.exec_script db "pragma foreign_keys = on";
  Db.exec_script db "delete from seed_levels where seed = '9'";
  Db.exec_script db "delete from seed_fills where seed = '9'";
  rescore_all ();
  show
    db
    "select 'caps after:  ' || coalesce(group_concat(distinct cap), 'none') from \
     seed_scores";
  show
    db
    "select 'orphans:     ' || count(*) from seed_scores where cap not in (select depth \
     from seed_fills)";
  [%expect
    {|
    caps before: 3,8
    caps after:  8
    orphans:     0
    |}]
;;

(* The property that licenses sharding: [shards] changes peak memory, never a
   score. [Heat.score] sees one seed's observations plus [surprise] and [n],
   both fixed above the loop, and [group_observations] never groups across
   seeds. Anything less than identical is a bug, not a rounding difference,
   which is why this compares stored floats at 17 significant digits, enough
   to round-trip a double. That holds only on the pinned sqlite: 3.45 renders
   [%!.17g] at 16.

   K=7 over 3 seeds is deliberate: ntile with more buckets than rows yields one
   group per row rather than empty shards, covering the
   cohort-smaller-than-K case prod hits. *)
let%expect_test "rescore: sharding changes peak memory, not scores" =
  let snapshot db =
    Db.query
      db
      "select seed || ' ' || cap || ' ' || printf('%!.17g', score) || ' ' || band from \
       seed_scores order by cap, seed"
    @ Db.query
        db
        "select 'band ' || cap || ' ' || band || ' ' || printf('%!.17g', min_score) from \
         heat_bands order by cap, band"
  in
  let scored_with ~shards =
    let db = setup () in
    Db.recompute_surprise db ~version ~cap:8;
    Db.rescore ~shards db ~version ~cap:8;
    snapshot db
  in
  let unsharded = scored_with ~shards:1 in
  printf "rows: %d\n" (List.length unsharded);
  List.iter [ 2; 3; 7 ] ~f:(fun shards ->
    let sharded = scored_with ~shards in
    printf
      "shards=%d: %s\n"
      shards
      (if List.equal String.equal unsharded sharded
       then "identical"
       else
         sprintf
           "DIFFERS\n  unsharded: %s\n  sharded:   %s"
           (String.concat ~sep:" | " unsharded)
           (String.concat ~sep:" | " sharded)));
  [%expect
    {|
    rows: 7
    shards=2: identical
    shards=3: identical
    shards=7: identical
    |}]
;;
