open! Core
module Query = Seed_corpus.Query

let served request = Served.of_string (Dream.param request "version")
let version request = Or_error.map (served request) ~f:Served.to_version

let page request =
  let open Or_error.Let_syntax in
  let%map limit =
    match Dream.query request "limit" with
    | None -> Ok Query.Page.default_limit
    | Some s ->
      (match Int.of_string_opt s with
       | Some n -> Ok n
       | None -> Or_error.errorf "not a number: %S" s)
  in
  Query.Page.create ?after:(Dream.query request "after") ~limit ()
;;

module Search = Seed_corpus.Search

(* A kill switch for search as a whole rather than a per-call-site argument:
   set once at process start from SEED_DISABLE_SEARCH, read by every search
   request. *)
let search_disabled = ref false

(* Mirrors [search_disabled]: set once at process start from
   SEED_DISABLE_DEEPEN, read by every deepen call site. *)
let deepen_disabled = ref false

(* Wall clock on the search path, not a query cancellation: sqlite3-ocaml 5.4.2
   binds neither [sqlite3_interrupt] nor a progress handler, so an expired
   search still runs to completion on its worker and holds its pool connection.
   This bounds what a client waits for, not what a query occupies. *)
let search_timeout = ref 60.

(* Seconds a search waits for a free [Gate] permit -- and so for a pool
   connection, since a permit is what one is taken under -- before answering
   503. Kept well under [search_timeout]: saturation is a capacity fact, and
   there is nothing to gain by making the client wait out the whole query
   budget for it. Set from SEED_POOL_TIMEOUT in {!Main}. *)
let pool_timeout = ref 5.

(* "3x " is an affix on a criterion rather than a criterion of its own, so it is
   peeled off before the prefix dispatch below.

   Only a leading run of digits followed by 'x': an 'x' elsewhere belongs to the
   name ("altar_xom", "executioner's axe"), and splitting on the first one would
   silently truncate the term. *)
let peel_min_count s =
  let digits = String.take_while s ~f:Char.is_digit in
  if String.is_empty digits
  then 1, s
  else (
    let rest = String.subo s ~pos:(String.length digits) in
    match String.chop_prefix rest ~prefix:"x" with
    | Some rest ->
      (match Int.of_string_opt digits with
       | Some n -> n, String.strip rest
       | None -> 1, s)
    | None -> 1, s)
;;

let item_type s =
  match String.lsplit2 s ~on:':' with
  | Some (base_type, sub_type)
    when (not (String.is_empty base_type)) && not (String.is_empty sub_type) ->
    Ok { Search.Item_type.base_type; sub_type }
  | _ -> Or_error.errorf "not a <base>:<sub> item: %S" s
;;

let not_an_item_monster =
  "only items are searchable, not monsters. Each seed page lists its uniques."
;;

(* "props:Conj,Alch", optionally led by a base type ("staff props:Conj,Alch").

   Comma separates. A '+' cannot: '+Blink' and '+Inv' are property names, so a
   set holding one would spell "Conj++Blink". It also avoids an encoding trap --
   [Dream.queries] decodes a raw '+' to a space, and only "%2B" survives it. *)
let props_of_string ?base_type ~position rest =
  let props =
    String.split rest ~on:','
    |> List.map ~f:String.strip
    |> List.filter ~f:(Fn.non String.is_empty)
  in
  if List.is_empty props
  then Or_error.errorf "props: needs a property, as in \"props:Conj\""
  else
    let open Or_error.Let_syntax in
    let%bind props =
      List.map props ~f:(fun prop ->
        match Search.Prop.canonical prop with
        (* An unknown property is rejected, never searched. Running it would
           match nothing and report that the build holds no such artefact --
           false, and indistinguishable from true. The case this catches in
           practice is a hand-typed "props:Conj+Alch", which arrives as one
           property named "Conj Alch" because [Dream.queries] decodes a raw '+'
           to a space. *)
        | None ->
          if String.mem prop ' '
          then
            Or_error.errorf
              "no property named %S. Separate properties with commas, as in \
               \"props:Conj,Alch\"."
              prop
          else Or_error.errorf "no property named %S" prop
        | Some canonical ->
          (* Named rather than counted: a reader who typed a drawback wants to
             know which one we will not search for, not that "one term was
             rejected". The reason comes from [Search.Prop] because the reasons
             differ -- calling [nupgr] a drawback would be wrong. *)
          (match Search.Prop.why_excluded canonical with
           | Some why -> Or_error.errorf "%S is %s and can't be searched." canonical why
           | None -> Ok canonical))
      |> Or_error.all
    in
    return (Search.Criterion.Props { base_type; props; position })
