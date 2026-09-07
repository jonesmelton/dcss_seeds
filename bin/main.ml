let env name ~default =
  match Sys.getenv_opt name with
  | None | Some "" -> default
  | Some s -> s
;;

let () =
  let port =
    let s = env "SEED_PORT" ~default:"8430" in
    match int_of_string_opt s with
    | Some n -> n
    | None ->
      Printf.eprintf "SEED_PORT: invalid value %S\n%!" s;
      exit 1
  in
  let interface = env "SEED_INTERFACE" ~default:"localhost" in
  let db_path = env "SEED_DB" ~default:"corpus.db" in
  let pool_size =
    let s = env "SEED_POOL_SIZE" ~default:"4" in
    match int_of_string_opt s with
    | Some n when n > 0 -> n
    | _ ->
      Printf.eprintf "SEED_POOL_SIZE: invalid value %S\n%!" s;
      exit 1
  in
  (* Escape hatch to take search down entirely; see fossil ticket 093f82b4a9. *)
  (match Sys.getenv_opt "SEED_DISABLE_SEARCH" with
   | Some ("1" | "true" | "yes") -> Seed_web.Params.search_disabled := true
   | _ -> ());
  if not (Sys.file_exists db_path)
  then (
    Printf.eprintf
      "no corpus at %S — create one with `just db %s` and ingest into it\n%!"
      db_path
      db_path;
    exit 1);
  (* Two connections, not one. Reads hold deferred transactions for their
     snapshot and a search may run detached on a worker thread, so the deepen
     enqueue takes its own handle rather than waiting behind either. See
     docs/architecture.md, "Writer stance". *)
  let reader = Seed_corpus.Db.open_ db_path in
  let writer = Seed_corpus.Db.open_ db_path in
  (* One connection per Lwt_preemptive worker thread, and the thread-pool cap
     raised to match: Lwt's default is 4, so a larger pool would sit behind a
     scheduler that never sends it more than 4 concurrent detached queries. Both
     numbers come from [pool_size] so they cannot drift -- see [Pool]'s
     saturation note, which is only true while they agree. *)
  Lwt_preemptive.set_bounds (0, pool_size);
  let pool = Seed_corpus.Pool.create db_path ~size:pool_size in
  (* Sessions exist for one reason: Dream's CSRF token is bound to one, and the
     deepen button is the app's only mutation. Cookie-backed, so there is no
     server-side store.

     Without SEED_SECRET Dream generates one per process, which invalidates
     every open page's token on restart. *)
  let secret =
    match Sys.getenv_opt "SEED_SECRET" with
    | Some secret when secret <> "" -> [ Dream.set_secret secret ]
    | _ -> []
  in
  let middlewares =
    [ Dream.logger ] @ secret @ [ Dream.cookie_sessions; Seed_web.security_headers ]
  in
  (* Probe the port before Dream takes it. Catching [Dream.run]'s failure is too
     late: Dream's logger has already printed the Lwt backtrace by then.

     [interface] is a name, not an address, and the default "localhost" resolves
     to ::1 before 127.0.0.1 -- so probing a hardcoded IPv4 loopback tests an
     address Dream is not about to bind. *)
  (let addrs =
     Unix.getaddrinfo interface (string_of_int port) [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
   in
   List.iter
     (fun (ai : Unix.addr_info) ->
        let probe = Unix.socket ai.ai_family ai.ai_socktype ai.ai_protocol in
        Fun.protect
          ~finally:(fun () -> Unix.close probe)
          (fun () ->
             match Unix.bind probe ai.ai_addr with
             | () -> ()
             | exception Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
               Printf.eprintf
                 "port %d is already in use on %s — stop what is on it, or set SEED_PORT\n\
                  %!"
                 port
                 interface;
               exit 1))
     addrs);
  Dream.run ~interface ~port ~error_handler:Seed_web.error_page
  @@ List.fold_right (fun m rest -> m rest) middlewares
  @@ Seed_web.router
       ~reader
       ~writer
       ~pool
       ~lock_path:(Seed_corpus.Deepen.fill_lock_path ~db_path)
;;
