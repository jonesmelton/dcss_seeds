open! Core

module Item_type = struct
  type t =
    { base_type : string
    ; sub_type : string
    }
  [@@deriving compare, equal, sexp_of]

  (* Crawl names an item "<sub> of <base>" for consumables but "<sub>" alone for
     gear, and the corpus stores the halves rather than the rendering. *)
  let to_string { base_type; sub_type } =
    match base_type with
    | "potion" | "scroll" | "wand" | "ring" | "amulet" ->
      sprintf "%s of %s" base_type sub_type
    | _ -> sub_type
  ;;
end

module Prop = struct
  (* Drawbacks are not searchable, and the reason is about the game rather than
     about this code. Nobody chooses a seed for a drawback: you find out about
     *Slow when you pick the item up, and it changes whether you keep it, not
     which seed you play. The forward question has no audience -- unlike the
     uniques dropped 2026-09-10, where the wanted question was the negative one
     and search has no negation. There is nothing here waiting on an operator.

     The sigils are how the list is derived, not why. Crawl prefixes a drawback
     that fires at random with '*', one that fires on a trigger with '^', and a
     capability it removes with '-'; [Bane] carries no sigil and is one anyway.
     A new drawback will arrive sigilled and belongs here, but a sigil is
     evidence, not the rule -- see [Rage].

     [nupgr] is excluded for a third reason: ARTP_NO_UPGRADE is an engine flag
     telling the game not to re-roll an artefact that manages its own
     properties, and every carrier in the corpus is such an unrand (Wyrmbane,
     the Octopus King set, Cigotuvi's embrace). It is never shown to a player
     and is not a property in any sense a reader would mean. *)
  let excluded =
    [ "*Corrode"
    ; "*Noise"
    ; "*Silence"
    ; "*Slow"
    ; "^Contam"
    ; "^Drain"
    ; "^Fragile"
    ; "-Cast"
    ; "-Tele"
    ; "Bane"
    ; "nupgr"
    ]
  ;;

  (* Sigilled and kept: berserk on hit is a build to commit to rather than a
     drawback to live with, which is what the rest of [excluded] are. Niche, and
     someone looking for it is looking for exactly it. *)
  let searchable prop = not (List.mem excluded prop ~equal:String.equal)

  (* Why a property was refused, in the reader's terms. [nupgr] is not a
     drawback and saying so would be wrong twice over -- it tells the reader
     their item is worse than it is, and it invites them to look for the
     "good" version of a flag that has none. *)
  let why_excluded prop =
    if String.equal prop "nupgr"
    then Some "an internal flag"
    else if not (searchable prop)
    then Some "a drawback"
    else None
  ;;

  (* Crawl's artefact property vocabulary, which is closed: [entry_props] holds
     one row per property per item and the whole set is 55 names on a 10k
     corpus. Listed rather than read from the corpus because the parse boundary
     is synchronous and cannot wait on a query, and because an unknown name has
     to be *rejected* -- a property search that runs and matches nothing tells
     the reader this build holds no such artefact, which is a false statement
     about the corpus rather than an answer.

     The concrete case: [Dream.queries] decodes a raw '+' to a space, so a
     hand-typed "props:Conj+Alch" arrives as one property named "Conj Alch".
     Without this it searched, found nothing, and said so.

     A crawl release adding a property would be silent in the same direction --
     present in the corpus, on real artefacts, unsearchable with no error --
     so [tools/corpus-check] diffs this list against the corpus and warns. *)
  let newest =
    [ "*Corrode"
    ; "*Noise"
    ; "*Rage"
    ; "*Silence"
    ; "*Slow"
    ; "+Blink"
    ; "+Inv"
    ; "-Cast"
    ; "-Tele"
    ; "AC"
    ; "Air"
    ; "Alch"
    ; "Archmagi"
    ; "BAcc"
    ; "BDam"
    ; "Bane"
    ; "Clar"
    ; "Conj"
    ; "Delay"
    ; "Dex"
    ; "EV"
    ; "Earth"
    ; "Fire"
    ; "Fly"
    ; "Forge"
    ; "HP"
    ; "Harm"
    ; "Hexes"
    ; "Ice"
    ; "Int"
    ; "MP"
    ; "Necro"
    ; "RMsl"
    ; "Rampage"
    ; "Regen"
    ; "RegenMP"
    ; "SH"
    ; "SInv"
    ; "Slay"
    ; "Stlth"
    ; "Str"
    ; "Summ"
    ; "Tloc"
    ; "Will"
    ; "^Contam"
    ; "^Drain"
    ; "^Fragile"
    ; "nupgr"
    ; "rC"
    ; "rCorr"
    ; "rElec"
    ; "rF"
    ; "rMut"
    ; "rN"
    ; "rPois"
    ]
  ;;

  (* (newest spelling, first build to use it, spelling before that). Not
     aliased: a reader on a build types that build's spelling, as the datalist
     offers it. One spelling per build is what keeps a term from having to
     expand into a disjunction over two interned strings. *)
  let renamed = [ "Alch", "0.33.1", "Alchemy" ]

  let spelled_on ~version prop =
    match List.find renamed ~f:(fun (now, _, _) -> String.equal now prop) with
    | Some (_, since, before)
      when Query.Version.release_compare
             version
             (Or_error.ok_exn (Query.Version.of_string since))
           < 0 -> before
    | _ -> prop
  ;;

  let known ~version = List.map newest ~f:(spelled_on ~version)

  (* Case-insensitive, so "conj" and "rf" resolve. Crawl's spellings mix case
     within a name ([rF], [SInv], [BAcc]) and no reader should have to reproduce
     that from memory. Returns the canonical spelling, which is what gets stored
     and echoed back. *)
  let canonical ~version prop =
    List.find (known ~version) ~f:(fun known -> String.Caseless.equal known prop)
  ;;

  let spelling ~version prop =
    List.find_map renamed ~f:(fun (now, _, before) ->
      if String.Caseless.equal now prop || String.Caseless.equal before prop
      then (
        let here = spelled_on ~version now in
        Option.some_if (not (String.Caseless.equal here prop)) here)
      else None)
  ;;

  (* Grants ('+Blink', '+Inv') keep their sigil and stay: a granted capability
     is a reason to pick a seed. *)
  let min_value = 1
end

module Brand = struct
  (* An item's ego is the identity of its enchantment: a weapon's brand or an
     armour's ego, "quick blade of distortion" or "robe of fire resistance".
     Crawl stores a terse code ("distort", "rF+") no reader types, so the
     searchable vocabulary is the *display word* -- what the rendered name
     shows, and therefore what a reader has in mind when they ask. A bare code
     would also be hostile to type: mixed case, pluses, a space in "rC+ rF+".

     The item is not optional, unlike [Props]' base type: the criterion has to
     carry it so the brand stays attached to one object (two terms leak; see
     [Criterion.Brand]). Nor is there a general brand search -- 9,971 of 10,000
     seeds hold *some* ego'd weapon or armour (10k, 0.34.1, D:8, local,
     2026-10-01, fossil ticket 6e121f4c44), so the unqualified form answers
     nothing anyone wants, and the parser refuses one by name. One brand per
     term: an item carries exactly one ego, so a set is not a meaning here. *)

  (* The base types whose ego is orthogonal to the sub type. Jewellery's ego
     is already spelled by its sub type ("ring of protection from fire"), so
     an ego term there would answer the item term's own question. *)
  let base_types = [ "weapon"; "armour" ]

  (* word, code -- the code is crawl's terse string, spelled as 0.34.1 stores
     it. The pairs mirror [Display_name.Ego], whose words are what a rendered
     name shows; the expect test tying the two together is what forces a rekey
     here when crawl renames one. *)
  let weapon_codes =
    [ "antimagic", "antimagic"
    ; "chaos", "chaos"
    ; "concussion", "concuss"
    ; "devious", "devious"
    ; "distortion", "distort"
    ; "draining", "drain"
    ; "electrocution", "elec"
    ; "entangling", "entangle"
    ; "flaming", "flame"
    ; "freezing", "freeze"
    ; "heavy", "heavy"
    ; "holy wrath", "holy"
    ; "pain", "pain"
    ; "protection", "protect"
    ; "rebuke", "rebuke"
    ; "spectral", "spect"
    ; "speed", "speed"
    ; "sundering", "sunder"
    ; "valour", "valour"
    ; "vampiric", "vamp"
    ; "venom", "venom"
    ; (* Never on a non-artefact weapon; the words come from crawl's verbose
       names, since [Display_name.Ego] has no word for them. *)
      "penetration", "penet"
    ; "reaping", "reap"
    ; "acid", "acid"
    ; "foul flame", "foul flame"
    ]
  ;;

  let armour_codes =
    [ "air", "Air"
    ; "archery", "Archery"
    ; "attunement", "Attunement"
    ; "command", "Command"
    ; "death", "Death"
    ; "dexterity", "Dex+3"
    ; "earth", "Earth"
    ; "energy", "Energy"
    ; "fire", "Fire"
    ; "flying", "Fly"
    ; "glass", "Glass"
    ; "guile", "Guile"
    ; "harm", "Harm"
    ; "hurling", "Hurl"
    ; "ice", "Ice"
    ; "infusion", "Infuse"
    ; "intelligence", "Int+3"
    ; "light", "Light"
    ; "mayhem", "Mayhem"
    ; "mesmerism", "Mesmerism"
    ; "parrying", "Parrying"
    ; "ponderousness", "Ponderous"
    ; "pyromania", "Pyromania"
    ; "rampaging", "Rampage"
    ; "reflection", "Reflect"
    ; "repulsion", "Repulsion"
    ; "resonance", "Resonance"
    ; "see invisible", "SInv"
    ; "shadows", "Shadows"
    ; "sniping", "Snipe"
    ; "stardust", "Stardust"
    ; "stealth", "Stlth+"
    ; "strength", "Str+3"
    ; "willpower", "Will+"
    ; "cold resistance", "rC+"
    ; "resistance", "rC+ rF+"
    ; "corrosion resistance", "rCorr"
    ; "fire resistance", "rF+"
    ; "positive energy", "rN+"
    ; "poison resistance", "rPois"
    ; "invisibility", "+Inv"
    ; "protection", "AC+3"
    ; (* Randart-only, as on weapons. *)
      "spirit shield", "Spirit"
    ; "the Archmagi", "Archmagi"
    ]
  ;;

  (* Crawl capitalised eleven armour ego codes in 0.34.1 (docs/plans/
     crawl-renames.md); the same brand on an earlier build is stored under the
     lowercase spelling. The word a reader types is the same either way, which
     is the whole point of keying on words: resolution is per version, not per
     spelling. The one version-aware thing in this module, and the first
     consumer of the release order Rename will generalise. *)
  let capitalised_since = Or_error.ok_exn (Query.Version.of_string "0.34.1")

  let recoded =
    [ "Harm"
    ; "Guile"
    ; "Mayhem"
    ; "Infuse"
    ; "Light"
    ; "Hurl"
    ; "Repulsion"
    ; "Reflect"
    ; "Ponderous"
    ; "Rampage"
    ; "Shadows"
    ]
  ;;

  (* [] for a base type that carries no brand vocabulary: the criterion is
     public, so one can be constructed for jewellery, and it should match
     nothing rather than silently resolving through the weapon table. *)
  let codes base_type =
    if String.equal base_type "weapon"
    then weapon_codes
    else if String.equal base_type "armour"
    then armour_codes
    else []
  ;;

  (* Case-insensitive, as [Prop.canonical] is: no reader should have to
     reproduce crawl's exact capitalisation from memory. Returns the canonical
     word, which is what the criterion stores and echoes back. *)
  let canonical ~base_type word =
    List.find_map (codes base_type) ~f:(fun (w, _) ->
      Option.some_if (String.Caseless.equal w word) w)
  ;;

  (* Any base type's word: for messages, where naming the thing matters more
     than which of the two tables it lives in. *)
  let canonical_any word =
    List.find_map [ "weapon"; "armour" ] ~f:(fun base_type -> canonical ~base_type word)
  ;;

  (* The inverse, code to word -- for the reader who typed the code ("ego:distort")
     and should be told the word rather than a bare "no brand named". *)
  let word_of_code ~base_type code =
    List.find_map (codes base_type) ~f:(fun (w, c) ->
      Option.some_if (String.equal c code) w)
  ;;

  let words ~base_type = List.map (codes base_type) ~f:fst

  (* Codes that never roll on a non-artefact item: crawl generates them only
     through [ARTP_BRAND] (crawl-ref source, shopping.cc calls penetration
     "Unrand-only", artefact.cc sets reaping), and every row carrying one is an
     artefact (10k, 0.34.1, D:8, local, 2026-10-01), so no rendered name a
     reader could type carries one. *)
  let randart_only = [ "penet"; "reap"; "acid"; "foul flame"; "Spirit"; "Archmagi" ]

  (* Why a brand is not searchable, or [None] if it is. One reason exists: a
     code in [randart_only] has no word in a rendered name, and an artefact's
     brand is part of the name [name~] searches. *)
  let why_excluded ~base_type word =
    match
      List.find_map (codes base_type) ~f:(fun (w, c) ->
        Option.some_if (String.Caseless.equal w word) c)
    with
    | Some code when List.mem randart_only code ~equal:String.equal ->
      Some "only ever on artefacts"
    | _ -> None
  ;;

  (* The code a given build stores for a word. [None] for a word neither table
     knows -- the criterion is public-API-constructible, so an unvalidated word
     can reach storage, and "no code" has to be distinguishable from a code. *)
  let code ~base_type ~version word =
    match
      List.find_map (codes base_type) ~f:(fun (w, c) ->
        Option.some_if (String.Caseless.equal w word) c)
    with
    | None -> None
    | Some code ->
      let code =
        if
          String.equal base_type "armour"
          && List.mem recoded code ~equal:String.equal
          && Query.Version.release_compare version capitalised_since < 0
        then String.lowercase code
        else code
      in
      Some code
  ;;
end

module Criterion = struct
  type position =
    | Floor
    | Shop
  [@@deriving compare, equal, sexp_of]

  type t =
    | Item of Item_type.t * position
    | Name_like of string * position
    | Feature of string
    | Unique of string
    | Props of
        { base_type : string option
        ; props : string list
        ; position : position
        }
    | Brand of
        { base_type : string
        ; sub_type : string option
        ; word : string
        ; position : position
        }
  [@@deriving compare, sexp_of]

  (* [feat] is crawl's machine vocabulary ("altar_trog"): stable enough to index
     on, too terse to show a reader. The prefix carries the meaning. *)
  let feature_to_string feat =
    let humanise s = String.tr s ~target:'_' ~replacement:' ' in
    (* God names are proper nouns and several are multi-word ("the shining one"),
       so every word is capitalised. *)
    let titlecase s =
      String.split (humanise s) ~on:' '
      |> List.map ~f:String.capitalize
      |> String.concat ~sep:" "
    in
    match String.lsplit2 feat ~on:'_' with
    | Some ("altar", god) -> sprintf "an altar of %s" (titlecase god)
    | Some ("enter", "shop") -> "a shop"
    | Some ("enter", place) -> sprintf "an entrance to %s" (humanise place)
    | Some ("exit", place) -> sprintf "an exit from %s" (humanise place)
    | _ -> humanise feat
  ;;

  (* "a staff with Conj and Alch", not "a staff, and something with Conj": the
     properties are all on one item, so the prose has to join them to the noun
     rather than list them beside it. *)
  let props_to_string ~base_type ~props =
    let noun = Option.value base_type ~default:"an artefact" in
    match props with
    | [] -> noun
    | [ one ] -> sprintf "%s with %s" noun one
    | props ->
      let last = List.last_exn props in
      let rest = List.drop_last_exn props in
      sprintf "%s with %s and %s" noun (String.concat rest ~sep:", ") last
  ;;

  (* Only [Shop] is qualified. Prose echoes the query back and the query leaves
     the floor default unspoken, so spelling it per term turns a three-term
     search into "potion of haste on the floor, wand of digging on the floor, an
     artefact". The default is stated once per page instead. *)
  let position_to_string = function
    | Floor -> ""
    | Shop -> " in a shop"
  ;;

  (* [Floor] is never spelled back, so the round-trip is lossy in spelling and
     exact in meaning: [floor potion:haste] returns as [potion:haste]. *)
  let position_to_query_string = function
    | Floor -> ""
    | Shop -> "shop "
  ;;

  let to_string = function
    | Item (item, position) -> Item_type.to_string item ^ position_to_string position
    | Name_like (s, position) -> sprintf "named like %S%s" s (position_to_string position)
    | Feature feat -> feature_to_string feat
    | Unique name -> name
    | Props { base_type; props; position } ->
      props_to_string ~base_type ~props ^ position_to_string position
    (* "quick blade with distortion", the [props_to_string] shape: the brand
       joins to the item, because it is a fact about the item rather than a
       second criterion. The rendered name's own "of" is skipped -- a prefix
       brand ("vampiric dagger") would read wrong in it. *)
    | Brand { base_type; sub_type = Some sub_type; word; position } ->
      sprintf "%s with %s" (Item_type.to_string { base_type; sub_type }) word
      ^ position_to_string position
    | Brand { base_type; sub_type = None; word; position } ->
      sprintf "%s with %s" base_type word ^ position_to_string position
  ;;

  (* The noun for counting several of what this criterion matches. An item
     type's plural depends on the stack name crawl rendered, and a name fragment
     names no category at all; only [Props] has a plural that reads, because
     every match is an artefact whatever base type it sits on. *)
  let plural_noun = function
    | Props _ -> Some "artefacts"
    | Brand _ | Item _ | Name_like _ | Feature _ | Unique _ -> None
  ;;

  (* Constantly true since interning: a substring match runs over the string
     dictionary rather than over entries, and since the trigram index, as a
     lookup there rather than a scan. Kept, with [partition_terms], because a
     future criterion no index serves would need exactly this. *)
  let is_indexed = function
    | Name_like _ | Item _ | Feature _ | Unique _ | Props _ | Brand _ -> true
  ;;

  (* Three characters is a hard precondition, not a tuning knob: the substring
     search is served by a trigram index, and trigram cannot answer a fragment
     shorter than a trigram -- fts5 silently falls back to scanning the whole
     dictionary below three. It happens to be the same threshold the scan-era
     heuristic wanted, and it still admits real unrand fragments (["cer"],
     ["wyr"]). *)
  let min_name_like_length = 3

  (* No [Name_like] is cheap. The trigram index made selective fragments fast
     (7.02s -> 0.21s) but the cost is the candidate set the dictionary hands on,
     not the lookup, so fragment length does not bound it: [name~the] is three
     characters and 14.2s. Nor does the search store cover the gap: it resolves
     a fragment to seeds before merging, which is that same candidate set, and
     declines a broad one to the SQL fallback.

     Inline, that fallback blocks the scheduler thread rather than awaiting on
     it, so [Lwt.pick]'s timer is armed against an already-resolved promise and
     the search timeout cannot fire at all. Ten concurrent fragments took index
     p99 from 0.29s to 48.2s with no 503 (prod, 1.3M, 0.34.1, 2026-09-21). A
     selective fragment being fast today is a property of the corpus, not of the
     query. Every other criterion is a single covering seek. *)
  let is_cheap = function
    | Name_like _ -> false
    (* With a base type the driver is that seek and the properties are filters
       on what it returns. Without one there is nothing to seek: the query
       drives [entries_seed] and the [limit] does not end it early, because a
       rare property pair matches a handful of seeds and the scan runs to the
       end of the build looking for more. Linear in corpus size regardless of
       page size (measured: full scan of the version at 10k, plan unchanged
       under the keyset shape), so it belongs off the scheduler thread. *)
    | Props { base_type; props = _; position = _ } -> Option.is_some base_type
    | Item _ | Feature _ | Unique _ | Brand _ -> true
  ;;

  let has_count_ceiling = function
    | Name_like _ | Props _ -> false
    | Item _ | Feature _ | Unique _ | Brand _ -> true
  ;;
end

module Term = struct
  type t =
    { criterion : Criterion.t
    ; min_count : int
    }
  [@@deriving compare, sexp_of]

  let create ?(min_count = 1) criterion = { criterion; min_count = Int.max 1 min_count }

  (* The inverse of the query-string syntax the web layer parses, so a rendered
     term round-trips: a result page's links and its prefilled form must produce
     the search the reader is already looking at. [Criterion.to_string] is prose
     and does not. *)
  let to_query_string { criterion; min_count } =
    let criterion =
      match criterion with
      | Criterion.Item ({ base_type; sub_type }, position) ->
        sprintf "%s%s:%s" (Criterion.position_to_query_string position) base_type sub_type
      | Criterion.Name_like (fragment, position) ->
        sprintf "%sname~%s" (Criterion.position_to_query_string position) fragment
      | Criterion.Feature feat -> feat
      | Criterion.Unique name -> sprintf "unique:%s" name
      (* Comma, not '+': '+Blink' and '+Inv' are property names, so a '+'
         separator spells a set holding one as "Conj++Blink". A comma cannot
         collide -- no property name contains one. It also sidesteps an encoding
         trap, since [Dream.queries] decodes a raw '+' to a space and only
         "%2B" survives; emitted links percent-encode either way, but readers
         hand-edit these URLs. *)
      | Criterion.Props { base_type; props; position } ->
        let props = String.concat props ~sep:"," in
        let position = Criterion.position_to_query_string position in
        (match base_type with
         | None -> sprintf "%sprops:%s" position props
         | Some base_type -> sprintf "%s%s props:%s" position base_type props)
      (* The word, not the code: a link carries what a reader can re-type, and
         the code is a spelling per build besides (see [Brand.code]). *)
      | Criterion.Brand { base_type; sub_type; word; position } ->
        sprintf
          "%s%s ego:%s"
          (Criterion.position_to_query_string position)
          (match sub_type with
           | Some sub_type -> base_type ^ ":" ^ sub_type
           | None -> base_type)
          word
    in
    if min_count > 1 then sprintf "%dx %s" min_count criterion else criterion
  ;;

  let to_string { criterion; min_count } =
    if min_count > 1
    then sprintf "%d+ %s" min_count (Criterion.to_string criterion)
    else Criterion.to_string criterion
  ;;
end

type t =
  { version : Query.Version.t
  ; terms : Term.t list
  ; page : Query.Page.t
  }
[@@deriving sexp_of]

let create ~version ?(terms = []) ?(page = Query.Page.first) () = { version; terms; page }
let is_empty t = List.is_empty t.terms

let ceiling_term t =
  match List.filter t.terms ~f:(fun (term : Term.t) -> term.min_count > 1) with
  | [ term ] when Criterion.has_count_ceiling term.criterion -> Some term
  | _ -> None
;;

let partition_terms t =
  List.partition_tf t.terms ~f:(fun (term : Term.t) ->
    Criterion.is_indexed term.criterion)
;;

let to_string t =
  match t.terms with
  | [] -> sprintf "all seeds on %s" (Query.Version.to_string t.version)
  | terms ->
    sprintf
      "seeds on %s with %s"
      (Query.Version.to_string t.version)
      (List.map terms ~f:Term.to_string |> String.concat ~sep:", ")
;;

module Match = struct
  type hit =
    { term : Term.t
    ; level : string
    ; name : string
    ; count : int
    ; distinct : int
    }
  [@@deriving sexp_of]

  type t =
    { seed : string
    ; hits : hit list
    }
  [@@deriving sexp_of]
end

module Rank = struct
  type t =
    | Seed
    | Shallowest
  [@@deriving compare, equal, sexp_of, enumerate]

  let to_string = function
    | Seed -> "seed"
    | Shallowest -> "shallowest"
  ;;

  let of_string = function
    | "seed" -> Some Seed
    | "shallowest" -> Some Shallowest
    | _ -> None
  ;;

  let default = Seed
  let sort_limit = 5_000

  (* Tagged rather than matched on the message text: the web layer must
     distinguish "your search is too broad" from a genuine failure. *)
  let too_broad_tag = "search-too-broad"

  let is_too_broad error =
    String.is_substring (Error.to_string_hum error) ~substring:too_broad_tag
  ;;
end

(* Tagged like [Rank.too_broad_tag], and for the same reason: the web layer has
   to tell "the substring index is rebuilding" apart from a genuine fault.

   Refusing rather than falling back to the dictionary scan is deliberate. The
   scan is correct but reads the whole dictionary -- seconds of disk per
   request, on a public read-only endpoint with no account behind it, which is
   an amplification factor sitting behind a query parameter. A refusal costs a
   reader the one criterion for as long as a rebuild takes; a fallback costs
   everyone the box. Both are honest about not knowing the answer, which is what
   a stale trigram index otherwise hides. *)
let stale_index_tag = "search-index-rebuilding"

let is_index_rebuilding error =
  String.is_substring (Error.to_string_hum error) ~substring:stale_index_tag
;;

let rank_matches matches ~rank ~depth_of_level =
  match (rank : Rank.t) with
  | Rank.Seed -> matches
  | Rank.Shallowest ->
    (* A match with no hits sorts last: an empty search matches every seed and has
       nothing to be shallow about. *)
    let deepest = Int.max_value in
    let depth (m : Match.t) =
      List.fold m.hits ~init:deepest ~f:(fun acc (hit : Match.hit) ->
        Int.min acc (depth_of_level hit.level))
    in
    List.sort matches ~compare:(fun a b ->
      match Int.compare (depth a) (depth b) with
      | 0 -> String.compare a.seed b.seed
      | c -> c)
;;
