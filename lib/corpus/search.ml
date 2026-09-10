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

module Criterion = struct
  type t =
    | Item of Item_type.t
    | Shop_item of Item_type.t
    | Floor_item of Item_type.t
    | Name_like of string
    | Feature of string
    | Artefact
    | Unique of string
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

  let to_string = function
    | Item item -> Item_type.to_string item
    | Shop_item item -> sprintf "%s in a shop" (Item_type.to_string item)
    | Floor_item item -> sprintf "%s on the floor" (Item_type.to_string item)
    | Name_like s -> sprintf "named like %S" s
    | Feature feat -> feature_to_string feat
    | Artefact -> "an artefact"
    | Unique name -> name
  ;;

  (* The noun for counting several of what this criterion matches. [Artefact] is
     the only one with a plural that reads: an item type's plural depends on the
     stack name crawl rendered, and a name fragment names no category at all. *)
  let plural_noun = function
    | Artefact -> Some "artefacts"
    | Item _ | Shop_item _ | Floor_item _ | Name_like _ | Feature _ | Unique _ -> None
  ;;

  (* Constantly true since interning: a substring match runs over the string
     dictionary rather than over entries, and since the trigram index, as a
     lookup there rather than a scan. Kept, with [partition_terms], because a
     future criterion no index serves would need exactly this. *)
  let is_indexed = function
    | Name_like _ | Item _ | Shop_item _ | Floor_item _ | Feature _ | Artefact | Unique _
      -> true
  ;;

  (* Three characters is a hard precondition, not a tuning knob: the substring
     search is served by a trigram index, and trigram cannot answer a fragment
     shorter than a trigram -- fts5 silently falls back to scanning the whole
     dictionary below three. It happens to be the same threshold the scan-era
     heuristic wanted, and it still admits real unrand fragments (["cer"],
     ["wyr"]). *)
  let min_name_like_length = 3

  (* [Name_like] is the sole survivor, and the trigram index did not change
     that. It made selective fragments fast (7.02s -> 0.21s) but a common one
     slower: [name~dragon] matches 33,523 names and costs 9.9s at 1.3M, because
     the cost is the candidate set the dictionary hands on, not the lookup.
     Every other criterion is a single covering seek. *)
  let is_cheap = function
    | Name_like s -> String.length s >= min_name_like_length
    | Item _ | Shop_item _ | Floor_item _ | Feature _ | Artefact | Unique _ -> true
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
      | Criterion.Item { base_type; sub_type } -> sprintf "%s:%s" base_type sub_type
      | Criterion.Shop_item { base_type; sub_type } ->
        sprintf "shop %s:%s" base_type sub_type
      | Criterion.Floor_item { base_type; sub_type } ->
        sprintf "floor %s:%s" base_type sub_type
      | Criterion.Name_like fragment -> sprintf "name~%s" fragment
      | Criterion.Feature feat -> feat
      | Criterion.Artefact -> "artefact"
      | Criterion.Unique name -> sprintf "unique:%s" name
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
