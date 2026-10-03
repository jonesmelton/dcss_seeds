open! Core

type t =
  { db : Sqlite3.db
  ; key : string
  }

let schema =
  {|
create table if not exists seed_flags (
    version text not null,
    seed text not null,
    session text not null,
    query text,
    depth text,
    flagged_at integer not null default (unixepoch()),
    primary key (version, seed, session)
) strict, without rowid
|}
;;

let open_ ~key path =
  let db = Sqlite3.db_open path in
  Sql.exec_script db "pragma journal_mode = wal";
  Sql.exec_script db "pragma synchronous = normal";
  Sql.exec_script db "pragma busy_timeout = 30000";
  Sql.exec_script db schema;
  { db; key }
;;

let close t = ignore (Sqlite3.db_close t.db : bool)
let max_query_length = 500

let flag_sql =
  {|
insert into seed_flags (version, seed, session, query, depth)
values (?, ?, ?, ?, ?)
on conflict do nothing
|}
;;

let hash t session_id = Digestif.SHA256.(hmac_string ~key:t.key session_id |> to_hex)

let flag t ~version ~seed ~session_id ~query ~depth =
  let query =
    match query with
    | Some q -> Sqlite3.Data.TEXT (String.prefix q max_query_length)
    | None -> Sqlite3.Data.NULL
  in
  Sql.with_stmt
    t.db
    flag_sql
    ~bind:
      [ TEXT (Query.Version.to_string version)
      ; TEXT seed
      ; TEXT (hash t session_id)
      ; query
      ; TEXT depth
      ]
    ~f:(fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.DONE -> Ok ()
      | rc -> Or_error.errorf "flag insert: %s" (Sqlite3.Rc.to_string rc))
;;

let is_flagged_sql =
  {|
select 1
  from seed_flags
 where version = ?
   and seed = ?
   and session = ?
|}
;;

let is_flagged t ~version ~seed ~session_id =
  Sql.with_stmt
    t.db
    is_flagged_sql
    ~bind:[ TEXT (Query.Version.to_string version); TEXT seed; TEXT (hash t session_id) ]
    ~f:(fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Ok true
      | Sqlite3.Rc.DONE -> Ok false
      | rc -> Or_error.errorf "flag lookup: %s" (Sqlite3.Rc.to_string rc))
;;

type row =
  { version : string
  ; seed : string
  ; session : string
  ; query : string option
  ; depth : string
  }
[@@deriving sexp_of]

let rows_sql =
  {|
select version, seed, session, query, depth
  from seed_flags
 order by flagged_at, version, seed, session
|}
;;

let sample_seeds_sql =
  {|
  select distinct seed
    from seed_flags
   where version = ?
order by random()
   limit ?
|}
;;

let sample_seeds t ~version ~limit =
  Sql.with_stmt
    t.db
    sample_seeds_sql
    ~bind:
      [ TEXT (Query.Version.to_string version); Sqlite3.Data.INT (Int64.of_int limit) ]
    ~f:(fun stmt ->
      Sql.fold_rows stmt ~init:[] ~f:(fun acc row ->
        let%map.Or_error seed = Sql.required row 0 ~field:"seed" in
        seed :: acc)
      |> Or_error.map ~f:List.rev)
;;

let rows t =
  let open Or_error.Let_syntax in
  Sql.with_stmt t.db rows_sql ~bind:[] ~f:(fun stmt ->
    let%map rows =
      Sql.fold_rows stmt ~init:[] ~f:(fun acc row ->
        let%bind version = Sql.required row 0 ~field:"version" in
        let%bind seed = Sql.required row 1 ~field:"seed" in
        let%bind session = Sql.required row 2 ~field:"session" in
        let%map depth = Sql.required row 4 ~field:"depth" in
        { version; seed; session; query = Sql.column_text row 3; depth } :: acc)
    in
    List.rev rows)
;;