;;

(* The two position words, and the one source both the prefix parse and the
   bare-word error read from. *)
let positions = [ "shop", Search.Criterion.Shop; "floor", Search.Criterion.Floor ]

(* A position is peeled off the front and the rest is parsed by the same body a
   bare term reaches. Handing that rest to [item_type] instead is the trap:
   "shop props:Conj" reads as base type "props", sub type "Conj" -- a search
   that runs, matches nothing, and reports the build holds no such thing. No
   reordering fixes it, because the props logic never sat beside the prefixes in
   the first place. *)
let position_prefix s =
  List.find_map positions ~f:(fun (word, position) ->
    Option.map
      (String.chop_prefix s ~prefix:(word ^ " "))
      ~f:(fun rest -> position, String.strip rest))
;;

(* A position word with nothing after it is a typo, and it must not fall through
   to the feature branch: the term arrives stripped, so a bare "floor" would
   parse as a *feature named "floor"* -- a search that runs, matches nothing,
   and tells the reader their build has no such thing. *)
let bare_prefix s =
  List.find_map positions ~f:(fun (word, _) ->
    if String.equal s word
    then
      Some
        (Or_error.errorf "%S needs an item after it, as in \"%s potion:haste\"" word word)
    else None)
;;

(* The one criterion with no shop form. Gold is the binding constraint in the
   early game, so an unrand you can afford in a shop is one you could have
   afforded off the floor -- "is it for sale" is not the question being asked.
   Bare "name~" and "floor name~" are therefore the same search. *)
let name_like ~position rest =
  if String.is_empty rest
  then Or_error.errorf "name~ needs something to match"
  else if String.length rest < Search.Criterion.min_name_like_length
  then
    Or_error.errorf
      "name~ needs at least %d characters (got %d)"
      Search.Criterion.min_name_like_length
      (String.length rest)
  else (
    match position with
    | Some Search.Criterion.Shop ->
      Or_error.errorf "name~ only searches the floor. Remove the \"shop \"."
    | Some Search.Criterion.Floor | None ->
      Ok (Search.Criterion.Name_like (rest, Search.Criterion.Floor)))
;;

(* The body every term reaches once its position is peeled off. [position] is
   [None] for a term that named none; everywhere else it settles to [Floor]. *)
let criterion_at ~position s =
  let at = Option.value position ~default:Search.Criterion.Floor in
  if List.mem [ "artefact"; "artifact" ] (String.lowercase s) ~equal:String.equal
  then
    Or_error.errorf
      "artefact isn't a search term. Search by property instead, as in \"props:Conj\" or \
       \"weapon props:rF\"."
  else if String.is_prefix s ~prefix:"unique:"
  then Or_error.errorf "%s" not_an_item_monster
  else if String.is_prefix s ~prefix:"name~"
  then name_like ~position (String.drop_prefix s (String.length "name~"))
  else if String.is_prefix s ~prefix:"props:"
  then
    props_of_string ~position:at (String.drop_prefix s (String.length "props:"))
    (* "staff props:Conj,Alch". The base type leads rather than following a
         fixed prefix, so it must be tried before the [<base>:<sub>] parse below,
         which would otherwise read "staff props" as a base type. *)
  else if String.is_substring s ~substring:" props:"
  then (
    match String.substr_index s ~pattern:" props:" with
    | None -> Or_error.errorf "not a property search: %S" s
    | Some i ->
      let base_type = String.strip (String.prefix s i) in
      let rest = String.drop_prefix s (i + String.length " props:") in
      if String.is_empty base_type
      then props_of_string ~position:at rest
      else props_of_string ~base_type ~position:at rest)
  else if String.mem s ':'
  then Or_error.map (item_type s) ~f:(fun item -> Search.Criterion.Item (item, at))
  else if String.is_empty s
  then
    Or_error.errorf "empty search term"
    (* A term that named a position named an item, so the feature message below
         would answer a question it did not ask. *)
  else if Option.is_some position
  then
    Or_error.errorf "not a <base>:<sub> item: %S" s
    (* Features are not searchable. Altars went first; the rest followed
         2026-09-10, when the unselective ones ([enter_temple] stands on every
         seed, [enter_shop] on 2.1x as many rows) turned out to be what made a
         multi-term intersection slow. Rejected rather than left to match
         nothing: a term that runs and finds nothing reads as "no such seeds"
         rather than "not a supported search". *)
  else Or_error.errorf "search covers items, not features: %S" s
