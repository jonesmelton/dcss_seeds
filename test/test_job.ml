open! Core
module Job = Seed_corpus.Job
module Query = Seed_corpus.Query

let v = Or_error.ok_exn (Query.Version.of_string "0.34.1")

let job ?started_at ?finished_at ?error ?(attempts = 0) () =
  { Job.seed = "300"
  ; version = v
  ; depth = "Swamp:4"
  ; queued_at = 1000
  ; started_at
  ; finished_at
  ; attempts
  ; error
  }
;;

let show j = print_endline (Job.State.to_string (Job.state j))

let%expect_test "a job's state is derived from its timestamps" =
  show (job ());
  [%expect {| queued |}];
  show (job ~started_at:1010 ());
  [%expect {| running |}];
  show (job ~started_at:1010 ~finished_at:1013 ());
  [%expect {| done |}];
  (* A job past its attempt limit records the error and keeps its claim, so it
     never gets a finished_at. The error is what makes it failed. *)
  show (job ~started_at:1010 ~error:"crawl exited 1" ~attempts:3 ());
  [%expect {| failed |}]
;;

(* started_at is the last refresh, not the start: this measures how long the
   worker has been silent. *)
let%expect_test "a claim goes stale ten minutes after it was last refreshed" =
  let running = job ~started_at:1000 () in
  List.iter [ 1000; 1599; 1600; 1601; 5000 ] ~f:(fun now ->
    printf "%d %b\n" now (Job.is_abandoned running ~now));
  [%expect
    {|
    1000 false
    1599 false
    1600 false
    1601 true
    5000 true
    |}];
  (* A queued job was never claimed, and a finished or failed one is not coming
     back. *)
  List.iter
    [ "queued", job ()
    ; "done", job ~started_at:1000 ~finished_at:1002 ()
    ; "failed", job ~started_at:1000 ~error:"boom" ()
    ]
    ~f:(fun (label, j) -> printf "%s %b\n" label (Job.is_abandoned j ~now:9999));
  [%expect
    {|
    queued false
    done false
    failed false
    |}]
;;

(* The three processes that touch the fill lock derive its path rather than
   configuring it, so they agree unconfigured. tools/corpus-fill does the same
   strip in shell; this is the OCaml half of that agreement. *)
let%expect_test "the fill lock sits beside the database it guards" =
  List.iter [ "/corpus/corpus.db"; "/corpus/corpus"; "rel.db" ] ~f:(fun db_path ->
    printf "%-20s -> %s\n" db_path (Seed_corpus.Deepen.fill_lock_path ~db_path));
  [%expect
    {|
    /corpus/corpus.db    -> /corpus/corpus-write.lock
    /corpus/corpus       -> /corpus/corpus-write.lock
    rel.db               -> rel-write.lock
    |}]
;;
