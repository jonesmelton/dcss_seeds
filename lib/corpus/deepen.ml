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

let tick = Time_float.Span.of_sec 5.
let timeout = Time_float.Span.of_sec 900.
let kill_grace = Time_float.Span.of_sec 10.

let extract_command (build : Build.t) ~seed ~depth ~db_path ~ingest =
  sprintf
    "cd %s && util/fake_pty ./crawl -dir %s -script seed_dump_sexp.lua -seed %s -depth \
     %s 2>&1 | grep '^#SEED#' | %s -db %s -quiet"
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
