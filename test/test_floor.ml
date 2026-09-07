open! Core
module Floor = Seed_corpus.Floor
module Level = Seed_corpus.Level
module Record = Seed_corpus.Record

let entry
      ?feat
      ?cost
      ?artefact
      ?ego
      ?x
      ?y
      ?timeout_turns
      ?unique_mons
      ?carried_by
      ?shop_type
      ?base_type
      ?sub_type
      ?(spells = [])
      ?(cat = Record.Cat.Items)
      ~name
      ()
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
  ; cost
  ; ego
  ; feat
  ; timeout_turns
  ; unique_mons
  ; native = None
  ; type_name = None
  ; x
  ; y
  ; carried_by
  ; shop_type
  ; toll_note = None
  ; spells
  ; props = []
  }
;;

let level ?parent_level ?temple_altars ?gold ~level:name entries : Level.t =
  { level = name; parent_level; temple_altars; gold; entries }
;;

let show (l : Level.t) =
  let f = Floor.of_level l in
  print_s
    [%message
      ""
        ~notable:(List.map f.notable ~f:Record.Entry.name : string list)
        ~sundries:(List.map f.sundries ~f:Record.Entry.name : string list)
        ~monsters:(List.map f.monsters ~f:Record.Entry.name : string list)
        ~altars:(List.map f.altars ~f:Floor.Altar.god : string list)
        ~ways_on:(List.map f.ways_on ~f:Record.Entry.name : string list)
        ~features:(List.map f.features ~f:Record.Entry.name : string list)
        ~shops:
          (List.map f.shops ~f:(fun s ->
             s.Floor.Shop.name, List.map s.stock ~f:Record.Entry.name)
           : (string * string list) list)]
;;

let%expect_test "a level splits into the things a reader asks of it separately" =
  show
    (level
       ~level:"D:5"
       [ entry ~name:"scroll of fog" ()
       ; entry ~cat:Record.Cat.Monsters ~name:"Sigmund" ()
       ; entry ~cat:Record.Cat.Features ~feat:"altar_trog" ~name:"a bloodstained altar" ()
       ]);
  [%expect
    {|
    ((notable ()) (sundries ("scroll of fog")) (monsters (Sigmund))
     (altars (Trog)) (ways_on ()) (features ()) (shops ()))
    |}]
;;

