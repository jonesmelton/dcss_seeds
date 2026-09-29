open! Core

let check_rc here rc =
  match (rc : Sqlite3.Rc.t) with
  | Sqlite3.Rc.OK | Sqlite3.Rc.DONE -> ()
  | rc -> failwithf "%s: %s" here (Sqlite3.Rc.to_string rc) ()
;;

(* [Rc.to_string] renders BUSY (5) and BUSY_SNAPSHOT (517) identically as
   `BUSY`, and they want opposite operator responses: a plain BUSY waited out
   busy_timeout and waiting longer would have helped, while a snapshot conflict
   returns at once and needs a retry on a fresh read. The extended code is the
   label; sqlite's message and the failing statement are the rest.

   A schema or migration statement can be arbitrarily long, so the statement is
   truncated rather than dumped whole into the log. *)
let statement_for_log sql =
  if String.length sql <= 200 then sql else String.prefix sql 200 ^ "... (truncated)"
;;

let exec_script t sql =
  match Sqlite3.exec t sql with
  | Sqlite3.Rc.OK -> ()
  | rc ->
    let extended = Sqlite3.extended_errcode_int t in
    let name =
      match extended with
      | 517 -> "BUSY_SNAPSHOT"
      | _ -> Sqlite3.Rc.to_string rc
    in
    failwithf
      "exec_script failed: %s (%d): %s; statement: %s"
      name
      extended
      (Sqlite3.errmsg t)
      (statement_for_log sql)
      ()
;;

let in_txn t ~begin_ ~f =
  exec_script t begin_;
  match f t with
  | result ->
    exec_script t "commit";
    result
  | exception exn ->
    (try exec_script t "rollback" with
     | _ -> ());
    raise exn
;;

let with_txn t ~f = in_txn t ~begin_:"begin" ~f
let with_immediate_txn t ~f = in_txn t ~begin_:"begin immediate" ~f
let version_id_sql = "(select id from versions where version = ?)"
let string_id_sql = "(select id from strings where val = ?)"
let version_bind version = Sqlite3.Data.TEXT (Query.Version.to_string version)

let column_text row i =
  match (row : Sqlite3.Data.t array).(i) with
  | Sqlite3.Data.TEXT s -> Some s
  | Sqlite3.Data.NULL -> None
  | data -> Some (Sqlite3.Data.to_string_coerce data)
;;

let column_int row i =
  match (row : Sqlite3.Data.t array).(i) with
  | Sqlite3.Data.INT i -> Some (Int64.to_int_exn i)
  | Sqlite3.Data.NULL -> None
  | data -> Option.bind (Sqlite3.Data.to_int64 data) ~f:Int64.to_int
;;

let column_bool row i = Option.map (column_int row i) ~f:(fun i -> i <> 0)

let required row i ~field =
  match column_text row i with
  | Some s -> Ok s
  | None -> Or_error.errorf "%s is null" field
;;

let fold_rows stmt ~init ~f =
  let rec loop acc =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      (match f acc (Sqlite3.row_data stmt) with
       | Ok acc -> loop acc
       | Error _ as err -> err)
    | Sqlite3.Rc.DONE -> Ok acc
    | rc -> Or_error.errorf "step: %s" (Sqlite3.Rc.to_string rc)
  in
  loop init
;;

let with_stmt t sql ~bind ~f =
  match Sqlite3.prepare t sql with
  | exception exn -> Or_error.of_exn exn
  | stmt ->
    Exn.protect
      ~finally:(fun () -> ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t))
      ~f:(fun () ->
        match
          List.iteri bind ~f:(fun i data ->
            check_rc "bind" (Sqlite3.bind stmt (i + 1) data))
        with
        | exception exn -> Or_error.of_exn exn
        | () -> f stmt)
;;
