open! Core

let default_batch_size = 2_000

let command =
  Command.basic
    ~summary:"Ingest #SEED# catalog lines from stdin into the seed corpus"
    ~readme:(fun () ->
      "Reads the filtered output of scripts/seed_dump_sexp.lua on stdin:\n\n\
      \  util/fake_pty ./crawl -script seed_dump_sexp.lua -seed 5000 -count 500 -depth \
       D:5 2>&1 \\\n\
      \    | grep '^#SEED#' | ingest -db corpus.db\n\n\
       Re-ingesting a (seed, version, level) replaces it rather than duplicating it.")
    (let%map_open.Command db_path =
       flag "-db" (required string) ~doc:"PATH the corpus SQLite file"
     and batch_size =
       flag
         "-batch-size"
         (optional_with_default default_batch_size int)
         ~doc:(sprintf "N records per transaction (default: %d)" default_batch_size)
     and quiet = flag "-quiet" no_arg ~doc:" do not report rejected lines individually" in
     fun () ->
       if batch_size < 1 then failwith "-batch-size must be at least 1";
       let on_reject line_number error =
         if not quiet
         then eprintf "line %d rejected: %s\n" line_number (Error.to_string_hum error)
       in
       let counts =
         Db.with_db db_path ~f:(fun db ->
           Db.ingest_channel db In_channel.stdin ~batch_size ~on_reject)
       in
       print_endline (Db.Counts.to_string counts))
;;
