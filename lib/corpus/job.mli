open! Core

(** A request to extract one seed deeper than the corpus holds it.

    Shallow is the corpus, deep is a request: a [Swamp:4] fill costs 5.4x the
    wall time and 4.5x the bytes of the [D:8] the corpus is filled at, so
    deepening every seed is not affordable at any corpus size worth having,
    while deepening the one seed a reader stopped on costs seconds.

    The queue is a table because the corpus is already the coordination point
    between the web process and the generator. *)

module State : sig
  (** Derived from the timestamps rather than stored, which keeps the states from
      disagreeing with the columns that produce them. *)
  type t =
    | Queued
    | Running
    | Done
    | Failed of string
  [@@deriving compare, equal, sexp_of]

  val to_string : t -> string
end

(** Who asked. A deepen extends a seed the corpus holds; a submission is a
    seed a reader named that it does not hold. Both are claimed from one queue,
    deepens first, so a flood of submissions cannot starve them. *)
module Origin : sig
  type t =
    | Deepen
    | Submit
  [@@deriving compare, equal, sexp_of]

  (** The [ingest_jobs.origin] spelling. *)
  val to_string : t -> string

  val of_string : string -> t Or_error.t
end

type t =
  { seed : string
  ; version : Query.Version.t
  ; depth : string
  ; queued_at : int
  ; started_at : int option
  ; finished_at : int option
  ; attempts : int
  ; error : string option
  ; origin : Origin.t
  }
[@@deriving sexp_of]

val state : t -> State.t

(** How long a claim may go unrefreshed before the job is presumed abandoned.

    Not a bet on how long a job takes. [started_at] is refreshed while crawl
    runs ([Db.refresh_claim]), so it measures the worker's liveness and this
    constant only has to exceed the refresh interval by a wide margin.

    It was a bet once, at 60s against a "~2.5s deep fill" measured as CPU time
    on an idle machine; real wall time is ~10s/seed at 4 workers and >60s at 8,
    so healthy jobs were reclaimed out from under live workers. A fixed timeout
    cannot express "still working" for a job whose duration scales with load. *)
val reclaim_after : Time_float.Span.t

(** How many times a job may *fail* before it is failed outright.

    Without a bound, a seed that reliably crashes crawl clears its claim, is
    reclaimed, and crashes again forever.  A job at the limit records its error
    and stays claimed, so it leaves the queue rather than consuming it.

    Only a real non-zero exit counts and a successful finish resets the counter,
    so this bounds *consecutive* failures. A reclaim does not count, so a worker
    that dies mid-job loops forever; catching that needs a separate counter and
    is not worth a column until it happens. *)
val max_attempts : int

val is_abandoned : t -> now:int -> bool
