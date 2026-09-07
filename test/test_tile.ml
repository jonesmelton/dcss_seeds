open! Core
open Seed_corpus
module Record = Seed_corpus.Record

let%expect_test "the derivation-resistant names resolve" =
  List.iter
    [ "altar_hepliaklqana"
    ; "altar_jiyva"
    ; "altar_makhleb"
    ; "altar_nemelex_xobeh"
    ; "altar_the_shining_one"
    ; "enter_sewer"
    ; "enter_ziggurat"
    ; "transporter"
    ]
    ~f:(fun feat -> print_s [%sexp (feat : string), (Tile.of_feat feat : Tile.t option)]);
  [%expect
    {|
    (altar_hepliaklqana (altars/hep0.png))
    (altar_jiyva (altars/jiyva01.png))
    (altar_makhleb (altars/makhleb_flame1.png))
    (altar_nemelex_xobeh (altars/nemelex1.png))
    (altar_the_shining_one (altars/shining_one.png))
    (enter_sewer (gateways/sewer_portal.png))
    (enter_ziggurat (gateways/zig_portal.png))
    (transporter (misc/transporter.png))
    |}]
;;

let%expect_test "an unknown feat has no tile" =
  print_s [%sexp (Tile.of_feat "altar_xobeh" : Tile.t option)];
  print_s [%sexp (Tile.of_feat "" : Tile.t option)];
  [%expect
    {|
    ()
    ()
    |}]
;;

let%expect_test "every temple pool god has a tile" =
  let missing =
    List.filter Temple.pool ~f:(fun feat -> Option.is_none (Tile.of_feat feat))
  in
  print_s [%sexp (missing : string list)];
  [%expect {| () |}]
;;

let%expect_test "the slice covers every feat" =
  print_s [%sexp (List.length Tile.known_feats : int)];
  [%expect {| 82 |}]
;;

