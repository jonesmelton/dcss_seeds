open! Core
module Depth = Seed_corpus.Depth
module Posting = Seed_corpus.Posting

let posting ~ord ~depth ~count : Posting.t = { ord; depth; count }

let hex s =
  String.to_list s
  |> List.map ~f:(fun c -> sprintf "%02x" (Char.to_int c))
  |> String.concat ~sep:" "
;;

let round_trip postings =
  let encoded = Posting.encode_block postings in
  print_endline (hex encoded);
  match Posting.decode_block encoded with
  | Error e -> print_s [%message "decode failed" (e : Error.t)]
  | Ok decoded ->
    print_s [%sexp (decoded : Posting.t array)];
    if not ([%equal: Posting.t list] postings (Array.to_list decoded))
    then print_endline "ROUND-TRIP MISMATCH"
;;

let raises f =
  match Or_error.try_with f with
  | Ok (_ : string) -> print_endline "did not raise"
  | Error e -> print_s [%sexp (e : Error.t)]
;;

let%expect_test "a hand-written block round-trips" =
  round_trip
    [ posting ~ord:0 ~depth:0 ~count:1
    ; posting ~ord:1 ~depth:Depth.unknown ~count:200
    ; posting ~ord:5000 ~depth:12 ~count:3
    ; posting ~ord:1_000_000 ~depth:Depth.unknown ~count:1
    ];
  [%expect
    {|
    00 01 01 01 00 c8 01 87 27 0d 03 b8 dd 3c 00 01
    (((ord 0) (depth 0) (count 1))
     ((ord 1) (depth 4611686018427387903) (count 200))
     ((ord 5000) (depth 12) (count 3))
     ((ord 1000000) (depth 4611686018427387903) (count 1)))
    |}]
;;

let%expect_test "an ord at the top of the int range round-trips" =
  round_trip [ posting ~ord:Int.max_value ~depth:(Int.max_value - 1) ~count:1 ];
  [%expect
    {|
    ff ff ff ff ff ff ff ff 3f ff ff ff ff ff ff ff ff 3f 01
    (((ord 4611686018427387903) (depth 4611686018427387902) (count 1)))
    |}]
;;

let%expect_test "a full block round-trips" =
  let postings =
    List.init Posting.block_size ~f:(fun i ->
      posting
        ~ord:(i * 3)
        ~depth:(if i % 7 = 0 then Depth.unknown else i % 27)
        ~count:(1 + (i % 500)))
  in
  let encoded = Posting.encode_block postings in
  print_s
    [%message
      "" ~postings:(List.length postings : int) ~bytes:(String.length encoded : int)];
  (match Posting.decode_block encoded with
   | Error e -> print_s [%message "decode failed" (e : Error.t)]
   | Ok decoded ->
     print_s
       [%message
         ""
           ~round_trips:([%equal: Posting.t list] postings (Array.to_list decoded) : bool)
           ~first:(decoded.(0) : Posting.t)
           ~last:(decoded.(Array.length decoded - 1) : Posting.t)]);
  [%expect
    {|
    ((postings 512) (bytes 1909))
    ((round_trips true) (first ((ord 0) (depth 4611686018427387903) (count 1)))
     (last ((ord 1533) (depth 4611686018427387903) (count 12))))
    |}]
;;

(* Truncating at a posting boundary yields a valid shorter block -- the format
   has no length prefix -- so what must never decode is a cut inside one. *)
let%expect_test "a truncated block is an error, not a partial array" =
  let encoded =
    Posting.encode_block
      [ posting ~ord:3 ~depth:2 ~count:1
      ; posting ~ord:9 ~depth:Depth.unknown ~count:400
      ; posting ~ord:70_000 ~depth:5 ~count:2
      ]
  in
  let n = String.length encoded in
  let decodes =
    List.range 0 n
    |> List.filter ~f:(fun i ->
      Or_error.is_ok (Posting.decode_block (String.prefix encoded i)))
  in
  print_s [%message "" ~bytes:(n : int) ~prefixes_that_decode:(decodes : int list)];
  print_s
    [%sexp
      (Posting.decode_block (String.prefix encoded (n - 1)) : Posting.t array Or_error.t)];
  print_s [%sexp (Posting.decode_block (encoded ^ "\x80") : Posting.t array Or_error.t)];
  [%expect
    {|
    ((bytes 12) (prefixes_that_decode (0 3 7)))
    (Error ("truncated varint" (pos 11)))
    (Error ("truncated varint" (pos 13)))
    |}]
;;

let%expect_test "a varint wider than an int is an error" =
  let overflowing = String.of_char_list (List.init 9 ~f:(fun _ -> '\xff') @ [ '\x7f' ]) in
  print_s [%sexp (Posting.decode_block overflowing : Posting.t array Or_error.t)];
  [%expect {| (Error ("varint overflows an int" (pos 8))) |}]
;;

