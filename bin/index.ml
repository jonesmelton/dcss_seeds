open! Core

let command =
  Command.basic
    ~summary:"Build the seed-granular search store: postings for 'which seeds contain X'"
    ~readme:(fun () ->
      "For each version (or the one named by -build), rebuilds the store schema.sql \
       carries at the bottom -- seed_ordinals, search_criteria, search_postings, \
       search_index_state -- so search can answer set-membership questions by \
       posting-list lookup instead of scanning entries. Same role for search that \
       tools/corpus-fts-rebuild plays for name~. See lib/corpus/search_index.mli.\n\n\
      \  corpus-index -db corpus.db\n\
      \  corpus-index -db corpus.db -build 0.34.1\n\n\
       Unlike a stale trigram index, a stale store is not refused at query time -- \
       search falls back to the slower SQL predicate path, the same semantics \
       implemented twice, so this is safe to defer -- and a full rebuild is the only \
       maintenance path; there is no incremental catch-up. Run it after a fill, deepened \
       seeds included.")
    (let%map_open.Command db_path =
       flag "-db" (required string) ~doc:"PATH the corpus SQLite file"
     and version_flag =
       flag "-build" (optional string) ~doc:"VERSION only this version (default: all)"
     in
     fun () ->
       Seed_corpus.Db.with_db db_path ~f:(fun db ->
         let versions =
           match version_flag with
           | Some v -> [ v ]
           | None ->
             Seed_corpus.Db.query
               db
               "select distinct version from versions order by version"
         in
         List.iter versions ~f:(fun version_str ->
           let version =
             Seed_corpus.Query.Version.of_string version_str |> Or_error.ok_exn
           in
           printf "==> %s: building search index\n%!" version_str;
           let started = Time_float.now () in
           Seed_corpus.Db.build_search_index db ~version |> Or_error.ok_exn;
           let elapsed = Time_float.diff (Time_float.now ()) started in
           let stats = Seed_corpus.Db.search_index_stats db ~version |> Or_error.ok_exn in
           printf
             "==> %s: %d seed(s), %d criteria, %d posting(s) in %d block(s), %d byte(s) \
              (%.1fs)\n\
              %!"
             version_str
             stats.seeds
             stats.criteria
             stats.postings
             stats.blocks
             stats.bytes
             (Time_float.Span.to_sec elapsed);
           let current = Seed_corpus.Db.search_index_is_current db ~version in
           printf
             "==> %s: store is %s\n%!"
             version_str
             (if current then "current" else "stale"))))
;;

let () = Command_unix.run command
