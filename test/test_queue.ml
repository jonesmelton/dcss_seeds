open! Core
module Db = Seed_corpus.Db
module Job = Seed_corpus.Job
module Query = Seed_corpus.Query

let v = Or_error.ok_exn (Query.Version.of_string "0.34.1")
let other = Or_error.ok_exn (Query.Version.of_string "0.33.1")

let corpus () =
  let path = Filename_unix.temp_file "queue" ".db" in
  let db = Db.open_ path in
  Db.exec_script db (In_channel.read_all "../schema.sql");
  path, db
;;

let cleanup path dbs =
  List.iter dbs ~f:Db.close;
  Sys_unix.remove path
;;

let serving db ~now versions =
  Or_error.ok_exn (Db.heartbeat db ~generator_id:"g1" ~versions ~now)
;;

let enqueue db ~seed ?(cap = 10) ?(now = 1000) version =
  Db.enqueue db ~version ~seed ~cap ~servable_since:(now - 60) |> Or_error.ok_exn
;;

let show_outcome = function
  | `Queued -> print_endline "queued"
  | `Already_queued (j : Job.t) ->
    printf "already queued (%s)\n" (Job.State.to_string (Job.state j))
  | `Queue_full -> print_endline "queue full"
  | `No_generator -> print_endline "no generator"
  | `Filling -> print_endline "filling"
  | `Failed err -> printf "failed (%s)\n" (Error.to_string_hum err)
;;

let state db ~seed version =
  match Or_error.ok_exn (Db.job_for_seed db ~version ~seed) with
  | None -> "absent"
  | Some j -> Job.State.to_string (Job.state j)
;;

let attempts db ~seed version =
  match Or_error.ok_exn (Db.job_for_seed db ~version ~seed) with
  | None -> -1
  | Some (j : Job.t) -> j.attempts
;;

let claim_of db ~seed version =
  match Or_error.ok_exn (Db.job_for_seed db ~version ~seed) with
  | None -> None
  | Some (j : Job.t) -> j.started_at
;;

let show_hold = function
  | `Held -> print_endline "held"
  | `Lost -> print_endline "lost"
;;

let show_record = function
  | `Recorded -> print_endline "recorded"
  | `Lost -> print_endline "lost"
;;

let finish db ~seed ~started_at ~now ?(error = None) version =
  Or_error.ok_exn (Db.finish_job db ~version ~seed ~started_at ~now ~error)
;;

let%expect_test "a request is refused unless some generator serves the version" =
  let path, db = corpus () in
  (* The version exists in the corpus, which says it was ingested, not that
     anyone can still build it. *)
  show_outcome (enqueue db ~seed:"300" v);
  [%expect {| no generator |}];
  serving db ~now:1000 [ v ];
  show_outcome (enqueue db ~seed:"300" ~now:1000 v);
  [%expect {| queued |}];
  show_outcome (enqueue db ~seed:"300" ~now:1000 other);
  [%expect {| no generator |}];
  show_outcome (enqueue db ~seed:"301" ~now:2000 v);
  [%expect {| no generator |}];
  cleanup path [ db ]
;;

let%expect_test "a double submission returns the job rather than a second one" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  show_outcome (enqueue db ~seed:"300" ~now:1000 v);
  [%expect {| queued |}];
  show_outcome (enqueue db ~seed:"300" ~now:1000 v);
  [%expect {| already queued (queued) |}];
  printf "%d outstanding\n" (Or_error.ok_exn (Db.outstanding_jobs db));
  [%expect {| 1 outstanding |}];
  cleanup path [ db ]
;;

let%expect_test "the cap refuses rather than dropping, and counts only live jobs" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  List.iter [ "300"; "301" ] ~f:(fun seed ->
    show_outcome (enqueue db ~seed ~cap:2 ~now:1000 v));
  [%expect
    {|
    queued
    queued
    |}];
  show_outcome (enqueue db ~seed:"302" ~cap:2 ~now:1000 v);
  [%expect {| queue full |}];
  (* The cap counts what is outstanding, not what has ever been asked for. An
     outcome is recorded against a claim, so the job is claimed first. *)
  ignore (Or_error.ok_exn (Db.claim_job db ~version:v ~now:1004) : Job.t option);
  ignore (finish db ~seed:"300" ~started_at:1004 ~now:1005 v : _);
  show_outcome (enqueue db ~seed:"302" ~cap:2 ~now:1000 v);
  [%expect {| queued |}];
  cleanup path [ db ]
