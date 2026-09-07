open! Core
module Reader = Seed_corpus.Reader
module Record = Seed_corpus.Record

let parse_exn line = Or_error.ok_exn (Reader.parse_line line)

let show_entries (r : Record.t) =
  List.iter r.entries ~f:(fun (e : Record.Entry.t) ->
    print_endline
      (Printf.sprintf
         "%-8s carried_by=%-12s %s"
         (Record.Cat.to_string e.cat)
         (Option.value e.carried_by ~default:"-")
         e.name))
;;

(* A real record from seed 777 at Orc:2: the serializer's escaping was written
   to match s-expression conventions but had not been round-tripped through an
   OCaml parser. *)
let%expect_test "artefact names carrying quotes and braces round-trip" =
  let line =
    {|#SEED#((format 4)(version "0.33-a0")(seed "777")(level "Orc:2")(cats (items (((artefact t)(base_type "weapon")(kind "item")(name "+1 sling \"Wipar\" {flame, Int+2 Stlth+}")(plus 1)(quantity 1)(sub_type "sling")(text "+1 sling \"Wipar\" {flame, Int+2 Stlth+}"))))))|}
  in
  let r = parse_exn line in
  print_s [%sexp (List.map r.entries ~f:Record.Entry.name : string list)];
  [%expect {| ("+1 sling \"Wipar\" {flame, Int+2 Stlth+}") |}]
;;

let%expect_test "monster inventories flatten to entries carrying the monster name" =
  let line =
    {|#SEED#((format 4)(version "0.33-a0")(seed "1")(level "D:2")(cats (items (((artefact nil)(base_type "scroll")(kind "item")(name "scroll of revelation")(quantity 1)(sub_type "revelation")(text "scroll of revelation"))))(monsters (((items (((artefact nil)(base_type "weapon")(branded t)(kind "item")(name "+0 whip of freezing")(plus 0)(quantity 1)(sub_type "whip")(text "+0 whip of freezing"))))(kind "monster")(name "kobold")(native t)(ood nil)(text "kobold")(type_name "kobold")(unique nil))))))|}
  in
  let r = parse_exn line in
  show_entries r;
  [%expect
    {|
    items    carried_by=-            scroll of revelation
    monsters carried_by=-            kobold
    items    carried_by=kobold       +0 whip of freezing
    |}]
;;

let%expect_test "nil is both false and absent" =
  let line =
    {|#SEED#((format 4)(version "0.33-a0")(seed "1")(level "D:2")(cats (monsters (((artefact nil)(kind "monster")(name "rat")(branded nil)(text "rat")(unique nil))))))|}
  in
  let r = parse_exn line in
  let e = List.hd_exn r.entries in
  print_s
    [%sexp
      { artefact = (e.artefact : bool option)
      ; branded = (e.branded : bool option)
      ; unique_mons = (e.unique_mons : bool option)
      ; native = (e.native : bool option)
      }];
  [%expect {| ((artefact (false)) (branded (false)) (unique_mons (false)) (native ())) |}]
;;

(* Vaults are level-generation scaffolding, and runed_clear_door records that a
   vault exists without recording what is in it. The dumper still emits both, so
   this is the only thing standing between them and the corpus. *)
let%expect_test "vaults and runed doors are dropped at ingest" =
  let line =
    {|#SEED#((format 4)(version "0.33-a0")(seed "1")(level "D:2")(cats (features (((feat "runed_clear_door")(kind "feature")(text "a runed door"))((feat "altar_trog")(kind "feature")(text "an altar of Trog"))))(vaults (((kind "vault")(name "layout_basic")(text "layout_basic"))))(items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste"))))))|}
  in
  let r = parse_exn line in
  List.iter r.entries ~f:(fun (e : Record.Entry.t) ->
    printf "%-8s %s\n" (Record.Cat.to_string e.cat) e.name);
  [%expect
    {|
    features an altar of Trog
    items    potion of haste
    |}]
;;

(* A Temple's pool-god altars collapse into a bitmask and lose their rows. The
   four vault-placed gods and altar_ecumenical are outside crawl's pool, have no
   bit, and must keep their rows -- otherwise a rare-god query finds nothing. *)
let%expect_test "temple pool altars become a mask; rare gods keep their rows" =
  let line =
    {|#SEED#((format 4)(version "0.33-a0")(seed "1")(level "Temple")(cats (features (((feat "altar_trog")(kind "feature")(text "an altar of Trog"))((feat "altar_zin")(kind "feature")(text "an altar of Zin"))((feat "altar_lugonu")(kind "feature")(text "an altar of Lugonu"))((feat "altar_ecumenical")(kind "feature")(text "a faded altar"))))))|}
  in
  let r = parse_exn line in
  let mask = Option.value_exn r.temple_altars in
  print_s
    [%sexp (Seed_corpus.Temple.to_feats (Seed_corpus.Temple.of_int mask) : string list)];
  [%expect {| (altar_trog altar_zin) |}];
  List.iter r.entries ~f:(fun (e : Record.Entry.t) ->
    print_endline (Option.value e.feat ~default:"-"));
  [%expect
    {|
    altar_lugonu
    altar_ecumenical
    |}]
;;

(* Only on the Temple: the mask has one slot per seed, and a D-level altar is a
   different fact. *)
let%expect_test "a D-level altar is untouched by the temple mask" =
  let line =
    {|#SEED#((format 4)(version "0.33-a0")(seed "1")(level "D:3")(cats (features (((feat "altar_trog")(kind "feature")(text "an altar of Trog"))))))|}
  in
  let r = parse_exn line in
  print_s [%sexp (r.temple_altars : int option)];
  [%expect {| () |}];
  print_s [%sexp (List.map r.entries ~f:Record.Entry.name : string list)];
  [%expect {| ("an altar of Trog") |}]
;;

(* A parchment holds exactly one spell, always its own sub_type minus the
   prefix, so the row is pure duplication. The randart book keeps every one of
   its spells: crawl's artefact flag tells a generated book from a designed
   one. *)
let%expect_test "a parchment's spell is dropped; a randart book's is kept" =
  let line =
    {|#SEED#((format 4)(version "0.33-a0")(seed "1")(level "D:2")(cats (items (((base_type "book")(kind "item")(name "parchment of Shock")(quantity 1)(spells ("Shock"))(sub_type "parchment of Shock")(text "parchment of Shock"))((artefact t)(base_type "book")(kind "item")(name "Wamnu's Compendium")(quantity 1)(spells ("Blink" "Freeze"))(sub_type "book of Fixed Theme")(text "Wamnu's Compendium"))((base_type "book")(kind "item")(name "book of Necromancy")(quantity 1)(spells ("Agony" "Vampiric Draining"))(sub_type "book of Necromancy")(text "book of Necromancy"))))))|}
  in
  let r = parse_exn line in
  List.iter r.entries ~f:(fun (e : Record.Entry.t) ->
    printf "%-24s %s\n" e.name (String.concat ~sep:", " e.spells));
  [%expect
    {|
    parchment of Shock
    Wamnu's Compendium       Blink, Freeze
    book of Necromancy       Agony, Vampiric Draining
    |}]
;;

(* Unstored, not lost: recovered from the name on the way back out. *)
let%expect_test "a parchment's spell is recoverable from its sub_type" =
  print_s
    [%sexp
      (Seed_corpus.Book.spells_of_sub_type "parchment of Shock" : string list option)];
  [%expect {| ((Shock)) |}];
  print_s
    [%sexp
      (Seed_corpus.Book.spells_of_sub_type "book of Necromancy" : string list option)];
  [%expect {| () |}]
;;

(* Real feature records carry [feat] and [text] but no [name] at all, so [text]
   stands in for the schema's not-null [name] column. *)
let%expect_test "features have no name and fall back to text" =
  let line =
    {|#SEED#((format 4)(version "0.33-a0")(seed "1")(level "D:2")(cats (features (((feat "altar_qazlal")(kind "feature")(text "a stormy altar of Qazlal"))))))|}
  in
  let r = parse_exn line in
  let e = List.hd_exn r.entries in
  print_s [%sexp { name = (e.name : string); feat = (e.feat : string option) }];
  [%expect {| ((name "a stormy altar of Qazlal") (feat (altar_qazlal))) |}]
;;

(* The format check rejects in both directions: a record from a newer dumper
   and one from a stale build are equally unparseable. *)
let%expect_test "an unsupported format is rejected at the parse boundary" =
  let newer = {|#SEED#((format 5)(version "0.33-a0")(seed "1")(level "D:2")(cats ))|} in
  print_s [%sexp (Reader.parse_line newer : Record.t Or_error.t)];
  [%expect {| (Error "unsupported format 5 (this reader understands 4)") |}];
  let stale = {|#SEED#((format 1)(version "0.33-a0")(seed "1")(level "D:2")(cats ))|} in
  print_s [%sexp (Reader.parse_line stale : Record.t Or_error.t)];
  [%expect {| (Error "unsupported format 1 (this reader understands 4)") |}]
;;

(* A portal whose parent went missing degrades silently -- the level just
   becomes unrankable again -- so it is refused rather than stored as a null. *)
let%expect_test "a format-2 portal must carry its parent level" =
  let line = {|#SEED#((format 4)(version "0.33-a0")(seed "1")(level "Sewer")(cats ))|} in
  print_s [%sexp (Reader.parse_line line : Record.t Or_error.t)];
  [%expect {| (Error "portal Sewer has no parent_level") |}];
  let ok =
    {|#SEED#((format 4)(version "0.33-a0")(seed "1")(level "Sewer")(parent_level "D:5")(cats ))|}
  in
  print_s
    [%sexp
      (Or_error.map (Reader.parse_line ok) ~f:Record.parent_level
       : string option Or_error.t)];
  [%expect {| (Ok (D:5)) |}]
;;

let%expect_test "a truncated line is an error, not an exception" =
  let line = {|#SEED#((format 4)(version "0.33-a0")(seed "1")(lev|} in
  (match Reader.parse_line line with
   | Ok _ -> print_endline "unexpectedly parsed"
   | Error _ -> print_endline "rejected");
  [%expect {| rejected |}]
;;

let%expect_test "shop items carry a cost; floor items do not" =
  let line =
    {|#SEED#((format 4)(version "0.33-a0")(seed "1")(level "D:2")(cats (items (((base_type "scroll")(cost 75)(kind "item")(name "scroll of revelation")(quantity 1)(sub_type "revelation")(text "scroll of revelation (cost: 75)"))((base_type "potion")(kind "item")(name "potion of curing")(quantity 2)(sub_type "curing")(text "potion of curing"))))))|}
  in
  let r = parse_exn line in
  List.iter r.entries ~f:(fun (e : Record.Entry.t) ->
    print_endline
      (Printf.sprintf
         "%s cost=%s quantity=%s"
         e.name
         (Option.value_map e.cost ~default:"-" ~f:Int.to_string)
         (Option.value_map e.quantity ~default:"-" ~f:Int.to_string)));
  [%expect
    {|
    scroll of revelation cost=75 quantity=1
    potion of curing cost=- quantity=2
    |}]
;;

(* Floor gold is level-scoped and is a sum the wire computes: crawl's own item
   filter drops the piles, so no row carries it and it cannot be recomputed.
   Zero is a real answer and stays distinct from the field a format-3 build
   omitted. *)
let%expect_test "floor gold is a level fact, and zero is not absent" =
  let line gold =
    sprintf {|#SEED#((format 4)(version "0.33-a0")(seed "1")(level "D:2")%s(cats ))|} gold
  in
  List.iter [ "(gold 431)"; "(gold 0)"; "" ] ~f:(fun gold ->
    print_s [%sexp ((parse_exn (line gold)).gold : int option)]);
  [%expect
    {|
    (431)
    (0)
    ()
    |}]
;;

(* A trove's toll rides on its entrance feature. Nothing else distinguishes one
   trove from another, and the note is crawl's rendered string: the structured
   toll table never reaches the lua marker API. *)
let%expect_test "a trove's toll note rides on its entrance feature" =
  let line =
    {|#SEED#((format 4)(version "0.33-a0")(seed "1")(level "D:5")(gold 12)(cats (features (((feat "enter_trove")(kind "feature")(text "a portal to a secret trove of treasure")(timeout_turns 512)(toll_note "give a scroll of acquirement")(x 4)(y 9))((feat "enter_sewer")(kind "feature")(text "a glowing drain")(timeout_turns 783)(x 1)(y 2))))))|}
  in
  let r = parse_exn line in
  List.iter r.entries ~f:(fun (e : Record.Entry.t) ->
    print_s [%sexp (e.feat : string option), (e.toll_note : string option)]);
  [%expect
    {|
    ((enter_trove) ("give a scroll of acquirement"))
    ((enter_sewer) ())
    |}]
;;
