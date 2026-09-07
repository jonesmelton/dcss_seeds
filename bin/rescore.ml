open! Core

let command =
  Command.basic
    ~summary:"Recompute seed heat: surprise tables and scores, per (version, cap)"
    ~readme:(fun () ->
      "For each version (or the one named by -build), runs recompute_surprise then \
       rescore for every distinct cap that seed_fills records for it. A seed filled deep \
       is scored at every shallower cap too, since eligibility is depth >= cap -- so \
       nothing has to enumerate 'every cap at or below this seed's own depth' \
       explicitly.\n\n\
      \  rescore -db corpus.db\n\
      \  rescore -db corpus.db -build 0.34.1\n\n\
       Both passes are full scans of entries for the version and must never run from a \
       web handler; this is the only place they are called. See docs/heat.md.")
    (let%map_open.Command db_path =
       flag "-db" (required string) ~doc:"PATH the corpus SQLite file"
     and version_flag =
       flag "-build" (optional string) ~doc:"VERSION only this version (default: all)"
     and shards =
       flag
         "-shards"
         (optional_with_default 1 int)
         ~doc:
           "N split the scoring scan into N seed ranges to bound peak memory (default \
            1). Scores are identical at any N; pick it from a memory budget of roughly \
            120MB + 24KB per seed per shard."
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
           (* Before the caps are read: a cap the version no longer holds is not in
              the list below, so nothing else would ever collect its rows. *)
           Seed_corpus.Db.drop_stale_caps db ~version |> Or_error.ok_exn;
           let caps = Seed_corpus.Db.fill_caps db ~version |> Or_error.ok_exn in
           List.iter caps ~f:(fun cap ->
             printf "==> %s @ cap %d: recomputing surprise\n%!" version_str cap;
             Seed_corpus.Db.recompute_surprise db ~version ~cap;
             printf "==> %s @ cap %d: rescoring (%d shard(s))\n%!" version_str cap shards;
             Seed_corpus.Db.rescore ~shards db ~version ~cap))))
;;

let () = Command_unix.run command