;;

let%expect_test "the oldest job is claimed first, and only for a served version" =
  let path, db = corpus () in
  serving db ~now:1000 [ v; other ];
  ignore (enqueue db ~seed:"300" ~now:1000 v : _);
  ignore (enqueue db ~seed:"301" ~now:1000 v : _);
  ignore (enqueue db ~seed:"400" ~now:1000 other : _);
  let claim version ~now =
    match Or_error.ok_exn (Db.claim_job db ~version ~now) with
    | None -> print_endline "nothing to claim"
    | Some (j : Job.t) -> printf "claimed %s @ %s\n" j.seed j.depth
  in
  claim v ~now:1001;
  [%expect {| claimed 300 @ Swamp:4 |}];
  claim v ~now:1002;
  [%expect {| claimed 301 @ Swamp:4 |}];
  claim v ~now:1003;
  [%expect {| nothing to claim |}];
  claim other ~now:1004;
  [%expect {| claimed 400 @ Swamp:4 |}];
  cleanup path [ db ]
;;

(* Under `begin immediate` two generators serialize, so the loser's update
   matches no row and it reports nothing to claim rather than proceeding on a
   job it does not hold. Two connections, because that is what two generators
   are. *)
let%expect_test "two generators cannot claim the same job" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  ignore (enqueue db ~seed:"300" ~now:1000 v : _);
  let g2 = Db.open_ path in
  let claim db label =
    match Or_error.ok_exn (Db.claim_job db ~version:v ~now:1001) with
    | None -> printf "%s: nothing\n" label
    | Some (j : Job.t) -> printf "%s: claimed %s\n" label j.seed
  in
  claim db "g1";
  claim g2 "g2";
  [%expect
    {|
    g1: claimed 300
    g2: nothing
    |}];
  cleanup path [ db; g2 ]
;;

(* started_at is a liveness signal, not a start time, so a job slower than the
   window survives as long as its worker keeps saying so. Seed 301's worker
   stops refreshing and is the one reclaimed. *)
let%expect_test "a refreshed claim is not reclaimed; one whose refresh stops is" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  ignore (enqueue db ~seed:"300" ~now:1000 v : _);
  ignore (enqueue db ~seed:"301" ~now:1000 v : _);
  ignore (Or_error.ok_exn (Db.claim_job db ~version:v ~now:1000) : Job.t option);
  ignore (Or_error.ok_exn (Db.claim_job db ~version:v ~now:1000) : Job.t option);
  let refresh ~started_at ~now =
    show_hold
      (Or_error.ok_exn (Db.refresh_claim db ~version:v ~seed:"300" ~started_at ~now))
  in
  refresh ~started_at:1000 ~now:1300;
  refresh ~started_at:1300 ~now:1600;
  [%expect
    {|
    held
    held
    |}];
  (* Past reclaim_after from both claims, but only 100s after 300's last
     refresh. *)
  (match Or_error.ok_exn (Db.claim_job db ~version:v ~now:1700) with
   | None -> print_endline "nothing to claim"
   | Some (j : Job.t) -> printf "claimed %s\n" j.seed);
  [%expect {| claimed 301 |}];
  printf
    "300 @ %d, 301 @ %d\n"
    (Option.value_exn (claim_of db ~seed:"300" v))
    (Option.value_exn (claim_of db ~seed:"301" v));
  [%expect {| 300 @ 1600, 301 @ 1700 |}];
  cleanup path [ db ]
;;

(* A reclaim is evidence a worker vanished, not that the work is bad. What
   bounds a dead-worker loop is that the worker is gone; what bounds a bad seed
   is the failure counter. *)
