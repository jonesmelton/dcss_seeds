open! Core
module Db = Seed_corpus.Db
module Depth = Seed_corpus.Depth
module Query = Seed_corpus.Query
module Search = Seed_corpus.Search

let default_queries =
  [ "potion:haste"
  ; "artefact"
  ; "scroll:acquirement"
  ; "wand:digging"
  ; "shop potion:haste"
  ; "3x potion:haste"
  ; "9x artefact"
  ; "wand:digging; shop potion:haste"
  ; "potion:experience; scroll:acquirement; artefact"
  ; "props:Conj"
  ; "staff props:Conj"
  ; "staff props:Conj,Alch"
  ; "props:rF,rC"
  ; "armour props:rF,Str"
  ; "name~hood of the Assassin"
  ; "jewellery props:rMut; name~hood of the Assassin"
  ; "name~robe of Vines; props:Conj"
  ]
;;

(* [Page.create] clamps to 200, and paging the SQL path costs its matched-row scan
   per page, so the reference is read in pages built directly: as large as they
   go while each one still binds its seeds under SQLite's variable limit. *)
let sql_chunk = 20_000

let timed f =
  let started = Time_float.now () in
  let result = f () in
  result, Time_float.Span.to_sec (Time_float.diff (Time_float.now ()) started)
;;

let depth_of (m : Search.Match.t) =
  List.fold m.hits ~init:Int.max_value ~f:(fun acc (h : Search.Match.hit) ->
    Int.min acc (Depth.of_level h.level))
;;

let hits (m : Search.Match.t) =
  List.map m.hits ~f:(fun (h : Search.Match.hit) -> h.level, h.name, h.count, h.distinct)
;;

let seeds matches = List.map matches ~f:(fun (m : Search.Match.t) -> m.seed)

(* The web layer's cursor rule (lib/web/views.ml): keyset on the last seed under
   [Rank.Seed], an offset into the ranked order otherwise. *)
let next_after ~rank ~after matches =
  if Search.Rank.equal rank Search.Rank.Seed
  then (List.last_exn matches : Search.Match.t).seed
  else
    Int.to_string
      (Option.value_map after ~default:0 ~f:Int.of_string + List.length matches)
;;

(* The store's answer, paged with the web cursor. One page sized past the corpus
   would bind every matched ordinal at once, past SQLite's variable limit for a
   broad term at 1.3M. A ranked page costs the whole matched set (e5f102e19d), so
   a ranked walk stops at [max_pages] and is checked as a prefix. *)
let walk_store db ~version ~terms ~rank ~limit ~max_pages =
  let rec loop after pages slowest acc =
    let search =
      Search.create ~version ~terms ~page:(Query.Page.create ?after ~limit ()) ()
    in
    let result, secs = timed (fun () -> Db.search_seeds_store db search ~rank) in
    match result with
    | Error e -> Error e
    | Ok None when pages = 0 -> Ok None
    | Ok None -> Or_error.errorf "store declined page %d" (pages + 1)
    | Ok (Some (matches, more)) ->
      let acc = List.rev_append matches acc in
      let slowest = Float.max slowest secs in
      (match more with
       | `End -> Ok (Some (List.rev acc, `Whole, pages + 1, slowest))
       | `More when List.is_empty matches -> Or_error.error_string "empty page with more"
       | `More when pages + 1 >= max_pages ->
         Ok (Some (List.rev acc, `Prefix, pages + 1, slowest))
       | `More -> loop (Some (next_after ~rank ~after matches)) (pages + 1) slowest acc)
  in
  loop None 0 0. []
;;

let walk_sql db ~version ~terms =
  let rec loop after acc =
    let search =
      Search.create ~version ~terms ~page:{ Query.Page.after; limit = sql_chunk } ()
    in
    match Db.search_seeds_sql db search ~rank:Search.Rank.Seed with
    | Error e -> Error e
    | Ok (matches, more) ->
      let acc = List.rev_append matches acc in
      (match more, List.last matches with
       | `More, Some (last : Search.Match.t) -> loop (Some last.seed) acc
       | _ -> Ok (List.rev acc, `End))
  in
  loop None []
;;