;;

let criterion s =
  match bare_prefix s with
  | Some err -> err
  | None ->
    (match position_prefix s with
     | None -> criterion_at ~position:None s
     (* Checked here rather than inside [criterion_at] so the message can quote
        the term as typed. The peeled remainder is not something the reader
        wrote, and naming it back at them is an answer to a question they cannot
        recognise. *)
     | Some (position, rest) ->
       (match position_prefix rest with
        | Some _ -> Or_error.errorf "use \"shop \" or \"floor \", not both: %S" s
        | None -> criterion_at ~position:(Some position) rest))
;;

(* "<term> by D:n" used to cap how deep a match could sit. Rejected rather than
   ignored: the corpus's fill depth already bounds every result, and a silently
   dropped cap answers a different question. Explicitly, because it would not
   fail on its own -- "potion:haste by D:5" splits on ':' into two non-empty
   halves and parses as the sub_type "haste by D:5". *)
let rejects_depth_cap s =
  if String.is_substring s ~substring:" by "
  then
    Or_error.errorf
      "depth limits are no longer supported. Remove the \" by ...\" from %S."
      s
  else Ok ()
;;

(* Counting properties is not a question anyone asks. The two kinds of answer it
   could give are both uninteresting: a build with three of the same resistance
   is ordinary rather than notable, and a second copy of a niche property is not
   what made the first one worth finding. Rejected rather than ignored, on the
   rule the depth cap follows -- a silently dropped count answers a different
   question than the one typed. *)
let rejects_prop_count criterion ~min_count =
  match (criterion : Search.Criterion.t) with
  | Search.Criterion.Props _ when min_count > 1 ->
    Or_error.errorf "props: terms don't take a count. Remove the \"%dx\"." min_count
  | _ -> Ok criterion
;;

let term_of_string s =
  let s = String.strip s in
  let open Or_error.Let_syntax in
  let%bind () = rejects_depth_cap s in
  let min_count, s = peel_min_count s in
  let%bind criterion = criterion s in
  let%map criterion = rejects_prop_count criterion ~min_count in
  Search.Term.create ~min_count criterion
;;

(* Each term is an AND, so the result set only shrinks while the cost of
   building the per-term subqueries grows linearly. Ten covers any real
   question. *)
let max_terms = 10
let is_blank s = String.is_empty (String.strip s)

let terms_of_strings strings =
  let terms = List.filter ~f:(fun s -> not (is_blank s)) strings in
  if List.length terms > max_terms
  then Or_error.errorf "too many search terms (max %d)" max_terms
  else (
    match List.map ~f:term_of_string terms |> Or_error.all with
    | Ok terms -> Ok terms
    | Error err -> Error err)
;;

module Box = struct
  type offer =
    { prompt : string
    ; terms : string list
    }

  type outcome =
    | Parsed of Search.Term.t
    | Resolved of Search.Term.t
    | Rejected of
        { message : string
        ; offer : offer option
        }

  type t =
    { typed : string
    ; outcome : outcome
    }
end

(* An underscore is crawl's feature vocabulary ("altar_trog"), which no item
   name uses, so the feature rejection is the truer answer for it. *)
let bare_word s =
  let s = String.strip s in
  match rejects_depth_cap s with
  | Error _ -> None
  | Ok () ->
    let min_count, rest = peel_min_count s in
    let position, word =
      match position_prefix rest with
      | Some (position, word) -> Some position, word
      | None -> None, rest
    in
    if
      String.is_empty word
      || String.mem word ':'
      || String.mem word '_'
      || String.is_prefix word ~prefix:"name~"
      || List.mem [ "artefact"; "artifact" ] (String.lowercase word) ~equal:String.equal
      || Option.is_some (bare_prefix word)
      || Option.is_some (position_prefix word)
    then None
    else Some (min_count, position, word)
;;

let count_affix min_count = if min_count > 1 then sprintf "%dx " min_count else ""

