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
    ; "unique:Sigmund"
    ; "name~Throatcutter"
    ];
  [%expect
    {|
    potion:haste                 -> potion of haste
    3x potion:haste              -> 3+ potion of haste
    potion:haste by D:5          -> error: depth limits are no longer supported. Remove the " by ..." from "potion:haste by D:5".
    3x potion:haste by D:5       -> error: depth limits are no longer supported. Remove the " by ..." from "3x potion:haste by D:5".
    shop potion:haste            -> potion of haste in a shop
    floor potion:haste           -> potion of haste
    3x floor potion:haste by D:5 -> error: depth limits are no longer supported. Remove the " by ..." from "3x floor potion:haste by D:5".
    altar_trog                   -> error: search covers items, not features: "altar_trog"
    enter_shop                   -> error: search covers items, not features: "enter_shop"
    unique:Sigmund               -> error: only items are searchable, not monsters. Each seed page lists its uniques.
    name~Throatcutter            -> named like "Throatcutter"
    |}]
;;

(* The position grammar, asserted on the parsed criterion rather than on its
   prose: [Criterion.to_string] leaves [Floor] unqualified, so prose cannot tell
   a floor term from a term that named no position, which is exactly the
   distinction every row here turns on. *)
let show_parse s =
  match Seed_web.Params.term_of_string s with
  | Error err -> printf "%-26s -> error: %s\n" s (Error.to_string_hum err)
  | Ok term -> printf "%-26s -> %s\n" s (Sexp.to_string [%sexp (term : Search.Term.t)])
;;

let%expect_test "a position prefix is peeled off and the rest parses as it would bare" =
  List.iter
    ~f:show_parse
    [ "potion:haste"
    ; "shop potion:haste"
    ; "floor potion:haste"
    ; "name~Wyrmbane"
    ; "floor name~Wyrmbane"
    ; "props:Conj"
    ; "shop props:Conj"
    ; "staff props:Conj"
    ; "shop staff props:Conj"
    ; "3x shop potion:haste"
    ];
  [%expect
    {|
    potion:haste               -> ((criterion(Item((base_type potion)(sub_type haste))Floor))(min_count 1))
    shop potion:haste          -> ((criterion(Item((base_type potion)(sub_type haste))Shop))(min_count 1))
    floor potion:haste         -> ((criterion(Item((base_type potion)(sub_type haste))Floor))(min_count 1))
    name~Wyrmbane              -> ((criterion(Name_like Wyrmbane Floor))(min_count 1))
    floor name~Wyrmbane        -> ((criterion(Name_like Wyrmbane Floor))(min_count 1))
    props:Conj                 -> ((criterion(Props(base_type())(props(Conj))(position Floor)))(min_count 1))
    shop props:Conj            -> ((criterion(Props(base_type())(props(Conj))(position Shop)))(min_count 1))
    staff props:Conj           -> ((criterion(Props(base_type(staff))(props(Conj))(position Floor)))(min_count 1))
    shop staff props:Conj      -> ((criterion(Props(base_type(staff))(props(Conj))(position Shop)))(min_count 1))
    3x shop potion:haste       -> ((criterion(Item((base_type potion)(sub_type haste))Shop))(min_count 3))
    |}]
;;

(* Every position guard, all of them errors rather than a silent acceptance
   that would answer a question nobody asked. *)
