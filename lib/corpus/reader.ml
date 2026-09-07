open! Core

let supported_format = 4
let prefix = "#SEED#"

(* Keys are unique within a record, so a plain assoc lookup is enough. *)
type fields = (string * Sexp.t) list

(* A field is [(key value)]; [cats] is the exception, carrying one value per
   non-empty category, so its values stay un-collapsed for [entries_of_cats]. An
   empty [(cats)] is a level with no catalog entries at all. *)
let fields_of_sexp_list sexps : fields Or_error.t =
  List.map sexps ~f:(function
    | Sexp.List (Sexp.Atom "cats" :: values) -> Ok ("cats", Sexp.List values)
    | Sexp.List [ Sexp.Atom key; value ] -> Ok (key, value)
    | other -> Or_error.errorf "not a (key value) field: %s" (Sexp.to_string other))
  |> Or_error.all
;;

let find (fields : fields) key = List.Assoc.find fields key ~equal:String.equal

(* [nil] is both false and absent, so a field written [nil] and a field left out
   are the same fact. *)
let is_nil = function
  | Sexp.Atom "nil" -> true
  | _ -> false
;;

let string_field fields key =
  match find fields key with
  | None -> Ok None
  | Some s when is_nil s -> Ok None
  | Some (Sexp.Atom v) -> Ok (Some v)
  | Some other ->
    Or_error.errorf "%s: expected a string, got %s" key (Sexp.to_string other)
;;

let required_string_field fields key =
  match string_field fields key with
  | Error _ as e -> e
  | Ok (Some v) -> Ok v
  | Ok None -> Or_error.errorf "missing required field %s" key
;;

let int_field fields key =
  match find fields key with
  | None -> Ok None
  | Some s when is_nil s -> Ok None
  | Some (Sexp.Atom v) ->
    (match Int.of_string_opt v with
     | Some i -> Ok (Some i)
     | None -> Or_error.errorf "%s: expected an integer, got %S" key v)
  | Some other ->
    Or_error.errorf "%s: expected an integer, got %s" key (Sexp.to_string other)
;;

