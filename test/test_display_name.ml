open! Core
module Display_name = Seed_corpus.Display_name
module Record = Seed_corpus.Record

let entry
      ?feat
      ?shop_type
      ?base_type
      ?sub_type
      ?quantity
      ?artefact
      ?branded
      ?plus
      ?ego
      ?type_name
      ?(cat = Record.Cat.Items)
      ?(name = "<stored>")
      ()
  : Record.Entry.t
  =
  { cat
  ; name
  ; base_type
  ; sub_type
  ; quantity
  ; artefact
  ; branded
  ; plus
  ; cost = None
  ; ego
  ; feat
  ; timeout_turns = None
  ; unique_mons = None
  ; native = None
  ; type_name
  ; x = None
  ; y = None
  ; carried_by = None
  ; shop_type
  ; toll_note = None
  ; spells = []
  ; props = []
  }
;;

let show es =
  List.iter es ~f:(fun e ->
    match Display_name.of_entry e with
    | Display_name.Derived s -> print_endline s
    | Display_name.Irreducible -> print_endline "<irreducible>")
;;

let item ?quantity ?artefact ?branded ?plus ?ego base_type sub_type =
  entry ?quantity ?artefact ?branded ?plus ?ego ~base_type ~sub_type ()
;;

let feature ?shop_type feat = entry ~cat:Record.Cat.Features ?shop_type ~feat ()

let%expect_test "a feature's name is a function of its feat" =
  show
    [ feature "altar_trog"
    ; feature "altar_the_shining_one"
    ; feature "altar_wu_jian"
    ; feature "altar_ecumenical"
    ; feature "enter_temple"
    ; feature "enter_lair"
    ; feature "enter_abyss"
    ; feature "enter_sewer"
    ; feature "transporter"
    ];
  [%expect
    {|
    a bloodstained altar of Trog
    a glowing golden altar of the Shining One
    an ornate altar of the Wu Jian Council
    a faded altar of an unknown god
    a staircase to the Ecumenical Temple
    a staircase to the Lair
    a one-way gate to the infinite horrors of the Abyss
    a glowing drain
    a transporter
    |}]
;;

let%expect_test "an ice cave's two tiers collapse to one rendering" =
  (* Deliberate: "a glacial archway" (31% of enter_ice_cave) is not recoverable
     from any stored column. *)
  show [ feature "enter_ice_cave"; feature "enter_ice_cave" ];
  [%expect
    {|
    a frozen archway
    a frozen archway
    |}]
;;

let%expect_test "a feat this version has never seen is irreducible" =
  show [ feature "enter_new_branch_from_the_future" ];
  [%expect {| <irreducible> |}]
;;

let%expect_test "a shop renders from its type, never its keeper" =
  show
    [ feature "enter_shop" ~shop_type:"General Store"
    ; feature "enter_shop" ~shop_type:"Distillery"
    ; feature "enter_shop" ~shop_type:"Book"
    ; feature "enter_shop" ~shop_type:"Antique Armour"
    ; feature "enter_shop" ~shop_type:"Assorted Antiques"
    ; feature "enter_shop" ~shop_type:"Jewellery"
      (* An unpatched build has no dgn.shop_type_at and stores null. The wire says
         nothing with an empty atom as readily as with a missing field, and
         neither may raise. *)
    ; feature "enter_shop"
    ; feature "enter_shop" ~shop_type:""
    ];
  [%expect
    {|
    a General Store
    a Distillery
    a Book Shop
    an Antique Armour Shop
    an Assorted Antiques Shop
    a Jewellery Shop
    a shop
    a shop
    |}]
;;

let%expect_test "a consumable pluralizes its base word, not its type" =
  show
    [ item "potion" "haste"
    ; item "potion" "haste" ~quantity:1
    ; item "potion" "haste" ~quantity:2
    ; item "scroll" "acquirement" ~quantity:3
    ; item "scroll" "enchant weapon" ~quantity:5
    ; item "bauble" "" ~quantity:2
    ];
  [%expect
    {|
    potion of haste
    potion of haste
    2 potions of haste
    3 scrolls of acquirement
    5 scrolls of enchant weapon
    <irreducible>
    |}]
;;

let%expect_test "a wand prints its charges, a staff its school" =
  show [ item "wand" "acid" ~plus:12; item "wand" "digging" ~plus:0; item "staff" "fire" ];
  [%expect
    {|
    wand of acid (12)
    wand of digging (0)
    staff of fire
    |}]
;;

