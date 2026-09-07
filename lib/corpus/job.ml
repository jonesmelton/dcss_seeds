open! Core

module State = struct
  type t =
    | Queued
    | Running
    | Done
    | Failed of string
  [@@deriving compare, equal, sexp_of]

  let to_string = function
    | Queued -> "queued"
    | Running -> "running"
    | Done -> "done"
    | Failed _ -> "failed"
  ;;
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
  }
[@@deriving sexp_of]

(* An error is what makes a job failed, not the presence of finished_at: a job
   past its attempt limit records the error and stays claimed. *)
let state t =
  match t.error, t.started_at, t.finished_at with
  | Some error, _, _ -> State.Failed error
  | None, _, Some _ -> State.Done
  | None, Some _, None -> State.Running
  | None, None, None -> State.Queued
;;

let reclaim_after = Time_float.Span.of_sec 600.
let max_attempts = 3

let is_abandoned t ~now =
  match t.error, t.started_at, t.finished_at with
  | None, Some started_at, None ->
    now - started_at > Float.to_int (Time_float.Span.to_sec reclaim_after)
  | _ -> false
;;
