open! Core

let show s =
  match Seed_corpus.Query.Seed.of_string s with
  | Ok seed -> printf "%-24s ok %s\n" s seed
  | Error err -> printf "%-24s %s\n" s (Error.to_string_hum err)
;;

let%expect_test "a seed is a canonical unsigned 64-bit decimal" =
  List.iter
    ~f:show
    [ "7"
    ; "1234567890"
    ; "18446744073709551615"
    ; "18446744073709551616"
    ; "99999999999999999999"
    ; "100000000000000000000"
    ; "0"
    ; "007"
    ; ""
    ; "-5"
    ; "12a"
    ; " 12"
    ];
  [%expect
    {|
    7                        ok 7
    1234567890               ok 1234567890
    18446744073709551615     ok 18446744073709551615
    18446744073709551616     a seed is at most 18446744073709551615
    99999999999999999999     a seed is at most 18446744073709551615
    100000000000000000000    a seed is at most 18446744073709551615
    0                        seed 0 names no game
    007                      a seed is written without leading zeros
                             a seed is a number
    -5                       a seed is a number
    12a                      a seed is a number
     12                      a seed is a number
    |}]
;;
