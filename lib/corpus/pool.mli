open! Core

(** A fixed set of read-only [Db.t] connections, checked out for one query.

    The problem is not concurrency on the Lwt scheduler -- [detach] handles
    that -- but concurrency underneath it. sqlite3-ocaml releases the runtime
    lock inside [sqlite3_step], so N connections on N preemptive workers run in
    parallel, where one shared connection serializes every detached search
    behind SQLite's own per-connection execution.

    Synchronous by construction: [lib/corpus] must not depend on Lwt, so
    checkout blocks the calling OS thread on a plain mutex and condition
    variable. Fine as long as callers are preemptive worker threads, which is
    the only shape {!with_conn} is meant for. *)

type t

val create : string -> size:int -> t

(** Callers must ensure no [with_conn] is in flight; there is no draining
    wait. *)
val close : t -> unit

(** Checks out a connection, runs [f], returns it whether [f] returns or raises.

    {b Saturation.} When every connection is out, this blocks the calling OS
    thread with no bound and no timeout. [bin/main.ml] sizes the
    [Lwt_preemptive] thread-pool cap to the same constant as the pool size, so a
    worker that would block here is itself a resource Lwt is already queueing
    behind -- this path is the safety net, not the mechanism, and only starts
    mattering if those two constants drift apart.

    {b Snapshot consistency.} Each connection has its own read snapshot, so two
    requests a moment apart can see different ones. Accepted for a read-mostly
    corpus. If several reads ever need to agree on one snapshot, the fix is
    connections sharing a deferred transaction begun at checkout, not a return
    to one connection. *)
val with_conn : t -> f:(Db.t -> 'a) -> 'a
