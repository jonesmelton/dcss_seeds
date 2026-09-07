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

(* A table rather than nested matches. No prefix is a prefix of another, so the
   order does not matter. *)
let prefixed =
  [ ( "shop "
    , fun rest -> Or_error.map (item_type rest) ~f:(fun i -> Search.Criterion.Shop_item i)
    )
  ; ( "floor "
    , fun rest ->
        Or_error.map (item_type rest) ~f:(fun i -> Search.Criterion.Floor_item i) )
  ; ( "unique:"
    , fun rest ->
        if String.is_empty rest
        then Or_error.errorf "unique: needs a monster name"
        else Ok (Search.Criterion.Unique rest) )
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
      (* Search no longer supports altar features at all -- pool gods, the four
       vault-placed gods, and altar_ecumenical alike. Rejected here rather than
       left to match nothing: a term the reader typed that silently finds
       nothing reads as "no such seeds" rather than "not a supported search". *)
    else if String.is_prefix s ~prefix:"altar"
    then Or_error.errorf "altar features are no longer supported in search: %S" s
    else Ok (Search.Criterion.Feature s)
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

let terms_of_strings strings =
  let terms = List.filter ~f:(fun s -> not (String.is_empty (String.strip s))) strings in
  if List.length terms > max_terms
  then Or_error.errorf "too many search terms (max %d)" max_terms
  else (
    match List.map ~f:term_of_string terms |> Or_error.all with
    | Ok terms -> Ok terms
    | Error err -> Error err)
;;

let search ~version request =
  let open Or_error.Let_syntax in
  let%bind page = page request in
  let%map terms = terms_of_strings (Dream.queries request "has") in
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
