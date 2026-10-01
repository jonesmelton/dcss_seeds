open! Core
module Gate = Seed_web.Gate

let state = function
  | `Admitted -> "admitted"
  | `Saturated -> "saturated"
;;

let sleeping p = phys_equal (Lwt.state p) Lwt.Sleep

(* [Lwt_main.run] directly, because the gate is Lwt-native: it queues on a
   condition variable and the deadline is a [Lwt_unix.sleep], so there is no
   synchronous entry point to call. *)
let run = Lwt_main.run

let%expect_test "a freed permit goes to a waiter, not back to the pool" =
  let gate = Gate.create ~size:1 in
  run
    (let open Lwt.Syntax in
     let* first = Gate.acquire gate ~timeout:1. in
     printf "first: %s\n" (state first);
     let waiter = Gate.acquire gate ~timeout:5. in
     (* Registered synchronously, before any yield: a release in the same tick
        as the request must not miss it. *)
     printf "waiting: %b\n" (sleeping waiter);
     Gate.release gate;
     let* second = waiter in
     printf "second: %s\n" (state second);
     Lwt.return_unit);
  [%expect
    {|
    first: admitted
    waiting: true
    second: admitted
    |}]
;;

let%expect_test "a waiter past its deadline answers Saturated and leaves the queue" =
  let gate = Gate.create ~size:1 in
  run
    (let open Lwt.Syntax in
     let* _held = Gate.acquire gate ~timeout:1. in
     let* late = Gate.acquire gate ~timeout:0.05 in
     printf "late: %s\n" (state late);
     (* The permit the release hands out must reach the pool, not the waiter
        that gave up on it. *)
     Gate.release gate;
     let* next = Gate.acquire gate ~timeout:1. in
     printf "next: %s\n" (state next);
     Lwt.return_unit);
  [%expect
    {|
    late: saturated
    next: admitted
    |}]
;;

(* The property the whole design turns on, and the one that would silently
   regress: [answer_search] races the run against [SEED_SEARCH_TIMEOUT] with
   [Lwt.pick], which cancels the loser. The work keeps running on its worker
   thread holding a pool connection, so the permit has to stay spent until the
   work finishes -- releasing it on cancellation would readmit a search into a
   pool that is still full, which is the queue this gate exists to bound. *)
let%expect_test "an abandoned run keeps its permit until its work finishes" =
  let gate = Gate.create ~size:1 in
  run
    (let open Lwt.Syntax in
     let work, finish = Lwt.wait () in
     let* winner =
       Lwt.pick
         [ Lwt.map
             (function
               | `Admitted v -> sprintf "work finished: %d" v
               | `Saturated -> "saturated")
             (Gate.with_permit gate ~timeout:1. ~f:(fun () -> work))
         ; Lwt.map (fun () -> "timed out first") (Lwt_unix.sleep 0.01)
         ]
     in
     printf "%s\n" winner;
     let* during = Gate.acquire gate ~timeout:0.05 in
     printf "while running: %s\n" (state during);
     Lwt.wakeup_later finish 7;
     let* after = Gate.acquire gate ~timeout:1. in
     printf "after finishing: %s\n" (state after);
     Lwt.return_unit);
  [%expect
    {|
    timed out first
    while running: saturated
    after finishing: admitted
    |}]
;;

let%expect_test "work that raises returns its permit" =
  let gate = Gate.create ~size:1 in
  run
    (let open Lwt.Syntax in
     let* outcome =
       Lwt.try_bind
         (fun () ->
            Gate.with_permit gate ~timeout:1. ~f:(fun () -> Lwt.fail (Failure "boom")))
         (fun _ -> Lwt.return "did not raise (unexpected)")
         (fun exn -> Lwt.return (Exn.to_string exn))
     in
     printf "raised: %s\n" outcome;
     let* next = Gate.acquire gate ~timeout:1. in
     printf "next: %s\n" (state next);
     Lwt.return_unit);
  [%expect
    {|
    raised: (Failure boom)
    next: admitted
    |}]
;;

let%expect_test "two waiters are served one per release" =
  let gate = Gate.create ~size:1 in
  run
    (let open Lwt.Syntax in
     let* _held = Gate.acquire gate ~timeout:1. in
     let a = Gate.acquire gate ~timeout:5. in
     let b = Gate.acquire gate ~timeout:5. in
     Gate.release gate;
     let* a = a in
     printf "a: %s\n" (state a);
     printf "b still waiting: %b\n" (sleeping b);
     Gate.release gate;
     let* b = b in
     printf "b: %s\n" (state b);
     Lwt.return_unit);
  [%expect
    {|
    a: admitted
    b still waiting: true
    b: admitted
    |}]
;;
