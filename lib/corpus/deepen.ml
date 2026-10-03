open! Core

module Build = struct
  type t =
    { version : Query.Version.t
    ; source : string
    ; sandbox : string
    }
  [@@deriving sexp_of]

  let of_version ~root ~version =
    let name = Query.Version.to_string version in
    { version
    ; source = String.concat ~sep:"/" [ root; "builds"; name; "crawl-ref"; "source" ]
    ; sandbox = String.concat ~sep:"/" [ root; "sandboxes"; name ]
    }
  ;;
end

module Failure_streak = struct
  type t = int

  let zero = 0
  let failed n = n + 1
  let passed _ = 0
  let count n = n
end

module Context = struct
  type t =
    { version : Query.Version.t
    ; seed : string option
    }
  [@@deriving sexp_of]
end

(* The generator's whole failure record in one line: which build was in flight
   and, once a job was claimed, which seed; how many passes this failure has
   survived; and the exception's message, which carries the extended result
   code and the failing statement. *)
let failure_message ~consecutive (context : Context.t option) message =
  let where =
    match context with
    | None -> ""
    | Some context ->
      sprintf
        " version=%s%s"
        (Query.Version.to_string context.version)
        (match context.seed with
         | Some seed -> sprintf " seed=%s" seed
         | None -> "")
  in
  sprintf "pass failed: consecutive=%d%s: %s" consecutive where message
;;

let tick = Time_float.Span.of_sec 5.
let timeout = Time_float.Span.of_sec 900.
let kill_grace = Time_float.Span.of_sec 10.

let extract_command (build : Build.t) ~seed ~depth ~db_path ~ingest =
  sprintf
    "cd %s && util/fake_pty ./crawl -dir %s -script seed_dump_sexp.lua -seed %s -depth \
     %s 2>&1 | grep '^#SEED#' | %s -db %s -quiet -requested"
    (Filename.quote build.source)
    (Filename.quote build.sandbox)
    (Filename.quote seed)
    (Filename.quote depth)
    (Filename.quote ingest)
    (Filename.quote db_path)
;;

module Outcome = struct
  type t =
    | Finished
    | Timed_out
    | Exited of string
    | Claim_lost
  [@@deriving sexp_of]

  let timed_out_message =
    sprintf "killed after %.0fs; crawl ran past the cap" (Time_float.Span.to_sec timeout)
  ;;

  let record = function
    | Claim_lost -> `Nothing
    | Finished -> `Record None
    | Timed_out -> `Record (Some timed_out_message)
    | Exited message -> `Record (Some message)
  ;;

  let to_string = function
    | Finished -> "done"
    | Timed_out -> timed_out_message
    | Exited message -> message
    | Claim_lost -> "claim expired; another generator holds this job"
  ;;
end

let guard ~on_error pass =
  try pass () with
  | Sqlite3.Error message | Failure message ->
    on_error message;
    false
  | exn ->
    on_error (Exn.to_string exn);
    false
;;

let fill_lock_path ~db_path =
  String.chop_suffix_if_exists db_path ~suffix:".db" ^ "-write.lock"
;;
