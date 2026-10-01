open! Core

(* State is touched only from the Lwt scheduler thread: [acquire] runs on it by
   construction, and [release] is called from a [Lwt.try_bind] continuation,
   which is where a detached search's promise resolves. Nothing here needs a
   lock, which is what keeps [free] and the waiter queue consistent with each
   other -- the pool's own mutex is for the worker threads that block on it. *)
type t =
  { mutable free : int
  ; waiters : unit Lwt_condition.t
  }

let create ~size =
  if size <= 0 then failwithf "Gate.create: size must be positive, got %d" size ();
  { free = size; waiters = Lwt_condition.create () }
;;

let release t =
  (* Increment and signal, rather than handing the permit to a named waiter:
     [Lwt_condition] offers no way to ask whether anyone is queued, and a waiter
     whose wait was cancelled at its deadline must not carry a permit away with
     it. A woken waiter re-reads [free], so a permit a fresh arrival takes first
     is not lost -- that arrival's own release signals again. *)
  t.free <- t.free + 1;
  Lwt_condition.signal t.waiters ()
;;

let acquire t ~timeout =
  let deadline = Core_unix.time () +. timeout in
  let rec wait () =
    let remaining = deadline -. Core_unix.time () in
    if Float.(remaining <= 0.)
    then Lwt.return `Saturated
    else if t.free > 0
    then (
      t.free <- t.free - 1;
      Lwt.return `Admitted)
    else (
      (* [Lwt.pick] cancels the loser, and cancelling a [Lwt_condition.wait]
         removes it from the queue -- which is what makes a timed-out waiter
         safe to abandon rather than something a later release could wake into
         a permit nobody spends. *)
      let%lwt () = Lwt.pick [ Lwt_condition.wait t.waiters; Lwt_unix.sleep remaining ] in
      wait ())
  in
  wait ()
;;

let with_permit t ~timeout ~f =
  let%lwt admitted = acquire t ~timeout in
  match admitted with
  | `Saturated -> Lwt.return `Saturated
  | `Admitted ->
    (* [Lwt.try_bind], not [Lwt.finalize]: the permit covers the *work*, not the
       promise. [answer_search] races the run against [SEED_SEARCH_TIMEOUT] with
       [Lwt.pick], which cancels this promise while the query keeps running on
       its worker thread holding a pool connection; releasing on cancellation
       would readmit a search into a pool that is still full. *)
    Lwt.try_bind
      f
      (fun value ->
         release t;
         Lwt.return (`Admitted value))
      (fun exn ->
         release t;
         Lwt.fail exn)
;;