let position_affix position =
  List.find_map positions ~f:(fun (word, p) ->
    Option.some_if (Search.Criterion.equal_position p position) (word ^ " "))
  |> Option.value ~default:""
;;

let within_one_edit a b =
  let a = String.lowercase a
  and b = String.lowercase b in
  let la = String.length a
  and lb = String.length b in
  if abs (la - lb) > 1
  then false
  else (
    let prefix =
      let rec go i =
        if i < la && i < lb && Char.equal a.[i] b.[i] then go (i + 1) else i
      in
      go 0
    in
    let rest_equal i j = String.equal (String.drop_prefix a i) (String.drop_prefix b j) in
    let transposed =
      la = lb
      && prefix + 1 < la
      && Char.equal a.[prefix] b.[prefix + 1]
      && Char.equal a.[prefix + 1] b.[prefix]
      && rest_equal (prefix + 2) (prefix + 2)
    in
    transposed
    || rest_equal (prefix + 1) (prefix + 1)
    || rest_equal (prefix + 1) prefix
    || rest_equal prefix (prefix + 1))
;;

let item_pairs vocabulary =
  List.filter_map vocabulary ~f:(fun token ->
    if String.is_prefix token ~prefix:"props:" || String.is_prefix token ~prefix:"name~"
    then None
    else (
      match item_type token with
      | Ok item -> Some (token, item)
      | Error _ -> None))
;;

(* A sub type is often typed without the noun crawl puts in front of it:
   "flight" for "ring of flight", "Shatter" for "parchment of Shatter". *)
let names_exactly word (item : Search.Item_type.t) =
  String.Caseless.equal word item.sub_type
  || String.Caseless.equal word item.base_type
  || String.Caseless.equal word (Search.Item_type.to_string item)
  || String.Caseless.is_suffix item.sub_type ~suffix:(" of " ^ word)
;;

(* Offered, never run. A whole word of a sub type is how "broad" and
   "dragon-coil" were typed (field log, 2026-09-10). An edit needs four
   characters, because at three a single edit reaches most of the short sub
   types and the offer stops meaning anything. *)
let names_nearly word (item : Search.Item_type.t) =
  let has_word =
    String.length word >= 3
    && String.Caseless.is_substring
         (" " ^ item.sub_type ^ " ")
         ~substring:(" " ^ word ^ " ")
  in
  let one_edit =
    String.length word >= 4
    && (within_one_edit word item.sub_type
        || within_one_edit word item.base_type
        || within_one_edit word (Search.Item_type.to_string item)
        ||
        match String.substr_index item.sub_type ~pattern:" of " with
        | Some i -> within_one_edit word (String.drop_prefix item.sub_type (i + 4))
        | None -> false)
  in
  has_word || one_edit
;;

let dedup tokens =
  List.fold tokens ~init:(String.Set.empty, []) ~f:(fun (seen, acc) token ->
    if Set.mem seen token then seen, acc else Set.add seen token, token :: acc)
  |> snd
  |> List.rev
;;

(* The three outcomes of ticket 2989672cd6. Only a unique exact reading runs; a
   near miss is offered even when it is the only one, since running a guess is
   the silent wrong answer this replaces. [name~] is offered and never run: its
   cost is the one the vocabulary does not bound. *)