let%expect_test "a weapon brand renders on the side crawl puts it" =
  show
    [ item "weapon" "long sword" ~plus:1
    ; item "weapon" "club" ~plus:0
    ; item "weapon" "dagger" ~plus:(-2)
    ; item "weapon" "arbalest" ~plus:0 ~ego:"venom" ~branded:true
    ; item "weapon" "broad axe" ~plus:2 ~ego:"holy" ~branded:true
    ; item "weapon" "dire flail" ~plus:0 ~ego:"concuss" ~branded:true
    ; item "weapon" "battleaxe" ~plus:3 ~ego:"distort" ~branded:true
    ; item "weapon" "arbalest" ~plus:0 ~ego:"elec" ~branded:true
      (* The five prefix brands: these do not render as "of X". *)
    ; item "weapon" "hand axe" ~plus:1 ~ego:"heavy" ~branded:true
    ; item "weapon" "bardiche" ~plus:0 ~ego:"vamp" ~branded:true
    ; item "weapon" "club" ~plus:0 ~ego:"spect" ~branded:true
    ; item "weapon" "dagger" ~plus:0 ~ego:"devious" ~branded:true
    ; item "weapon" "arbalest" ~plus:0 ~ego:"antimagic" ~branded:true
    ];
  [%expect
    {|
    +1 long sword
    +0 club
    -2 dagger
    +0 arbalest of venom
    +2 broad axe of holy wrath
    +0 dire flail of concussion
    +3 battleaxe of distortion
    +0 arbalest of electrocution
    +1 heavy hand axe
    +0 vampiric bardiche
    +0 spectral club
    +0 devious dagger
    +0 antimagic arbalest
    |}]
;;

let%expect_test "the two weapon reskins render their canonical base" =
  (* Deliberate: "hammer" and "scythe" are per-item cosmetic rolls recorded in
     no column. *)
  show [ item "weapon" "mace" ~plus:3; item "weapon" "halberd" ~plus:0 ~ego:"venom" ];
  [%expect
    {|
    +3 mace
    +0 halberd of venom
    |}]
;;

let%expect_test "gloves and boots come in pairs, outside the enchantment" =
  show
    [ item "armour" "gloves" ~plus:0
    ; item "armour" "boots" ~plus:2 ~ego:"Fly"
    ; item "armour" "gloves" ~plus:0 ~ego:"Str+3"
    ];
  [%expect
    {|
    +0 pair of gloves
    +2 pair of boots of flying
    +0 pair of gloves of strength
    |}]
;;

let%expect_test "armour egos spell out, and orbs and scarves take no enchantment" =
  show
    [ item "armour" "robe" ~plus:0
    ; item "armour" "chain mail" ~plus:1 ~ego:"Will+"
    ; item "armour" "buckler" ~plus:0 ~ego:"rC+ rF+"
    ; item "armour" "hat" ~plus:0 ~ego:"SInv"
    ; item "armour" "crystal plate armour" ~plus:0 ~ego:"Ponderous"
    ; item "armour" "troll leather armour" ~plus:1
    ; item "armour" "orb" ~plus:0 ~ego:"Guile"
    ; item "armour" "scarf" ~plus:0 ~ego:"+Inv"
    ; item "armour" "scarf" ~plus:0 ~ego:"Harm"
    ];
  [%expect
    {|
    +0 robe
    +1 chain mail of willpower
    +0 buckler of resistance
    +0 hat of see invisible
    +0 crystal plate armour of ponderousness
    +1 troll leather armour
    orb of guile
    scarf of invisibility
    scarf of harm
    |}]
;;

let%expect_test "jewellery already spells itself; only a nonzero plus is added" =
  show
    [ item "jewellery" "ring of protection from fire" ~plus:0 ~ego:"rF+"
    ; item "jewellery" "amulet of faith" ~plus:0 ~ego:"Faith"
    ; item "jewellery" "ring of slaying" ~plus:4 ~ego:"Slay"
    ; item "jewellery" "ring of strength" ~plus:(-3) ~ego:"Str"
    ];
  [%expect
    {|
    ring of protection from fire
    amulet of faith
    +4 ring of slaying
    -3 ring of strength
    |}]
;;

let%expect_test "books and talismans are their sub_type; evokers print a counter" =
  show
    [ item "book" "Necronomicon"
    ; item "book" "Great Wizards, Vol. II"
    ; item "talisman" "dragon-coil talisman"
    ; item "miscellaneous" "box of beasts"
    ; item "miscellaneous" "lightning rod"
    ; item "miscellaneous" "tin of tremorstones"
    ; item "miscellaneous" "Gell's gravitambourine"
    ];
  [%expect
    {|
    Necronomicon
    Great Wizards, Vol. II
    dragon-coil talisman
    box of beasts
    lightning rod (4/4)
    tin of tremorstones (2/2)
    Gell's gravitambourine (2/2)
    |}]
;;

let%expect_test "an artefact, a monster and a vault keep their stored names" =
  show
    [ item "weapon" "lance" ~artefact:true
    ; item "book" "the Grand Grimoire of Doom" ~artefact:true
    ; entry ~cat:Record.Cat.Monsters ~name:"Sigmund" ()
    ; entry ~cat:Record.Cat.Vaults ~name:"uniq_sigmund" ()
    ; item "gizmo" "whatever"
    ];
  [%expect
    {|
    <irreducible>
    <irreducible>
    <irreducible>
    <irreducible>
    <irreducible>
    |}]
;;

let%expect_test "render falls back to the stored name" =
  let arte =
    entry
      ~base_type:"weapon"
      ~sub_type:"lance"
      ~artefact:true
      ~name:"the +8 lance \"Wyrmbane\" {slay dragon, rPois}"
      ()
  in
  print_endline (Display_name.render arte);
  print_endline (Display_name.render (item "potion" "curing" ~quantity:2));
  [%expect
    {|
    the +8 lance "Wyrmbane" {slay dragon, rPois}
    2 potions of curing
    |}]
;;
