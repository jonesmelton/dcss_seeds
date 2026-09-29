open! Core

(* Plain mutex rather than a Core-flavoured queue: checkout happens inside
   [Lwt_preemptive] worker threads, which are OS threads blocking
   synchronously, so the primitive that blocks the underlying pthread is the
   correct one. Qualified because [Core] shadows [Mutex].

   The stdlib condition variable has no timed wait, so a bounded checkout polls
   rather than waiting on a signal. Saturation is the abnormal case -- the
   [Lwt_preemptive] thread-pool cap is sized to the pool size in [bin/main.ml],
   so a worker that finds every connection out is already the exception -- and
   polling only starts once it happens. *)
type t =
  { mutex : Stdlib.Mutex.t
  ; mutable free : Db.t list
  }

exception Saturated

let poll_seconds = 0.01

let create path ~size =
  if size <= 0 then failwithf "Pool.create: size must be positive, got %d" size ();
  let free = List.init size ~f:(fun _ -> Db.open_ ~readonly:true path) in
  { mutex = Stdlib.Mutex.create (); free }
;;

let close t =
  Stdlib.Mutex.lock t.mutex;
  List.iter t.free ~f:(fun db -> Db.close ~readonly:true db);
  t.free <- [];
  Stdlib.Mutex.unlock t.mutex
;;

let checkout t ~timeout =
  let deadline =
    Option.map timeout ~f:(fun seconds -> Caml_unix.gettimeofday () +. seconds)
  in
  let rec wait () =
    Stdlib.Mutex.lock t.mutex;
    match t.free with
    | db :: rest ->
      t.free <- rest;
      Stdlib.Mutex.unlock t.mutex;
      db
    | [] ->
      Stdlib.Mutex.unlock t.mutex;
      (match deadline with
       | Some d when Float.(Caml_unix.gettimeofday () >= d) -> raise Saturated
       | _ ->
         Caml_unix.sleepf poll_seconds;
         wait ())
  in
  wait ()
;;

let checkin t db =
  Stdlib.Mutex.lock t.mutex;
  t.free <- db :: t.free;
  Stdlib.Mutex.unlock t.mutex
;;

let with_conn ?timeout t ~f =
  let db = checkout t ~timeout in
  Exn.protect ~f:(fun () -> f db) ~finally:(fun () -> checkin t db)
;;