let%expect_test "attempts counts failures, not claims" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  ignore (enqueue db ~seed:"300" ~now:1000 v : _);
  let attempt ~now =
    match Or_error.ok_exn (Db.claim_job db ~version:v ~now) with
    | None -> printf "%d: nothing to claim (%s)\n" now (state db ~seed:"300" v)
    | Some (j : Job.t) -> printf "%d: claimed, attempts %d\n" now j.attempts
  in
  attempt ~now:1000;
  attempt ~now:1030;
  (* Past it with no refresh the claim is cleared for retry, as many times as it
     takes -- nothing here is a strike. *)
  attempt ~now:2000;
  attempt ~now:3000;
  attempt ~now:4000;
  [%expect
    {|
    1000: claimed, attempts 0
    1030: nothing to claim (running)
    2000: claimed, attempts 0
    3000: claimed, attempts 0
    4000: claimed, attempts 0
    |}];
  ignore (finish db ~seed:"300" ~started_at:4000 ~now:4010 v : _);
  printf "%s, attempts %d\n" (state db ~seed:"300" v) (attempts db ~seed:"300" v);
  [%expect {| done, attempts 0 |}];
  cleanup path [ db ]
;;

(* max_attempts bounds *consecutive* failures: a seed that fails, works, then
   fails twice is not a seed tried three times. *)
let%expect_test "a finish resets the failure counter" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  ignore (enqueue db ~seed:"300" ~now:1000 v : _);
  let pass ~now ~error =
    match Or_error.ok_exn (Db.claim_job db ~version:v ~now) with
    | None -> printf "%d: nothing to claim (%s)\n" now (state db ~seed:"300" v)
    | Some (j : Job.t) ->
      ignore
        (finish db ~seed:"300" ~started_at:(Option.value_exn j.started_at) ~now ~error v
         : _);
      printf
        "%d: %s, attempts %d\n"
        now
        (state db ~seed:"300" v)
        (attempts db ~seed:"300" v)
  in
  pass ~now:1000 ~error:(Some "extraction exited 1");
  pass ~now:1010 ~error:None;
  pass ~now:1020 ~error:(Some "extraction exited 1");
  pass ~now:1030 ~error:(Some "extraction exited 1");
  [%expect
    {|
    1000: queued, attempts 1
    1010: done, attempts 0
    1020: nothing to claim (done)
    1030: nothing to claim (done)
    |}];
  cleanup path [ db ]
;;

(* A worker whose claim was taken from it must write nothing: the row belongs
   to the new claimant. *)
let%expect_test "a lost claim does not clobber the new claimant" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  ignore (enqueue db ~seed:"300" ~now:1000 v : _);
  let g2 = Db.open_ path in
  ignore (Or_error.ok_exn (Db.claim_job db ~version:v ~now:1000) : Job.t option);
  (match Or_error.ok_exn (Db.claim_job g2 ~version:v ~now:2000) with
   | None -> print_endline "nothing to claim"
   | Some (j : Job.t) -> printf "g2 claimed %s\n" j.seed);
  [%expect {| g2 claimed 300 |}];
  let report () =
    printf
      "claim %d, attempts %d, %s\n"
      (Option.value_exn (claim_of db ~seed:"300" v))
      (attempts db ~seed:"300" v)
      (state db ~seed:"300" v)
  in
  show_hold
    (Or_error.ok_exn
       (Db.refresh_claim db ~version:v ~seed:"300" ~started_at:1000 ~now:2100));
  report ();
  show_record (finish db ~seed:"300" ~started_at:1000 ~now:2200 v);
  report ();
  show_record
    (finish db ~seed:"300" ~started_at:1000 ~now:2300 ~error:(Some "exited 1") v);
  report ();
  [%expect
    {|
    lost
    claim 2000, attempts 0, running
    lost
    claim 2000, attempts 0, running
    lost
    claim 2000, attempts 0, running
    |}];
  show_record (finish g2 ~seed:"300" ~started_at:2000 ~now:2400 v);
  report ();
  [%expect
    {|
    recorded
    claim 2000, attempts 0, done
    |}];
  cleanup path [ db; g2 ]
;;

(* give_up_sql is the sweep's last resort, for a job over the limit with no
   error on it -- what a hand-requeue that cleared only the error leaves behind.
   It runs on the claiming generator's behalf, so it must not fail a build that
   generator does not serve. *)
let%expect_test "give-up is scoped to the version being claimed" =
  let path, db = corpus () in
  serving db ~now:1000 [ v; other ];
  ignore (enqueue db ~seed:"300" ~now:1000 v : _);
  ignore (enqueue db ~seed:"400" ~now:1000 other : _);
  Db.exec_script db "update ingest_jobs set attempts = 3";
  ignore (Or_error.ok_exn (Db.claim_job db ~version:v ~now:1100) : Job.t option);
  printf "300 %s, 400 %s\n" (state db ~seed:"300" v) (state db ~seed:"400" other);
  [%expect {| 300 failed, 400 queued |}];
  cleanup path [ db ]
