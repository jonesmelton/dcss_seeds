open! Core

(* Plain mutex/condition rather than a Core-flavoured queue: checkout happens
   inside Lwt_preemptive worker threads, which are OS threads blocking
   synchronously, so the primitive that blocks the underlying pthread is the
   correct one. Qualified because [Core] shadows [Mutex]. *)
type t =
  { mutex : Stdlib.Mutex.t
  ; condition : Stdlib.Condition.t
  ; mutable free : Db.t list
  }

let create path ~size =
  if size <= 0 then failwithf "Pool.create: size must be positive, got %d" size ();
  let free = List.init size ~f:(fun _ -> Db.open_ ~readonly:true path) in
  { mutex = Stdlib.Mutex.create (); condition = Stdlib.Condition.create (); free }
;;

let close t =
  Stdlib.Mutex.lock t.mutex;
  List.iter t.free ~f:(fun db -> Db.close ~readonly:true db);
  t.free <- [];
  Stdlib.Mutex.unlock t.mutex
;;

let checkout t =
  Stdlib.Mutex.lock t.mutex;
  let rec wait () =
    match t.free with
    | db :: rest ->
      t.free <- rest;
      Stdlib.Mutex.unlock t.mutex;
      db
    | [] ->
      (* Blocks the calling OS thread until [checkin] signals. No bound, no timeout;
         see the .mli's saturation note. *)
      Stdlib.Condition.wait t.condition t.mutex;
      wait ()
  in
  wait ()
;;

let checkin t db =
  Stdlib.Mutex.lock t.mutex;
  t.free <- db :: t.free;
  Stdlib.Condition.signal t.condition;
  Stdlib.Mutex.unlock t.mutex
;;

let with_conn t ~f =
  let db = checkout t in
  Exn.protect ~f:(fun () -> f db) ~finally:(fun () -> checkin t db)
;;
