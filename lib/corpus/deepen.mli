open! Core

(** What the generator needs to know that is not process control.

    The generator itself is [bin/deepen.ml]: it claims a job, runs crawl for one
    seed, and records the outcome. **The web process must not run crawl.** It
    has no build tree and no sandbox, and storage is synchronous, so the tens of
    seconds a deep fill costs would stall every concurrent request.

    A generator serves the versions it has build trees for and declares them
    through [Db.heartbeat], which is what lets the web process refuse a request
    nothing can serve. Jobs for a version it cannot build are left unclaimed,
    not errored: a different generator may serve them. *)

module Build : sig
  (** A provisioned crawl for one version: [builds/<version>/crawl-ref/source]
      with a runnable [crawl] in it, and the sandbox it writes to. *)
  type t =
    { version : Query.Version.t
    ; source : string
    ; sandbox : string
    }
  [@@deriving sexp_of]

  (** Says nothing about whether they exist; [bin/deepen.ml] checks that, since
      only it looks at the filesystem. *)
  val of_version : root:string -> version:Query.Version.t -> t
end

(** The shell pipeline that extracts one seed, identical to what
    [tools/corpus-fill] runs with a chunk of one, so there is one extraction
    path rather than two.

    Everything crawl writes that is not [#SEED#]-prefixed is noise, which is
    what the grep is for; [fake_pty] is because crawl will not run without a
    tty.

    [db_path] and [ingest] must be absolute. The pipeline [cd]s into the build
    tree, so a relative corpus path resolves there -- and since ingest creates a
    database it does not find, the failure is a stray empty file in [builds/]
    and a job failing with "no such table: versions".

    The pipeline's exit status is its last stage's, so a crawl crash surfaces as
    ingest reading nothing and succeeding. Caught downstream instead:
    [Db.write_batch] recomputes fill depth from the levels that landed, so a
    partial extraction shows up as a seed that never reached its cap. *)
val extract_command
  :  Build.t
  -> seed:string
  -> depth:string
  -> db_path:string
  -> ingest:string
  -> string

(** How often the generator looks at its child and refreshes its claim. 120x
    under [Job.reclaim_after]. The refresh is a write and takes the same lock as
    everything else, which is why it is a tick and not a spin. *)
val tick : Time_float.Span.t

(** How long a child may run before it is killed and the job reported as a
    timeout.

    A second bound, not the only one: [fake_pty] already kills crawl after 60s
    with no output and carries a hard one-hour [alarm]. This bounds the queue's
    latency, so it sits well under that hour to be the one that fires. Crawl
    bounds level generation at 50 attempts and terminates rather than spinning,
    so a job running far past the median is pathological. *)
val timeout : Time_float.Span.t

(** How long a killed process group gets between [SIGTERM] and [SIGKILL].

    The group, not the pid: the extraction is a shell pipeline, and killing the
    shell leaves crawl running and still writing rows through an ingest that
    outlives its parent. That ingest must also be *reaped*, not merely
    signalled -- it holds the corpus's write lock until it is gone, so a worker
    that signals and immediately claims again walks into its own
    [busy_timeout]. *)
val kill_grace : Time_float.Span.t

module Outcome : sig
  (** How a pass ended. Three of these were one error string and they are
      opposite operator actions: a lost claim means looking at the generator, a
      timeout at the seed, and a non-zero exit at the status. *)
  type t =
    | Finished
    | Timed_out
    | Exited of string
    | Claim_lost
  [@@deriving sexp_of]

  (** What to record on the job row, as [Db.finish_job]'s [error].

      [`Nothing] is [Claim_lost]: the row belongs to another worker now. The
      extraction is not discarded with it -- levels that landed are real and
      [seed_fills] records them. *)
  val record : t -> [ `Record of string option | `Nothing ]

  (** What to tell the operator, which is not what goes on the row: a lost claim
      is worth seeing even though it is not the job's failure. *)
  val to_string : t -> string
end

(** Run one pass of the generator's loop, turning any exception into a logged
    error rather than an exit.

    Every *expected* failure is already logged and skipped. An exception is the
    inconsistency: [Db.with_immediate_txn] re-raises after rolling back, so a
    [SQLITE_BUSY] past [busy_timeout] would take the whole generator down with
    no supervisor to restart it.

    Returns whether the pass did work, so a failed pass sleeps rather than
    spinning. Nothing here retries: the claim stays claimed and stops being
    refreshed, so reclaim gives it back after [Job.reclaim_after] at no cost in
    attempts. *)
val guard : on_error:(string -> unit) -> (unit -> bool) -> bool

(** Where the fill lock for [db_path] lives.

    [tools/corpus-fill] holds this for a whole fill and the generator yields to
    it, so the path is derived rather than configured -- three processes
    agreeing by construction. [FILL_LOCK] overrides it in the shell script only,
    for tests. *)
val fill_lock_path : db_path:string -> string