;;

let%expect_test "a failure retries until the limit, then stands" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  ignore (enqueue db ~seed:"300" ~now:1000 v : _);
  let fail ~now =
    ignore (Or_error.ok_exn (Db.claim_job db ~version:v ~now) : Job.t option);
    ignore
      (finish db ~seed:"300" ~started_at:now ~now ~error:(Some "crawl exited 1") v : _);
    printf "%d: %s\n" now (state db ~seed:"300" v)
  in
  fail ~now:1000;
  [%expect {| 1000: queued |}];
  fail ~now:1010;
  [%expect {| 1010: queued |}];
  fail ~now:1020;
  [%expect {| 1020: failed |}];
  (match Or_error.ok_exn (Db.job_for_seed db ~version:v ~seed:"300") with
   | None -> print_endline "absent"
   | Some j -> print_endline (Option.value j.error ~default:"(no error)"));
  [%expect {| crawl exited 1 |}];
  cleanup path [ db ]
;;

let%expect_test "a finished job records when, and stops being outstanding" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  ignore (enqueue db ~seed:"300" ~now:1000 v : _);
  ignore (Or_error.ok_exn (Db.claim_job db ~version:v ~now:1000) : Job.t option);
  printf "%s\n" (state db ~seed:"300" v);
  [%expect {| running |}];
  ignore (finish db ~seed:"300" ~started_at:1000 ~now:1003 v : _);
  printf
    "%s, %d outstanding\n"
    (state db ~seed:"300" v)
    (Or_error.ok_exn (Db.outstanding_jobs db));
  [%expect {| done, 0 outstanding |}];
  cleanup path [ db ]
;;

(* Trunk is a new build most days, so the facts the corpus stores once per
   version would describe whichever build was checked out. *)
let%expect_test "trunk is not a version a generator serves" =
  List.iter [ "0.34.1"; "0.33.1"; "trunk"; "0.34-a0-1234-gabc"; "master" ] ~f:(fun s ->
    match Query.Version.of_string s with
    | Error _ -> printf "%-20s rejected\n" s
    | Ok v -> printf "%-20s %b\n" s (Query.Version.is_released v));
  [%expect
    {|
    0.34.1               true
    0.33.1               true
    trunk                false
    0.34-a0-1234-gabc    true
    master               false
    |}]
;;

(* Every expected failure in a pass is already caught and logged. An exception
   is the inconsistency: with_immediate_txn re-raises after rolling back, so a
   SQLITE_BUSY past busy_timeout would take the generator down silently. *)
let%expect_test "a pass that raises does not end the generator" =
  let attempts = ref 0 in
  let pass () =
    Int.incr attempts;
    if !attempts = 2 then failwith "database is locked";
    !attempts > 2
  in
  let on_error message = printf "logged: %s\n" message in
  List.iter [ 1; 2; 3 ] ~f:(fun _ ->
    printf "worked: %b\n" (Seed_corpus.Deepen.guard ~on_error pass));
  printf "passes run: %d\n" !attempts;
  [%expect
    {|
    worked: false
    logged: database is locked
    worked: false
    worked: true
    passes run: 3
    |}]
;;

(* The loop's sleep is a fixed poll interval, so wall-clock between failures
   says little: the count is what separates the first BUSY of an incident from
   one that has survived several passes and is not clearing on its own. A pass
   that returns without raising resets it. *)
let%expect_test "a failure streak counts up and resets on a clean pass" =
  let open Seed_corpus.Deepen.Failure_streak in
  printf "%d\n" (count zero);
  let streak = failed zero in
  printf "%d\n" (count streak);
  let streak = failed streak in
  printf "%d\n" (count streak);
  printf "%d\n" (count (passed streak));
  [%expect
    {|
    0
    1
    2
    0
    |}]
;;

