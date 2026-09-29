open! Core
module Db = Seed_corpus.Db
module Pool = Seed_corpus.Pool

let with_corpus_file ~f =
  let path = Filename_unix.temp_file "pool" ".db" in
  let db = Db.open_ path in
  Db.exec_script db (In_channel.read_all "../schema.sql");
  Db.close db;
  Fun.protect ~finally:(fun () -> Sys_unix.remove path) (fun () -> f path)
;;

(* Structural, not timing: N threads each check out a connection and block on a
   barrier that only releases once all N are through. If [with_conn] secretly
   serialized checkouts the Nth thread would never reach the barrier, so
   [Thread.join]ing all of them is itself the pass/fail signal. A hang reads as
   the test process hanging, which is what deadlock detection looks like
   here. *)
let%expect_test "with_conn hands out N distinct concurrent connections" =
  with_corpus_file ~f:(fun path ->
    let n = 4 in
    let pool = Pool.create path ~size:n in
    let arrived = ref 0 in
    let mutex = Stdlib.Mutex.create () in
    let condition = Stdlib.Condition.create () in
    let barrier () =
      Stdlib.Mutex.lock mutex;
      incr arrived;
      Stdlib.Condition.broadcast condition;
      while !arrived < n do
        Stdlib.Condition.wait condition mutex
      done;
      Stdlib.Mutex.unlock mutex
    in
    let threads =
      List.init n ~f:(fun _ ->
        Caml_threads.Thread.create
          (fun () -> Pool.with_conn pool ~f:(fun (_ : Db.t) -> barrier ()))
          ())
    in
    List.iter threads ~f:Caml_threads.Thread.join;
    Pool.close pool;
    print_endline "all threads held a connection simultaneously");
  [%expect {| all threads held a connection simultaneously |}]
;;

let%expect_test "with_conn returns the connection to the pool after an exception" =
  with_corpus_file ~f:(fun path ->
    let pool = Pool.create path ~size:1 in
    (match Pool.with_conn pool ~f:(fun (_ : Db.t) -> failwith "boom") with
     | () -> print_endline "did not raise (unexpected)"
     | exception Failure msg -> printf "raised: %s\n" msg);
    (* The one connection in a size-1 pool must be back, or this call hangs. *)
    Pool.with_conn pool ~f:(fun db ->
      print_endline (Db.query db "select count(*) from versions" |> String.concat));
    Pool.close pool);
  [%expect
    {|
    raised: boom
    0
    |}]
;;

let%expect_test "a pooled connection is read-only" =
  with_corpus_file ~f:(fun path ->
    let pool = Pool.create path ~size:1 in
    Pool.with_conn pool ~f:(fun db ->
      match Db.exec_script db "insert into versions (version) values ('0.34.1')" with
      | () -> print_endline "write succeeded (unexpected)"
      | exception Failure msg ->
        printf "write refused: %b\n" (String.is_substring msg ~substring:"readonly"));
    Pool.close pool);
  [%expect {| write refused: true |}]
;;

(* The bounded checkout is what turns a saturated pool into a fast 503 instead
   of a request that waits out the search budget. Structural: hold the only
   connection on another thread, then ask for it with a deadline. *)
let%expect_test
    "checkout past its deadline raises Saturated and the connection comes back"
  =
  with_corpus_file ~f:(fun path ->
    let pool = Pool.create path ~size:1 in
    let holding =
      Caml_threads.Thread.create
        (fun () -> Pool.with_conn pool ~f:(fun (_ : Db.t) -> Caml_unix.sleepf 0.25))
        ()
    in
    Caml_unix.sleepf 0.05;
    (match
       Pool.with_conn pool ~timeout:0.05 ~f:(fun (_ : Db.t) -> print_endline "got one")
     with
     | () -> print_endline "got one (unexpected)"
     | exception Pool.Saturated -> print_endline "saturated");
    Caml_threads.Thread.join holding;
    (* The connection must be back, or this call hangs. *)
    Pool.with_conn pool ~f:(fun (_ : Db.t) -> print_endline "recovered");
    Pool.close pool);
  [%expect
    {|
    saturated
    recovered
    |}]
;;
