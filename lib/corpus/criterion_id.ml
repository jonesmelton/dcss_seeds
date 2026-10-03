open! Core

module Kind = struct
  type t =
    | Floor_item
    | Shop_item
    | Floor_prop
    | Shop_prop
    | Floor_brand
    | Shop_brand
  [@@deriving compare, equal, enumerate, sexp_of]

  let to_int = function
    | Floor_item -> 0
    | Shop_item -> 1
    | Floor_prop -> 3
    | Shop_prop -> 4
    | Floor_brand -> 5
    | Shop_brand -> 6
  ;;

  let of_int = function
    | 0 -> Some Floor_item
    | 1 -> Some Shop_item
    | 3 -> Some Floor_prop
    | 4 -> Some Shop_prop
    | 5 -> Some Floor_brand
    | 6 -> Some Shop_brand
    | _ -> None
  ;;

  (* 2 was [Artefact], removed 2026-10. The integer is retired rather than
     reused: [search_criteria.kind] is on-disk format. *)
  let () = assert (Option.is_none (of_int 2))
end

type key =
  { kind : Kind.t
  ; a : string option
  ; b : string option
  }
[@@deriving compare, equal, sexp_of]

include Comparable.Make_plain (struct
    type t = key

    let compare = compare_key
    let sexp_of_t = sexp_of_key
  end)

type t =
  | Exact of key list
  | Narrowing of key list
  | Unindexed

let of_criterion ~version (criterion : Search.Criterion.t) : t =
  match criterion with
  | Search.Criterion.Item ({ base_type; sub_type }, position) ->
    let kind : Kind.t =
      match (position : Search.Criterion.position) with
      | Search.Criterion.Floor -> Floor_item
      | Search.Criterion.Shop -> Shop_item
    in
    Exact [ { kind; a = Some base_type; b = Some sub_type } ]
  | Search.Criterion.Name_like _ -> Unindexed
  | Search.Criterion.Feature _ -> Unindexed
  | Search.Criterion.Unique _ -> Unindexed
  | Search.Criterion.Props { base_type; props; position } ->
    let kind : Kind.t =
      match (position : Search.Criterion.position) with
      | Search.Criterion.Floor -> Floor_prop
      | Search.Criterion.Shop -> Shop_prop
    in
    (match List.map props ~f:(fun p -> { kind; a = base_type; b = Some p }) with
     | [] -> Unindexed
     | [ key ] -> Exact [ key ]
     | keys -> Narrowing keys)
  (* The brand and the item are two lists, so seed-granular membership can
     only narrow -- "a quick blade" and "a distortion weapon" may be
     different weapons -- and [verify] re-checks the pair on one entry, the
     [Props] mechanism unchanged. The key's [b] is the build's own code
     spelling ([Search.Brand.code]), because the catalog's rows are keyed by
     the code the corpus stores; resolving through a spelling the build never
     used would find no row and answer "no seeds" over a corpus that holds
     them. An unknown word has no code and narrows nothing. *)
  | Search.Criterion.Brand { base_type; sub_type; word; position } ->
    let (kind : Kind.t), (brand_kind : Kind.t) =
      match (position : Search.Criterion.position) with
      | Search.Criterion.Floor -> Floor_item, Floor_brand
      | Search.Criterion.Shop -> Shop_item, Shop_brand
    in
    (match Search.Brand.code ~base_type ~version word with
     | None -> Unindexed
     | Some code ->
       let brand_key = { kind = brand_kind; a = Some base_type; b = Some code } in
       (match sub_type with
        | None -> Exact [ brand_key ]
        | Some sub_type ->
          Narrowing [ { kind; a = Some base_type; b = Some sub_type }; brand_key ]))
;;

let keys = function
  | Exact keys -> keys
  | Narrowing keys -> keys
  | Unindexed -> []
;;
