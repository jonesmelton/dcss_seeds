open! Core
module Brand = Seed_corpus.Search.Brand
module Display_name = Seed_corpus.Display_name
module Record = Seed_corpus.Record
module Version = Seed_corpus.Query.Version

let version s = Or_error.ok_exn (Version.of_string s)

(* {1 Release order}

   [compare] is string order, which cannot answer "did this build have the
   capitalised armour ego codes". Only [release_compare] can, and [Brand.code]
   is its first consumer. *)

let show_compare a b =
  printf "%-28s vs %-20s %d\n" a b (Version.release_compare (version a) (version b))
;;

let%expect_test "release_compare orders the dotted numbers, not the strings" =
  show_compare "0.33.1" "0.34.1";
  show_compare "0.34.1" "0.33.1";
  show_compare "0.34.1" "0.34.1";
  show_compare "0.9.1" "0.10.1";
  show_compare "0.34" "0.34.1";
  show_compare "0.34.2" "0.34.10";
  [%expect
    {|
    0.33.1                       vs 0.34.1               -1
    0.34.1                       vs 0.33.1               1
    0.34.1                       vs 0.34.1               0
    0.9.1                        vs 0.10.1               -1
    0.34                         vs 0.34.1               -1
    0.34.2                       vs 0.34.10              -1
    |}]
;;

(* Trunk is a build a day and carries changes no release has taken, so it sorts
   after every release. A dev version string with a release prefix compares by
   that prefix. *)
let%expect_test "an unreleased build sorts after every release" =
  show_compare "trunk" "0.34.1";
  show_compare "0.34.1" "trunk";
  show_compare "trunk" "trunk";
  show_compare "0.33-a0-4444-g172805db8e" "0.32.1";
  show_compare "0.33-a0-4444-g172805db8e" "0.34.1";
  [%expect
    {|
    trunk                        vs 0.34.1               1
    0.34.1                       vs trunk                -1
    trunk                        vs trunk                0
    0.33-a0-4444-g172805db8e     vs 0.32.1               1
    0.33-a0-4444-g172805db8e     vs 0.34.1               -1
    |}]
;;

(* {1 The word tables}

   The tables are the searchable vocabulary and they mirror what a rendered name
   shows, which is what a reader types. This is the test that forces a rekey
   here when crawl renames one -- the job the renames plan
   (docs/plans/crawl-renames.md) wants [Rename] to do generally. *)

(* Rendered through the real path rather than by reaching into Display_name's
   tables: the fact the vocabulary rests on is that the word a reader types is
   the word a name shows. *)
