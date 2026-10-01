open! Core

(** Admission control for detached corpus work: at most [size] searches are in
    flight, and the rest wait in Lwt rather than in [Lwt_preemptive]'s queue.

    {b The queue this exists to bound.} [Lwt_preemptive.detach] hands work to a
    worker thread and pauses the request without blocking the scheduler, but its
    queue is unbounded: in lwt 6.1.2 [get_worker] suspends on an unbounded
    sequence and [set_max_number_of_threads_queued] is vestigial -- the setter
    exists and [get_worker] never consults it. With the thread cap set to the
    pool size, that queue is where a burst accumulates: measured at 200 RPS
    against a 1.3M corpus, searches waited ~46s for a slot that
    [SEED_POOL_TIMEOUT] was supposed to bound at 5s, and the cheap routes lost
    their Caddy upstream connections behind them (prod, 0.34.1, 2026-09-30).

    [Pool.with_conn]'s own deadline cannot be that bound. Checkout happens
    {i inside} the detached computation, so a worker slot and a connection are
    taken at the same instant and the pool's free list is never empty when a
    worker runs; the deadline is unreachable and the request waits out
    [SEED_SEARCH_TIMEOUT] instead. Acquiring a permit {i before} detaching is
    what makes it reachable.

    {b Not a substitute for the pool.} A permit is not a connection. The two are
    sized from the same constant ([Pool.size]) and every detached pool user
    takes a permit first, so a permit holder can only ever find a connection
    free. Sizing them apart restores the queue above with extra steps.

    {b Release is tied to the work, not to the promise.} See {!with_permit}. *)
type t

(** [size] must equal the pool's size; [Seed_corpus.Pool.size] is where it comes
    from. *)
val create : size:int -> t

(** Takes a permit, waiting at most [timeout] for one. Never queues past
    [timeout], and never blocks the calling thread: the wait is a condition
    variable with a deadline. The caller must eventually {!release}. *)
val acquire : t -> timeout:float -> [ `Admitted | `Saturated ] Lwt.t

(** Returns a permit to the pool, or hands it directly to the longest-waiting
    acquirer. Only ever called for a permit that was taken. *)
val release : t -> unit

(** [acquire] then run [f] under the permit, returning [`Saturated] without
    calling [f] if none was free in time.

    The permit is released when [f]'s promise {i resolves}, not when the caller
    stops waiting on it. That distinction is the point: [answer_search] races
    this against [SEED_SEARCH_TIMEOUT] with [Lwt.pick], so an abandoned search
    goes on occupying its worker thread and its pool connection until it
    finishes. Releasing at cancellation instead would admit a search into a pool
    that is still full, which is the queue {!acquire} exists to bound.

    Consequently an exception out of [f] still releases, and so does a promise
    the caller never observes. *)
val with_permit
  :  t
  -> timeout:float
  -> f:(unit -> 'a Lwt.t)
  -> [ `Admitted of 'a | `Saturated ] Lwt.t
