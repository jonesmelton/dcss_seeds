open! Core

(** The SQLite plumbing {!Db} and {!Search_index} share: statement lifecycle,
    row accessors, transactions, and the two scalar subqueries that keep
    interned lookups covering.

    Extracted rather than duplicated because {!Search_index} cannot depend on
    {!Db} -- [Db.search_seeds] calls into it, so the dependency runs the other
    way. It holds no domain facts; those are in the modules that use it. *)

(** Raises [Failure] on the first failing statement, carrying the primary code,
    the extended code, sqlite's message, and the statement itself -- enough to
    tell BUSY (5) from BUSY_SNAPSHOT (517), which want different operator
    responses, and to say which statement took the lock. *)
val exec_script : Sqlite3.db -> string -> unit

(** Raises [Failure] naming [here] on anything but [OK] or [DONE]. *)
val check_rc : string -> Sqlite3.Rc.t -> unit

(** Not reentrant. *)
val with_txn : Sqlite3.db -> f:(Sqlite3.db -> 'a) -> 'a

(** Takes the write lock up front. Every read-then-write path uses this. *)
val with_immediate_txn : Sqlite3.db -> f:(Sqlite3.db -> 'a) -> 'a

(** Resolved as a scalar subquery, not a join on [versions]: the join form
    reorders the plan and adds a temp b-tree for distinct. *)
val version_id_sql : string

(** The dictionary lookup every interned predicate uses. Same reasoning as
    {!version_id_sql}: a scalar subquery keeps the covering seek on entries. *)
val string_id_sql : string

(** Binds the version string; {!version_id_sql} resolves it to an id. Nothing
    above storage learns that ids exist. *)
val version_bind : Query.Version.t -> Sqlite3.Data.t

val column_text : Sqlite3.Data.t array -> int -> string option
val column_int : Sqlite3.Data.t array -> int -> int option
val column_bool : Sqlite3.Data.t array -> int -> bool option
val required : Sqlite3.Data.t array -> int -> field:string -> string Or_error.t

val fold_rows
  :  Sqlite3.stmt
  -> init:'a
  -> f:('a -> Sqlite3.Data.t array -> 'a Or_error.t)
  -> 'a Or_error.t

val with_stmt
  :  Sqlite3.db
  -> string
  -> bind:Sqlite3.Data.t list
  -> f:(Sqlite3.stmt -> 'a Or_error.t)
  -> 'a Or_error.t
