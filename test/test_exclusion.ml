open! Core
module Exclusion = Seed_corpus.Exclusion
module Level = Seed_corpus.Level
module Record = Seed_corpus.Record

let item ~base_type ~sub_type : Record.Entry.t =
  { cat = Record.Cat.Items
  ; name = sprintf "%s of %s" base_type sub_type
  ; base_type = Some base_type
  ; sub_type = Some sub_type
  ; quantity = None
  ; artefact = None
  ; branded = None
  ; plus = None
  ; cost = None
  ; ego = None
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

let level ~level:name entries : Level.t =
  { level = name; parent_level = None; temple_altars = None; gold = None; entries }
;;

let show levels =
  Exclusion.draws levels
  |> List.map ~f:(fun ((g : Exclusion.Group.t), draw) -> g.name, draw)
  |> [%sexp_of: (string * Exclusion.Draw.t) list]
  |> print_s
;;

(* Every group keeps its row whether or not a member turned up: an unanswered
   axis is a fact about the seed, and dropping it would read as the group not
   existing. *)
let%expect_test "every group is answered, seen or not" =
  show
    [ level
        ~level:"D:3"
        [ item ~base_type:"wand" ~sub_type:"iceblast"
        ; item ~base_type:"wand" ~sub_type:"flame"
        ]
    ];
  [%expect
    {|
    (("wand A" Unseen) ("wand B" (Drew iceblast)) ("wand C" Unseen)
     (scroll Unseen) ("evoker A" Unseen) ("evoker B" Unseen) ("evoker C" Unseen))
    |}]
;;

(* The draw is a per-seed fact, so it is collected across every level. *)
let%expect_test "a draw is gathered across the whole seed" =
  show
    [ level ~level:"D:1" [ item ~base_type:"wand" ~sub_type:"paralysis" ]
    ; level ~level:"D:6" [ item ~base_type:"scroll" ~sub_type:"butterflies" ]
    ; level ~level:"Sewer" [ item ~base_type:"miscellaneous" ~sub_type:"box of beasts" ]
    ];
  [%expect
    {|
    (("wand A" (Drew paralysis)) ("wand B" Unseen) ("wand C" Unseen)
     (scroll (Drew butterflies)) ("evoker A" Unseen) ("evoker B" Unseen)
     ("evoker C" (Drew "box of beasts")))
    |}]
;;

(* A sub_type is a bare word another base type may reuse, so the group is keyed
   on the pair. A scroll of summoning is not the wand group's business. *)
let%expect_test "a member is matched on its base type too" =
  show [ level ~level:"D:2" [ item ~base_type:"potion" ~sub_type:"paralysis" ] ];
  [%expect
    {|
    (("wand A" Unseen) ("wand B" Unseen) ("wand C" Unseen) (scroll Unseen)
     ("evoker A" Unseen) ("evoker B" Unseen) ("evoker C" Unseen))
    |}]
;;

(* Exclusivity holds on every seed measured, so two members of one group is a
   broken model rather than an interesting seed. *)
let%expect_test "two members of one group are reported as the contradiction they are" =
  show
    [ level
        ~level:"D:4"
        [ item ~base_type:"wand" ~sub_type:"warping"
        ; item ~base_type:"wand" ~sub_type:"roots"
        ]
    ];
  [%expect
    {|
    (("wand A" Unseen) ("wand B" (Conflict (roots warping))) ("wand C" Unseen)
     (scroll Unseen) ("evoker A" Unseen) ("evoker B" Unseen) ("evoker C" Unseen))
    |}]
;;