let%expect_test "position guards" =
  List.iter
    ~f:show_parse
    [ (* Two positions on one term: the inner one would otherwise be read as a
         base type, so "shop floor potion:haste" would search for a "floor
         potion" in a shop and find nothing. *)
      "shop floor potion:haste"
    ; "floor shop potion:haste"
    ; "shop shop potion:haste"
      (* No shop form of name~, and its own message -- never a fallthrough to
         the not-a-feature branch. *)
    ; "shop name~Wyrmbane"
      (* A position must not rescue a term search dropped on other grounds. *)
    ; "shop unique:Sigmund"
    ; "floor unique:Sigmund"
    ];
  [%expect
    {|
    shop floor potion:haste    -> error: use "shop " or "floor ", not both: "shop floor potion:haste"
    floor shop potion:haste    -> error: use "shop " or "floor ", not both: "floor shop potion:haste"
    shop shop potion:haste     -> error: use "shop " or "floor ", not both: "shop shop potion:haste"
    shop name~Wyrmbane         -> error: name~ only searches the floor. Remove the "shop ".
    shop unique:Sigmund        -> error: only items are searchable, not monsters. Each seed page lists its uniques.
    floor unique:Sigmund       -> error: only items are searchable, not monsters. Each seed page lists its uniques.
    |}]
;;

(* [artefact] was the one criterion spanning both positions and has no colon
   for a position prefix to lead. Removed 2026-10, and every spelling ticket
   48784e91b7 taught the parser is rejected with the message naming what
   replaced it -- including a position prefix, which must not get the generic
   position message instead. *)
let%expect_test "artefact is rejected in every spelling it used to accept" =
  List.iter
    ~f:show_parse
    [ "artefact"
    ; "Artefact"
    ; "ARTEFACT"
    ; "artifact"
    ; "3x Artifact"
    ; "shop artefact"
    ; "floor artifact"
    ];
  [%expect
    {|
    artefact                   -> error: artefact isn't a search term. Search by property instead, as in "props:Conj" or "weapon props:rF".
    Artefact                   -> error: artefact isn't a search term. Search by property instead, as in "props:Conj" or "weapon props:rF".
    ARTEFACT                   -> error: artefact isn't a search term. Search by property instead, as in "props:Conj" or "weapon props:rF".
    artifact                   -> error: artefact isn't a search term. Search by property instead, as in "props:Conj" or "weapon props:rF".
    3x Artifact                -> error: artefact isn't a search term. Search by property instead, as in "props:Conj" or "weapon props:rF".
    shop artefact              -> error: artefact isn't a search term. Search by property instead, as in "props:Conj" or "weapon props:rF".
    floor artifact             -> error: artefact isn't a search term. Search by property instead, as in "props:Conj" or "weapon props:rF".
    |}]
;;

(* A live bug this change closes, not a hypothetical. [prefixed] was consulted
   before the " props:" infix branch, so "shop props:Conj" reached [item_type]
   and parsed as base type "props", sub type "Conj" -- a search that runs,
   matches nothing, and tells the reader the build holds no such thing.
   Reordering the two would not have fixed it, because the props logic was never
   in the prefix table to reorder. *)
let%expect_test "shop props: is a property search, not a base type named props" =
  List.iter ~f:show_parse [ "shop props:Conj"; "shop staff props:Conj,Alch" ];
  [%expect
    {|
    shop props:Conj            -> ((criterion(Props(base_type())(props(Conj))(position Shop)))(min_count 1))
    shop staff props:Conj,Alch -> ((criterion(Props(base_type(staff))(props(Conj Alch))(position Shop)))(min_count 1))
    |}]
;;

(* "floor " is accepted and redundant, on the same rule that accepts "floor
   potion:haste". It must reach the identical criterion, not a near-miss. *)
let%expect_test "floor name~ is accepted and is the same search as bare name~" =
  let parse s = Or_error.ok_exn (Seed_web.Params.term_of_string s) in
  let same a b = Search.Term.compare (parse a) (parse b) = 0 in
  printf "floor name~ = bare name~: %b\n" (same "floor name~Wyrmbane" "name~Wyrmbane");
  printf
    "floor potion:haste = bare potion:haste: %b\n"
    (same "floor potion:haste" "potion:haste");
  printf "floor props:Conj = bare props:Conj: %b\n" (same "floor props:Conj" "props:Conj");
  (* And the shop forms are a different criterion, so the above is not passing
     because position is being dropped on the way in. *)
  printf
    "shop potion:haste = bare potion:haste: %b\n"
    (same "shop potion:haste" "potion:haste");
  [%expect
    {|
    floor name~ = bare name~: true
    floor potion:haste = bare potion:haste: true
    floor props:Conj = bare props:Conj: true
    shop potion:haste = bare potion:haste: false
    |}]
;;

(* [to_query_string] is what result links and the prefilled form emit, so every
   criterion the parser can build has to survive the round trip back through the
   parser. Lossy in spelling -- [Floor] comes back unprefixed whether or not
   "floor " was typed -- and exact in meaning, which is what is asserted: the
   re-parsed term must compare equal to the original.

   [Feature] and [Unique] are omitted deliberately: [to_query_string] still
   emits them for the seed page, but [Params] refuses them, so they have no
   round trip to make. *)
let%expect_test "every term the parser builds round-trips through to_query_string" =
  List.iter
    ~f:(fun s ->
      match Seed_web.Params.term_of_string s with
      | Error err -> printf "%-26s -> unparseable: %s\n" s (Error.to_string_hum err)
      | Ok term ->
        let emitted = Search.Term.to_query_string term in
        (match Seed_web.Params.term_of_string emitted with
         | Error err ->
           printf "%-26s -> %-26s REJECTED: %s\n" s emitted (Error.to_string_hum err)
         | Ok reparsed ->
           printf
             "%-26s -> %-26s %s\n"
             s
             emitted
             (if Search.Term.compare term reparsed = 0
              then "same"
              else
                sprintf
                  "DIFFERENT: %s"
                  (Sexp.to_string [%sexp (reparsed : Search.Term.t)]))))
    [ "potion:haste"
    ; "floor potion:haste"
    ; "shop potion:haste"
    ; "3x potion:haste"
    ; "3x shop potion:haste"
    ; "weapon:executioner's axe"
    ; "shop weapon:executioner's axe"
    ; "name~Wyrmbane"
    ; "floor name~Wyrmbane"
    ; "props:Conj"
    ; "props:Conj,Alch"
    ; "props:+Blink"
    ; "shop props:Conj"
    ; "shop props:Conj,Alch"
    ; "staff props:Conj,Alch"
    ; "shop staff props:Conj,Alch"
    ; "floor props:Conj"
    ; "floor staff props:Conj"
    ];
  [%expect
    {|
    potion:haste               -> potion:haste               same
    floor potion:haste         -> potion:haste               same
    shop potion:haste          -> shop potion:haste          same
    3x potion:haste            -> 3x potion:haste            same
    3x shop potion:haste       -> 3x shop potion:haste       same
    weapon:executioner's axe   -> weapon:executioner's axe   same
    shop weapon:executioner's axe -> shop weapon:executioner's axe same
    name~Wyrmbane              -> name~Wyrmbane              same
    floor name~Wyrmbane        -> name~Wyrmbane              same
    props:Conj                 -> props:Conj                 same
    props:Conj,Alch            -> props:Conj,Alch            same
    props:+Blink               -> props:+Blink               same
    shop props:Conj            -> shop props:Conj            same
    shop props:Conj,Alch       -> shop props:Conj,Alch       same
    staff props:Conj,Alch      -> staff props:Conj,Alch      same
    shop staff props:Conj,Alch -> shop staff props:Conj,Alch same
    floor props:Conj           -> props:Conj                 same
    floor staff props:Conj     -> staff props:Conj           same
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
    unique:                      -> error: only items are searchable, not monsters. Each seed page lists its uniques.
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

(* The property grammar. Comma separates, a base type may lead, and the whole
   term round-trips back to what was typed. *)
let%expect_test "property search syntax" =
  List.iter
    ~f:show
    [ "props:Conj"
    ; "props:Conj,Alch"
    ; "staff props:Conj,Alch"
    ; "armour props:rF"
    ; "props:+Blink"
    ; "props: Conj , Alch "
    ; "props:"
    ; "props:,"
    ];
  [%expect
    {|
    props:Conj                   -> an artefact with Conj
    props:Conj,Alch              -> an artefact with Conj and Alch
    staff props:Conj,Alch        -> staff with Conj and Alch
    armour props:rF              -> armour with rF
    props:+Blink                 -> an artefact with +Blink
    props: Conj , Alch           -> an artefact with Conj and Alch
    props:                       -> error: props: needs a property, as in "props:Conj"
    props:,                      -> error: props: needs a property, as in "props:Conj"
    |}]
;;

(* Drawbacks are refused by name, wherever they appear in the set. The message
   is about the game, not about the index: there is no operator we are missing. *)
let%expect_test "drawbacks are not searchable" =
  List.iter ~f:show [ "props:*Slow"; "props:Conj,*Noise"; "props:^Contam"; "props:nupgr" ];
  [%expect
    {|
    props:*Slow                  -> error: "*Slow" is a drawback and can't be searched.
    props:Conj,*Noise            -> error: "*Noise" is a drawback and can't be searched.
    props:^Contam                -> error: "^Contam" is a drawback and can't be searched.
    props:nupgr                  -> error: "nupgr" is an internal flag and can't be searched.
    |}]
;;

(* Kept despite the sigil: berserk on hit is a build to commit to. *)
let%expect_test "*Rage is searchable" =
  List.iter ~f:show [ "props:*Rage"; "staff props:*Rage" ];
  [%expect
    {|
    props:*Rage                  -> an artefact with *Rage
    staff props:*Rage            -> staff with *Rage
    |}]
;;

(* A count on properties is rejected rather than dropped, on the rule the depth
   cap follows. *)
let%expect_test "properties take no count" =
  List.iter ~f:show [ "3x props:Conj"; "2x staff props:Conj,Alch"; "1x props:Conj" ];
  [%expect
    {|
    3x props:Conj                -> error: props: terms don't take a count. Remove the "3x".
    2x staff props:Conj,Alch     -> error: props: terms don't take a count. Remove the "2x".
    1x props:Conj                -> an artefact with Conj
    |}]
;;

(* A term round-trips: the search form and the result links must reproduce the
   search already on screen. *)
let%expect_test "property terms round-trip through the query string" =
  List.iter
    ~f:(fun s ->
      match Seed_web.Params.term_of_string s with
      | Error err -> printf "%-28s -> error: %s\n" s (Error.to_string_hum err)
      | Ok term -> printf "%-28s -> %s\n" s (Search.Term.to_query_string term))
    [ "props:Conj"; "props:Conj,Alch"; "staff props:Conj,Alch"; "props: Conj , Alch " ];
  [%expect
    {|
    props:Conj                   -> props:Conj
    props:Conj,Alch              -> props:Conj,Alch
    staff props:Conj,Alch        -> staff props:Conj,Alch
    props: Conj , Alch           -> props:Conj,Alch
    |}]
;;

(* Every example on the help page is a live link, so each one must parse. The
   page teaches the grammar; an example that errors teaches the wrong one. These
   were checked by hand when search narrowed in 2026-09-10 -- pinned here so the
   next change to either side is caught by the build. *)
let%expect_test "help page examples parse" =
  List.iter
    ~f:(fun s ->
      match Seed_web.Params.term_of_string s with
      | Error err -> printf "FAILS: %-28s %s\n" s (Error.to_string_hum err)
      | Ok _ -> ())
    [ "potion:haste"
    ; "wand:digging"
    ; "scroll:acquirement"
    ; "weapon:executioner's axe"
    ; "floor potion:haste"
    ; "shop wand:digging"
    ; "3x potion:haste"
    ; "3x floor potion:haste"
    ; "name~Throatcutter"
    ; "props:Alch"
    ; "props:rF,rC"
    ; "props:rF,rC,rN"
    ; "staff props:Alch"
    ; "staff props:Conj,Alch"
    ; "staff props:Conj,Alch,rC"
    ; "weapon props:rF"
    ; "weapon props:rF,rC"
    ; "weapon props:rF,rC,Will"
    ; "3x scroll:acquirement"
    ; "armour:crystal plate armour"
    ];
  [%expect {| |}]
;;

(* An unknown property is rejected rather than searched. Running it would match
   nothing and report that the build holds no such artefact -- false, and
   indistinguishable from a true empty result. *)
let%expect_test "unknown properties are rejected, not searched" =
  List.iter ~f:show [ "props:Conj Alch"; "props:Blink"; "props:rFire"; "props:Conj,Xyz" ];
  [%expect
    {|
    props:Conj Alch              -> error: no property named "Conj Alch". Separate properties with commas, as in "props:Conj,Alch".
    props:Blink                  -> error: no property named "Blink"
    props:rFire                  -> error: no property named "rFire"
    props:Conj,Xyz               -> error: no property named "Xyz"
    |}]
;;

(* Crawl mixes case within a property name and no reader should have to
   reproduce it. The canonical spelling is what gets echoed back. *)
let%expect_test "property names are case-insensitive and canonicalised" =
  List.iter
    ~f:(fun s ->
      match Seed_web.Params.term_of_string s with
      | Error err -> printf "%-28s -> error: %s\n" s (Error.to_string_hum err)
      | Ok term -> printf "%-28s -> %s\n" s (Search.Term.to_query_string term))
    [ "props:conj"; "props:rf"; "props:sinv"; "props:CONJ,alch"; "props:*rage" ];
  [%expect
    {|
    props:conj                   -> props:Conj
    props:rf                     -> props:rF
    props:sinv                   -> props:SInv
    props:CONJ,alch              -> props:Conj,Alch
    props:*rage                  -> props:*Rage
    |}]
;;

let%expect_test "an empty first page logs the version and the terms by kind" =
  let version = Seed_corpus.Query.Version.of_string "0.34.1" |> Or_error.ok_exn in
  List.iter
    ~f:(fun has ->
      let terms = Seed_web.Params.terms_of_strings has |> Or_error.ok_exn in
      print_endline (Seed_web.Params.empty_search_line (Search.create ~version ~terms ())))
    [ [ "potion:haste"; "staff props:Conj,Alch" ]
    ; [ "3x shop potion:haste"; "shop props:rF"; "shop scroll:acquirement" ]
    ; [ "name~robe of\nVines" ]
    ];
  [%expect
    {|
    search found nothing on 0.34.1: item potion:haste; props staff Conj,Alch
    search found nothing on 0.34.1: 3x item shop potion:haste; props shop rF; item shop scroll:acquirement
    search found nothing on 0.34.1: name robe of\nVines
    |}]
;;

(* Drawn from the local 0.34.1 catalog, trimmed to the pairs the cases below
   touch plus neighbours that would make a sloppy matcher ambiguous. *)
let vocabulary =
  lazy
    (Some
       [ "armour:hat"
       ; "armour:fire dragon scales"
       ; "book:parchment of Shatter"
       ; "jewellery:ring of flight"
       ; "jewellery:ring of protection from fire"
       ; "potion:haste"
       ; "potion:heal wounds"
       ; "scroll:acquirement"
       ; "staff:fire"
       ; "talisman:blade talisman"
       ; "talisman:granite talisman"
       ; "weapon:broad axe"
       ; "weapon:hand axe"
       ])
;;

let show_box ?(vocabulary = vocabulary) s =
  let box = Seed_web.Params.box ~vocabulary s in
  match box.outcome with
  | Parsed term -> printf "%-18s -> parsed %s\n" s (Search.Term.to_query_string term)
  | Resolved term -> printf "%-18s -> resolved %s\n" s (Search.Term.to_query_string term)
  | Rejected { message; offer } ->
    printf
      "%-18s -> rejected: %s%s\n"
      s
      message
      (match offer with
       | None -> ""
       | Some { prompt; terms } ->
         sprintf " %s [%s]" prompt (String.concat terms ~sep:" | "))
;;

let%expect_test "a bare word resolves against the vocabulary" =
  List.iter
    ~f:show_box
    [ "potion:haste"
    ; "haste"
    ; "Haste"
    ; "potion of haste"
    ; "3x haste"
    ; "shop haste"
    ; "broad axe"
    ; "hat"
    ; "flight"
    ; "shatter"
    ; "rf"
    ];
  [%expect
    {|
    potion:haste       -> parsed potion:haste
    haste              -> resolved potion:haste
    Haste              -> resolved potion:haste
    potion of haste    -> resolved potion:haste
    3x haste           -> resolved 3x potion:haste
    shop haste         -> resolved shop potion:haste
    broad axe          -> resolved weapon:broad axe
    hat                -> resolved armour:hat
    flight             -> resolved jewellery:ring of flight
    shatter            -> resolved book:parchment of Shatter
    rf                 -> resolved props:rF
    |}]
;;

(* Several matches run nothing: picking one would answer a question the reader
   may not have asked, and say nothing about the others. *)
let%expect_test "an ambiguous or misspelled word offers, and does not run" =
  List.iter
    ~f:show_box
    [ "talisman"
    ; "fire"
    ; "aquirement"
    ; "hsate"
    ; "3x scroll of aquirement"
    ; "broad"
    ; "axe"
    ; "granite"
    ; "3x rF"
    ];
  [%expect
    {|
    talisman           -> rejected: "talisman" could mean several things. Pick one: [talisman:blade talisman | talisman:granite talisman]
    fire               -> rejected: "fire" could mean several things. Pick one: [staff:fire | props:Fire]
    aquirement         -> rejected: Nothing matches "aquirement". Did you mean: [scroll:acquirement]
    hsate              -> rejected: Nothing matches "hsate". Did you mean: [potion:haste]
    3x scroll of aquirement -> rejected: Nothing matches "scroll of aquirement". Did you mean: [3x scroll:acquirement]
    broad              -> rejected: Nothing matches "broad". Did you mean: [weapon:broad axe]
    axe                -> rejected: Nothing matches "axe". Did you mean: [weapon:broad axe | weapon:hand axe]
    granite            -> rejected: Nothing matches "granite". Did you mean: [talisman:granite talisman]
    3x rF              -> rejected: props: terms don't take a count. Remove the "3x".
    |}]
;;

(* [name~] is offered, never run: it is the one criterion whose cost the
   vocabulary does not bound. *)
let%expect_test "an unknown word offers a name search" =
  List.iter ~f:show_box [ "spectral"; "3x spectral"; "shop spectral"; "xy"; "altar_trog" ];
  [%expect
    {|
    spectral           -> rejected: Nothing matches "spectral". Search artefact names instead: [name~spectral]
    3x spectral        -> rejected: Nothing matches "spectral". Search artefact names instead: [3x name~spectral]
    shop spectral      -> rejected: Nothing matches "spectral". Search artefact names instead: [name~spectral]
    xy                 -> rejected: Nothing matches "xy".
    altar_trog         -> rejected: search covers items, not features: "altar_trog"
    |}]
;;

(* Before the store is built and before the datalist scan lands there is no
   item vocabulary, and "nothing is called hat" would be false. Nor does a
   property resolve alone: [fire] reads as [props:Fire] only because the
   [staff:fire] it would otherwise collide with is not in view. *)
let%expect_test "without a vocabulary a bare word is told the syntax" =
  List.iter ~f:(show_box ~vocabulary:(lazy None)) [ "hat"; "fire" ];
  [%expect
    {|
    hat                -> rejected: "hat" needs a prefix: an item is written base:sub, as in potion:haste. Search artefact names instead: [name~hat]
    fire               -> rejected: "fire" needs a prefix: an item is written base:sub, as in potion:haste. Search artefact names instead: [name~fire]
    |}]
;;

(* The vocabulary is a store read, so a search that has no bare word must not
   pay for it. *)
let%expect_test "a well-formed term never forces the vocabulary" =
  let forced = ref false in
  let vocabulary =
    lazy
      (forced := true;
       None)
  in
  List.iter
    ~f:(show_box ~vocabulary)
    [ "potion:haste"; "potion:"; "name~ab"; "shop "; "haste by D:5" ];
  printf "forced %b\n" !forced;
  [%expect
    {|
    potion:haste       -> parsed potion:haste
    potion:            -> rejected: not a <base>:<sub> item: "potion:"
    name~ab            -> rejected: name~ needs at least 3 characters (got 2)
    shop               -> rejected: "shop" needs an item after it, as in "shop potion:haste"
    haste by D:5       -> rejected: depth limits are no longer supported. Remove the " by ..." from "haste by D:5".
    forced false
    |}]
;;
