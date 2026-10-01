open! Core
module Front_cache = Seed_web.Front_cache

let run = Lwt_main.run
let max_age = Time_ns.Span.of_sec 60.

(* Builds stay pending until the test resolves them, so the cache's view of
   in-flight work is observable. *)
let harness () =
  let clock = ref Time_ns.epoch in
  let builds = Queue.create () in
  let cache =
    Front_cache.create
      ~max_age
      ~now:(fun () -> !clock)
      ~build:(fun key ->
        let promise, resolver = Lwt.wait () in
        Queue.enqueue builds (key, resolver);
        promise)
  in
  let finish result =
    let _key, resolver = Queue.dequeue_exn builds in
    Lwt.wakeup_later resolver result
  in
  let advance seconds = clock := Time_ns.add !clock (Time_ns.Span.of_sec seconds) in
  cache, builds, finish, advance
;;

let show = function
  | Ok value -> value
  | Error err -> "error: " ^ Error.to_string_hum err
;;

let%expect_test "concurrent cold gets share one build" =
  let cache, builds, finish, _ = harness () in
  let first = Front_cache.get cache ~key:"v" in
  let second = Front_cache.get cache ~key:"v" in
  printf "builds started: %d\n" (Queue.length builds);
  finish (Ok "a");
  printf "%s %s\n" (show (run first)) (show (run second));
  [%expect
    {|
    builds started: 1
    a a
    |}]
;;

let%expect_test "a fresh entry is served without building" =
  let cache, builds, finish, advance = harness () in
  let cold = Front_cache.get cache ~key:"v" in
  finish (Ok "a");
  ignore (run cold : string Or_error.t);
  advance 59.;
  printf
    "%s, builds started: %d\n"
    (show (run (Front_cache.get cache ~key:"v")))
    (Queue.length builds);
  [%expect {| a, builds started: 0 |}]
;;

let%expect_test "a stale entry is served while one refresh runs behind it" =
  let cache, builds, finish, advance = harness () in
  let cold = Front_cache.get cache ~key:"v" in
  finish (Ok "a");
  ignore (run cold : string Or_error.t);
  advance 61.;
  let during = List.init 3 ~f:(fun _ -> show (run (Front_cache.get cache ~key:"v"))) in
  printf "%s, builds started: %d\n" (String.concat ~sep:" " during) (Queue.length builds);
  finish (Ok "b");
  run (Lwt.pause ());
  printf "%s\n" (show (run (Front_cache.get cache ~key:"v")));
  [%expect
    {|
    a a a, builds started: 1
    b
    |}]
;;

let%expect_test "a failed cold build is not cached" =
  let cache, builds, finish, _ = harness () in
  let cold = Front_cache.get cache ~key:"v" in
  finish (Or_error.error_string "pool busy");
  printf "%s\n" (show (run cold));
  let retry = Front_cache.get cache ~key:"v" in
  printf "builds started: %d\n" (Queue.length builds);
  finish (Ok "a");
  printf "%s\n" (show (run retry));
  [%expect
    {|
    error: pool busy
    builds started: 1
    a
    |}]
;;

let%expect_test "a failed refresh keeps the old entry and retries on the next get" =
  let cache, builds, finish, advance = harness () in
  let cold = Front_cache.get cache ~key:"v" in
  finish (Ok "a");
  ignore (run cold : string Or_error.t);
  advance 61.;
  ignore (run (Front_cache.get cache ~key:"v") : string Or_error.t);
  finish (Or_error.error_string "pool busy");
  run (Lwt.pause ());
  printf "%s\n" (show (run (Front_cache.get cache ~key:"v")));
  printf "builds started: %d\n" (Queue.length builds);
  [%expect
    {|
    a
    builds started: 1
    |}]
;;

let%expect_test "keys are cached independently" =
  let cache, builds, finish, _ = harness () in
  let v1 = Front_cache.get cache ~key:"v1" in
  let v2 = Front_cache.get cache ~key:"v2" in
  printf "builds started: %d\n" (Queue.length builds);
  finish (Ok "one");
  finish (Ok "two");
  printf "%s %s\n" (show (run v1)) (show (run v2));
  [%expect
    {|
    builds started: 2
    one two
    |}]
;;