let check db ~version ~limit ~ranked_pages ~rank query =
  let label = sprintf "%-48s %-10s" query (Search.Rank.to_string rank) in
  let terms =
    String.split query ~on:';'
    |> List.map ~f:String.strip
    |> Seed_web.Params.terms_of_strings
    |> Or_error.ok_exn
  in
  let max_pages =
    if Search.Rank.equal rank Search.Rank.Seed then Int.max_value else ranked_pages
  in
  let store, store_secs =
    timed (fun () -> walk_store db ~version ~terms ~rank ~limit ~max_pages)
  in
  match store with
  | Error e ->
    printf "%s FAIL store errored: %s\n%!" label (Error.to_string_hum e);
    false
  | Ok None ->
    printf "%s store declined, nothing to compare\n%!" label;
    true
  | Ok (Some (store_matches, extent, pages, slowest)) ->
    let whole =
      match extent with
      | `Whole -> true
      | `Prefix -> false
    in
    (* The reference is always the SQL path under [Rank.Seed], which never
       refuses: a ranked order is checked as the SQL set's depths, sorted, since
       above [Rank.sort_limit] the SQL path will not rank at all. *)
    let sql, sql_secs = timed (fun () -> walk_sql db ~version ~terms) in
    let problems = Queue.create () in
    let note fmt = ksprintf (Queue.enqueue problems) fmt in
    let sql_summary =
      match sql with
      | Error e ->
        note "sql errored: %s" (Error.to_string_hum e);
        "sql errored"
      | Ok (sql_matches, _) ->
        let by_seed ms =
          String.Map.of_alist_reduce
            (List.map ms ~f:(fun (m : Search.Match.t) -> m.seed, hits m))
            ~f:(fun a _ -> a)
        in
        let s = by_seed store_matches
        and q = by_seed sql_matches in
        let only_store = Set.diff (Map.key_set s) (Map.key_set q)
        and only_sql = Set.diff (Map.key_set q) (Map.key_set s) in
        if not (Set.is_empty only_store && ((not whole) || Set.is_empty only_sql))
        then
          note
            "seed sets differ: %d store-only %s, %d sql-only %s"
            (Set.length only_store)
            (Sexp.to_string
               ([%sexp_of: string list] (List.take (Set.to_list only_store) 5)))
            (Set.length only_sql)
            (Sexp.to_string
               ([%sexp_of: string list] (List.take (Set.to_list only_sql) 5)))
        else (
          let differing =
            Map.count
              (Map.merge s q ~f:(fun ~key:_ -> function
                 | `Both (a, b) when not (Poly.equal a b) -> Some ()
                 | _ -> None))
              ~f:(fun () -> true)
          in
          if differing > 0 then note "hits differ on %d seed(s)" differing);
        if
          (not (Search.Rank.equal rank Search.Rank.Seed))
          && not
               ([%equal: int list]
                  (List.map store_matches ~f:depth_of)
                  (List.map sql_matches ~f:depth_of
                   |> List.sort ~compare:Int.compare
                   |> Fn.flip List.take (List.length store_matches)))
        then note "ranked depth sequence differs from the SQL set's sorted depths";
        sprintf "sql=%d (%.2fs)" (List.length sql_matches) sql_secs
    in
    let paged = seeds store_matches in
    let distinct = List.dedup_and_sort paged ~compare:String.compare in
    if List.length distinct <> List.length paged
    then note "paging repeated %d seed(s)" (List.length paged - List.length distinct);
    printf
      "%s store=%d%s (%.2fs) %s pages=%d slowest=%.3fs"
      label
      (List.length distinct)
      (if whole then "" else " prefix")
      store_secs
      sql_summary
      pages
      slowest;
    if Queue.is_empty problems
    then (
      printf " ok\n%!";
      true)
    else (
      printf " FAIL\n";
      Queue.iter problems ~f:(printf "    %s\n");
      Out_channel.flush stdout;
      false)
;;

let command =
  Command.basic
    ~summary:"Check the search store against the SQL predicate path on a real corpus"
    ~readme:(fun () ->
      "For each query and both ranks: the store paged to the end with the web layer's \
       cursor (a shallowest walk only to -ranked-pages, since each ranked page costs the \
       whole matched set), checked for repeats, then against the SQL path's whole \
       matched set by seed, by per-seed evidence, and under a ranked order by depth \
       sequence against the SQL set's sorted depths. Refuses a stale store rather than \
       comparing the SQL path with itself.\n\n\
      \  corpus-search-equiv -db corpus.db -build 0.34.1\n\
      \  corpus-search-equiv -db corpus.db -build 0.34.1 -query 'wand:digging; shop \
       potion:haste'\n\n\
       Terms within a query are separated by ';'. Exits 1 on any disagreement.")
    (let%map_open.Command db_path =
       flag "-db" (required string) ~doc:"PATH the corpus SQLite file"
     and version =
       flag
         "-build"
         (required (Arg_type.create (Fn.compose Or_error.ok_exn Query.Version.of_string)))
         ~doc:"VERSION the build to check"
     and queries =
       flag "-query" (listed string) ~doc:"TERMS a query to check (default: a fixed set)"
     and limit =
       flag
         "-page"
         (optional_with_default 50 int)
         ~doc:"N page size for the store walk (default 50, max 200)"
     and ranked_pages =
       flag
         "-ranked-pages"
         (optional_with_default 100 int)
         ~doc:"N stop a shallowest walk here and check it as a prefix (default 100)"
     in
     fun () ->
       let queries = if List.is_empty queries then default_queries else queries in
       let ok =
         Db.with_db db_path ~f:(fun db ->
           if not (Db.search_index_is_current db ~version)
           then (
             eprintf "the store is not current for this build; run: just index\n";
             false)
           else
             List.concat_map queries ~f:(fun q ->
               [ q, Search.Rank.Seed; q, Search.Rank.Shallowest ])
             |> List.map ~f:(fun (q, rank) ->
               check db ~version ~limit ~ranked_pages ~rank q)
             |> List.for_all ~f:Fn.id)
       in
       if not ok then exit 1)
;;

let () = Command_unix.run command
