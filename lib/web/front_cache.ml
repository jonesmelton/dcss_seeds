open! Core

type 'a entry =
  { value : 'a
  ; built : Time_ns.t
  }

type 'a t =
  { max_age : Time_ns.Span.t
  ; now : unit -> Time_ns.t
  ; build : string -> 'a Or_error.t Lwt.t
  ; entries : (string, 'a entry) Hashtbl.t
  ; pending : (string, 'a Or_error.t Lwt.t) Hashtbl.t
  }

let create ~max_age ~now ~build =
  { max_age
  ; now
  ; build
  ; entries = Hashtbl.create (module String)
  ; pending = Hashtbl.create (module String)
  }
;;

let refresh t ~key =
  match Hashtbl.find t.pending key with
  | Some building -> building
  | None ->
    let building =
      let%lwt result =
        Lwt.catch (fun () -> t.build key) (fun exn -> Lwt.return (Or_error.of_exn exn))
      in
      Hashtbl.remove t.pending key;
      (match result with
       | Ok value -> Hashtbl.set t.entries ~key ~data:{ value; built = t.now () }
       | Error _ -> ());
      Lwt.return result
    in
    if Lwt.is_sleeping building then Hashtbl.set t.pending ~key ~data:building;
    building
;;

let get t ~key =
  match Hashtbl.find t.entries key with
  | None -> refresh t ~key
  | Some { value; built } ->
    if Time_ns.Span.( > ) (Time_ns.diff (t.now ()) built) t.max_age
    then Lwt.async (fun () -> Lwt.map ignore (refresh t ~key));
    Lwt.return (Ok value)
;;
