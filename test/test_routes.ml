open! Core
module Db = Seed_corpus.Db
module Pool = Seed_corpus.Pool
module Reader = Seed_corpus.Reader
module Served = Seed_web.Served

let line ~seed ~level ~version =
  sprintf
    {|#SEED#((format 4)(version "%s")(seed "%s")(level "%s")(cats (items (((base_type "potion")(kind "item")(name "potion of haste")(quantity 1)(sub_type "haste")(text "potion of haste")(x 3)(y 4))))))|}
    version
    seed
    level
;;

(* File-backed, not [:memory:]: [Pool.create] takes a path and opens its own
   connections, so an in-memory corpus would leave the pool reading an empty
   database that happens to share a name. *)
let with_router ~f =
  let path = Filename_unix.temp_file "routes" ".db" in
  let writer = Db.open_ path in
  Db.exec_script writer (In_channel.read_all "../schema.sql");
  let version = Served.to_version Served.current in
  let records =
    List.concat_map [ "100"; "200" ] ~f:(fun seed ->
      List.map [ "D:1"; "D:2" ] ~f:(fun level ->
        Or_error.ok_exn
          (Reader.parse_line
             (line ~seed ~level ~version:(Seed_corpus.Query.Version.to_string version)))))
  in
  ignore (Db.write_batch writer records : Db.Counts.t);
  (* /health reads back a generator heartbeat and answers 503 without one, so a
     corpus with rows but no heartbeat is still an unservable corpus. *)
  Or_error.ok_exn
    (Db.heartbeat
       writer
       ~generator_id:"test"
       ~versions:[ version ]
       ~now:(Float.to_int (Core_unix.time ())));
  let reader = Db.open_ path in
  let pool = Pool.create path ~size:2 in
  Fun.protect
    ~finally:(fun () ->
      Db.close reader;
      Db.close writer;
      Sys_unix.remove path)
    (fun () ->
       f
         (Dream.test
            (Seed_web.head_as_get
               (Seed_web.security_headers
                  (Seed_web.router
                     ~reader
                     ~writer
                     ~pool
                     ~lock_path:(Seed_corpus.Deepen.fill_lock_path ~db_path:path))))))
;;

let status_of response = Dream.status response |> Dream.status_to_int

(* The paths a reader or a crawler reaches without being handed a link, which
   is what makes them the ones an outage shows up on first. *)
let public_paths =
  let v = Served.to_string Served.current in
  [ "/"
  ; "/health"
  ; "/robots.txt"
  ; "/sitemap.xml"
  ; sprintf "/%s/" v
  ; sprintf "/%s/about" v
  ; sprintf "/%s/search/help" v
  ]
;;

let%expect_test "GET answers every public path" =
  with_router ~f:(fun handle ->
    List.iter public_paths ~f:(fun target ->
      let response = handle (Dream.request ~method_:`GET ~target "") in
      printf "%-20s %d\n" target (status_of response)));
  [%expect
    {|
    /                    303
    /health              200
    /robots.txt          200
    /sitemap.xml         200
    /0.34.1/             200
    /0.34.1/about        200
    /0.34.1/search/help  200
    |}]
;;

(* RFC 9110 section 9.3.2: HEAD must answer with the status and headers GET
   would, and no body. Unfurlers, uptime monitors and link checkers send it, so
   a 404 here is invisible in a browser and visible everywhere a link is
   pasted. [Dream.router] dispatches on method, so a table of [Dream.get]
   routes sends every HEAD to the catch-all unless something rewrites it. *)
let%expect_test "HEAD matches GET status on every public path" =
  with_router ~f:(fun handle ->
    List.iter public_paths ~f:(fun target ->
      let get = handle (Dream.request ~method_:`GET ~target "") in
      let head = handle (Dream.request ~method_:`HEAD ~target "") in
      printf
        "%-20s GET %d  HEAD %d  %s\n"
        target
        (status_of get)
        (status_of head)
        (if status_of get = status_of head then "ok" else "MISMATCH")));
  [%expect
    {|
    /                    GET 303  HEAD 303  ok
    /health              GET 200  HEAD 200  ok
    /robots.txt          GET 200  HEAD 200  ok
    /sitemap.xml         GET 200  HEAD 200  ok
    /0.34.1/             GET 200  HEAD 200  ok
    /0.34.1/about        GET 200  HEAD 200  ok
    /0.34.1/search/help  GET 200  HEAD 200  ok
    |}]
;;

(* The body is the half of the contract a status check does not cover: a HEAD
   that answers 200 and then sends the page is still wrong, and httpaf's
   [body_length] does not strip it for us. *)
let%expect_test "HEAD sends no body but reports the length GET would" =
  with_router ~f:(fun handle ->
    List.iter public_paths ~f:(fun target ->
      let get = handle (Dream.request ~method_:`GET ~target "") in
      let head = handle (Dream.request ~method_:`HEAD ~target "") in
      let body response = Lwt_main.run (Dream.body response) in
      printf
        "%-20s GET body %d  HEAD body %d  HEAD content-length %s\n"
        target
        (String.length (body get))
        (String.length (body head))
        (Option.value (Dream.header head "Content-Length") ~default:"(none)")));
  [%expect
    {|
    /                    GET body 0  HEAD body 0  HEAD content-length 0
    /health              GET body 7  HEAD body 0  HEAD content-length 7
    /robots.txt          GET body 138  HEAD body 0  HEAD content-length 138
    /sitemap.xml         GET body 545  HEAD body 0  HEAD content-length 545
    /0.34.1/             GET body 5859  HEAD body 0  HEAD content-length 5859
    /0.34.1/about        GET body 3854  HEAD body 0  HEAD content-length 3854
    /0.34.1/search/help  GET body 8739  HEAD body 0  HEAD content-length 8739
    |}]
;;

(* Ranked [shallowest] so the search detaches: the timeout is an Lwt race and
   the cheap path runs inline on the scheduler thread, where no timer can fire.
   That is the mechanism's real limit, not a property of this fixture -- a
   search [is_cheap] misjudges is one the timeout cannot shed. *)
let%expect_test "search over its time budget answers a styled 503" =
  with_router ~f:(fun handle ->
    let target =
      sprintf
        "/%s/search?has=potion:haste&rank=shallowest"
        (Served.to_string Served.current)
    in
    let budget = !Seed_web.Params.search_timeout in
    Fun.protect
      ~finally:(fun () -> Seed_web.Params.search_timeout := budget)
      (fun () ->
         Seed_web.Params.search_timeout := 0.;
         let response = handle (Dream.request ~method_:`GET ~target "") in
         (* The handler logs the shed with a wall-clock stamp; drop it so the
            expectation is stable, having already confirmed it is emitted. *)
         [%expect.output] |> (ignore : string -> unit);
         printf "status %d\n" (status_of response);
         printf
           "retry-after %s\n"
           (Option.value (Dream.header response "Retry-After") ~default:"(none)");
         let body = Lwt_main.run (Dream.body response) in
         printf "styled %b\n" (String.is_substring body ~substring:"<!DOCTYPE html>")));
  [%expect
    {|
    status 503
    retry-after 300
    styled true
    |}]
;;

(* A generous budget must not shed a query that answers, which is the half of
   the contract that a 503-on-zero test cannot show. *)
let%expect_test "search within its time budget answers normally" =
  with_router ~f:(fun handle ->
    let target =
      sprintf "/%s/search?has=potion:haste" (Served.to_string Served.current)
    in
    let response = handle (Dream.request ~method_:`GET ~target "") in
    printf "status %d\n" (status_of response));
  [%expect {| status 200 |}]
;;

(* The vocabulary scan is minutes long on the real corpus, so a cold cache must
   render the page without it rather than await it. The datalist is absent on
   the first search and present once the background scan lands. *)
let%expect_test "cold datalist renders the search page without suggestions" =
  with_router ~f:(fun handle ->
    let target =
      sprintf "/%s/search?has=potion:haste" (Served.to_string Served.current)
    in
    Seed_web.criteria_cache_clear ();
    let cold =
      Lwt_main.run (Dream.body (handle (Dream.request ~method_:`GET ~target "")))
    in
    printf "cold datalist %b\n" (String.is_substring cold ~substring:"term-suggestions");
    Seed_web.criteria_cache_wait ();
    let warm =
      Lwt_main.run (Dream.body (handle (Dream.request ~method_:`GET ~target "")))
    in
    printf "warm datalist %b\n" (String.is_substring warm ~substring:"term-suggestions"));
  [%expect
    {|
    cold datalist false
    warm datalist true
    |}]
;;