let box ~vocabulary typed =
  let rejected ?offer message = { Box.typed; outcome = Rejected { message; offer } } in
  let offering prompt terms = { Box.prompt; terms } in
  match term_of_string typed with
  | Ok term -> { Box.typed; outcome = Parsed term }
  | Error err ->
    (match bare_word typed with
     | None -> rejected (Error.to_string_hum err)
     | Some (min_count, position, word) ->
       let affix =
         count_affix min_count ^ Option.value_map position ~default:"" ~f:position_affix
       in
       let readings tokens =
         List.map (dedup tokens) ~f:(fun token ->
           let spelled = affix ^ token in
           spelled, term_of_string spelled)
       in
       let valid readings =
         List.filter_map readings ~f:(fun (spelled, result) ->
           Option.map (Result.ok result) ~f:(fun term -> spelled, term))
       in
       let name_offer =
         let spelled = count_affix min_count ^ "name~" ^ word in
         Result.ok (term_of_string spelled)
         |> Option.map ~f:(fun _ -> offering "Search artefact names instead:" [ spelled ])
       in
       (match Option.map (force vocabulary) ~f:item_pairs with
        | None ->
          rejected
            ?offer:name_offer
            (sprintf
               "%S needs a prefix: an item is written base:sub, as in potion:haste."
               word)
        | Some items ->
          let exact =
            List.filter_map items ~f:(fun (token, item) ->
              Option.some_if (names_exactly word item) token)
            @ Option.value_map (Search.Prop.canonical word) ~default:[] ~f:(fun prop ->
              [ "props:" ^ prop ])
            |> readings
          in
          (match valid exact, exact with
           | [ (_, term) ], _ -> { Box.typed; outcome = Resolved term }
           | (_ :: _ :: _ as several), _ ->
             rejected
               ~offer:(offering "Pick one:" (List.map several ~f:fst))
               (sprintf "%S could mean several things." word)
           | [], (_, Error err) :: _ -> rejected (Error.to_string_hum err)
           | [], _ ->
             (match
                List.filter_map items ~f:(fun (token, item) ->
                  Option.some_if (names_nearly word item) token)
                |> readings
                |> valid
              with
              | [] -> rejected ?offer:name_offer (sprintf "Nothing matches %S." word)
              | near ->
                rejected
                  ~offer:(offering "Did you mean:" (List.map near ~f:fst))
                  (sprintf "Nothing matches %S." word)))))
;;

let boxes ~vocabulary strings =
  let strings = List.filter strings ~f:(Fn.non is_blank) in
  if List.length strings > max_terms
  then Or_error.errorf "too many search terms (max %d)" max_terms
  else Ok (List.map strings ~f:(box ~vocabulary))
;;

let terms_of_boxes boxes =
  List.map boxes ~f:(fun (box : Box.t) ->
    match box.outcome with
    | Parsed term | Resolved term -> Some term
    | Rejected _ -> None)
  |> Option.all
;;

(* "<n>:<term>": n counts the boxes holding this same term that come before it,
   not the box's position. Position cannot work -- it is fixed when the button
   renders, while what arrives is whatever the boxes hold at submit time, and the
   reader may have cleared or edited another box in between; the blank box is
   submitted too, so it shifts every later position as well. An occurrence
   ordinal survives all of that, still tells two boxes holding the same term
   apart, and still makes a replay a no-op: htmx pushes the URL that carried the
   drop, so a reload re-applies it against a list the term has already left.

   n leads because a term may contain a colon. *)
let without_dropped ~drop strings =
  let strings = List.filter strings ~f:(fun s -> not (is_blank s)) in
  match Option.map drop ~f:(String.lsplit2 ~on:':') with
  | None | Some None -> strings
  | Some (Some (nth, term)) ->
    (match Int.of_string_opt nth with
     | None -> strings
     | Some nth ->
       let term = String.strip term in
       let seen = ref 0 in
       List.filter strings ~f:(fun s ->
         if String.equal (String.strip s) term
         then (
           let this = !seen in
           incr seen;
           this <> nth)
         else true))
;;

let empty_search_line (search : Search.t) =
  let position = function
    | Search.Criterion.Floor -> ""
    | Search.Criterion.Shop -> "shop "
  in
  let term { Search.Term.criterion; min_count } =
    let count = if min_count > 1 then sprintf "%dx " min_count else "" in
    let body =
      match criterion with
      | Search.Criterion.Item ({ base_type; sub_type }, at) ->
        sprintf "item %s%s:%s" (position at) base_type sub_type
      | Name_like (fragment, at) -> sprintf "name %s%s" (position at) fragment
      | Search.Criterion.Props { base_type; props; position = at } ->
        sprintf
          "props %s%s%s"
          (position at)
          (Option.value_map base_type ~default:"" ~f:(fun b -> b ^ " "))
          (String.concat ~sep:"," props)
      | Feature feature -> "feature " ^ feature
      | Unique unique -> "unique " ^ unique
    in
    String.escaped (count ^ body)
  in
  sprintf
    "search found nothing on %s: %s"
    (Seed_corpus.Query.Version.to_string search.version)
    (String.concat ~sep:"; " (List.map search.terms ~f:term))
;;

let rank request =
  match Dream.query request "rank" with
  | None -> Ok Search.Rank.default
  | Some s ->
    (match Search.Rank.of_string s with
     | Some rank -> Ok rank
     | None -> Or_error.errorf "not a ranking: %S" s)
;;