(* Absent is [None] rather than [Some false] -- the schema's columns are
   nullable, and "the serializer said no" is worth distinguishing from "this
   category has no such field". *)
let bool_field fields key =
  match find fields key with
  | None -> Ok None
  | Some (Sexp.Atom "t") -> Ok (Some true)
  | Some (Sexp.Atom "nil") -> Ok (Some false)
  | Some other ->
    Or_error.errorf "%s: expected t or nil, got %s" key (Sexp.to_string other)
;;

(* [spells] is a lua array and serializes as a bare list of atoms; [artprops] is
   a lua table and serializes as a record of [(prop value)] fields. An empty
   collection is emitted as absent rather than [()]. *)
let string_list_field fields key =
  match find fields key with
  | None -> Ok []
  | Some s when is_nil s -> Ok []
  | Some (Sexp.List items) ->
    List.map items ~f:(function
      | Sexp.Atom v -> Ok v
      | other ->
        Or_error.errorf "%s: expected a string, got %s" key (Sexp.to_string other))
    |> Or_error.all
  | Some other -> Or_error.errorf "%s: expected a list, got %s" key (Sexp.to_string other)
;;

let props_field fields key =
  match find fields key with
  | None -> Ok []
  | Some s when is_nil s -> Ok []
  | Some (Sexp.List pairs) ->
    List.map pairs ~f:(function
      | Sexp.List [ Sexp.Atom prop; Sexp.Atom value ] ->
        (match Int.of_string_opt value with
         | Some value -> Ok { Record.Prop.prop; value }
         | None -> Or_error.errorf "%s: %s has non-integer value %S" key prop value)
      | other ->
        Or_error.errorf
          "%s: expected a (prop value) pair, got %s"
          key
          (Sexp.to_string other))
    |> Or_error.all
  | Some other -> Or_error.errorf "%s: expected a list, got %s" key (Sexp.to_string other)
;;

let entry_of_fields ~cat ~carried_by (fields : fields) : Record.Entry.t Or_error.t =
  let open Or_error.Let_syntax in
  (* [kind] is required on the wire but not stored: it was always [cat] minus the
     plural, verified 1:1 across all 15,336,469 rows of the 100k corpus.
     Requiring it still validates the record's shape at the parse boundary. *)
  let%bind (_ : string) = required_string_field fields "kind" in
  (* Features carry [feat] and [text] but never [name]; everything else always
     carries [name]. The schema's [name] is not null and [text] is what a
     feature is actually called, so it stands in -- after which the two are
     identical on every row, so only [name] is stored. *)
  let%bind name =
    match%bind.Or_error string_field fields "name" with
    | Some name -> return name
    | None ->
      (match%bind.Or_error string_field fields "text" with
       | Some text -> return text
       | None -> Or_error.errorf "record has neither name nor text")
  in
  let%bind base_type = string_field fields "base_type" in
  let%bind sub_type = string_field fields "sub_type" in
  let%bind quantity = int_field fields "quantity" in
  let%bind artefact = bool_field fields "artefact" in
  let%bind branded = bool_field fields "branded" in
  let%bind plus = int_field fields "plus" in
  let%bind cost = int_field fields "cost" in
  let%bind ego = string_field fields "ego" in
  let%bind feat = string_field fields "feat" in
  let%bind timeout_turns = int_field fields "timeout_turns" in
  let%bind shop_type = string_field fields "shop_type" in
  let%bind toll_note = string_field fields "toll_note" in
  let%bind unique_mons = bool_field fields "unique" in
  let%bind native = bool_field fields "native" in
  let%bind type_name = string_field fields "type_name" in
  let%bind x = int_field fields "x" in
  let%bind y = int_field fields "y" in
  let%bind spells = string_list_field fields "spells" in
  let%bind props = props_field fields "artprops" in
  return
    { Record.Entry.cat
    ; name
    ; base_type
    ; sub_type
    ; quantity
    ; artefact
    ; branded
    ; plus
    ; cost
    ; ego
    ; feat
    ; timeout_turns
    ; shop_type
    ; toll_note
    ; unique_mons
    ; native
    ; type_name
    ; x
    ; y
    ; carried_by
    ; spells
    ; props
    }
;;

(* A monster's [items] become their own entries tagged with [carried_by], so an
   [entries] row is not 1:1 with a catalog record and counting floor items needs
   [where carried_by is null]. Nesting is one level deep. *)
let rec entries_of_sexp ~cat (sexp : Sexp.t) : Record.Entry.t list Or_error.t =
  let open Or_error.Let_syntax in
  match sexp with
  | Sexp.Atom _ -> Or_error.errorf "expected a record, got an atom"
  | Sexp.List field_sexps ->
    let%bind fields = fields_of_sexp_list field_sexps in
    let%bind entry = entry_of_fields ~cat ~carried_by:None fields in
    let%bind carried =
      match find fields "items" with
      | None -> return []
      | Some s when is_nil s -> return []
      | Some (Sexp.List nested) ->
        List.map nested ~f:(entries_of_sexp ~cat:Record.Cat.Items)
        |> Or_error.all
        |> Or_error.map ~f:List.concat
        |> Or_error.map
             ~f:
               (List.map ~f:(fun (e : Record.Entry.t) ->
                  { e with carried_by = Some entry.name }))
      | Some other ->
        Or_error.errorf "items: expected a list, got %s" (Sexp.to_string other)
    in
    return (entry :: carried)
;;

(* Dropped at ingest rather than at extraction, so re-pruning costs a re-run of
   the fill rather than a schema migration. Both cuts are storage, not
   capability: vaults are level-generation scaffolding, and the `uniq_*` ones
   carry no placement unique_mons does not already cover; runed_clear_door
   records that a vault exists without recording what is in it. *)
let drop_entry (e : Record.Entry.t) =
  match e.cat with
  | Record.Cat.Vaults -> true
  | _ ->
    (match e.feat with
     | Some "runed_clear_door" -> true
     | _ -> false)
;;

(* A parchment's one spell is its own sub_type minus the prefix, so the list is
   dropped here and rebuilt from the name on read. The entry itself stays. *)
let drop_derivable_spells (e : Record.Entry.t) =
  if Book.spells_are_derivable ~sub_type:e.sub_type then { e with spells = [] } else e
;;

(* A Temple's pool-god altars become a bitmask and their rows are dropped: 22
   possible gods bounds the set however large the corpus grows, while the rows
   are 64% of every altar row in it. Gods outside the pool have no bit and keep
   their rows, which is what stops a rare-god query needing bit logic. *)
let extract_temple_altars ~level entries =
  if not (String.equal level "Temple")
  then None, entries
  else (
    let mask, kept =
      List.fold
        entries
        ~init:(Temple.empty, [])
        ~f:(fun (mask, kept) (e : Record.Entry.t) ->
          match e.feat with
          | Some feat when Option.is_some (Temple.of_feat feat) ->
            Temple.add mask feat, kept
          | _ -> mask, e :: kept)
    in
    Some (Temple.to_int mask), List.rev kept)
;;

let entries_of_cats (sexp : Sexp.t) : Record.Entry.t list Or_error.t =
  let open Or_error.Let_syntax in
  match sexp with
  | Sexp.Atom _ -> Or_error.errorf "cats: expected a list, got an atom"
  | Sexp.List cat_sexps ->
    let%bind cats = fields_of_sexp_list cat_sexps in
    List.map cats ~f:(fun (cat_name, payload) ->
      match Record.Cat.of_string cat_name with
      | None -> Or_error.errorf "unknown category %S" cat_name
      | Some cat ->
        (match payload with
         | Sexp.List records ->
           List.map records ~f:(entries_of_sexp ~cat)
           |> Or_error.all
           |> Or_error.map ~f:List.concat
         | Sexp.Atom _ -> Or_error.errorf "%s: expected a list of records" cat_name))
    |> Or_error.all
    |> Or_error.map ~f:List.concat
    |> Or_error.map ~f:(List.filter ~f:(Fn.non drop_entry))
    |> Or_error.map ~f:(List.map ~f:drop_derivable_spells)
;;

let parse_sexp (sexp : Sexp.t) : Record.t Or_error.t =
  let open Or_error.Let_syntax in
  match sexp with
  | Sexp.Atom _ -> Or_error.errorf "expected a record, got an atom"
  | Sexp.List field_sexps ->
    let%bind fields = fields_of_sexp_list field_sexps in
    let%bind format =
      match int_field fields "format" with
      | Error _ as e -> e
      | Ok (Some f) -> Ok f
      | Ok None -> Or_error.errorf "missing required field format"
    in
    let%bind () =
      if format = supported_format
      then Ok ()
      else
        Or_error.errorf
          "unsupported format %d (this reader understands %d)"
          format
          supported_format
    in
    let%bind version = required_string_field fields "version" in
    let%bind seed = required_string_field fields "seed" in
    let%bind level = required_string_field fields "level" in
    let%bind parent_level = string_field fields "parent_level" in
    let%bind gold = int_field fields "gold" in
    (* A portal with no parent degrades silently -- the level simply becomes
       unrankable again -- so format 2 rejects it rather than storing a null that
       looks like ordinary missing data. *)
    let%bind () =
      if Depth.is_portal level && Option.is_none parent_level
      then Or_error.errorf "portal %s has no parent_level" level
      else Ok ()
    in
    let%bind entries =
      match find fields "cats" with
      | None -> return []
      | Some cats -> entries_of_cats cats
    in
    let temple_altars, entries = extract_temple_altars ~level entries in
    return
      { Record.format; version; seed; level; parent_level; temple_altars; gold; entries }
;;

let parse_line line =
  let open Or_error.Let_syntax in
  match String.chop_prefix line ~prefix with
  | None -> Or_error.errorf "line does not start with %s" prefix
  | Some body ->
    let%bind sexp =
      match Parsexp.Single.parse_string body with
      | Ok sexp -> Ok sexp
      | Error e ->
        Or_error.errorf "malformed s-expression: %s" (Parsexp.Parse_error.message e)
    in
    parse_sexp sexp
;;
