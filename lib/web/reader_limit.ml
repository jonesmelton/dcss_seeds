open! Core

type t =
  { per_ip : int
  ; per_session : int
  ; mutable day : int
  ; by_ip : int String.Table.t
  ; by_session : int String.Table.t
  }

let create ~per_ip ~per_session =
  { per_ip
  ; per_session
  ; day = Int.min_value
  ; by_ip = String.Table.create ()
  ; by_session = String.Table.create ()
  }
;;

let roll t ~day =
  if t.day <> day
  then (
    t.day <- day;
    Hashtbl.clear t.by_ip;
    Hashtbl.clear t.by_session)
;;

let count table key = Hashtbl.find table key |> Option.value ~default:0

let check t ~day ~ip ~session =
  roll t ~day;
  if count t.by_session session >= t.per_session
  then `Session_cap
  else if count t.by_ip ip >= t.per_ip
  then `Ip_cap
  else `Ok
;;

let record t ~day ~ip ~session =
  roll t ~day;
  Hashtbl.incr t.by_ip ip;
  Hashtbl.incr t.by_session session
;;

let without_port peer =
  match String.chop_prefix peer ~prefix:"[" with
  | Some rest -> String.lsplit2 rest ~on:']' |> Option.value_map ~default:peer ~f:fst
  | None ->
    (match String.lsplit2 peer ~on:':' with
     | Some (host, port) when not (String.mem port ':') -> host
     | _ -> peer)
;;

let client_address ~forwarded_for ~peer =
  match
    Option.bind forwarded_for ~f:(fun header ->
      String.split header ~on:',' |> List.last |> Option.map ~f:String.strip)
  with
  | Some address when not (String.is_empty address) -> address
  | _ -> without_port peer
;;