let%expect_test "encode_block refuses unrepresentable blocks" =
  raises (fun () ->
    Posting.encode_block
      [ posting ~ord:5 ~depth:1 ~count:1; posting ~ord:3 ~depth:1 ~count:1 ]);
  raises (fun () ->
    Posting.encode_block
      [ posting ~ord:5 ~depth:1 ~count:1; posting ~ord:5 ~depth:1 ~count:1 ]);
  raises (fun () -> Posting.encode_block [ posting ~ord:1 ~depth:0 ~count:0 ]);
  raises (fun () -> Posting.encode_block [ posting ~ord:(-1) ~depth:0 ~count:1 ]);
  raises (fun () -> Posting.encode_block [ posting ~ord:1 ~depth:(-2) ~count:1 ]);
  [%expect
    {|
    (Failure "Posting.encode_block: ord 3 does not follow 5")
    (Failure "Posting.encode_block: ord 5 does not follow 5")
    (Failure "Posting.encode_block: count 0 at ord 1")
    (Failure "Posting.encode_block: negative ord -1")
    (Failure "Posting.encode_block: negative depth -2 at ord 1")
    |}]
;;

let block =
  [| posting ~ord:0 ~depth:1 ~count:1
   ; posting ~ord:4 ~depth:Depth.unknown ~count:2
   ; posting ~ord:9 ~depth:7 ~count:3
   ; posting ~ord:100 ~depth:0 ~count:4
  |]
;;

let%expect_test "find" =
  List.iter [ 0; 4; 9; 100; -1; 3; 5; 99; 101 ] ~f:(fun ord ->
    print_s [%message "" ~(ord : int) ~found:(Posting.find block ~ord : Posting.t option)]);
  print_s [%sexp (Posting.find [||] ~ord:0 : Posting.t option)];
  [%expect
    {|
    ((ord 0) (found (((ord 0) (depth 1) (count 1)))))
    ((ord 4) (found (((ord 4) (depth 4611686018427387903) (count 2)))))
    ((ord 9) (found (((ord 9) (depth 7) (count 3)))))
    ((ord 100) (found (((ord 100) (depth 0) (count 4)))))
    ((ord -1) (found ()))
    ((ord 3) (found ()))
    ((ord 5) (found ()))
    ((ord 99) (found ()))
    ((ord 101) (found ()))
    ()
    |}]
;;

let%expect_test "lower_bound" =
  List.iter [ -1; 0; 1; 4; 5; 9; 10; 100; 101 ] ~f:(fun ord ->
    print_s [%message "" ~(ord : int) ~lower_bound:(Posting.lower_bound block ~ord : int)]);
  print_s [%sexp (Posting.lower_bound [||] ~ord:7 : int)];
  [%expect
    {|
    ((ord -1) (lower_bound 0))
    ((ord 0) (lower_bound 0))
    ((ord 1) (lower_bound 1))
    ((ord 4) (lower_bound 1))
    ((ord 5) (lower_bound 2))
    ((ord 9) (lower_bound 2))
    ((ord 10) (lower_bound 3))
    ((ord 100) (lower_bound 3))
    ((ord 101) (lower_bound 4))
    0
    |}]
;;

let%expect_test "pseudo-random sorted blocks round-trip" =
  let state = Random.State.make [| 42 |] in
  let random_block () =
    let n = 1 + Random.State.int state Posting.block_size in
    let rec go i ord acc =
      if i = n
      then List.rev acc
      else (
        let ord = if i = 0 then ord else ord + 1 + Random.State.int state 10_000 in
        let depth =
          if Random.State.int state 5 = 0
          then Depth.unknown
          else Random.State.int state 40
        in
        go
          (i + 1)
          ord
          (posting ~ord ~depth ~count:(1 + Random.State.int state 1000) :: acc))
    in
    go 0 (Random.State.int state 1000) []
  in
  let rec run i ~postings ~bytes ~mismatches ~sample =
    if i = 200
    then postings, bytes, mismatches, sample
    else (
      let block = random_block () in
      let encoded = Posting.encode_block block in
      let decoded = Posting.decode_block encoded in
      let matched =
        match decoded with
        | Ok decoded -> [%equal: Posting.t list] block (Array.to_list decoded)
        | Error _ -> false
      in
      let sample =
        match sample, decoded with
        | None, Ok decoded when Array.length decoded > 1 ->
          Some (decoded.(0), decoded.(Array.length decoded - 1))
        | sample, _ -> sample
      in
      run
        (i + 1)
        ~postings:(postings + List.length block)
        ~bytes:(bytes + String.length encoded)
        ~mismatches:(mismatches + if matched then 0 else 1)
        ~sample)
  in
  let postings, bytes, mismatches, sample =
    run 0 ~postings:0 ~bytes:0 ~mismatches:0 ~sample:None
  in
  print_s
    [%message
      ""
        ~blocks:(200 : int)
        (postings : int)
        (bytes : int)
        (mismatches : int)
        ~(sample : (Posting.t * Posting.t) option)];
  [%expect
    {|
    ((blocks 200) (postings 51306) (bytes 249340) (mismatches 0)
     (sample
      ((((ord 320) (depth 16) (count 352)) ((ord 925576) (depth 33) (count 443))))))
    |}]
;;
