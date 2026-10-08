open! Core
module Db = Seed_corpus.Db
module Level = Seed_corpus.Level
module Query = Seed_corpus.Query
module Reader = Seed_corpus.Reader

let line ~seed ~level =
  sprintf
    {|#SEED#((format 4)(version "0.34.1")(seed "%s")(level "%s")(cats (features (((feat "altar_okawaru")(kind "feature")(name "an iron altar of Okawaru")(text "an altar"))))(monsters (((items (((artefact t)(base_type "weapon")(kind "item")(name "+1 sling")(quantity 1)(sub_type "sling")(text "+1 sling"))))(kind "monster")(name "kobold")(native t)(ood nil)(text "kobold")(type_name "kobold")(unique nil))))))|}
    seed
    level
;;

(* A feature row on its own level: what a Temple entrance, a rare altar or a
   portal entrance looks like on the wire. *)
let feat_line ~seed ~level ~feat =
  sprintf
    {|#SEED#((format 4)(version "0.34.1")(seed "%s")(level "%s")(cats (features (((feat "%s")(kind "feature")(name "a feature")(text "a feature"))))))|}
    seed
    level
    feat
;;

(* [cost] present is the only thing telling shop stock from floor loot. *)
let item_line ~seed ~level ~name ~cost =
  let cost =
    match cost with
    | None -> ""
    | Some c -> sprintf "(cost %d)" c
  in
  sprintf
    {|#SEED#((format 4)(version "0.34.1")(seed "%s")(level "%s")(cats (items (((artefact t)(base_type "weapon")%s(kind "item")(name "%s")(quantity 1)(sub_type "sling")(text "%s"))))))|}
    seed
    level
    cost
    name
    name
;;

let consumable_line ~seed ~level ~base_type ~sub_type ~quantity ~cost =
  let cost =
    match cost with
    | None -> ""
    | Some c -> sprintf "(cost %d)" c
  in
  let name = sprintf "%s of %s" base_type sub_type in
  sprintf
    {|#SEED#((format 4)(version "0.34.1")(seed "%s")(level "%s")(cats (items (((base_type "%s")%s(kind "item")(name "%s")(quantity %d)(sub_type "%s")(text "%s"))))))|}
    seed
    level
    base_type
    cost
    name
    quantity
    sub_type
    name
;;

let portal_line ~seed ~level ~parent =
  sprintf
    {|#SEED#((format 4)(version "0.34.1")(seed "%s")(level "%s")(parent_level "%s")(cats (features (((feat "altar_okawaru")(kind "feature")(name "an iron altar of Okawaru")(text "an altar"))))))|}
    seed
    level
    parent
;;

let corpus () =
  let db = Db.open_ ":memory:" in
  Db.exec_script db (In_channel.read_all "../schema.sql");
  let records =
    List.concat_map [ "100"; "200"; "300" ] ~f:(fun seed ->
      List.map [ "D:1"; "D:2" ] ~f:(fun level ->
        Or_error.ok_exn (Reader.parse_line (line ~seed ~level))))
  in
  ignore (Db.write_batch db records : Db.Counts.t);
  db
;;

(* Seed 100 carries every summary signal, seed 200 none, seed 300 a Temple and
   nothing else. Every seed also holds the base fixture's two monster-carried
   artefacts, which is why the counts below are two higher than the floor items
   each was given. *)
let summary_corpus () =
  let db = corpus () in
  let records =
    [ feat_line ~seed:"100" ~level:"D:4" ~feat:"enter_temple"
    ; feat_line ~seed:"100" ~level:"D:6" ~feat:"altar_lugonu"
    ; feat_line ~seed:"100" ~level:"D:3" ~feat:"enter_sewer"
    ; portal_line ~seed:"100" ~level:"Sewer" ~parent:"D:3"
      (* One record per level: re-ingesting a (seed, version, level) replaces it,
         so two records for one level would overwrite rather than
         accumulate. *)
    ; item_line ~seed:"100" ~level:"D:5" ~name:"+9 rapier of Fixture" ~cost:None
    ; item_line ~seed:"100" ~level:"D:7" ~name:"ring of Fixture" ~cost:None
    ; item_line ~seed:"100" ~level:"D:8" ~name:"+3 shop stock" ~cost:(Some 400)
    ; consumable_line
        ~seed:"100"
        ~level:"D:9"
        ~base_type:"potion"
        ~sub_type:"experience"
        ~quantity:2
        ~cost:None
    ; consumable_line
        ~seed:"100"
        ~level:"D:10"
        ~base_type:"scroll"
        ~sub_type:"acquirement"
        ~quantity:1
        ~cost:None
      (* Priced: shop stock, and never a boon. *)
    ; consumable_line
        ~seed:"300"
        ~level:"D:9"
        ~base_type:"scroll"
        ~sub_type:"acquirement"
        ~quantity:1
        ~cost:(Some 350)
    ; feat_line ~seed:"300" ~level:"D:7" ~feat:"enter_temple"
    ]
    |> List.map ~f:(fun l -> Or_error.ok_exn (Reader.parse_line l))
  in
  ignore (Db.write_batch db records : Db.Counts.t);
  db
;;

let v = Or_error.ok_exn (Query.Version.of_string "0.34.1")

let show_page db page =
  let summaries, more = Or_error.ok_exn (Db.list_seeds db ~version:v ~page) in
  List.map summaries ~f:(fun (s : Level.Summary.t) -> s.seed, s.artefacts)
  |> [%sexp_of: (string * int) list]
  |> print_s;
  print_s [%sexp (more : [ `More | `End ])]
;;

(* A unique's weapon is loot you can take, unlike shop stock, so it counts. *)
let%expect_test "listing reports an unpriced artefact count per seed" =
  let db = corpus () in
  show_page db Query.Page.first;
  [%expect
    {|
    ((100 2) (200 2) (300 2))
    End
    |}];
  Db.close db
;;

let%expect_test "a summary carries temple depth, floor artefacts and highlights" =
  let db = summary_corpus () in
  let summaries, _ =
    Or_error.ok_exn (Db.list_seeds db ~version:v ~page:Query.Page.first)
  in
  List.iter summaries ~f:(fun (s : Level.Summary.t) ->
    print_s
      [%message
        ""
          ~seed:(s.seed : string)
          ~temple:(s.temple : string option)
          ~artefacts:(s.artefacts : int)
          ~altars:(s.rare_altars : string list)
          ~portals:(s.portals : (string * string option) list)
          ~boons:(s.boons : (Seed_corpus.Boon.t * int) list)
          ~heat:(s.heat : Seed_corpus.Heat.Band.t option)]);
  [%expect
    {|
    ((seed 100) (temple (D:4)) (artefacts 4) (altars (altar_lugonu))
     (portals ((Sewer (D:3)))) (boons ((Experience 2) (Acquirement 1)))
     (heat ()))
    ((seed 200) (temple ()) (artefacts 2) (altars ()) (portals ()) (boons ())
     (heat ()))
    ((seed 300) (temple (D:7)) (artefacts 2) (altars ()) (portals ()) (boons ())
     (heat ()))
    |}];
  Db.close db
;;

(* [summary_corpus]'s fixture only reaches D:2, so it cannot exercise
   [summarize]'s own D:8 cap. This one fills three seeds to D:8: "500" holds a
   floor artefact and reads warmer than "600" and "700", which tie at Cold. *)
let d8_corpus () =
  let db = Db.open_ ":memory:" in
  Db.exec_script db (In_channel.read_all "../schema.sql");
  let empty_level ~seed ~level =
    sprintf
      {|#SEED#((format 4)(version "0.34.1")(seed "%s")(level "%s")(cats))|}
      seed
      level
  in
  let levels ~seed ~with_item =
    List.init 8 ~f:(fun i ->
      let level = sprintf "D:%d" (i + 1) in
      if with_item && String.equal level "D:1"
      then item_line ~seed ~level ~name:"+9 rapier of Fixture" ~cost:None
      else empty_level ~seed ~level)
  in
  let records =
    levels ~seed:"500" ~with_item:true
    @ levels ~seed:"600" ~with_item:false
    @ levels ~seed:"700" ~with_item:false
    |> List.map ~f:(fun l -> Or_error.ok_exn (Reader.parse_line l))
  in
  ignore (Db.write_batch db records : Db.Counts.t);
  db
;;

(* No rescore has run, so every seed reads absent, not cold: a seed_scores miss
   means unscored, and the listing must not render that as [Cold]. [summarize]
   picks up [Fill_depth.shallow] without being told, because it hardcodes it. *)
let%expect_test "the listing's own D:8 cap: unscored reads absent, scored reads a band" =
  let db = d8_corpus () in
  let summaries, _ =
    Or_error.ok_exn (Db.list_seeds db ~version:v ~page:Query.Page.first)
  in
  List.iter summaries ~f:(fun (s : Level.Summary.t) ->
    print_s
      [%message
        "" ~seed:(s.seed : string) ~heat:(s.heat : Seed_corpus.Heat.Band.t option)]);
  [%expect
    {|
    ((seed 500) (heat ()))
    ((seed 600) (heat ()))
    ((seed 700) (heat ()))
    |}];
  Db.recompute_surprise db ~version:v ~cap:Seed_corpus.Fill_depth.shallow;
  Db.rescore db ~version:v ~cap:Seed_corpus.Fill_depth.shallow;
  let summaries, _ =
    Or_error.ok_exn (Db.list_seeds db ~version:v ~page:Query.Page.first)
  in
  List.iter summaries ~f:(fun (s : Level.Summary.t) ->
    print_s
      [%message
        "" ~seed:(s.seed : string) ~heat:(s.heat : Seed_corpus.Heat.Band.t option)]);
  [%expect
    {|
    ((seed 500) (heat (Hot)))
    ((seed 600) (heat (Cold)))
    ((seed 700) (heat (Cold)))
    |}];
  Db.close db
;;

(* Shop artefacts outnumber floor ones ~9:1 and are the ones a player cannot
   have, so counting both ranks shops rather than seeds. *)
let%expect_test "shop artefacts do not count toward a seed's loot" =
  let db = summary_corpus () in
  let all =
    Db.query
      db
      "select count(*) from entries e join versions v on v.id = e.version_id where \
       v.version = '0.34.1' and e.seed = '100' and e.artefact = 1"
  in
  print_s [%sexp (all : string list)];
  [%expect {| (5) |}];
  let summaries, _ =
    Or_error.ok_exn (Db.list_seeds db ~version:v ~page:Query.Page.first)
  in
  let hundred = List.find_exn summaries ~f:(fun s -> String.equal s.seed "100") in
  printf "%d\n" hundred.artefacts;
  [%expect {| 4 |}];
  Db.close db
;;

(* Keyset paging: the cursor is the last seed of the previous page, so the next
   page seeks straight past it rather than counting rows it discards. *)
let%expect_test "a page is bounded by limit and resumed by its last seed" =
  let db = corpus () in
  let page = Query.Page.create ~limit:2 () in
  show_page db page;
  [%expect
    {|
    ((100 2) (200 2))
    More
    |}];
  show_page db (Query.Page.create ~after:"200" ~limit:2 ());
  [%expect
    {|
    ((300 2))
    End
    |}];
  show_page db (Query.Page.create ~after:"300" ~limit:2 ());
  [%expect
    {|
    ()
    End
    |}];
  Db.close db
;;

(* The front page samples rather than paging from the first seed, so what
   matters is that every draw lands on a real seed of the right build and that
   asking twice can give different answers. *)
let%expect_test "a sample draws real seeds of the right build" =
  let db = corpus () in
  let sample limit =
    let summaries, more = Or_error.ok_exn (Db.sample_seeds db ~version:v ~limit) in
    List.map summaries ~f:(fun (s : Level.Summary.t) -> s.seed), more
  in
  let seeds, more = sample 3 in
  let known = Set.of_list (module String) [ "100"; "200"; "300" ] in
  (* Draws are independent, so two can land on the same seed: [limit] is an upper
     bound, not a promise. Invisible on a real corpus, near-certain on a
     three-seed one. *)
  printf
    "within limit: %b, all real: %b, distinct: %b\n"
    (List.length seeds <= 3 && not (List.is_empty seeds))
    (List.for_all seeds ~f:(Set.mem known))
    (List.contains_dup seeds ~compare:String.compare |> not);
  (* A sample has no end to reach, so it never advertises more. *)
  print_s [%sexp (more : [ `More | `End ])];
  [%expect
    {|
    within limit: true, all real: true, distinct: true
    End
    |}];
  (* Asking for more than the corpus holds cannot invent seeds. *)
  let seeds, _ = sample 20 in
  printf "%d\n" (List.length seeds);
  [%expect {| 3 |}];
  (* A build with nothing ingested samples empty rather than falling back to
     another build's seeds. *)
  let other = Or_error.ok_exn (Query.Version.of_string "0.33.1") in
  let empty, _ = Or_error.ok_exn (Db.sample_seeds db ~version:other ~limit:5) in
  printf "%d\n" (List.length empty);
  [%expect {| 0 |}];
  Db.close db
;;

let%expect_test "a submitted seed is not listed, sampled or counted" =
  let db = corpus () in
  ignore
    (Db.write_batch
       ~requested:true
       db
       [ Or_error.ok_exn (Reader.parse_line (line ~seed:"150" ~level:"D:1")) ]
     : Db.Counts.t);
  show_page db Query.Page.first;
  [%expect
    {|
    ((100 2) (200 2) (300 2))
    End
    |}];
  let sampled, _ = Or_error.ok_exn (Db.sample_seeds db ~version:v ~limit:50) in
  List.map sampled ~f:(fun (s : Level.Summary.t) -> s.seed)
  |> List.sort ~compare:String.compare
  |> String.concat ~sep:" "
  |> print_endline;
  [%expect {| 100 200 300 |}];
  printf "%d\n" (Or_error.ok_exn (Db.seed_count db ~version:v));
  [%expect {| 3 |}];
  (* The seed itself is still there to read. *)
  printf
    "%d level(s)\n"
    (List.length (Or_error.ok_exn (Db.seed_levels db ~version:v ~seed:"150")));
  [%expect {| 1 level(s) |}];
  Db.close db
;;

let%expect_test "the searchable count takes a submitted seed once a rebuild indexes it" =
  let db = corpus () in
  ignore
    (Db.write_batch
       ~requested:true
       db
       [ Or_error.ok_exn (Reader.parse_line (line ~seed:"150" ~level:"D:1")) ]
     : Db.Counts.t);
  let show () =
    printf
      "sample %d, searchable %d\n"
      (Or_error.ok_exn (Db.seed_count db ~version:v))
      (Or_error.ok_exn (Db.searchable_seed_count db ~version:v))
  in
  show ();
  [%expect {| sample 3, searchable 3 |}];
  Or_error.ok_exn (Db.build_search_index db ~version:v);
  show ();
  [%expect {| sample 3, searchable 4 |}];
  Db.close db
;;

(* Without sqlite_stat1 the planner sizes every index from built-in defaults
   and underestimates the partial ones badly: on the 10k corpus it chose
   entries_seed over entries_search_artefact, walking every entry of all 200
   seeds to find 151 rows -- 161ms against 1.9ms once statistics existed. *)
let%expect_test "closing a connection leaves index statistics behind" =
  let path = Filename_unix.temp_file "corpus" ".db" in
  Exn.protect
    ~finally:(fun () -> Sys_unix.remove path)
    ~f:(fun () ->
      let db = Db.open_ path in
      Db.exec_script db (In_channel.read_all "../schema.sql");
      let records =
        List.map [ "D:1"; "D:2" ] ~f:(fun level ->
          Or_error.ok_exn (Reader.parse_line (line ~seed:"100" ~level)))
      in
      ignore (Db.write_batch db records : Db.Counts.t);
      Db.close db;
      let db = Db.open_ path in
      Db.query db "select count(*) from sqlite_master where name = 'sqlite_stat1'"
      |> List.iter ~f:print_endline;
      [%expect {| 1 |}];
      Db.close db)
;;

let%expect_test "a seed's levels come back grouped and version-scoped" =
  let db = corpus () in
  Db.seed_levels db ~version:v ~seed:"200"
  |> Or_error.ok_exn
  |> List.map ~f:(fun (l : Level.t) -> l.level, List.map l.entries ~f:(fun e -> e.name))
  |> [%sexp_of: (string * string list) list]
  |> print_s;
  [%expect
    {|
    ((D:1 ("an iron altar of Okawaru" "+1 sling" kobold))
     (D:2 ("an iron altar of Okawaru" "+1 sling" kobold)))
    |}];
  (* A seed that exists on another build is not this build's seed. *)
  let other = Or_error.ok_exn (Query.Version.of_string "0.33.1") in
  Db.seed_levels db ~version:other ~seed:"200"
  |> Or_error.ok_exn
  |> List.length
  |> printf "%d\n";
  [%expect {| 0 |}];
  Db.close db
;;

let%expect_test "an unknown seed reads as empty rather than an error" =
  let db = corpus () in
  Db.seed_levels db ~version:v ~seed:"999"
  |> Or_error.ok_exn
  |> List.length
  |> printf "%d\n";
  [%expect {| 0 |}];
  Db.close db
;;

(* Both accessors run on the Lwt scheduler thread, so both must be
   index-backed; a plan that scans is a missing index. Only the SEARCH/SCAN
   lines are asserted: they name the access path, which is the property. The
   rest -- subquery labels, temp b-trees, bloom filters -- is planner narration
   whose wording changes between sqlite versions. *)
let show_plan db sql =
  Db.query db ("explain query plan " ^ sql)
  |> List.map ~f:(fun row -> List.last_exn (String.split row ~on:'|'))
  |> List.filter ~f:(fun text ->
    String.is_prefix text ~prefix:"SEARCH " || String.is_prefix text ~prefix:"SCAN ")
  |> List.iter ~f:print_endline
;;

let%expect_test "the read queries are index-backed" =
  let db = corpus () in
  show_plan
    db
    "select distinct seed from seed_levels where version_id = 1 and seed > 'y' order by \
     seed limit 2";
  [%expect
    {| SEARCH seed_levels USING COVERING INDEX seed_levels_version_seed (version_id=? AND seed>?) |}];
  (* Each summary lookup must seek per named seed: an `in` list of the page's
     seeds is what keeps these flat, where bounding them by [first, last] would
     scan the sampler's whole keyspace range. *)
  show_plan
    db
    "select e.seed, e.feat_id, e.level_id from entries e where e.version_id = 1 and \
     e.feat_id in (select id from strings where val in ('enter_temple', 'altar_lugonu')) \
     and e.seed in ('a', 'b')";
  [%expect
    {|
    SEARCH e USING COVERING INDEX entries_search_feat (version_id=? AND feat_id=? AND seed=?)
    SEARCH strings USING COVERING INDEX sqlite_autoindex_strings_1 (val=?)
    |}];
  (* On a three-seed corpus entries_seed is genuinely the cheaper plan, so this
     asserts only that the artefact count seeks *something*. Which index it
     picks at corpus scale is a statistics question, not a schema one. *)
  show_plan
    db
    "select seed, count(*) from entries where version_id = 1 and artefact = 1 and cost \
     is null and seed in ('a', 'b') group by seed";
  [%expect
    {| SEARCH entries USING INDEX entries_search_artefact (version_id=? AND seed=?) |}];
  show_plan
    db
    "select seed, count(*) from entries indexed by entries_search_artefact where \
     version_id = 1 and artefact = 1 and cost is null and seed in ('a', 'b') group by \
     seed";
  [%expect
    {| SEARCH entries USING INDEX entries_search_artefact (version_id=? AND seed=?) |}];
  show_plan
    db
    "select seed, level_id, parent_level_id from seed_levels where version_id = 1 and \
     seed in ('a', 'b') and parent_level_id is not null";
  [%expect
    {| SEARCH seed_levels USING COVERING INDEX seed_levels_parent (version_id=? AND parent_level_id>?) |}];
  (* The seed page's own entry read: one seek over the seed's rows, with the
     dictionary joins hanging off it as rowid probes rather than scans. *)
  show_plan
    db
    "select e.id, s_name.val from entries e left join strings s_name on s_name.id = \
     e.name_id where e.seed = 'a' and e.version_id = 1 order by e.level_id, e.cat, e.id";
  [%expect
    {|
    SEARCH e USING INDEX entries_seed (seed=? AND version_id=?)
    SEARCH s_name USING INTEGER PRIMARY KEY (rowid=?) LEFT-JOIN
    |}];
  Db.close db
;;

(* The [like] runs over the dictionary -- the corpus's *vocabulary*, not its
   rows -- and each id it yields is a covering seek on entries_search_name. Both
   halves are asserted, because losing either silently restores the scan. *)
let%expect_test "a substring name search seeks rather than scanning entries" =
  let db = corpus () in
  show_plan
    db
    "select distinct seed from entries where version_id = 1 and name_id in (select id \
     from strings where val like '%Wyrmbane%' escape '\\')";
  [%expect
    {|
    SEARCH entries USING COVERING INDEX entries_search_name (version_id=? AND name_id=?)
    SCAN strings
    |}];
  Db.close db
;;

(* The [cost is null] test used to fall outside entries_search_type, so the seek
   was index-driven but every matching row cost a random table lookup. [cost]
   now trails the index, so both shapes are covering; this is what would catch
   the column falling back out.

   It stopped being an edge case when floor became the default: every
   unqualified item search now carries this predicate, and the positionless
   shape below is only the control. *)
let%expect_test "a floor-item search seeks a covering index, same as the bare item search"
  =
  let db = corpus () in
  show_plan
    db
    "select distinct seed from entries where version_id = 1 and base_type_id = 2 and \
     sub_type_id = 3 and cost is null";
  [%expect
    {| SEARCH entries USING COVERING INDEX entries_search_type (version_id=? AND base_type_id=? AND sub_type_id=?) |}];
  show_plan
    db
    "select distinct seed from entries where version_id = 1 and base_type_id = 2 and \
     sub_type_id = 3";
  [%expect
    {| SEARCH entries USING COVERING INDEX entries_search_type (version_id=? AND base_type_id=? AND sub_type_id=?) |}];
  (* The shop half stays covering whichever index wins, which is the property
     worth pinning: entries_search_shop is qualified on [cost is not null] and
     entries_search_type carries [cost] as its last column. Without statistics
     this fixture picks the latter; prod picks the former. What must not vary is
     the predicate itself -- dropping it let the planner return floor stock too
     (335,174 vs 30,870 rows, wand:digging, 1.3M, 0.34.1, 2026-09-05, prod). *)
  show_plan
    db
    "select distinct seed from entries where version_id = 1 and base_type_id = 2 and \
     sub_type_id = 3 and cost is not null";
  [%expect
    {| SEARCH entries USING COVERING INDEX entries_search_type (version_id=? AND base_type_id=? AND sub_type_id=?) |}];
  Db.close db
;;

(* sqlite_stat1's average of 4 rows per (version_id, name_id) is a wild
   underestimate for a unique monster's name (Sigmund: 98,156 rows), so a fresh
   `analyze` retargeted this query onto entries_search_name and ate an uncovered
   table lookup per row. Steering the planner back by statistics was rejected --
   the next `analyze` can retarget it again. Instead entries_search_name also
   carries `unique_mons`, so this asserts coverage, not index choice. *)
let%expect_test
    "a unique-monster search seeks a covering index regardless of which index the \
     planner picks"
  =
  let db = corpus () in
  show_plan
    db
    "select distinct seed from entries where version_id = 1 and unique_mons = 1 and \
     name_id = 3";
  [%expect
    {| SEARCH entries USING COVERING INDEX entries_search_unique (version_id=? AND name_id=?) |}];
  Db.close db
;;

(* entry_spells is keyed by entries.id, which is a rowid alias, so a re-ingest
   -- delete from seed_levels, cascade, re-insert -- reassigns it. *)
let book_line ~seed ~level ~name ~filler =
  let filler =
    if filler
    then
      {|((base_type "scroll")(kind "item")(name "filler")(quantity 1)(sub_type "fear")(text "filler"))|}
    else ""
  in
  sprintf
    {|#SEED#((format 4)(version "0.34.1")(seed "%s")(level "%s")(cats (items (%s((artefact t)(base_type "book")(kind "item")(name "%s")(quantity 1)(spells ("Blink" "Freeze"))(sub_type "book of Fixed Theme")(text "%s"))))))|}
    seed
    level
    filler
    name
    name
;;

(* Db.seed_levels runs five statements. WAL gives a consistent snapshot per
   *statement*, not across a call, so without an enclosing transaction a commit
   landing mid-call is half-visible: the spell and property tables are keyed by
   the ids that existed when they were read, and the entries arrive carrying the
   ids assigned after. The book renders with no spells -- no error, no missing
   row. *)
let%expect_test "a read sees one snapshot even when a re-ingest lands mid-call" =
  let path = Filename_unix.temp_file "corpus" ".db" in
  Exn.protect
    ~finally:(fun () ->
      (Db.between_reads := fun () -> ());
      Sys_unix.remove path)
    ~f:(fun () ->
      let reader = Db.open_ path in
      Db.exec_script reader (In_channel.read_all "../schema.sql");
      let ingest db lines =
        ignore
          (Db.write_batch
             db
             (List.map lines ~f:(fun l -> Or_error.ok_exn (Reader.parse_line l)))
           : Db.Counts.t)
      in
      let book ~filler =
        book_line ~seed:"300" ~level:"D:1" ~name:"Wamnu's Compendium" ~filler
      in
      ingest reader [ book ~filler:true ];
      let writer = Db.open_ path in
      (* The interleave, forced into the one window where it corrupts: the writer
         commits between the reader's child reads and its entry read. *)
      (Db.between_reads
       := fun () ->
            (Db.between_reads := fun () -> ());
            ingest writer [ book ~filler:false ];
            Db.close writer);
      Db.seed_levels reader ~version:v ~seed:"300"
      |> Or_error.ok_exn
      |> List.concat_map ~f:(fun (l : Level.t) ->
        List.map l.entries ~f:(fun e -> e.name, e.spells))
      |> [%sexp_of: (string * string list) list]
      |> print_s;
      [%expect {| (("Wamnu's Compendium" (Blink Freeze)) ("scroll of fear" ())) |}];
      Db.close reader)
;;
