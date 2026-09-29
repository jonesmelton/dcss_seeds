open! Core
module Db = Seed_corpus.Db
module Reader = Seed_corpus.Reader
module Record = Seed_corpus.Record

let sample_line =
  {|#SEED#((format 4)(version "0.33-a0")(seed "777")(level "D:2")(gold 431)(cats (features (((feat "altar_okawaru")(kind "feature")(name "an iron altar of Okawaru")(text "an iron altar of Okawaru")(x 10)(y 20))((feat "enter_sewer")(kind "feature")(text "a glowing drain")(timeout_turns 783)(x 58)(y 31))((feat "enter_shop")(kind "feature")(shop_type "General Store")(text "Sanarr's Fire Supplies")(x 44)(y 12))((feat "enter_trove")(kind "feature")(text "a portal to a secret trove of treasure")(timeout_turns 512)(toll_note "give a scroll of acquirement")(x 21)(y 7))))(items (((base_type "scroll")(cost 75)(kind "item")(name "scroll of revelation")(quantity 1)(sub_type "revelation")(text "scroll of revelation (cost: 75)")(x 3)(y 4))((base_type "book")(kind "item")(name "parchment of Shock")(quantity 1)(spells ("Shock"))(sub_type "parchment of Shock")(text "parchment of Shock")(x 5)(y 6))((artefact t)(base_type "book")(kind "item")(name "Wamnu's Compendium")(quantity 1)(spells ("Blink" "Freeze"))(sub_type "book of Fixed Theme")(text "Wamnu's Compendium")(x 9)(y 9))))(monsters (((items (((artefact t)(artprops ((Int 2) (Stlth 1)))(base_type "weapon")(branded t)(ego "flame")(kind "item")(name "+1 sling \"Wipar\" {flame, Int+2 Stlth+}")(plus 1)(quantity 1)(sub_type "sling")(text "+1 sling \"Wipar\" {flame, Int+2 Stlth+}")(x 7)(y 8))))(kind "monster")(name "kobold")(native t)(text "kobold")(type_name "kobold")(unique nil)(x 7)(y 8))))))|}
;;

let fresh_db () =
  let db = Db.open_ ":memory:" in
  Db.exec_script db (In_channel.read_all "../schema.sql");
  db
;;

let show db sql = List.iter (Db.query db sql) ~f:print_endline

(* Prints what storage actually holds -- an em dash where the name is derived --
   rather than the rendered string, which [seed_levels] is the accessor for.
   Ordered by the category enum then the id, since neither the interned name nor
   the level has an order of its own. *)
let entries_by_name_sql =
  "select e.cat, coalesce(s_name.val, '-'), coalesce(s_carried.val, '-') from entries e \
   left join strings s_name on s_name.id = e.name_id left join strings s_carried on \
   s_carried.id = e.carried_by_id order by e.cat, e.id"
;;

let%expect_test "a batch registers its version, level, and flattened entries" =
  let db = fresh_db () in
  let record = Or_error.ok_exn (Reader.parse_line sample_line) in
  let counts = Db.write_batch db [ record ] in
  print_endline (Db.Counts.to_string counts);
  [%expect {| 1 levels ingested, 9 entries written, 0 lines rejected |}];
  show db "select version from versions";
  [%expect {| 0.33-a0 |}];
  show
    db
    "select sl.seed, v.version, s.val, sl.format from seed_levels sl join versions v on \
     v.id = sl.version_id join strings s on s.id = sl.level_id";
  [%expect {| 777|0.33-a0|D:2|4 |}];
  Db.close db
;;

(* The carried item is its own row keyed to the monster that holds it, which is
   what makes "something carries Wyrmbane" an indexed lookup. Counting floor
   items therefore needs [where carried_by is null]. *)
let%expect_test "monster inventories become their own rows with carried_by set" =
  let db = fresh_db () in
  let record = Or_error.ok_exn (Reader.parse_line sample_line) in
  ignore (Db.write_batch db [ record ] : Db.Counts.t);
  show db entries_by_name_sql;
  [%expect
    {|
    0|-|-
    0|-|-
    0|-|-
    0|-|-
    1|-|-
    1|-|-
    1|Wamnu's Compendium|-
    1|+1 sling "Wipar" {flame, Int+2 Stlth+}|kobold
    2|kobold|-
    |}];
  show db "select count(*) from entries where cat = 1 and carried_by_id is null";
  [%expect {| 3 |}];
  Db.close db
;;

let%expect_test "booleans store as 0/1 so the artefact partial index applies" =
  let db = fresh_db () in
  let record = Or_error.ok_exn (Reader.parse_line sample_line) in
  ignore (Db.write_batch db [ record ] : Db.Counts.t);
  show
    db
    "select s.val, e.artefact, e.branded from entries e join strings s on s.id = \
     e.name_id where e.artefact = 1";
  [%expect
    {|
    Wamnu's Compendium|1|
    +1 sling "Wipar" {flame, Int+2 Stlth+}|1|1
    |}];
  show
    db
    "select s.val, e.unique_mons, e.native from entries e join strings s on s.id = \
     e.name_id where e.cat = 2";
  [%expect {| kobold|0|1 |}];
  Db.close db
;;

(* Db.Columns keeps the insert's binds and the select's reads resolving through
   one list each, but nothing ties the two lists to each other or to the record
   type. Every scalar field goes out and comes back here. *)
let%expect_test "every entry field survives the insert/read-back round trip" =
  let db = fresh_db () in
  let record = Or_error.ok_exn (Reader.parse_line sample_line) in
  ignore (Db.write_batch db [ record ] : Db.Counts.t);
  let levels =
    Or_error.ok_exn
      (Db.seed_levels
         db
         ~version:(Or_error.ok_exn (Seed_corpus.Query.Version.of_string "0.33-a0"))
         ~seed:"777")
  in
  List.iter levels ~f:(fun (l : Seed_corpus.Level.t) ->
    List.iter l.entries ~f:(fun e -> print_s [%sexp (e : Record.Entry.t)]));
  [%expect
    {|
    ((cat Features) (name "a General Store") (base_type ()) (sub_type ())
     (quantity ()) (artefact ()) (branded ()) (plus ()) (cost ()) (ego ())
     (feat (enter_shop)) (timeout_turns ()) (shop_type ("General Store"))
     (toll_note ()) (unique_mons ()) (native ()) (type_name ()) (x (44))
     (y (12)) (carried_by ()) (spells ()) (props ()))
    ((cat Features) (name "a glowing drain") (base_type ()) (sub_type ())
     (quantity ()) (artefact ()) (branded ()) (plus ()) (cost ()) (ego ())
     (feat (enter_sewer)) (timeout_turns (783)) (shop_type ()) (toll_note ())
     (unique_mons ()) (native ()) (type_name ()) (x (58)) (y (31))
     (carried_by ()) (spells ()) (props ()))
    ((cat Features) (name "a portal to a secret trove of treasure")
     (base_type ()) (sub_type ()) (quantity ()) (artefact ()) (branded ())
     (plus ()) (cost ()) (ego ()) (feat (enter_trove)) (timeout_turns (512))
     (shop_type ()) (toll_note ("give a scroll of acquirement")) (unique_mons ())
     (native ()) (type_name ()) (x (21)) (y (7)) (carried_by ()) (spells ())
     (props ()))
    ((cat Features) (name "an iron altar of Okawaru") (base_type ())
     (sub_type ()) (quantity ()) (artefact ()) (branded ()) (plus ()) (cost ())
     (ego ()) (feat (altar_okawaru)) (timeout_turns ()) (shop_type ())
     (toll_note ()) (unique_mons ()) (native ()) (type_name ()) (x (10))
     (y (20)) (carried_by ()) (spells ()) (props ()))
    ((cat Items) (name "+1 sling \"Wipar\" {flame, Int+2 Stlth+}")
     (base_type (weapon)) (sub_type (sling)) (quantity (1)) (artefact (true))
     (branded (true)) (plus (1)) (cost ()) (ego (flame)) (feat ())
     (timeout_turns ()) (shop_type ()) (toll_note ()) (unique_mons ())
     (native ()) (type_name ()) (x (7)) (y (8)) (carried_by (kobold)) (spells ())
     (props (((prop Int) (value 2)) ((prop Stlth) (value 1)))))
    ((cat Items) (name "Wamnu's Compendium") (base_type (book))
     (sub_type ("book of Fixed Theme")) (quantity (1)) (artefact (true))
     (branded ()) (plus ()) (cost ()) (ego ()) (feat ()) (timeout_turns ())
     (shop_type ()) (toll_note ()) (unique_mons ()) (native ()) (type_name ())
     (x (9)) (y (9)) (carried_by ()) (spells (Blink Freeze)) (props ()))
    ((cat Items) (name "parchment of Shock") (base_type (book))
     (sub_type ("parchment of Shock")) (quantity (1)) (artefact ()) (branded ())
     (plus ()) (cost ()) (ego ()) (feat ()) (timeout_turns ()) (shop_type ())
     (toll_note ()) (unique_mons ()) (native ()) (type_name ()) (x (5)) (y (6))
     (carried_by ()) (spells (Shock)) (props ()))
    ((cat Items) (name "scroll of revelation") (base_type (scroll))
     (sub_type (revelation)) (quantity (1)) (artefact ()) (branded ()) (plus ())
     (cost (75)) (ego ()) (feat ()) (timeout_turns ()) (shop_type ())
     (toll_note ()) (unique_mons ()) (native ()) (type_name ()) (x (3)) (y (4))
     (carried_by ()) (spells ()) (props ()))
    ((cat Monsters) (name kobold) (base_type ()) (sub_type ()) (quantity ())
     (artefact ()) (branded ()) (plus ()) (cost ()) (ego ()) (feat ())
     (timeout_turns ()) (shop_type ()) (toll_note ()) (unique_mons (false))
     (native (true)) (type_name (kobold)) (x (7)) (y (8)) (carried_by ())
     (spells ()) (props ()))
    |}];
  Db.close db
;;

(* Both format-4 fields are stored where the fact lives rather than where it was
   found: the toll on the trove's own feature row, gold on the level. The column
   list machinery cannot catch a column wired to the wrong name -- both sides
   would agree on the wrong one. *)
let%expect_test "a trove's toll and a level's floor gold survive the round trip" =
  let db = fresh_db () in
  let record = Or_error.ok_exn (Reader.parse_line sample_line) in
  ignore (Db.write_batch db [ record ] : Db.Counts.t);
  show
    db
    "select s_feat.val, coalesce(s_toll.val, '-') from entries e join strings s_feat on \
     s_feat.id = e.feat_id left join strings s_toll on s_toll.id = e.toll_note_id where \
     s_feat.val like 'enter_%' order by s_feat.val";
  [%expect
    {|
    enter_sewer|-
    enter_shop|-
    enter_trove|give a scroll of acquirement
    |}];
  show db "select s.val, sl.gold from seed_levels sl join strings s on s.id = sl.level_id";
  [%expect {| D:2|431 |}];
  let levels =
    Or_error.ok_exn
      (Db.seed_levels
         db
         ~version:(Or_error.ok_exn (Seed_corpus.Query.Version.of_string "0.33-a0"))
         ~seed:"777")
  in
  print_s
    [%sexp
      (List.map levels ~f:(fun (l : Seed_corpus.Level.t) -> l.gold) : int option list)];
  [%expect {| ((431)) |}];
  Db.close db
;;

(* A child row hangs off entries.id, and re-ingest must cascade to it through
   seed_levels rather than leaving orphans. *)
let%expect_test "spells and properties round trip and cascade on re-ingest" =
  let db = fresh_db () in
  let record = Or_error.ok_exn (Reader.parse_line sample_line) in
  ignore (Db.write_batch db [ record ] : Db.Counts.t);
  show
    db
    "select s_name.val, s_spell.val from entry_spells es join entries e on e.id = \
     es.entry_id join strings s_name on s_name.id = e.name_id join strings s_spell on \
     s_spell.id = es.spell_id";
  [%expect
    {|
    Wamnu's Compendium|Blink
    Wamnu's Compendium|Freeze
    |}];
  show
    db
    "select s_name.val, s_prop.val, p.value from entry_props p join entries e on e.id = \
     p.entry_id join strings s_name on s_name.id = e.name_id join strings s_prop on \
     s_prop.id = p.prop_id order by s_prop.val";
  [%expect
    {|
    +1 sling "Wipar" {flame, Int+2 Stlth+}|Int|2
    +1 sling "Wipar" {flame, Int+2 Stlth+}|Stlth|1
    |}];
  ignore (Db.write_batch db [ record ] : Db.Counts.t);
  show db "select count(*) from entry_spells";
  [%expect {| 2 |}];
  show db "select count(*) from entry_props";
  [%expect {| 2 |}];
  Db.close db
;;

let book_line ~seed ~spells =
  sprintf
    {|#SEED#((format 4)(version "0.33-a0")(seed "%s")(level "D:2")(cats (items (((base_type "book")(kind "item")(name "book of Necromancy")(quantity 1)(spells (%s))(sub_type "book of Necromancy")(text "book of Necromancy"))((artefact t)(base_type "book")(kind "item")(name "Wamnu's Compendium")(quantity 1)(spells ("Blink" "Freeze"))(sub_type "book of Fixed Theme")(text "Wamnu's Compendium"))))))|}
    seed
    (String.concat ~sep:" " (List.map spells ~f:(sprintf {|"%s"|})))
;;

(* A named book's contents are compiled into the build, so they are stored once
   per (version, sub_type). The randart book beside it is per-seed. *)
let%expect_test "a named book's spells are stored once per version, not per copy" =
  let db = fresh_db () in
  let ingest seed =
    let line = book_line ~seed ~spells:[ "Agony"; "Vampiric Draining" ] in
    ignore (Db.write_batch db [ Or_error.ok_exn (Reader.parse_line line) ] : Db.Counts.t)
  in
  ingest "1";
  ingest "2";
  show
    db
    "select v.version, s_sub.val, s_spell.val from book_spells bs join versions v on \
     v.id = bs.version_id join strings s_sub on s_sub.id = bs.sub_type_id join strings \
     s_spell on s_spell.id = bs.spell_id order by s_spell.val";
  [%expect
    {|
    0.33-a0|book of Necromancy|Agony
    0.33-a0|book of Necromancy|Vampiric Draining
    |}];
  show
    db
    "select s_name.val, s_spell.val from entry_spells es join entries e on e.id = \
     es.entry_id join strings s_name on s_name.id = e.name_id join strings s_spell on \
     s_spell.id = es.spell_id order by e.seed, s_spell.val";
  [%expect
    {|
    Wamnu's Compendium|Blink
    Wamnu's Compendium|Freeze
    Wamnu's Compendium|Blink
    Wamnu's Compendium|Freeze
    |}];
  Db.close db
;;

(* A released version is one build, so a title's spell set cannot change within
   it. A disagreement means the version string describes two builds. *)
let%expect_test "a named book whose spells disagree with the version is rejected" =
  let db = fresh_db () in
  let ingest seed spells =
    Or_error.try_with (fun () ->
      Db.write_batch db [ Or_error.ok_exn (Reader.parse_line (book_line ~seed ~spells)) ])
  in
  ignore (Or_error.ok_exn (ingest "1" [ "Agony"; "Vampiric Draining" ]) : Db.Counts.t);
  (match ingest "2" [ "Agony"; "Borgnjor's Vile Clutch" ] with
   | Ok _ -> print_endline "unexpectedly accepted"
   | Error e -> print_endline (Error.to_string_hum e));
  [%expect
    {|
    ("a book's spells disagree with the version's recorded set" (version 0.33-a0)
     (sub_type "book of Necromancy") (got (Agony "Borgnjor's Vile Clutch"))
     (recorded (Agony "Vampiric Draining")))
    |}];
  (* The rejected batch rolled back. *)
  show db "select count(*) from seed_levels";
  [%expect {| 1 |}];
  show
    db
    "select s.val from book_spells bs join strings s on s.id = bs.spell_id order by s.val";
  [%expect
    {|
    Agony
    Vampiric Draining
    |}];
  Db.close db
;;

(* Neither derivation is a loss: the seed page must still show every spell,
   from whichever of the three places it now lives. *)
let%expect_test "a seed page still shows every spell, however it is stored" =
  let db = fresh_db () in
  let line =
    {|#SEED#((format 4)(version "0.33-a0")(seed "9")(level "D:2")(cats (items (((base_type "book")(kind "item")(name "parchment of Shock")(quantity 1)(spells ("Shock"))(sub_type "parchment of Shock")(text "parchment of Shock"))((base_type "book")(kind "item")(name "book of Necromancy")(quantity 1)(spells ("Agony" "Vampiric Draining"))(sub_type "book of Necromancy")(text "book of Necromancy"))((artefact t)(base_type "book")(kind "item")(name "Wamnu's Compendium")(quantity 1)(spells ("Blink" "Freeze"))(sub_type "book of Fixed Theme")(text "Wamnu's Compendium"))((base_type "book")(kind "item")(name "manual of Axes")(quantity 1)(sub_type "manual of Axes")(text "manual of Axes"))))))|}
  in
  ignore (Db.write_batch db [ Or_error.ok_exn (Reader.parse_line line) ] : Db.Counts.t);
  let levels =
    Or_error.ok_exn
      (Db.seed_levels
         db
         ~version:(Or_error.ok_exn (Seed_corpus.Query.Version.of_string "0.33-a0"))
         ~seed:"9")
  in
  List.iter levels ~f:(fun (l : Seed_corpus.Level.t) ->
    List.iter l.entries ~f:(fun (e : Record.Entry.t) ->
      printf "%-24s %s\n" e.name (String.concat ~sep:", " e.spells)));
  [%expect
    {|
    Wamnu's Compendium       Blink, Freeze
    book of Necromancy       Agony, Vampiric Draining
    manual of Axes
    parchment of Shock       Shock
    |}];
  Db.close db
;;

let%expect_test "re-ingesting the same (seed, version, level) does not duplicate" =
  let db = fresh_db () in
  let record = Or_error.ok_exn (Reader.parse_line sample_line) in
  ignore (Db.write_batch db [ record ] : Db.Counts.t);
  ignore (Db.write_batch db [ record ] : Db.Counts.t);
  show db "select count(*) from seed_levels";
  [%expect {| 1 |}];
  show db "select count(*) from entries";
  [%expect {| 9 |}];
  show db "select count(*) from versions";
  [%expect {| 1 |}];
  Db.close db
;;

let%expect_test "a malformed line is counted, not fatal" =
  let db = fresh_db () in
  let input =
    String.concat ~sep:"\n" [ sample_line; "#SEED#((format 4)(trunc"; sample_line ]
  in
  let rejects = ref [] in
  let counts =
    let tmp = Filename_unix.temp_file "ingest_test" ".txt" in
    Out_channel.write_all tmp ~data:input;
    let counts =
      In_channel.with_file tmp ~f:(fun ic ->
        Db.ingest_channel db ic ~batch_size:16 ~on_reject:(fun n _ ->
          rejects := n :: !rejects))
    in
    Core_unix.unlink tmp;
    counts
  in
  print_endline (Db.Counts.to_string counts);
  [%expect {| 2 levels ingested, 18 entries written, 1 lines rejected |}];
  print_s [%sexp (List.rev !rejects : int list)];
  [%expect {| (2) |}];
  show db "select count(*) from seed_levels";
  [%expect {| 1 |}];
  Db.close db
;;

(* Re-ingesting a (seed, version, level) replaces it, and the row counts are
   what says so: a duplicated level shows up here and nowhere else, since every
   accessor above storage reads through seed_levels and would render one copy.

   The two batches are separate on purpose. Interning makes the delete resolve
   its level through the dictionary, so a level name the corpus has never seen
   yields a null subquery and duplicates instead of replacing -- reachable only
   on a level's *first* ingest, which a single-batch test cannot produce. *)
let%expect_test "re-ingesting a record replaces it rather than adding a copy" =
  let db = fresh_db () in
  let record = Or_error.ok_exn (Reader.parse_line sample_line) in
  let counts sql = List.iter (Db.query db sql) ~f:print_endline in
  let show_all () =
    counts
      "select (select count(*) from seed_levels), (select count(*) from entries), \
       (select count(*) from entry_spells), (select count(*) from entry_props), (select \
       count(*) from book_spells)"
  in
  ignore (Db.write_batch db [ record ] : Db.Counts.t);
  show_all ();
  [%expect {| 1|9|2|2|0 |}];
  ignore (Db.write_batch db [ record ] : Db.Counts.t);
  show_all ();
  [%expect {| 1|9|2|2|0 |}];
  (* A third pass with the level renamed adds a level rather than replacing one,
     which keeps the assertion above from passing vacuously. *)
  let other =
    Or_error.ok_exn
      (Reader.parse_line
         (String.substr_replace_first
            sample_line
            ~pattern:{|(level "D:2")|}
            ~with_:{|(level "D:3")|}))
  in
  ignore (Db.write_batch db [ other ] : Db.Counts.t);
  show_all ();
  [%expect {| 2|18|4|4|0 |}];
  ignore (Db.write_batch db [ other ] : Db.Counts.t);
  show_all ();
  [%expect {| 2|18|4|4|0 |}];
  Db.close db
;;

(* Fill depth is recomputed from the stored level list rather than tracked per
   batch, because a seed's levels can split across batches. *)
let%expect_test "ingest records a seed's fill depth, and deepening updates it" =
  let db = fresh_db () in
  let record level =
    Or_error.ok_exn
      (Reader.parse_line
         (String.substr_replace_first
            sample_line
            ~pattern:{|(level "D:2")|}
            ~with_:(sprintf {|(level "%s")|} level)))
  in
  ignore (Db.write_batch db [ record "D:2"; record "D:8" ] : Db.Counts.t);
  show
    db
    "select f.seed, v.version, f.depth from seed_fills f join versions v on v.id = \
     f.version_id";
  [%expect {| 777|0.33-a0|8 |}];
  ignore (Db.write_batch db [ record "Swamp:4" ] : Db.Counts.t);
  show
    db
    "select f.seed, v.version, f.depth from seed_fills f join versions v on v.id = \
     f.version_id";
  [%expect {| 777|0.33-a0|14 |}];
  Db.close db
;;

(* What makes a column list edited apart from its SQL skeleton fail loudly
   instead of reading a shifted row. *)
let%expect_test "a column list that disagrees with the statement is refused" =
  let raw = Sqlite3.db_open ":memory:" in
  ignore (Sqlite3.exec raw "create table t (a text, b text, c text)" : Sqlite3.Rc.t);
  let check names sql =
    let stmt = Sqlite3.prepare raw sql in
    print_s
      [%sexp (Db.Columns.check_header (Db.Columns.of_list names) stmt : unit Or_error.t)];
    ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t)
  in
  check [ "t.a"; "t.b"; "t.c" ] "select a, b, c from t";
  [%expect {| (Ok ()) |}];
  (* two names swapped: the reader would have read b as a and never noticed *)
  check [ "t.a"; "t.c"; "t.b" ] "select a, b, c from t";
  [%expect {| (Error "column 1: expected c, statement reports b") |}];
  check [ "t.a"; "t.b"; "t.c" ] "select a, b from t";
  [%expect {| (Error "column count: expected 3, statement reports 2") |}];
  ignore (Sqlite3.db_close raw : bool)
;;

let%expect_test "resolving an absent column raises rather than reading a neighbour" =
  let columns = Db.Columns.of_list [ "e.level"; "e.cat" ] in
  print_s [%sexp (Db.Columns.at columns "cat" : int)];
  [%expect {| 1 |}];
  print_s
    [%sexp (Or_error.try_with (fun () -> Db.Columns.at columns "name") : int Or_error.t)];
  [%expect {| (Error (Failure "unknown column: name")) |}]
;;

(* The generator's whole diagnostic record is one line. [Deepen.guard]
   catches the Failure, and by then the build and seed are out of scope, so
   the loop captures them and formats through [Deepen.failure_message]. A real
   BUSY must name the version, the seed, the failing statement, and the
   extended code -- which is what tells BUSY (5) from BUSY_SNAPSHOT (517). *)
let%expect_test "a guarded BUSY names the version, seed, statement, and extended code" =
  let path = Filename_unix.temp_file "corpus" ".db" in
  Exn.protect
    ~finally:(fun () -> Sys_unix.remove path)
    ~f:(fun () ->
      let holder = Db.open_ path in
      Db.exec_script holder (In_channel.read_all "../schema.sql");
      let contender = Db.open_ path in
      (* Without this the contender waits the corpus's full 30s before failing. *)
      Db.exec_script contender "pragma busy_timeout = 0";
      Db.exec_script holder "begin immediate";
      let context =
        { Seed_corpus.Deepen.Context.version =
            Or_error.ok_exn (Seed_corpus.Query.Version.of_string "0.34.1")
        ; seed = Some "1234567890"
        }
      in
      ignore
        (Seed_corpus.Deepen.guard
           ~on_error:(fun message ->
             printf
               "%s\n%!"
               (Seed_corpus.Deepen.failure_message ~consecutive:1 (Some context) message))
           (fun () ->
              Db.exec_script contender "begin immediate";
              true)
         : bool);
      [%expect
        {| pass failed: consecutive=1 version=0.34.1 seed=1234567890: exec_script failed: BUSY (5): database is locked; statement: begin immediate |}];
      Db.exec_script holder "rollback";
      Db.close contender;
      Db.close holder)
;;

(* SQLITE_BUSY_SNAPSHOT (517) is not a longer wait: a read transaction whose
   snapshot a writer has passed cannot be upgraded, and it has to be retried
   on a fresh read. [Rc.to_string] would print it as `BUSY`, so the rendered
   message must carry the extended code. *)
let%expect_test "a snapshot conflict renders as BUSY_SNAPSHOT, not BUSY" =
  let path = Filename_unix.temp_file "corpus" ".db" in
  Exn.protect
    ~finally:(fun () -> Sys_unix.remove path)
    ~f:(fun () ->
      let reader = Db.open_ path in
      Db.exec_script reader (In_channel.read_all "../schema.sql");
      Db.exec_script reader "insert into versions (version) values ('0.34.1')";
      Db.exec_script reader "begin";
      ignore (Db.query reader "select count(*) from versions" : string list);
      let writer = Db.open_ path in
      Db.exec_script writer "insert into versions (version) values ('0.33.1')";
      print_s
        [%sexp
          (Or_error.try_with (fun () ->
             Db.exec_script reader "insert into versions (version) values ('0.32.1')")
           : unit Or_error.t)];
      [%expect
        {|
        (Error
         (Failure
          "exec_script failed: BUSY_SNAPSHOT (517): database is locked; statement: insert into versions (version) values ('0.32.1')"))
        |}];
      Db.exec_script reader "rollback";
      Db.close writer;
      Db.close reader)
;;

(* A deepened seed reaches levels the fill never saw, so it interns names the
   dictionary did not have. That is an ordinary ingest, and until the index
   catches up every one of those names is invisible to `name~` -- and because
   currency is a high-water mark over the whole dictionary, one new name
   withdraws name search for the entire corpus, not just for that seed. *)
let%expect_test "catching the index up covers names interned after the rebuild" =
  let db = fresh_db () in
  let record = Or_error.ok_exn (Reader.parse_line sample_line) in
  ignore (Db.write_batch db [ record ] : Db.Counts.t);
  Or_error.ok_exn (Db.rebuild_fts db);
  print_s [%sexp (Db.fts_is_current db : bool)];
  [%expect {| true |}];
  let deepened =
    String.substr_replace_first
      sample_line
      ~pattern:{|(level "D:2")|}
      ~with_:{|(level "D:9")|}
    |> String.substr_replace_first ~pattern:"Wamnu's Compendium" ~with_:"Xomnu's Grimoire"
  in
  ignore
    (Db.write_batch db [ Or_error.ok_exn (Reader.parse_line deepened) ] : Db.Counts.t);
  print_s [%sexp (Db.fts_is_current db : bool)];
  [%expect {| false |}];
  Or_error.ok_exn (Db.catch_up_fts db);
  print_s [%sexp (Db.fts_is_current db : bool)];
  [%expect {| true |}];
  show
    db
    "select s.val from strings s where s.id in (select rowid from strings_fts where \
     strings_fts match '\"Grimoire\"')";
  [%expect {| Xomnu's Grimoire |}];
  (* The rebuild's own coverage must survive the catch-up. *)
  show
    db
    "select s.val from strings s where s.id in (select rowid from strings_fts where \
     strings_fts match '\"kobold\"')";
  [%expect {| kobold |}];
  Db.close db
;;

(* [driver_select]/[correlated_select]'s [Props] shape drives off
   [entry_props_search] and joins back to [entries], rather than scanning
   [entries] with a correlated [exists] per property -- the shape
   [criterion_where] alone still produces, and still correctly serves, for
   [verify_terms]/[cohort_depths_sql]/[term_hits_sql]'s bounded seed batches.
   A bare [Props] search under the old shape was measured 67-69s under a
   bounded fetch at 1.3M (0.34.1, prod clone, 2026-09-17, fossil ticket
   1e34af034b); [entry_props] is two orders of magnitude smaller than
   [entries] (AGENTS.md), so seeking it instead is the fix. *)
let show_plan = Test_read.show_plan

let%expect_test "a bare Props search, as the sole term, seeks entry_props_search" =
  let db = Test_search.fresh_db () in
  show_plan
    db
    "select distinct e.seed from entry_props p0 join entries e on e.id = p0.entry_id \
     where p0.version_id = (select id from versions where version = '0.34.1') and e.seed \
     > '' and p0.prop_id = (select id from strings where val = 'Conj') and p0.value >= 1 \
     and exists (select 1 from entry_props p where p.entry_id = e.id and p.prop_id = \
     (select id from strings where val = 'Alch') and p.value >= 1) order by e.seed limit \
     51";
  [%expect
    {|
    SEARCH p0 USING INDEX entry_props_search (version_id=? AND prop_id=? AND value>?)
    SEARCH versions USING COVERING INDEX sqlite_autoindex_versions_1 (version=?)
    SEARCH strings USING COVERING INDEX sqlite_autoindex_strings_1 (val=?)
    SEARCH e USING INTEGER PRIMARY KEY (rowid=?)
    SEARCH p EXISTS USING INDEX entry_props_entry (entry_id=?)
    SEARCH strings USING COVERING INDEX sqlite_autoindex_strings_1 (val=?)
    |}];
  Db.close db
;;

(* Same shape, correlated as a non-driver term inside [correlated_select] --
   confirms the join survives being wrapped in an uncorrelated [in (select ...)]
   rather than sitting at the top level. *)
let%expect_test "a Props search as a non-driver term also seeks entry_props_search" =
  let db = Test_search.fresh_db () in
  show_plan
    db
    "select distinct e.seed from entries e where e.version_id = (select id from versions \
     where version = '0.34.1') and e.seed > '' and e.base_type_id = (select id from \
     strings where val = 'wand') and e.sub_type_id = (select id from strings where val = \
     'digging') and e.cost is null and e.seed in (select a0.seed from entry_props a0p \
     join entries a0 on a0.id = a0p.entry_id where a0p.version_id = (select id from \
     versions where version = '0.34.1') and a0p.prop_id = (select id from strings where \
     val = 'Conj') and a0p.value >= 1 and a0.cost is null and a0.seed > '') order by \
     e.seed limit 51";
  [%expect
    {|
    SEARCH e USING COVERING INDEX entries_search_type (version_id=? AND base_type_id=? AND sub_type_id=? AND seed=?)
    SEARCH versions USING COVERING INDEX sqlite_autoindex_versions_1 (version=?)
    SEARCH strings USING COVERING INDEX sqlite_autoindex_strings_1 (val=?)
    SEARCH strings USING COVERING INDEX sqlite_autoindex_strings_1 (val=?)
    SEARCH a0p USING INDEX entry_props_search (version_id=? AND prop_id=? AND value>?)
    SEARCH versions USING COVERING INDEX sqlite_autoindex_versions_1 (version=?)
    SEARCH strings USING COVERING INDEX sqlite_autoindex_strings_1 (val=?)
    SEARCH a0 USING INTEGER PRIMARY KEY (rowid=?)
    |}];
  Db.close db
;;