let%expect_test "a failure line names the count and the build and seed in flight" =
  let version = Or_error.ok_exn (Query.Version.of_string "0.34.1") in
  let context = { Seed_corpus.Deepen.Context.version; seed = Some "1234567890" } in
  printf
    "%s\n"
    (Seed_corpus.Deepen.failure_message
       ~consecutive:3
       (Some context)
       "exec_script failed: BUSY (5): database is locked; statement: begin immediate");
  printf
    "%s\n"
    (Seed_corpus.Deepen.failure_message ~consecutive:1 None "heartbeat failed");
  [%expect
    {|
    pass failed: consecutive=3 version=0.34.1 seed=1234567890: exec_script failed: BUSY (5): database is locked; statement: begin immediate
    pass failed: consecutive=1: heartbeat failed
    |}]
;;

(* The position a reader is told is only honest if it is the position
   [claim_job] will work through, so it counts by the same rule. A generator
   claims per version, so a job on another build is not ahead. *)
let position db ~seed version =
  match Or_error.ok_exn (Db.queue_position db ~version ~seed) with
  | None -> "-"
  | Some n -> Int.to_string n
;;

let%expect_test "position counts the jobs ahead of a seed on its own build" =
  let path, db = corpus () in
  serving db ~now:1000 [ v; other ];
  List.iteri [ "10"; "20"; "30" ] ~f:(fun i seed ->
    ignore (enqueue db ~seed ~now:(1000 + i) v : _));
  ignore (enqueue db ~seed:"5" ~now:900 other : _);
  List.iter [ "10"; "20"; "30" ] ~f:(fun seed ->
    printf "%s ahead:%s\n" seed (position db ~seed v));
  [%expect
    {|
    10 ahead:0
    20 ahead:1
    30 ahead:2
    |}];
  cleanup path [ db ]
;;

let%expect_test "claiming the head moves everyone behind it up" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  List.iteri [ "10"; "20"; "30" ] ~f:(fun i seed ->
    ignore (enqueue db ~seed ~now:(1000 + i) v : _));
  let claimed = Or_error.ok_exn (Db.claim_job db ~version:v ~now:2000) in
  printf "claimed: %s\n" (Option.value_map claimed ~default:"-" ~f:(fun j -> j.Job.seed));
  List.iter [ "10"; "20"; "30" ] ~f:(fun seed ->
    printf "%s ahead:%s\n" seed (position db ~seed v));
  [%expect
    {|
    claimed: 10
    10 ahead:-
    20 ahead:0
    30 ahead:1
    |}];
  cleanup path [ db ]
;;

(* queued_at is whole seconds and the cap is 32, so a burst collides routinely.
   Without a tie-break two seeds report the same position, which reads as one of
   them being lost. seed is the rest of the primary key, so ordering by it is
   total. *)
let%expect_test "seeds queued in the same second still get distinct positions" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  List.iter [ "30"; "10"; "20" ] ~f:(fun seed ->
    ignore (enqueue db ~seed ~now:1000 v : _));
  List.iter [ "10"; "20"; "30" ] ~f:(fun seed ->
    printf "%s ahead:%s\n" seed (position db ~seed v));
  [%expect
    {|
    10 ahead:0
    20 ahead:1
    30 ahead:2
    |}];
  cleanup path [ db ]
;;

(* A position is a statement about waiting, so only a waiting job has one. *)
let%expect_test "only a queued job has a position" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  List.iter [ "10"; "20" ] ~f:(fun seed -> ignore (enqueue db ~seed ~now:1000 v : _));
  ignore (Or_error.ok_exn (Db.claim_job db ~version:v ~now:2000) : Job.t option);
  printf "running:  %s\n" (position db ~seed:"10" v);
  ignore (finish db ~seed:"10" ~started_at:2000 ~now:2100 v : _);
  printf "done:     %s\n" (position db ~seed:"10" v);
  printf "absent:   %s\n" (position db ~seed:"999" v);
  printf "queued:   %s\n" (position db ~seed:"20" v);
  [%expect
    {|
    running:  -
    done:     -
    absent:   -
    queued:   0
    |}];
  cleanup path [ db ]
;;

(* A job at the attempt limit keeps its claim and records an error, so it
   leaves the queue rather than consuming it. [claim_job] skips it, so the count
   of jobs ahead must too. *)