(* The reader is scanning a column of ordinary items for the one that is not, so
   the rare thing leads. Order within a group is storage's. *)
let%expect_test "the notable list leads with artefacts, then the enchanted" =
  show
    (level
       ~level:"D:5"
       [ entry ~name:"scroll of fog" ()
       ; entry ~name:"a dagger of venom" ~ego:"venom" ()
       ; entry ~name:"potion of haste" ()
       ; entry ~name:{|+5 scales "Eshyac"|} ~artefact:true ()
       ]);
  [%expect
    {|
    ((notable ("+5 scales \"Eshyac\"" "a dagger of venom"))
     (sundries ("scroll of fog" "potion of haste")) (monsters ()) (altars ())
     (ways_on ()) (features ()) (shops ()))
    |}]
;;

(* Boons sort ahead of artefacts, in storage order within the tier. *)
let%expect_test "a boon leads the notable list, ahead of artefacts" =
  show
    (level
       ~level:"D:5"
       [ entry ~name:"scroll of fog" ()
       ; entry ~name:{|+5 scales "Eshyac"|} ~artefact:true ()
       ; entry
           ~name:"scroll of acquirement"
           ~base_type:"scroll"
           ~sub_type:"acquirement"
           ()
       ; entry ~name:"potion of experience" ~base_type:"potion" ~sub_type:"experience" ()
       ]);
  [%expect
    {|
    ((notable
      ("scroll of acquirement" "potion of experience" "+5 scales \"Eshyac\""))
     (sundries ("scroll of fog")) (monsters ()) (altars ()) (ways_on ())
     (features ()) (shops ()))
    |}]
;;

(* A priced boon is shop stock, not a boon. *)
let%expect_test "a priced boon is shop stock, not a boon" =
  show
    (level
       ~level:"D:5"
       [ entry
           ~name:"an armour shop"
           ~feat:"enter_shop"
           ~cat:Record.Cat.Features
           ~x:3
           ~y:4
           ()
       ; entry
           ~name:"scroll of acquirement"
           ~base_type:"scroll"
           ~sub_type:"acquirement"
           ~cost:350
           ~x:3
           ~y:4
           ()
       ]);
  [%expect
    {|
    ((notable ()) (sundries ()) (monsters ()) (altars ()) (ways_on ())
     (features ()) (shops (("an armour shop" ("scroll of acquirement")))))
    |}]
;;

(* Shop stock is flattened alongside floor items and carries the shop's own
   square, so the square is what reassembles the two. *)
let%expect_test "stock joins its shop by the square they share" =
  show
    (level
       ~level:"D:7"
       [ entry
           ~cat:Record.Cat.Features
           ~feat:"enter_shop"
           ~name:"Plog's Distillery"
           ~x:10
           ~y:2
           ()
       ; entry
           ~cat:Record.Cat.Features
           ~feat:"enter_shop"
           ~name:"Plog's Book Shoppe"
           ~x:40
           ~y:9
           ()
       ; entry ~name:"potion of haste" ~cost:120 ~x:10 ~y:2 ()
       ; entry ~name:"manual of Axes" ~cost:1200 ~x:40 ~y:9 ()
       ; entry ~name:"potion of might" ~cost:90 ~x:10 ~y:2 ()
       ; entry ~name:"scroll of fog" ~x:55 ~y:3 ()
       ]);
  [%expect
    {|
    ((notable ()) (sundries ("scroll of fog")) (monsters ()) (altars ())
     (ways_on ()) (features ())
     (shops
      (("Plog's Distillery" ("potion of haste" "potion of might"))
       ("Plog's Book Shoppe" ("manual of Axes")))))
    |}]
;;

let%expect_test "a shop whose stock was not recorded is still a shop" =
  show
    (level
       ~level:"D:3"
       [ entry
           ~cat:Record.Cat.Features
           ~feat:"enter_shop"
           ~name:"Raing's General Store"
           ~x:62
           ~y:8
           ()
       ]);
  [%expect
    {|
    ((notable ()) (sundries ()) (monsters ()) (altars ()) (ways_on ())
     (features ()) (shops (("Raing's General Store" ()))))
    |}]
;;

(* A named book has no artefact flag and no enchantment, so it would sort into
   the run of consumables -- but its spell set is the reason to take it and its
   name does not say what is in it. A parchment states its own single spell. *)
let%expect_test "a book that does not name its spells is notable" =
  show
    (level
       ~level:"D:6"
       [ entry ~name:"scroll of fog" ()
       ; entry ~name:"Fen Folio" ~spells:[ "Sting"; "Summon Forest" ] ()
       ; entry ~name:"parchment of Apportation" ~spells:[ "Apportation" ] ()
       ]);
  [%expect
    {|
    ((notable ("Fen Folio"))
     (sundries ("scroll of fog" "parchment of Apportation")) (monsters ())
     (altars ()) (ways_on ()) (features ()) (shops ()))
    |}]
;;

(* What a shop sells is not recoverable from its name -- a vault may call a
   jewellery shop "Sanarr's Fire Supplies" -- so the type travels with the
   shop. *)
let%expect_test "a shop carries crawl's own type, not just its name" =
  let f =
    Floor.of_level
      (level
         ~level:"D:5"
         [ entry
             ~cat:Record.Cat.Features
             ~feat:"enter_shop"
             ~name:"John Lambton's Dragon-Slaying Spoils"
             ~shop_type:"Armour"
             ~x:22
             ~y:25
             ()
         ; entry
             ~cat:Record.Cat.Features
             ~feat:"enter_shop"
             ~name:"Raing's General Store"
             ~x:62
             ~y:8
             ()
         ])
  in
  print_s
    [%sexp
      (List.map f.shops ~f:(fun s -> s.Floor.Shop.name, s.Floor.Shop.shop_type)
       : (string * string option) list)];
  [%expect
    {|
    (("John Lambton's Dragon-Slaying Spoils" (Armour))
     ("Raing's General Store" ()))
    |}]
;;

(* A monster's coordinate is its spawn square and it wanders as soon as the
   level is entered; an item in its inventory is recorded on that same square.
   Neither has a position, while the identical x,y on a floor item is real. *)
let%expect_test "only what stays put has a position" =
  let show_position (e : Record.Entry.t) =
    print_s
      [%message "" ~_:(e.name : string) ~_:(Record.Entry.position e : (int * int) option)]
  in
  show_position (entry ~name:"scroll of fog" ~x:24 ~y:18 ());
  [%expect {| ("scroll of fog" ((24 18))) |}];
  show_position
    (entry ~cat:Record.Cat.Monsters ~name:"Gastronok" ~unique_mons:true ~x:24 ~y:18 ());
  [%expect {| (Gastronok ()) |}];
  show_position (entry ~name:"+0 hat of ice" ~carried_by:"Gastronok" ~x:24 ~y:18 ());
  [%expect {| ("+0 hat of ice" ()) |}]
;;

(* Sixteen items of which four matter should not ask for sixteen rows to be
   read. *)
let%expect_test "items divide into what is worth the trip and what is not" =
  show
    (level
       ~level:"D:7"
       [ entry ~name:"potion of brilliance" ()
       ; entry ~name:"+2 sling of flaming" ~ego:"flame" ()
       ; entry ~name:"scroll of noise" ()
       ; entry ~name:{|+8 longbow "Zephyr"|} ~artefact:true ~ego:"speed" ()
       ; entry ~name:"potion of curing" ()
       ]);
  [%expect
    {|
    ((notable ("+8 longbow \"Zephyr\"" "+2 sling of flaming"))
     (sundries ("potion of brilliance" "scroll of noise" "potion of curing"))
     (monsters ()) (altars ()) (ways_on ()) (features ()) (shops ()))
    |}]
;;

(* An altar is a commitment, a stair is a route and a shop is a room. They were
   one "features" table only because storage has one shape for all three. *)
let%expect_test "features divide by what they ask of a reader" =
  show
    (level
       ~level:"D:5"
       [ entry ~cat:Record.Cat.Features ~feat:"altar_xom" ~name:"a shimmering altar" ()
       ; entry ~cat:Record.Cat.Features ~feat:"enter_temple" ~name:"a staircase" ()
       ; entry ~cat:Record.Cat.Features ~feat:"granite_statue" ~name:"a granite statue" ()
       ]);
  [%expect
    {|
    ((notable ()) (sundries ()) (monsters ()) (altars (Xom))
     (ways_on ("a staircase")) (features ("a granite statue")) (shops ()))
    |}]
;;

(* A Temple's pool gods are a bitmask and the gods outside the pool are rows.
   Both are altars to a reader, so they arrive as one list -- rare ones first,
   since a pool god stands in every seed's Temple. *)
let%expect_test "the temple mask and the altar rows become one list" =
  show
    (level
       ~level:"Temple"
       ~temple_altars:
         (Seed_corpus.Temple.to_int
            (List.fold
               [ "altar_trog"; "altar_okawaru" ]
               ~init:Seed_corpus.Temple.empty
               ~f:Seed_corpus.Temple.add))
       [ entry ~cat:Record.Cat.Features ~feat:"altar_lugonu" ~name:"a corrupted altar" ()
       ]);
  [%expect
    {|
    ((notable ()) (sundries ()) (monsters ()) (altars (Lugonu Okawaru Trog))
     (ways_on ()) (features ()) (shops ()))
    |}]
;;

(* Twenty artefacts and twenty potions are both "20 items". What tells a
   treasury from a general store is the money. Stock reads dearest first. *)
let%expect_test "a shop knows what its stock is worth" =
  let f =
    Floor.of_level
      (level
         ~level:"D:8"
         [ entry
             ~cat:Record.Cat.Features
             ~feat:"enter_shop"
             ~name:"Gozag's Platinum Reserve"
             ~x:67
             ~y:38
             ()
         ; entry ~name:{|+2 cloak of Cotuang|} ~artefact:true ~cost:1450 ~x:67 ~y:38 ()
         ; entry ~name:{|ring "Ubumen"|} ~artefact:true ~cost:5980 ~x:67 ~y:38 ()
         ; entry ~name:"potion of curing" ~cost:84 ~x:67 ~y:38 ()
         ])
  in
  print_s
    [%message
      ""
        ~stock:(List.map (List.hd_exn f.shops).stock ~f:Record.Entry.name : string list)
        ~total:((List.hd_exn f.shops).total : int)
        ~artefacts:((List.hd_exn f.shops).artefacts : int)];
  [%expect
    {|
    ((stock ("ring \"Ubumen\"" "+2 cloak of Cotuang" "potion of curing"))
     (total 7514) (artefacts 2))
    |}]
;;

(* An unremarkable floor prints nothing, which is the honest answer to whether
   it is worth the trip. *)
let%expect_test "a floor states only the facts it has" =
  let facts l =
    print_s [%sexp (Floor.standing_facts (Floor.of_level l) l : string list)]
  in
  facts (level ~level:"D:2" [ entry ~name:"scroll of fog" () ]);
  [%expect {| () |}];
  (* Never bare "gold": the sum is the piles on the ground, so it excludes
     monster drops and Gozag and is a lower bound. A level filled before format
     4 knows nothing either way. *)
  List.iter [ Some 431; Some 0; None ] ~f:(fun gold ->
    facts (level ~level:"D:2" ?gold [ entry ~name:"scroll of fog" () ]));
  [%expect
    {|
    ("431 floor gold")
    ()
    ()
    |}];
  facts
    (level
       ~level:"D:8"
       [ entry ~cat:Record.Cat.Monsters ~name:"Gastronok" ~unique_mons:true ()
       ; entry ~name:"+1 robe of Umugoixeaw" ~artefact:true ()
       ; entry ~cat:Record.Cat.Features ~feat:"altar_gozag" ~name:"an opulent altar" ()
       ; entry
           ~cat:Record.Cat.Features
           ~feat:"enter_shop"
           ~name:"Hyphom's Gadgets"
           ~x:24
           ~y:35
           ()
       ; entry ~name:{|ring "Ubumen"|} ~artefact:true ~cost:5980 ~x:24 ~y:35 ()
       ]);
  [%expect {| ("2 artefacts, 1 of them for sale" Gozag Gastronok "1 shop") |}]
;;

(* The faded altar is neither a god nor a rarity -- it stands on 59% of seeds.
   Still an altar on the floor, just never one of the floor's facts. *)
let%expect_test "a faded altar is listed but never gilded" =
  let l =
    level
      ~level:"D:1"
      [ entry
          ~cat:Record.Cat.Features
          ~feat:"altar_ecumenical"
          ~name:"a faded altar of an unknown god"
          ()
      ]
  in
  let f = Floor.of_level l in
  print_s
    [%message
      ""
        ~altars:(List.map f.altars ~f:(fun a -> a.god, a.in_pool) : (string * bool) list)
        ~facts:(Floor.standing_facts f l : string list)];
  [%expect {| ((altars ((Ecumenical true))) (facts ())) |}]
;;

let show_entrances levels =
  Floor.entrances levels
  |> List.map ~f:(fun (e : Floor.Entrance.t) -> e.branch, e.level, e.timeout_turns)
  |> [%sexp_of: (string * string * int option) list]
  |> print_s
;;

(* The index is a route, so it is ordered by how early a player reaches the
   level holding each entrance -- not by level name, which sorts Bailey before
   D:2. *)
let%expect_test "entrances are collected across levels in reach order" =
  show_entrances
    [ level
        ~level:"D:4"
        [ entry
            ~cat:Record.Cat.Features
            ~feat:"enter_temple"
            ~name:"a staircase"
            ~x:55
            ~y:31
            ()
        ]
    ; level
        ~level:"D:7"
        [ entry
            ~cat:Record.Cat.Features
            ~feat:"enter_ossuary"
            ~name:"a sand-covered staircase"
            ~timeout_turns:703
            ()
        ]
    ; level
        ~level:"D:2"
        [ entry
            ~cat:Record.Cat.Features
            ~feat:"enter_sewer"
            ~name:"a glowing drain"
            ~timeout_turns:640
            ()
        ]
    ; level ~level:"Ossuary" ~parent_level:"D:7" []
    ];
  [%expect {| ((Sewer D:2 (640)) (Temple D:4 ()) (Ossuary D:7 (703))) |}]
;;

(* A shop is a room on the level, not a way off it, and there are more shops
   than branches. *)
let%expect_test "shops are not entrances" =
  show_entrances
    [ level
        ~level:"D:3"
        [ entry ~cat:Record.Cat.Features ~feat:"enter_shop" ~name:"Plog's Distillery" ()
        ; entry
            ~cat:Record.Cat.Features
            ~feat:"enter_lair"
            ~name:"a staircase to the Lair"
            ()
        ]
    ];
  [%expect {| ((Lair D:3 ())) |}]
;;

(* The branch name is derived from the feat, not matched against a table, so a
   portal the depth table has never heard of still appears. *)
let%expect_test "an unknown branch still appears" =
  show_entrances
    [ level
        ~level:"D:6"
        [ entry
            ~cat:Record.Cat.Features
            ~feat:"enter_necropolis"
            ~name:"a gate"
            ~timeout_turns:1000
            ()
        ]
    ];
  [%expect {| ((Necropolis D:6 (1000))) |}]
;;

let show_order levels =
  Floor.in_reach_order levels
  |> List.map ~f:Level.level
  |> [%sexp_of: string list]
  |> print_s
;;

let entrance ~feat ~name = entry ~cat:Record.Cat.Features ~feat ~name ()

(* Storage orders by name, which strands a Sewer off D:3 eight floors from the
   drain leading to it. *)
let%expect_test "a portal follows the floor its entrance stands on" =
  show_order
    [ level ~level:"D:1" []
    ; level ~level:"D:2" []
    ; level ~level:"D:3" [ entrance ~feat:"enter_sewer" ~name:"a glowing drain" ]
    ; level ~level:"D:4" []
    ; level ~level:"Sewer" ~parent_level:"D:3" []
    ];
  [%expect {| (D:1 D:2 D:3 Sewer D:4) |}]
;;

(* The Temple is a branch, not a portal, so format 2 records no parent. The
   entrance row is what places it. *)
let%expect_test "a branch with no recorded parent is placed by its entrance" =
  show_order
    [ level ~level:"D:1" []
    ; level
        ~level:"D:5"
        [ entrance ~feat:"enter_temple" ~name:"a staircase to the Ecumenical Temple" ]
    ; level ~level:"D:6" []
    ; level ~level:"Temple" []
    ];
  [%expect {| (D:1 D:5 Temple D:6) |}]
;;

(* A portal that itself holds an entrance keeps its own child beneath it. *)
let%expect_test "a portal off a portal nests beneath it" =
  show_order
    [ level
        ~level:"D:2"
        [ entrance ~feat:"enter_ossuary" ~name:"a sand-covered staircase" ]
    ; level ~level:"D:3" []
    ; level
        ~level:"Ossuary"
        ~parent_level:"D:2"
        [ entrance ~feat:"enter_bailey" ~name:"a flagged portal" ]
    ; level ~level:"Bailey" ~parent_level:"Ossuary" []
    ];
  [%expect {| (D:2 Ossuary Bailey D:3) |}]
;;

(* A level the corpus cannot place has no depth to sort by, so it sorts last
   rather than being guessed into the middle. Storage position was never
   evidence. *)
let%expect_test "an unplaceable level sorts last" =
  show_order [ level ~level:"D:1" []; level ~level:"Volcano" []; level ~level:"D:2" [] ];
  [%expect {| (D:1 D:2 Volcano) |}]
;;

(* A parent naming a level this seed does not hold cannot place anything, so
   the child stays where it was rather than vanishing. *)
let%expect_test "a parent outside the extracted floors places nothing" =
  show_order [ level ~level:"D:1" []; level ~level:"Sewer" ~parent_level:"D:12" [] ];
  [%expect {| (D:1 Sewer) |}]
;;

let%expect_test "a consumable's name drops the class its tile already shows" =
  let show name ?base_type ?sub_type () =
    print_endline (Floor.display_name (entry ~name ?base_type ?sub_type ()))
  in
  show "scroll of butterflies" ~base_type:"scroll" ~sub_type:"butterflies" ();
  show "potion of heal wounds" ~base_type:"potion" ~sub_type:"heal wounds" ();
  [%expect
    {|
    butterflies
    heal wounds
    |}];
  (* Quantity is the one part of the name no other column repeats. *)
  show "3 scrolls of revelation" ~base_type:"scroll" ~sub_type:"revelation" ();
  show "2 potions of curing" ~base_type:"potion" ~sub_type:"curing" ();
  [%expect
    {|
    3 revelation
    2 curing
    |}];
  (* Anything whose name is not the pair it was built from keeps all of it. *)
  show "+3 greatsling \"Punk\" {acid}" ~base_type:"weapon" ~sub_type:"greatsling" ();
  show "wand of digging" ~base_type:"wand" ~sub_type:"digging" ();
  show "a shimmering scroll" ~base_type:"scroll" ~sub_type:"butterflies" ();
  show "altar of Trog" ();
  [%expect
    {|
    +3 greatsling "Punk" {acid}
    wand of digging
    a shimmering scroll
    altar of Trog
    |}]
;;

(* The class word is dropped only because a tile is about to say it, so a
   trimmed name with no tile would read as a bare "butterflies". *)
let%expect_test "anything whose name is trimmed has a tile to carry the class" =
  let untiled =
    List.filter_map Seed_corpus.Tile.known_items ~f:(fun (base_type, sub_type) ->
      let e =
        entry ~name:(sprintf "%s of %s" base_type sub_type) ~base_type ~sub_type ()
      in
      if String.equal (Floor.display_name e) (Record.Entry.name e)
      then None
      else if Option.is_some (Seed_corpus.Tile.of_entry e)
      then None
      else Some (base_type ^ " of " ^ sub_type))
  in
  print_s [%sexp (untiled : string list)];
  [%expect {| () |}]
;;

let%expect_test "a parchment reads as its spell, tiered by the spell's level" =
  let show sub =
    let e = entry ~name:sub ~base_type:"book" ~sub_type:sub () in
    print_s
      [%sexp
        (Floor.display_name e : string), (Seed_corpus.Tile.of_entry e : string option)]
  in
  show "parchment of Magic Dart";
  show "parchment of Airstrike";
  show "parchment of Fire Storm";
  [%expect
    {|
    ("Magic Dart" (items/parchment_low.png))
    (Airstrike (items/parchment_low.png))
    ("Fire Storm" (items/parchment_high.png))
    |}];
  (* A named book is not a parchment: its name is not its sub_type. *)
  show "Fen Folio";
  [%expect {| ("Fen Folio" ()) |}]
;;

(* Storage orders by name, and a name orders D:10 before D:2. Siblings are
   placed by depth, or a deepened seed reads D:1 D:10 D:11 ... D:2. *)
let%expect_test "a two-digit floor sorts by depth, not by name" =
  show_order
    [ level ~level:"D:1" []
    ; level ~level:"D:10" []
    ; level ~level:"D:11" []
    ; level ~level:"D:2" []
    ; level ~level:"D:9" []
    ];
  [%expect {| (D:1 D:2 D:9 D:10 D:11) |}]
;;

(* Branches interleave with the D-levels they hang off. *)
let%expect_test "a deep branch sits at its entrance, not after every floor" =
  show_order
    [ level ~level:"D:1" []
    ; level ~level:"D:10" []
    ; level ~level:"D:11" []
    ; level ~level:"D:2" []
    ; level ~level:"D:9" [ entrance ~feat:"enter_lair" ~name:"a staircase to the Lair" ]
    ; level ~level:"Lair:1" []
    ; level ~level:"Lair:2" []
    ];
  [%expect {| (D:1 D:2 D:9 Lair:1 Lair:2 D:10 D:11) |}]
;;

(* A branch deep enough to reach two digits has the same name-order problem its
   parent dungeon does. *)
let%expect_test "a branch's own floors sort by depth" =
  show_order
    [ level ~level:"D:9" [ entrance ~feat:"enter_lair" ~name:"a staircase to the Lair" ]
    ; level ~level:"Lair:1" []
    ; level ~level:"Lair:10" []
    ; level ~level:"Lair:2" []
    ];
  [%expect {| (D:9 Lair:1 Lair:2 Lair:10) |}]
;;

(* A player clears a branch and comes back, so a sub-branch hanging off Lair:2
   does not split Lair in half: the whole of Lair runs contiguously and Shoals
   follows it. A portal is the exception -- a single excursion off one floor. *)
let%expect_test "a branch runs contiguously, a portal stays inline" =
  show_order
    [ level ~level:"D:11" [ entrance ~feat:"enter_lair" ~name:"a staircase to the Lair" ]
    ; level ~level:"D:12" []
    ; level ~level:"Lair:1" []
    ; level
        ~level:"Lair:2"
        [ entrance ~feat:"enter_shoals" ~name:"a staircase to the Shoals" ]
    ; level ~level:"Lair:3" [ entrance ~feat:"enter_sewer" ~name:"a glowing drain" ]
    ; level ~level:"Sewer" ~parent_level:"Lair:3" []
    ; level ~level:"Shoals:1" []
    ; level ~level:"Shoals:2" []
    ];
  [%expect {| (D:11 Lair:1 Lair:2 Lair:3 Sewer Shoals:1 Shoals:2 D:12) |}]
;;
