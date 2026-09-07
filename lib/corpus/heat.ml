open! Core

module Band = struct
  type t =
    | Cold
    | Warm
    | Hot
    | Blazing
  [@@deriving compare, equal, sexp_of]

  let to_string = function
    | Cold -> "cold"
    | Warm -> "warm"
    | Hot -> "hot"
    | Blazing -> "blazing"
  ;;

  let to_int = function
    | Cold -> 0
    | Warm -> 1
    | Hot -> 2
    | Blazing -> 3
  ;;

  let of_int = function
    | 0 -> Some Cold
    | 1 -> Some Warm
    | 2 -> Some Hot
    | 3 -> Some Blazing
    | _ -> None
  ;;
end

type observation =
  { base_type : string
  ; sub_type : string
  ; count : int
  ; shallowest : Depth.t
  }

let book_surprise_key = "book", "#early-spells"
let book_weight = 20
let decay = 0.6

let depth_util ~cap ~d =
  let cap = Float.of_int cap in
  let d = Float.of_int d in
  0.5 +. (0.5 *. ((cap -. d +. 1.) /. cap))
;;

let contrib ~surprise ~n ~weight ~base_type ~sub_type ~count ~depth_util =
  let p = surprise ~base_type ~sub_type ~count in
  let floor = 1. /. Float.of_int n in
  let tail = Float.max p floor in
  Float.of_int weight *. -.Float.log10 tail *. depth_util
;;

let score ~surprise ~n ~cap ~early_spells observations =
  let item_contribs =
    List.filter_map observations ~f:(fun o ->
      match Weight.find ~base_type:o.base_type ~sub_type:o.sub_type with
      | None -> None
      | Some { weight; tier = _ } ->
        let depth_util = depth_util ~cap ~d:o.shallowest in
        Some
          (contrib
             ~surprise
             ~n
             ~weight
             ~base_type:o.base_type
             ~sub_type:o.sub_type
             ~count:o.count
             ~depth_util))
  in
  let book_base_type, book_sub_type = book_surprise_key in
  let book_contrib =
    contrib
      ~surprise
      ~n
      ~weight:book_weight
      ~base_type:book_base_type
      ~sub_type:book_sub_type
      ~count:early_spells
      ~depth_util:1.0
  in
  let contribs = book_contrib :: item_contribs in
  let sorted = List.sort contribs ~compare:(fun a b -> Float.compare b a) in
  List.foldi sorted ~init:0. ~f:(fun i acc c -> acc +. (c *. (decay **. Float.of_int i)))
;;
