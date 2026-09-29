open! Core
module Build = Seed_corpus.Deepen.Build

let now () = Float.to_int (Core_unix.time ())

(* A fill holds this lock for its whole run. Deepen yields rather than
   competing: the corpus has a single writer, and two of them exhausting each
   other's busy_timeout is how a fill loses chunks. The test is non-blocking and
   the claim loop is skipped, not queued -- a deepen request arriving mid-fill
   waits in ingest_jobs, which is where an unserved request belongs. The
   heartbeat continues regardless. *)
let fill_in_progress ~lock_path =
  match Core_unix.openfile lock_path ~mode:[ O_RDONLY ] with
  | exception _ -> false
  | fd ->
    Exn.protect
      ~finally:(fun () -> Core_unix.close fd)
      ~f:(fun () ->
        match Core_unix.flock fd Core_unix.Flock_command.lock_shared with
        | true ->
          ignore (Core_unix.flock fd Core_unix.Flock_command.unlock : bool);
          false
        | false -> true)
;;

(* A build tree is served only if crawl is actually runnable in it, so a
   half-provisioned version is silently not heartbeat rather than claimed and
   failed. Trunk is skipped even when built: it is a moving tag, so deepening
   against it writes rows the per-version invariants cannot hold. *)
let runnable (build : Build.t) =
  match Sys_unix.file_exists (Filename.concat build.source "crawl") with
  | `Yes -> true
  | `No | `Unknown -> false
;;

let discover ~root =
  let builds = Filename.concat root "builds" in
  match Sys_unix.is_directory builds with
  | `No | `Unknown -> []
  | `Yes ->
    Sys_unix.ls_dir builds
    |> List.sort ~compare:String.compare
    |> List.filter_map ~f:(fun name ->
      match Seed_corpus.Query.Version.of_string name with
      | Error _ -> None
      | Ok version ->
        if not (Seed_corpus.Query.Version.is_released version)
        then None
        else (
          let build = Build.of_version ~root ~version in
          if runnable build then Some build else None))
;;

module Outcome = Seed_corpus.Deepen.Outcome

let sec span = Time_float.Span.to_sec span
let sleep span = ignore (Core_unix.nanosleep (sec span) : float)

(* The extraction is a shell pipeline, so the child is a shell and the work is
   its descendants: signalling the pid leaves crawl running and still writing
   rows through an ingest that outlives its parent. *)
let spawn command =
  let child =
    Core_unix.create_process_with_fds
      ~setpgid:Core_unix.Pgid.new_process_group
      ~prog:"/bin/sh"
      ~args:[ "-c"; command ]
      ~stdin:(Use_this Core_unix.stdin)
      ~stdout:(Use_this Core_unix.stdout)
      ~stderr:(Use_this Core_unix.stderr)
      ()
  in
  child.pid
;;

