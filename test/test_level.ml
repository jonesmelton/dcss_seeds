open! Core
module Level = Seed_corpus.Level
module Record = Seed_corpus.Record

let entry ?feat ~name () : Record.Entry.t =
  { cat = Record.Cat.Items
  ; name
  ; base_type = None
  ; sub_type = None
  ; quantity = None
  ; artefact = None
  ; branded = None
  ; plus = None
  ; cost = None
  ; ego = None
  ; feat
  ; timeout_turns = None
  ; unique_mons = None
  ; native = None
  ; type_name = None
  ; x = None
  ; y = None
  ; carried_by = None
  ; shop_type = None
  ; toll_note = None
  ; spells = []
  ; props = []
  }
;;

let show rows =
  Level.of_rows rows
  |> List.map ~f:(fun (l : Level.t) -> l.level, List.map l.entries ~f:Record.Entry.name)
  |> [%sexp_of: (string * string list) list]
  |> print_s
;;

let%expect_test "levels keep first-seen order and entries keep row order" =
  show
    [ "D:1", entry ~name:"a" ()
    ; "D:1", entry ~name:"b" ()
    ; "D:2", entry ~name:"c" ()
    ; "D:1", entry ~name:"d" ()
    ];
  [%expect {| ((D:1 (a b d)) (D:2 (c))) |}]
;;

let show_parents rows =
  Level.of_rows rows
  |> List.map ~f:(fun (l : Level.t) -> l.level, l.parent_level)
  |> [%sexp_of: (string * string option) list]
  |> print_s
;;

let%expect_test "a portal takes the level holding its entrance feature" =
  show_parents
    [ "D:5", entry ~feat:"enter_sewer" ~name:"a glowing drain" ()
    ; "Sewer", entry ~name:"potion of haste" ()
    ; "D:6", entry ~feat:"enter_ossuary" ~name:"a sand-covered staircase" ()
    ; "Ossuary", entry ~name:"scroll of fog" ()
    ];
  [%expect {| ((D:5 ()) (Sewer (D:5)) (D:6 ()) (Ossuary (D:6))) |}]
;;

let%expect_test "a non-portal level has no parent, and an unmatched portal stays unknown" =
  show_parents
    [ "D:1", entry ~name:"a" ()
    ; "D:7", entry ~feat:"enter_temple" ~name:"a staircase" ()
    ; "Temple", entry ~name:"an altar" ()
    ; "Bailey", entry ~name:"a sword" ()
    ];
  [%expect {| ((D:1 ()) (D:7 ()) (Temple ()) (Bailey ())) |}]
;;