let rendered ~base_type code =
  let sub_type = if String.equal base_type "weapon" then "dagger" else "robe" in
  Display_name.render
    { Record.Entry.cat = Record.Cat.Items
    ; name = ""
    ; base_type = Some base_type
    ; sub_type = Some sub_type
    ; quantity = Some 1
    ; artefact = Some false
    ; branded = Some true
    ; plus = Some 0
    ; cost = None
    ; ego = Some code
    ; feat = None
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

let%expect_test "every searchable word is the word Display_name renders" =
  let mismatches = ref 0 in
  List.iter Brand.base_types ~f:(fun base_type ->
    List.iter (Brand.words ~base_type) ~f:(fun word ->
      match Brand.code ~base_type ~version:(version "0.34.1") word with
      | None ->
        incr mismatches;
        printf "%s: %S has no code\n" base_type word
      | Some code ->
        let shown = rendered ~base_type code in
        (match Brand.why_excluded ~base_type word with
         | Some _ ->
           (* An artefact-only code has no display word: no non-artefact item
              ever renders it, so the plain item is what comes out. *)
           if String.is_substring shown ~substring:word
           then (
             incr mismatches;
             printf
               "%s: %S is excluded yet a mundane item renders %S\n"
               base_type
               word
               shown)
         | None ->
           if not (String.is_substring shown ~substring:word)
           then (
             incr mismatches;
             printf
               "%s: %S is searchable but a mundane item renders %S\n"
               base_type
               word
               shown))));
  printf "mismatches: %d\n" !mismatches;
  [%expect {| mismatches: 0 |}]
;;

(* Injective per base type: one word, one code. Cross-table collisions are
   expected and fine ("protection" is a weapon brand and an armour ego) -- the
   criterion's base type picks the table. *)
let%expect_test "each base type's words and codes are injective" =
  List.iter Brand.base_types ~f:(fun base_type ->
    let words = Brand.words ~base_type in
    let codes =
      List.filter_map words ~f:(Brand.code ~base_type ~version:(version "0.34.1"))
    in
    printf
      "%s: %d words, %d codes, %d distinct\n"
      base_type
      (List.length words)
      (List.length codes)
      (List.length (List.dedup_and_sort codes ~compare:String.compare)));
  [%expect
    {|
    weapon: 25 words, 25 codes, 25 distinct
    armour: 44 words, 44 codes, 44 distinct
    |}]
;;

(* The artefact-only codes are the ones with no display word, and the parse
   boundary refuses them by name. This is the list the exclusion rests on. *)
let%expect_test "the artefact-only words are exactly the excluded ones" =
  List.iter Brand.base_types ~f:(fun base_type ->
    let excluded =
      List.filter (Brand.words ~base_type) ~f:(fun word ->
        Option.is_some (Brand.why_excluded ~base_type word))
    in
    printf "%s: %s\n" base_type (String.concat excluded ~sep:", "));
  [%expect
    {|
    weapon: penetration, reaping, acid, foul flame
    armour: spirit shield, the Archmagi
    |}]
;;

(* {1 Word to code} *)

let%expect_test "a word resolves case-insensitively, per base type" =
  printf
    "weapon protection -> %s\n"
    (Option.value_exn
       (Brand.code ~base_type:"weapon" ~version:(version "0.34.1") "PROTECTION"));
  printf
    "armour protection -> %s\n"
    (Option.value_exn
       (Brand.code ~base_type:"armour" ~version:(version "0.34.1") "Protection"));
  printf
    "unknown -> %s\n"
    (Sexp.to_string
       (Option.sexp_of_t
          String.sexp_of_t
          (Brand.code ~base_type:"weapon" ~version:(version "0.34.1") "flame")));
  [%expect
    {|
    weapon protection -> protect
    armour protection -> AC+3
    unknown -> ()
    |}]
;;

(* Weapon codes are stable across the served builds; armour capitalised eleven
   of them in 0.34.1 (crawl-renames.md). Trunk carries the newer spelling. *)
let%expect_test "the armour capitalisation is version-keyed" =
  let show ~base_type word v =
    printf
      "%-6s %-16s %-10s %s\n"
      base_type
      word
      v
      (Option.value_exn (Brand.code ~base_type ~version:(version v) word))
  in
  List.iter [ "0.32.1"; "0.33.1"; "0.34.1"; "trunk" ] ~f:(fun v ->
    show ~base_type:"armour" "harm" v);
  List.iter [ "0.32.1"; "0.34.1" ] ~f:(fun v ->
    show ~base_type:"armour" "fire resistance" v);
  List.iter [ "0.32.1"; "0.34.1" ] ~f:(fun v -> show ~base_type:"weapon" "distortion" v);
  (* Spirit and the Archmagi were already capitalised before 0.34.1, so they
     are not in the renamed set and must not be downcased for an old build. *)
  show ~base_type:"armour" "spirit shield" "0.32.1";
  show ~base_type:"armour" "the Archmagi" "0.32.1";
  [%expect
    {|
    armour harm             0.32.1     harm
    armour harm             0.33.1     harm
    armour harm             0.34.1     Harm
    armour harm             trunk      Harm
    armour fire resistance  0.32.1     rF+
    armour fire resistance  0.34.1     rF+
    weapon distortion       0.32.1     distort
    weapon distortion       0.34.1     distort
    armour spirit shield    0.32.1     Spirit
    armour the Archmagi     0.32.1     Archmagi
    |}]
;;

let%expect_test "word_of_code is the inverse, for a reader who typed the code" =
  printf
    "distort -> %s\n"
    (Option.value_exn (Brand.word_of_code ~base_type:"weapon" "distort"));
  printf "rF+ -> %s\n" (Option.value_exn (Brand.word_of_code ~base_type:"armour" "rF+"));
  printf
    "reap (artefact-only) -> %s\n"
    (Option.value_exn (Brand.word_of_code ~base_type:"weapon" "reap"));
  printf
    "no such code -> %s\n"
    (Sexp.to_string
       (Option.sexp_of_t
          String.sexp_of_t
          (Brand.word_of_code ~base_type:"weapon" "no such code")));
  [%expect
    {|
    distort -> distortion
    rF+ -> fire resistance
    reap (artefact-only) -> reaping
    no such code -> ()
    |}]
;;
