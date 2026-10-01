open! Core
module Db = Seed_corpus.Db
module Query = Seed_corpus.Query
module Search = Seed_corpus.Search

let default_queries =
  [ "wand:digging"
  ; "potion:haste"
  ; "scroll:teleportation"
  ; "potion:experience; scroll:acquirement; scroll:teleportation"
  ; "wand:digging; shop potion:haste"
  ; "9x scroll:acquirement; 3x potion:haste"
  ; "props:Conj"
  ; "staff props:Conj,Alch"
  ; "armour props:rF,Str"
  ; "name~Throatcutter"
  ; "name~Wyrmbane; potion:haste"
  ]
;;

let timed f =
  let started = Time_float.now () in
  let result = f () in
  result, Time_float.Span.to_sec (Time_float.diff (Time_float.now ()) started)
;;

let median xs =
  let xs = List.sort xs ~compare:Float.compare in
  List.nth_exn xs (List.length xs / 2)
;;

let next_after ~rank ~after matches =
  if Search.Rank.equal rank Search.Rank.Seed
  then (List.last_exn matches : Search.Match.t).seed
  else
    Int.to_string
      (Option.value_map after ~default:0 ~f:Int.of_string + List.length matches)
;;

type outcome =
  | Page of int * [ `More | `End ] * float
  | Declined
  | Failed of string

let run ~runs f =
  let results = List.init runs ~f:(fun _ -> timed f) in
  let secs = median (List.map results ~f:snd) in
  match fst (List.hd_exn results) with
  | Error e -> Failed (String.prefix (Error.to_string_hum e) 60)
  | Ok None -> Declined
  | Ok (Some (matches, more)) -> Page (List.length matches, more, secs)
;;

let show = function
  | Page (n, more, secs) ->
    sprintf
      "%7.3fs %3d%s"
      secs
      n
      (match more with
       | `More -> "+"
       | `End -> " ")
  | Declined -> sprintf "%12s" "declined"
  | Failed msg -> sprintf "FAIL %s" msg
;;

(* The cursor for page [depth], walked the way the web layer walks it; [None] if
   the results end first. *)
let cursor_at db ~version ~terms ~rank ~limit ~depth =
  let rec loop after page =
    if page = depth
    then Some after
    else (
      let search =
        Search.create ~version ~terms ~page:(Query.Page.create ?after ~limit ()) ()
      in
      match Db.search_seeds db search ~rank with
      | Ok (matches, `More) when not (List.is_empty matches) ->
        loop (Some (next_after ~rank ~after matches)) (page + 1)
      | _ -> None)
  in
  loop None 1
;;

let bench db ~version ~limit ~depth ~runs query =
  let terms =
    String.split query ~on:';'
    |> List.map ~f:String.strip
    |> Seed_web.Params.terms_of_strings
    |> Or_error.ok_exn
  in
  List.iter [ Search.Rank.Seed; Search.Rank.Shallowest ] ~f:(fun rank ->
    let at after =
      let search =
        Search.create ~version ~terms ~page:(Query.Page.create ?after ~limit ()) ()
      in
      ( run ~runs (fun () -> Db.search_seeds_store db search ~rank)
      , run ~runs (fun () ->
          Db.search_seeds_sql db search ~rank |> Or_error.map ~f:Option.some) )
    in
    let store1, sql1 = at None in
    let deep =
      match cursor_at db ~version ~terms ~rank ~limit ~depth with
      | None -> "no page " ^ Int.to_string depth
      | Some after ->
        let store, sql = at after in
        sprintf "store %s  sql %s" (show store) (show sql)
    in
    printf
      "%-48s %-10s | p1 store %s  sql %s | p%d %s\n%!"
      query
      (Search.Rank.to_string rank)
      (show store1)
      (show sql1)
      depth
      deep)
;;

let command =
  Command.basic
    ~summary:"Time the store and the SQL path on first and deep pages"
    ~readme:(fun () ->
      "Per query and rank: the median over -runs of the store's first page and the SQL \
       path's, then the same at page -depth, reached by the web layer's cursor. [n+] \
       means more results follow. Terms within a query are separated by ';'.")
    (let%map_open.Command db_path = flag "-db" (required string) ~doc:"PATH corpus"
     and version =
       flag
         "-build"
         (required (Arg_type.create (Fn.compose Or_error.ok_exn Query.Version.of_string)))
         ~doc:"VERSION build"
     and queries =
       flag "-query" (listed string) ~doc:"TERMS a query (default: a fixed set)"
     and limit =
       flag "-page" (optional_with_default 50 int) ~doc:"N page size (default 50)"
     and depth =
       flag "-depth" (optional_with_default 20 int) ~doc:"N deep page (default 20)"
     and runs =
       flag "-runs" (optional_with_default 3 int) ~doc:"N runs per timing (default 3)"
     in
     fun () ->
       let queries = if List.is_empty queries then default_queries else queries in
       Db.with_db db_path ~f:(fun db ->
         if not (Db.search_index_is_current db ~version)
         then eprintf "warning: store not current; every store timing will decline\n%!";
         List.iter queries ~f:(bench db ~version ~limit ~depth ~runs)))
;;

let () = Command_unix.run command
