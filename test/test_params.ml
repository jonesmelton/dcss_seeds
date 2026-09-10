open! Core
module Search = Seed_corpus.Search

(* Exercised through the same entry point the handler uses, but the affix
   peeling is where the ambiguity lives: "3x" is a count, an "x" inside a name
   is not. *)
let show s =
  match Seed_web.Params.term_of_string s with
  | Error err -> printf "%-28s -> error: %s\n" s (Error.to_string_hum err)
  | Ok term -> printf "%-28s -> %s\n" s (Search.Term.to_string term)
;;

let%expect_test "term syntax" =
  List.iter
    ~f:show
    [ "potion:haste"
    ; "3x potion:haste"
    ; "potion:haste by D:5"
    ; "3x potion:haste by D:5"
    ; "shop potion:haste"
    ; "floor potion:haste"
    ; "3x floor potion:haste by D:5"
    ; "altar_trog"
    ; "enter_shop"
    ; "artefact"
    ; "unique:Sigmund"
    ; "name~Throatcutter"
    ];
  [%expect
    {|
    potion:haste                 -> potion of haste
    3x potion:haste              -> 3+ potion of haste
    potion:haste by D:5          -> error: depth caps are no longer supported: drop the " by ..." from "potion:haste by D:5". Results cover the whole depth each seed was catalogued to.
    3x potion:haste by D:5       -> error: depth caps are no longer supported: drop the " by ..." from "3x potion:haste by D:5". Results cover the whole depth each seed was catalogued to.
    shop potion:haste            -> potion of haste in a shop
    floor potion:haste           -> potion of haste on the floor
    3x floor potion:haste by D:5 -> error: depth caps are no longer supported: drop the " by ..." from "3x floor potion:haste by D:5". Results cover the whole depth each seed was catalogued to.
    altar_trog                   -> error: search covers items, not features: "altar_trog"
    enter_shop                   -> error: search covers items, not features: "enter_shop"
    artefact                     -> an artefact
    unique:Sigmund               -> error: search covers items, not monsters. A seed page lists the uniques on each level.
    name~Throatcutter            -> named like "Throatcutter"
    |}]
;;

(* An "x" inside a name must not be read as a count separator. *)
let%expect_test "an x inside a name is not a count" =
  List.iter
    ~f:show
    [ "scroll:vulnerability"; "name~Xom"; "altar_xom"; "weapon:executioner's axe" ];
  [%expect
    {|
    scroll:vulnerability         -> scroll of vulnerability
    name~Xom                     -> named like "Xom"
    altar_xom                    -> error: search covers items, not features: "altar_xom"
    weapon:executioner's axe     -> executioner's axe
    |}]
;;

let%expect_test "malformed terms are errors, not dropped filters" =
  List.iter
    ~f:show
    [ ""
    ; "potion:"
    ; ":haste"
    ; "unique:"
    ; "name~"
    ; "name~ab"
    ; "floor "
    ; "floor potion"
    ; "shop "
    ];
  [%expect
    {|
                                 -> error: empty search term
    potion:                      -> error: not a <base>:<sub> item: "potion:"
    :haste                       -> error: not a <base>:<sub> item: ":haste"
    unique:                      -> error: search covers items, not monsters. A seed page lists the uniques on each level.
    name~                        -> error: name~ needs something to match
    name~ab                      -> error: name~ needs at least 3 characters (got 2)
    floor                        -> error: "floor" needs an item after it, as in "floor potion:haste"
    floor potion                 -> error: not a <base>:<sub> item: "potion"
    shop                         -> error: "shop" needs an item after it, as in "shop potion:haste"
    |}]
;;

let%expect_test "a term count above the cap is an error" =
  let many =
    List.init (Seed_web.Params.max_terms + 1) ~f:(fun i -> sprintf "potion:haste%d" i)
  in
  (match Seed_web.Params.terms_of_strings many with
   | Error err -> printf "%s\n" (Error.to_string_hum err)
   | Ok _ -> printf "unexpectedly accepted");
  [%expect {| too many search terms (max 10) |}]
;;

(* A digit run too large for [int] is a count only in appearance, and must not
   escape the Or_error pipeline as a Failure. Treated as a literal term, which
   is what the same digits without the "x" already do. *)
let%expect_test "an out-of-range count does not raise" =
  List.iter
    ~f:show
    [ "99999999999999999999x potion:haste"
    ; "99999999999999999999 potion:haste"
    ; "4611686018427387904x potion:haste"
    ];
  [%expect
    {|
    99999999999999999999x potion:haste -> haste
    99999999999999999999 potion:haste -> haste
    4611686018427387904x potion:haste -> haste
    |}]
;;

(* The remove button names a box as "<n>:<term>": n counts *earlier boxes
   holding the same term*, not absolute position. Absolute position cannot work:
   the index is fixed when the button renders, but what arrives is whatever the
   boxes hold at submit time -- the reader may have cleared or edited another
   box in between, and the always-submitted blank box shifts it too. An
   occurrence ordinal is stable under every such edit, still distinguishes
   duplicates, and still makes a replayed URL (htmx pushes the one carrying the
   drop) a no-op once the term is gone. *)
let%expect_test "dropping a term removes the box named, not a namesake" =
  let show ~drop terms =
    printf
      "%-20s %s\n"
      (Option.value drop ~default:"-")
      (String.concat ~sep:", " (Seed_web.Params.without_dropped ~drop terms))
  in
  let terms = [ "name~bear"; "potion:experience"; "name~bear"; "" ] in
  show ~drop:None terms;
  show ~drop:(Some "0:name~bear") terms;
  (* The second name~bear, not the first. *)
  show ~drop:(Some "1:name~bear") terms;
  (* A term with a colon in it: the split takes the first one, so n has to
     lead. *)
  show ~drop:(Some "0:potion:experience") terms;
  (* Replay, after that term is gone: nothing left to match. *)
  show ~drop:(Some "2:name~bear") terms;
  show ~drop:(Some "0:wand:digging") terms;
  (* Boxes cleared or added between render and click do not shift the ordinal. *)
  show ~drop:(Some "1:name~bear") [ "name~bear"; ""; "artefact"; "name~bear"; "" ];
  (* Malformed rather than crashing: these arrive from a URL. *)
  show ~drop:(Some "name~bear") terms;
  show ~drop:(Some "x:name~bear") terms;
  show ~drop:(Some "-1:name~bear") terms;
  [%expect
    {|
    -                    name~bear, potion:experience, name~bear
    0:name~bear          potion:experience, name~bear
    1:name~bear          name~bear, potion:experience
    0:potion:experience  name~bear, name~bear
    2:name~bear          name~bear, potion:experience, name~bear
    0:wand:digging       name~bear, potion:experience, name~bear
    1:name~bear          name~bear, artefact
    name~bear            name~bear, potion:experience, name~bear
    x:name~bear          name~bear, potion:experience, name~bear
    -1:name~bear         name~bear, potion:experience, name~bear
    |}]
;;