let%expect_test "a given-up job is not counted as being ahead of anyone" =
  let path, db = corpus () in
  serving db ~now:1000 [ v ];
  List.iteri [ "10"; "20"; "30" ] ~f:(fun i seed ->
    ignore (enqueue db ~seed ~now:(1000 + i) v : _));
  let rec exhaust n =
    if n > 0
    then (
      let claimed = Or_error.ok_exn (Db.claim_job db ~version:v ~now:(2000 + n)) in
      match claimed with
      | Some (j : Job.t) when String.equal j.seed "10" ->
        ignore
          (finish
             db
             ~seed:"10"
             ~started_at:(2000 + n)
             ~now:(2000 + n)
             ~error:(Some "boom")
             v
           : _);
        exhaust (n - 1)
      | _ -> ())
  in
  exhaust (Job.max_attempts + 1);
  printf "head state: %s\n" (state db ~seed:"10" v);
  printf "head place: %s\n" (position db ~seed:"10" v);
  (* 20 was handed out on the pass that gave up on 10, so 30 is the one still
     waiting -- and with the failed head skipped it is next, not second. *)
  printf "20 state:   %s\n" (state db ~seed:"20" v);
  printf "30 state:   %s\n" (state db ~seed:"30" v);
  printf "30 place:   %s\n" (position db ~seed:"30" v);
  [%expect
    {|
    head state: failed
    head place: -
    20 state:   running
    30 state:   queued
    30 place:   0
    |}];
  cleanup path [ db ]
;;

let%expect_test "servable_versions is the health check's three states" =
  let path, db = corpus () in
  let show ~since =
    match Or_error.ok_exn (Db.servable_versions db ~since) with
    | [] -> print_endline "none"
    | versions -> print_endline (String.concat ~sep:" " versions)
  in
  show ~since:940;
  [%expect {| none |}];
  serving db ~now:1000 [ v; other ];
  show ~since:940;
  [%expect {| 0.33.1 0.34.1 |}];
  show ~since:1700;
  [%expect {| none |}];
  cleanup path [ db ]
;;

(* The fill lock gates the POST route, not just the button: a page rendered
   before the fill started still carries one, and the route is reachable with a
   valid CSRF token regardless. [Db.enqueue] takes `begin immediate`, so an
   ungated POST is a second writer during exactly the window the lock
   protects. *)
let%expect_test "a deepen request is refused outright while a fill holds the lock" =
  let path, db = corpus () in
  let lock_path = path ^ "-write.lock" in
  Exn.protect
    ~finally:(fun () ->
      cleanup path [ db ];
      try Sys_unix.remove lock_path with
      | _ -> ())
    ~f:(fun () ->
      serving db ~now:1000 [ v ];
      let fd = Core_unix.openfile lock_path ~mode:[ O_RDWR; O_CREAT ] in
      Exn.protect
        ~finally:(fun () -> Core_unix.close fd)
        ~f:(fun () ->
          assert (Core_unix.flock fd Core_unix.Flock_command.lock_exclusive);
          printf "filling: %b\n" (Seed_web.fill_in_progress ~lock_path);
          [%expect {| filling: true |}];
          (* The gate is consulted before the write, so the outcome is a refusal
             rather than anything [Db.enqueue] could return. *)
          show_outcome
            (Seed_web.deepen_outcome db ~lock_path ~version:v ~seed:"300" ~now:1000);
          [%expect {| filling |}]);
      (* Nothing reached the corpus: no row, so no `begin immediate`. *)
      printf "job: %s\n" (state db ~seed:"300" v);
      [%expect {| job: absent |}])
;;

(* The gate is a refusal during a fill and nothing at all otherwise, or the fix
   has cost the feature rather than scoped it. *)
let%expect_test "the same request is queued once no fill holds the lock" =
  let path, db = corpus () in
  let lock_path = path ^ "-write.lock" in
  Exn.protect
    ~finally:(fun () -> cleanup path [ db ])
    ~f:(fun () ->
      serving db ~now:1000 [ v ];
      printf "filling: %b\n" (Seed_web.fill_in_progress ~lock_path);
      [%expect {| filling: false |}];
      show_outcome
        (Seed_web.deepen_outcome db ~lock_path ~version:v ~seed:"300" ~now:1000);
      [%expect {| queued |}];
      printf "job: %s\n" (state db ~seed:"300" v);
      [%expect {| job: queued |}])
;;
