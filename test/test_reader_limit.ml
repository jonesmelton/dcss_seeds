open! Core
module Limit = Seed_web.Reader_limit

let show = function
  | `Ok -> print_endline "ok"
  | `Ip_cap -> print_endline "ip cap"
  | `Session_cap -> print_endline "session cap"
;;

let%expect_test "a reader is capped per session and per address, and a new day resets" =
  let limit = Limit.create ~per_ip:3 ~per_session:2 in
  let try_ ~day ~ip ~session =
    let verdict = Limit.check limit ~day ~ip ~session in
    (match verdict with
     | `Ok -> Limit.record limit ~day ~ip ~session
     | `Ip_cap | `Session_cap -> ());
    show verdict
  in
  try_ ~day:1 ~ip:"a" ~session:"s1";
  try_ ~day:1 ~ip:"a" ~session:"s1";
  try_ ~day:1 ~ip:"a" ~session:"s1";
  (* A fresh session is one GET away, which is why the address cap exists. *)
  try_ ~day:1 ~ip:"a" ~session:"s2";
  try_ ~day:1 ~ip:"a" ~session:"s3";
  try_ ~day:1 ~ip:"b" ~session:"s3";
  try_ ~day:2 ~ip:"a" ~session:"s1";
  [%expect
    {|
    ok
    ok
    session cap
    ok
    ip cap
    ok
    ok
    |}]
;;

let%expect_test "the client address is the last hop the proxy forwarded" =
  let show headers peer =
    print_endline (Limit.client_address ~forwarded_for:headers ~peer)
  in
  show None "127.0.0.1:5555";
  show (Some "203.0.113.9") "127.0.0.1:5555";
  show (Some "10.0.0.1, 203.0.113.9") "127.0.0.1:5555";
  show (Some " ") "127.0.0.1:5555";
  [%expect
    {|
    127.0.0.1
    203.0.113.9
    203.0.113.9
    127.0.0.1
    |}]
;;
