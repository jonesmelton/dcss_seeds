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

(* Wall clock on the search path, not a query cancellation: sqlite3-ocaml 5.4.1
   binds neither [sqlite3_interrupt] nor a progress handler, so an expired
   search still runs to completion on its worker and holds its pool connection.
   This bounds what a client waits for, not what a query occupies. *)
let search_timeout = ref 30.

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
  "search covers items, not monsters. A seed page lists the uniques on each level."
;;

(* A table rather than nested matches. No prefix is a prefix of another, so the
   order does not matter. *)
let prefixed =
  [ ( "shop "
    , fun rest -> Or_error.map (item_type rest) ~f:(fun i -> Search.Criterion.Shop_item i)
    )
  ; ( "floor "
    , fun rest ->
        Or_error.map (item_type rest) ~f:(fun i -> Search.Criterion.Floor_item i) )
    (* Kept as a prefix so the message names what happened. Dropped from search
       2026-09-10: the useful question about an early unique is negative ("a
       seed without Sigmund"), which needs an operator search does not have, and
       the forward form answers the opposite. [Search.Criterion.Unique] still
       exists and still drives the seed page -- this is a parse-boundary
       decision, not a corpus one. *)
  ; ("unique:", fun _ -> Or_error.errorf "%s" not_an_item_monster)
  ; ( "name~"
    , fun rest ->
        if String.is_empty rest
        then Or_error.errorf "name~ needs something to match"
        else if String.length rest < Search.Criterion.min_name_like_length
        then
          Or_error.errorf
            "name~ needs at least %d characters (got %d)"
            Search.Criterion.min_name_like_length
            (String.length rest)
        else Ok (Search.Criterion.Name_like rest) )
  ]
;;

(* A prefix with nothing after it is a typo, and it must not fall through to the
   feature branch: the term arrives stripped, so a bare "floor" would parse as a
   *feature named "floor"* -- a search that runs, matches nothing, and tells the
   reader their build has no such thing.

   Only the space-separated prefixes. The punctuated ones ("unique:", "name~")
   cannot be mistaken for a feature name and carry their own messages. *)
let bare_prefix s =
  List.find_map prefixed ~f:(fun (prefix, _) ->
    match String.chop_suffix prefix ~suffix:" " with
    | Some bare when String.equal s bare ->
      Some
        (Or_error.errorf
           "%S needs an item after it, as in \"%spotion:haste\""
           bare
           prefix)
    | _ -> None)
;;

let criterion s =
  match
    match bare_prefix s with
    | Some err -> Some err
    | None ->
      List.find_map prefixed ~f:(fun (prefix, build) ->
        Option.map (String.chop_prefix s ~prefix) ~f:(fun rest ->
          build (String.strip rest)))
  with
  | Some result -> result
  | None ->
    if String.equal s "artefact"
    then Ok Search.Criterion.Artefact
    else if String.mem s ':'
    then Or_error.map (item_type s) ~f:(fun item -> Search.Criterion.Item item)
    else if String.is_empty s
    then
      Or_error.errorf "empty search term"
      (* Features are not searchable. Altars went first; the rest followed
         2026-09-10, when the unselective ones ([enter_temple] stands on every
         seed, [enter_shop] on 2.1x as many rows) turned out to be what made a
         multi-term intersection slow. Rejected rather than left to match
         nothing: a term that runs and finds nothing reads as "no such seeds"
         rather than "not a supported search". *)
    else Or_error.errorf "search covers items, not features: %S" s
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
      "depth caps are no longer supported: drop the \" by ...\" from %S. Results cover \
       the whole depth each seed was catalogued to."
      s
  else Ok ()
;;

let term_of_string s =
  let s = String.strip s in
  let open Or_error.Let_syntax in
  let%bind () = rejects_depth_cap s in
  let min_count, s = peel_min_count s in
  Or_error.map (criterion s) ~f:(Search.Term.create ~min_count)
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

let search ~version request =
  let open Or_error.Let_syntax in
  let%bind page = page request in
  let%map terms =
    Dream.queries request "has"
    |> without_dropped ~drop:(Dream.query request "drop")
    |> terms_of_strings
  in
  Search.create ~version ~terms ~page ()
;;

let rank request =
  match Dream.query request "rank" with
  | None -> Ok Search.Rank.default
  | Some s ->
    (match Search.Rank.of_string s with
     | Some rank -> Ok rank
     | None -> Or_error.errorf "not a ranking: %S" s)
;;