let reap pid =
  try Option.map (Core_unix.wait_nohang (`Pid pid)) ~f:snd with
  | Core_unix.Unix_error (ECHILD, _, _) -> Some (Ok ())
;;

let signal_group pid signal =
  match Signal_unix.send signal (`Group pid) with
  | `Ok | `No_such_process -> ()
;;

(* The SIGKILL is sent even when the shell was reaped in the grace window: the
   shell dies on the group's SIGTERM while a stage that trapped it lives on, so
   reaping the leader says nothing about the pipeline.

   Reaping is not bookkeeping either. A killed ingest rolls back, but it holds
   the corpus's write lock until the process is actually gone, so a worker that
   signals and immediately claims another job walks into its own busy_timeout.
   ECHILD means it is already reaped, which is normal. *)
let kill_group pid =
  let poll = Time_float.Span.of_sec 0.2 in
  let rec wait_out remaining =
    if Float.( <= ) remaining 0. || Option.is_some (reap pid)
    then ()
    else (
      sleep poll;
      wait_out (remaining -. sec poll))
  in
  signal_group pid Signal.term;
  wait_out (sec Seed_corpus.Deepen.kill_grace);
  signal_group pid Signal.kill;
  try ignore (Core_unix.waitpid pid : Core_unix.Exit_or_signal.t) with
  | Core_unix.Unix_error (ECHILD, _, _) -> ()
;;

let exited = function
  | Ok () -> Outcome.Finished
  | Error (`Exit_non_zero code) -> Outcome.Exited (sprintf "extraction exited %d" code)
  | Error (`Signal signal) ->
    Outcome.Exited (sprintf "extraction killed by %s" (Signal.to_string signal))
;;

(* The claim is refreshed from the loop that watches the child, so started_at
   measures this worker's liveness rather than the job's age. A refresh matching
   no row means the claim was reclaimed and someone else holds it: kill the
   child and abandon the pass rather than record an outcome on a row that is not
   ours.

   Returns the claim the pass ends holding, since that is what finish_job must
   match on. *)
let run_job db ~(build : Build.t) ~(job : Seed_corpus.Job.t) ~db_path ~ingest ~claim =
  let command =
    Seed_corpus.Deepen.extract_command
      build
      ~seed:job.seed
      ~depth:job.depth
      ~db_path
      ~ingest
  in
  let pid = spawn command in
  let started = now () in
  let rec watch claim =
    match reap pid with
    | Some status -> exited status, claim
    | None ->
      if now () - started > Float.to_int (sec Seed_corpus.Deepen.timeout)
      then (
        kill_group pid;
        Outcome.Timed_out, claim)
      else (
        let at = now () in
        match
          Seed_corpus.Db.refresh_claim
            db
            ~version:build.version
            ~seed:job.seed
            ~started_at:claim
            ~now:at
        with
        | Error err ->
          eprintf "refresh failed: %s\n%!" (Error.to_string_hum err);
          sleep Seed_corpus.Deepen.tick;
          watch claim
        | Ok `Lost ->
          kill_group pid;
          Outcome.Claim_lost, claim
        | Ok `Held ->
          sleep Seed_corpus.Deepen.tick;
          watch at)
  in
  watch claim
;;

(* Not part of the claim loop, and must not be skipped with it. The heartbeat
   declares which versions this generator CAN build, not that it is working: a
   fill pauses the work, not the capability. Skipping it would lapse the 300s
   window, answering every deepen request `No_generator and reporting /health as
   "no generator" for the whole of a multi-hour fill. *)
let heartbeat db ~builds ~generator_id =
  match
    Seed_corpus.Db.heartbeat
      db
      ~generator_id
      ~versions:(List.map builds ~f:(fun (b : Build.t) -> b.version))
      ~now:(now ())
  with
  | Ok () -> ()
  | Error err -> eprintf "heartbeat failed: %s\n%!" (Error.to_string_hum err)
;;

let one_pass db ~builds ~db_path ~ingest ~generator_id ~on_context ~on_pass_start =
  (* The caller owns [on_context]'s slot across passes, so clear it before
     [heartbeat] can fail: otherwise a pass that dies before its first
     [on_context] reports the previous pass's last build. *)
  on_pass_start ();
  heartbeat db ~builds ~generator_id;
  (* At most one job per version per pass, so a busy version cannot starve the
     others. *)
  List.fold builds ~init:false ~f:(fun worked (build : Build.t) ->
    on_context { Seed_corpus.Deepen.Context.version = build.version; seed = None };
    match Seed_corpus.Db.claim_job db ~version:build.version ~now:(now ()) with
    | Error err ->
      eprintf "claim failed: %s\n%!" (Error.to_string_hum err);
      worked
    | Ok None -> worked
    | Ok (Some job) ->
      on_context
        { Seed_corpus.Deepen.Context.version = build.version; seed = Some job.seed };
      printf
        "%s %s: deepening to %s\n%!"
        (Seed_corpus.Query.Version.to_string build.version)
        job.seed
        job.depth;
      let outcome, claim =
        run_job
          db
          ~build
          ~job
          ~db_path
          ~ingest
          ~claim:(Option.value_exn job.started_at ~message:"claimed job with no claim")
      in
      (* Unconditional, and before the outcome is recorded: ingest commits as it
         goes, so a job that timed out or was killed has still interned whatever
         names it reached. Skipping the catch-up on a bad outcome would leave
         those indexed nowhere and withdraw name search corpus-wide until
         someone rebuilt by hand.

         Failure is logged, not fatal: the mark stays where it was, name search
         stays withdrawn, and the next job retries the same range. That is the
         status quo this replaces, not a regression. *)
      (match Seed_corpus.Db.catch_up_fts db with
       | Ok () -> ()
       | Error err -> eprintf "fts catch-up failed: %s\n%!" (Error.to_string_hum err));
      let recorded =
        match Outcome.record outcome with
        | `Nothing -> Outcome.Claim_lost
        | `Record error ->
          (match
             Seed_corpus.Db.finish_job
               db
               ~version:build.version
               ~seed:job.seed
               ~started_at:claim
               ~now:(now ())
               ~error
           with
           | Ok `Recorded -> outcome
           | Ok `Lost -> Outcome.Claim_lost
           | Error err ->
             eprintf "finish failed: %s\n%!" (Error.to_string_hum err);
             outcome)
      in
      (match recorded with
       | Finished -> printf "%s: %s\n%!" job.seed (Outcome.to_string recorded)
       | Timed_out | Exited _ | Claim_lost ->
         eprintf "%s: %s\n%!" job.seed (Outcome.to_string recorded));
      true)
;;

let command =
  Command.basic
    ~summary:"Serve deep-fill requests from the corpus's ingest queue"
    ~readme:(fun () ->
      "Claims one seed at a time from ingest_jobs, runs crawl for it, and\n\
       records the outcome. Serves the versions that have a runnable build\n\
       under builds/; jobs for anything else are left for another generator.\n\n\
       The web process must not do this: it has no build tree, and a ~2.5s\n\
       extraction on the request thread would stall every concurrent reader.")
    (let%map_open.Command db_path =
       flag "-db" (optional_with_default "corpus.db" string) ~doc:"PATH the corpus"
     and root =
       flag
         "-root"
         (optional string)
         ~doc:"DIR where builds/ and sandboxes/ live (default: alongside -db)"
     and poll_every =
       flag
         "-poll"
         (optional_with_default 2.0 float)
         ~doc:"SECONDS to sleep when there is nothing to claim (default: 2)"
     and once = flag "-once" no_arg ~doc:" make one pass and exit, for testing" in
     fun () ->
       if not (Sys_unix.file_exists_exn db_path)
       then failwithf "no corpus at %s" db_path ();
       (* The extraction pipeline cds into the build tree, so every path it
          carries is resolved first: a relative corpus path would resolve there,
          and ingest would create an empty database inside builds/. *)
       let db_path = Filename_unix.realpath db_path in
       let root =
         match root with
         | Some root -> Filename_unix.realpath root
         | None -> Filename.dirname db_path
       in
       let ingest =
         String.concat ~sep:"/" [ root; "_build"; "default"; "bin"; "ingest.exe" ]
       in
       if not (Sys_unix.file_exists_exn ingest)
       then failwithf "no ingest binary at %s; run: just build" ingest ();
       let lock_path = Seed_corpus.Deepen.fill_lock_path ~db_path in
       match discover ~root with
       | [] -> failwithf "no runnable crawl under %s/builds; run: make provision" root ()
       | builds ->
         printf
           "serving %s\n%!"
           (String.concat
              ~sep:", "
              (List.map builds ~f:(fun (b : Build.t) ->
                 Seed_corpus.Query.Version.to_string b.version)));
         (* Identity is the machine and the build root, not the pid: a generator
            restarted after a crash is the same generator, and a pid-keyed row
            would leave the dead one carrying a stale timestamp forever while
            the table grew a row per restart. *)
         let generator_id = sprintf "%s:%s" (Core_unix.gethostname ()) root in
         let db = Seed_corpus.Db.open_ db_path in
         Exn.protect
           ~finally:(fun () -> Seed_corpus.Db.close db)
           ~f:(fun () ->
             let context = ref None in
             let streak = ref Seed_corpus.Deepen.Failure_streak.zero in
             let rec loop () =
               let failed = ref false in
               let worked =
                 if fill_in_progress ~lock_path
                 then (
                   (* Still heartbeat. Only the claim loop yields to the fill. *)
                   heartbeat db ~builds ~generator_id;
                   false)
                 else
                   Seed_corpus.Deepen.guard
                     ~on_error:(fun message ->
                       failed := true;
                       streak := Seed_corpus.Deepen.Failure_streak.failed !streak;
                       eprintf
                         "%s\n%!"
                         (Seed_corpus.Deepen.failure_message
                            ~consecutive:(Seed_corpus.Deepen.Failure_streak.count !streak)
                            !context
                            message))
                     (fun () ->
                        one_pass
                          db
                          ~builds
                          ~db_path
                          ~ingest
                          ~generator_id
                          ~on_context:(fun c -> context := Some c)
                          ~on_pass_start:(fun () -> context := None))
               in
               if not !failed
               then streak := Seed_corpus.Deepen.Failure_streak.passed !streak;
               if once
               then ()
               else (
                 if not worked then ignore (Core_unix.nanosleep poll_every : float);
                 loop ())
             in
             loop ()))
;;

let () = Command_unix.run command
