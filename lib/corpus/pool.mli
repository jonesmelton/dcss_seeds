open! Core

(** A fixed set of read-only [Db.t] connections, checked out for one query.

    The problem is not concurrency on the Lwt scheduler -- [detach] handles
    that -- but concurrency underneath it. sqlite3-ocaml releases the runtime
    lock inside [sqlite3_step], so N connections on N preemptive workers run in
    parallel, where one shared connection serializes every detached search
    behind SQLite's own per-connection execution.

    Synchronous by construction: [lib/corpus] must not depend on Lwt, so
    checkout blocks the calling OS thread on a plain mutex. Fine as long as
    callers are preemptive worker threads, which is the only shape {!with_conn}
    is meant for. *)

type t

(** Raised by a bounded checkout that reached its deadline with every
    connection still out. *)
exception Saturated

val create : string -> size:int -> t

(** How many connections there are. The number that has to agree with the
    [Lwt_preemptive] thread cap, and with [Seed_web.Gate]'s size. *)
val size : t -> int

(** Callers must ensure no [with_conn] is in flight; there is no draining
    wait. *)
val close : t -> unit

(** Checks out a connection, runs [f], returns it whether [f] returns or raises.

    {b Saturation.} With no [timeout] this blocks the calling OS thread until a
    connection is free. [bin/main.ml] sizes the [Lwt_preemptive] thread-pool cap
    to the same constant as the pool size, and [Seed_web.Gate] is sized from
    {!size}, so a permit is taken before detaching and a worker that would block
    here is already a resource Lwt is queueing behind. The deadline is
    therefore the backstop, not the mechanism: it is unreachable while every
    pool user takes a permit first, and it starts mattering only if a caller
    skips the gate or the two constants drift apart. A [timeout] turns the wait
    into a deadline anyway: checkout raises {!Saturated} rather than blocking
    past it.

    {b Snapshot consistency.} Each connection has its own read snapshot, so two
    requests a moment apart can see different ones. Accepted for a read-mostly
    corpus. If several reads ever need to agree on one snapshot, the fix is
    connections sharing a deferred transaction begun at checkout, not a return
    to one connection. *)
val with_conn : ?timeout:float -> t -> f:(Db.t -> 'a) -> 'a
