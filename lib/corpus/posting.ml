open! Core

type t =
  { ord : int
  ; depth : Depth.t
  ; count : int
  }
[@@deriving compare, equal, sexp_of]

let block_size = 512

let add_varint buf n =
  let rec go n =
    if n land lnot 0x7f = 0
    then Buffer.add_char buf (Char.of_int_exn n)
    else (
      Buffer.add_char buf (Char.of_int_exn (0x80 lor (n land 0x7f)));
      go (n lsr 7))
  in
  go n
;;

let encode_block postings =
  let buf = Buffer.create (block_size * 3) in
  let previous = ref None in
  List.iter postings ~f:(fun { ord; depth; count } ->
    if ord < 0 then failwithf "Posting.encode_block: negative ord %d" ord ();
    if count < 1 then failwithf "Posting.encode_block: count %d at ord %d" count ord ();
    if (not (Depth.equal depth Depth.unknown)) && depth < 0
    then failwithf "Posting.encode_block: negative depth %d at ord %d" depth ord ();
    let delta =
      match !previous with
      | None -> ord
      | Some previous when ord > previous -> ord - previous
      | Some previous ->
        failwithf "Posting.encode_block: ord %d does not follow %d" ord previous ()
    in
    previous := Some ord;
    add_varint buf delta;
    add_varint buf (if Depth.equal depth Depth.unknown then 0 else depth + 1);
    add_varint buf count);
  Buffer.contents buf
;;

let read_varint block ~pos =
  let len = String.length block in
  let rec go pos acc shift =
    if pos >= len
    then Or_error.error_s [%message "truncated varint" (pos : int)]
    else (
      let byte = Char.to_int (String.get block pos) in
      let payload = byte land 0x7f in
      if shift >= Int.num_bits
      then Or_error.error_s [%message "varint overflows an int" (pos : int)]
      else (
        let contribution = payload lsl shift in
        if contribution lsr shift <> payload || contribution < 0
        then Or_error.error_s [%message "varint overflows an int" (pos : int)]
        else (
          let acc = acc lor contribution in
          if byte land 0x80 = 0 then Ok (acc, pos + 1) else go (pos + 1) acc (shift + 7))))
  in
  go pos 0 0
;;

(* A decoded block is consumed only by binary search, so a block that decodes
   non-monotone answers wrong rather than loudly: the ordering the encoder
   refuses to write is checked again on the way back in. *)
let decode_block block =
  let open Or_error.Let_syntax in
  let len = String.length block in
  let rec go pos previous acc =
    if pos >= len
    then Ok (Array.of_list_rev acc)
    else (
      let%bind delta, pos = read_varint block ~pos in
      let%bind depth_code, pos = read_varint block ~pos in
      let%bind count, pos = read_varint block ~pos in
      let%bind ord =
        match previous with
        | None -> Ok delta
        | Some previous ->
          if delta < 1 || previous + delta < 0
          then
            Or_error.error_s
              [%message "delta does not advance" (previous : int) (delta : int)]
          else Ok (previous + delta)
      in
      if count < 1
      then Or_error.error_s [%message "count below one" (ord : int) (count : int)]
      else (
        let depth = if depth_code = 0 then Depth.unknown else depth_code - 1 in
        go pos (Some ord) ({ ord; depth; count } :: acc)))
  in
  go 0 None []
;;

let compare_to_ord (posting : t) ord = Int.compare posting.ord ord

let find block ~ord =
  Array.binary_search block ~compare:compare_to_ord `First_equal_to ord
  |> Option.map ~f:(Array.get block)
;;

let lower_bound block ~ord =
  Array.binary_search block ~compare:compare_to_ord `First_greater_than_or_equal_to ord
  |> Option.value ~default:(Array.length block)
;;
