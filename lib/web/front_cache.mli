open! Core

(** Per-key values rebuilt in the background once they are older than
    [max_age]. A stale value keeps being served until its replacement lands, so
    only a cold key ever waits on [build], and concurrent waiters on one key
    share a single build. A failed build is not cached: a cold key answers the
    error and the next [get] tries again; a stale key keeps its old value.

    State is touched only from the Lwt scheduler thread; [build] is where any
    detaching happens. *)

type 'a t

val create
  :  max_age:Time_ns.Span.t
  -> now:(unit -> Time_ns.t)
  -> build:(string -> 'a Or_error.t Lwt.t)
  -> 'a t

val get : 'a t -> key:string -> 'a Or_error.t Lwt.t
