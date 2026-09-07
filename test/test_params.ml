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
    altar_trog                   -> error: altar features are no longer supported in search: "altar_trog"
    enter_shop                   -> a shop
    artefact                     -> an artefact
    unique:Sigmund               -> Sigmund
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
    altar_xom                    -> error: altar features are no longer supported in search: "altar_xom"
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
    unique:                      -> error: unique: needs a monster name
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
    [ "99999999999999999999x enter_shop"
    ; "99999999999999999999 enter_shop"
    ; "4611686018427387904x enter_shop"
    ];
  [%expect
    {|
    99999999999999999999x enter_shop -> 99999999999999999999x enter shop
    99999999999999999999 enter_shop -> 99999999999999999999 enter shop
    4611686018427387904x enter_shop -> 4611686018427387904x enter shop
    |}]
;;