let%expect_test "a unique whose tile drops its epithet still resolves" =
  List.iter
    [ "Blorkula the orcula"; "Sigmund"; "Bai Suzhen"; "Xak'krixis"; "Prince Ribbit" ]
    ~f:(fun name ->
      print_s [%sexp (name : string), (Tile.of_unique name : Tile.t option)]);
  [%expect
    {|
    ("Blorkula the orcula" (uniques/blorkula.png))
    (Sigmund (uniques/sigmund.png))
    ("Bai Suzhen" (uniques/bai_suizhen.png))
    (Xak'krixis (uniques/xakkrixis.png))
    ("Prince Ribbit" (uniques/prince_ribbit.png))
    |}]
;;

let%expect_test "an ordinary monster has no tile" =
  print_s [%sexp (Tile.of_unique "gnoll" : Tile.t option)];
  [%expect {| () |}]
;;

(* Crawl draws a separate randart tile for many base types, so an artefact of
   those types is not merely the base item with a flag beside it. *)
let%expect_test "an artefact prefers crawl's randart art where it exists" =
  let show base_type sub_type =
    let of_ artefact = Tile.of_item ~base_type ~sub_type ~artefact in
    print_s
      [%sexp (sub_type : string), (of_ false : Tile.t option), (of_ true : Tile.t option)]
  in
  show "weapon" "sling";
  show "armour" "fire dragon scales";
  show "jewellery" "ring of slaying";
  show "staff" "alchemy";
  [%expect
    {|
    (sling (items/sling1.png) (items/sling3.png))
    ("fire dragon scales" (items/fire_dragon_armour.png)
     (items/fire_dragon_armour_art.png))
    ("ring of slaying" (items/i-slaying.png) (items/i-slaying.png))
    (alchemy (items/i-staff_poison.png) (items/i-staff_poison.png))
    |}]
;;

(* Renames that never reached the tile tables: crawl's own two halves disagree,
   so these are the cases a derivation gets wrong rather than merely misses. *)
let%expect_test "the renamed types resolve to the art crawl actually drew" =
  List.iter
    [ "talisman", "serpent talisman"
    ; "talisman", "lupine talisman"
    ; "talisman", "granite talisman"
    ; "staff", "alchemy"
    ; "jewellery", "amulet of chemistry"
    ; "jewellery", "amulet of regeneration"
    ; "miscellaneous", "Gell's gravitambourine"
    ; "weapon", "eudemon blade"
    ]
    ~f:(fun (base_type, sub_type) ->
      print_s
        [%sexp
          (sub_type : string)
        , (Tile.of_item ~base_type ~sub_type ~artefact:false : Tile.t option)]);
  [%expect
    {|
    ("serpent talisman" (items/snake.png))
    ("lupine talisman" (items/lupine.png))
    ("granite talisman" (items/statue.png))
    (alchemy (items/i-staff_poison.png))
    ("amulet of chemistry" (items/i-alchemy.png))
    ("amulet of regeneration" (items/i-regeneration.png))
    ("Gell's gravitambourine" (items/misc_tambourine.png))
    ("eudemon blade" (items/blessed_blade.png))
    |}]
;;

let%expect_test "an unmapped item has no tile" =
  print_s
    [%sexp
      (Tile.of_item ~base_type:"potion" ~sub_type:"haste" ~artefact:false : Tile.t option)];
  print_s
    [%sexp
      (Tile.of_item ~base_type:"weapon" ~sub_type:"arrow" ~artefact:false : Tile.t option)];
  [%expect
    {|
    (items/potion_haste.png)
    ()
    |}]
;;

let%expect_test "the slice covers every unique and item type" =
  print_s [%sexp (List.length Tile.known_uniques : int)];
  print_s [%sexp (List.length Tile.known_items : int)];
  [%expect
    {|
    94
    192
    |}]
;;

let entry ?feat ?base_type ?sub_type ?artefact ?unique_mons ?carried_by ~cat ~name ()
  : Record.Entry.t
  =
  { cat
  ; name
  ; base_type
  ; sub_type
  ; quantity = None
  ; artefact
  ; branded = None
  ; plus = None
  ; cost = None
  ; ego = None
  ; feat
  ; timeout_turns = None
  ; unique_mons
  ; native = None
  ; type_name = None
  ; x = None
  ; y = None
  ; carried_by
  ; shop_type = None
  ; toll_note = None
  ; spells = []
  ; props = []
  }
;;

let%expect_test "an entry draws from the vocabulary it belongs to" =
  let show label e =
    print_s [%sexp (label : string), (Tile.of_entry e : Tile.t option)]
  in
  show
    "feature"
    (entry ~cat:Features ~name:"a staircase to the Lair" ~feat:"enter_lair" ());
  show "unique" (entry ~cat:Monsters ~name:"Sigmund" ~unique_mons:true ());
  show
    "plain item"
    (entry ~cat:Items ~name:"a +0 sling" ~base_type:"weapon" ~sub_type:"sling" ());
  show
    "artefact item"
    (entry
       ~cat:Items
       ~name:{|+9 sling of the Reaper {drain}|}
       ~base_type:"weapon"
       ~sub_type:"sling"
       ~artefact:true
       ());
  show
    "evokable"
    (entry
       ~cat:Items
       ~name:"a lightning rod"
       ~base_type:"miscellaneous"
       ~sub_type:"lightning rod"
       ());
  [%expect
    {|
    (feature (gateways/enter_lair.png))
    (unique (uniques/sigmund.png))
    ("plain item" (items/sling1.png))
    ("artefact item" (items/sling3.png))
    (evokable (items/misc_lightning_rod.png))
    |}]
;;

(* The vocabulary is deliberately narrower than the corpus's: an ordinary
   monster and an ammunition type are outside it, while a potion is inside it
   because its class is 61% of what a seed page prints. *)
let%expect_test "an entry outside the slice has no tile" =
  let show label e =
    print_s [%sexp (label : string), (Tile.of_entry e : Tile.t option)]
  in
  show "ordinary monster" (entry ~cat:Monsters ~name:"a gnoll" ());
  show
    "ammunition"
    (entry ~cat:Items ~name:"12 boomerangs" ~base_type:"missile" ~sub_type:"boomerang" ());
  show
    "potion"
    (entry ~cat:Items ~name:"2 potions of haste" ~base_type:"potion" ~sub_type:"haste" ());
  [%expect
    {|
    ("ordinary monster" ())
    (ammunition ())
    (potion (items/potion_haste.png))
    |}]
;;

(* A wrong path renders as a broken image rather than raising, so the table is
   checked against the vendored tree instead of only against itself. *)
let%expect_test "every tile the tables name is vendored" =
  let missing =
    List.filter_map Tile.known_items ~f:(fun (base_type, sub_type) ->
      match Tile.of_item ~base_type ~sub_type ~artefact:false with
      | None -> Some (base_type ^ "/" ^ sub_type)
      | Some path ->
        if Sys_unix.file_exists_exn ("../static/tiles/" ^ Tile.to_string path)
        then None
        else Some (Tile.to_string path))
  in
  print_s [%sexp (missing : string list)];
  [%expect {| () |}]
;;

(* A parchment's art is picked by its spell's tier rather than by its type, so
   the table has to cover every spell a player book can carry. *)
let%expect_test "every book spell resolves to a parchment tile" =
  let unresolved =
    List.filter Seed_corpus.Spell.known ~f:(fun s ->
      Option.is_none (Seed_corpus.Spell.of_parchment ("parchment of " ^ s)))
  in
  print_s [%sexp (List.length Seed_corpus.Spell.known : int), (unresolved : string list)];
  [%expect {| (132 ()) |}]
;;
