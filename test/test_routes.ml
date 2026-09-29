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
   database that happens to share a name.

   [heartbeat] controls what [/health] sees: [`Fresh] (the default, matching
   every pre-existing test) is within [Seed_web.heartbeat_window]; [`Stale] is
   just outside it; [`None] writes no heartbeat row at all. [records] (default
   [true]) skips seeding seeds 100 and 200, for a corpus with the schema but
   nothing in it. *)
let with_corpus ?(heartbeat = `Fresh) ?(records = true) ~f () =
  let path = Filename_unix.temp_file "routes" ".db" in
  let writer = Db.open_ path in
  Db.exec_script writer (In_channel.read_all "../schema.sql");
  let version = Served.to_version Served.current in
  if records
  then (
    let records =
      List.concat_map [ "100"; "200" ] ~f:(fun seed ->
        List.map [ "D:1"; "D:2" ] ~f:(fun level ->
          Or_error.ok_exn
            (Reader.parse_line
               (line ~seed ~level ~version:(Seed_corpus.Query.Version.to_string version)))))
    in
    ignore (Db.write_batch writer records : Db.Counts.t));
  (* /health reads back a generator heartbeat and answers 503 without one, so a
     corpus with rows but no heartbeat is still an unservable corpus. *)
  (match heartbeat with
   | `None -> ()
   | (`Fresh | `Stale) as heartbeat ->
     let now = Float.to_int (Core_unix.time ()) in
     let stamp =
       match heartbeat with
       | `Fresh -> now
       | `Stale -> now - Seed_web.heartbeat_window - 1
     in
     Or_error.ok_exn
       (Db.heartbeat writer ~generator_id:"test" ~versions:[ version ] ~now:stamp));
  let reader = Db.open_ path in
  let pool = Pool.create path ~size:2 in
  let lock_path = Seed_corpus.Deepen.fill_lock_path ~db_path:path in
  Fun.protect
    ~finally:(fun () ->
      Db.close reader;
      Db.close writer;
      Pool.close pool;
      Sys_unix.remove path)
    (fun () ->
       f
         ~handle:
           (Dream.test
              (Seed_web.head_as_get
                 (Seed_web.security_headers
                    (Seed_web.router ~reader ~writer ~pool ~lock_path))))
         ~writer
         ~lock_path)
;;

let with_router ~f = with_corpus ~f:(fun ~handle ~writer:_ ~lock_path:_ -> f handle) ()
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
    /robots.txt          GET body 129  HEAD body 0  HEAD content-length 129
    /sitemap.xml         GET body 482  HEAD body 0  HEAD content-length 482
    /0.34.1/             GET body 5727  HEAD body 0  HEAD content-length 5727
    /0.34.1/about        GET body 4232  HEAD body 0  HEAD content-length 4232
    /0.34.1/search/help  GET body 11548  HEAD body 0  HEAD content-length 11548
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

(* deepen_disabled withdraws the offer, not just the button under it: the
   depth note falls through to the same [filling_note] a live fill renders,
   with no form and no poll. *)
let%expect_test "deepen_disabled withdraws the button and the poll" =
  with_router ~f:(fun handle ->
    let target = sprintf "/%s/seed/100" (Served.to_string Served.current) in
    let disabled = !Seed_web.Params.deepen_disabled in
    Fun.protect
      ~finally:(fun () -> Seed_web.Params.deepen_disabled := disabled)
      (fun () ->
         Seed_web.Params.deepen_disabled := true;
         let body =
           Lwt_main.run (Dream.body (handle (Dream.request ~method_:`GET ~target "")))
         in
         printf
           "filling note %b\n"
           (String.is_substring body ~substring:"Deeper searches are paused");
         printf "deepen form  %b\n" (String.is_substring body ~substring:"/deepen");
         printf "polling      %b\n" (String.is_substring body ~substring:"hx-trigger")));
  [%expect
    {|
    filling note true
    deepen form  false
    polling      false
    |}]
;;

(* The fill lock gates the write, not just the button -- and so does the
   disable: a POST carrying a valid CSRF token from a page rendered before the
   restart must still be refused, and nothing may land in the queue. *)
let%expect_test "deepen_disabled refuses the write, not just the button" =
  with_corpus
    ~f:(fun ~handle:_ ~writer ~lock_path ->
      let version = Served.to_version Served.current in
      let disabled = !Seed_web.Params.deepen_disabled in
      Fun.protect
        ~finally:(fun () -> Seed_web.Params.deepen_disabled := disabled)
        (fun () ->
           Seed_web.Params.deepen_disabled := true;
           (match
              Seed_web.deepen_outcome
                writer
                ~lock_path
                ~version
                ~seed:"100"
                ~now:(Float.to_int (Core_unix.time ()))
            with
            | `Filling -> print_endline "outcome: filling"
            | `Queued -> print_endline "outcome: queued"
            | `Already_queued _ -> print_endline "outcome: already queued"
            | `Queue_full -> print_endline "outcome: queue full"
            | `No_generator -> print_endline "outcome: no generator"
            | `Failed err -> printf "outcome: failed (%s)\n" (Error.to_string_hum err));
           match Db.job_for_seed writer ~version ~seed:"100" with
           | Ok None -> print_endline "queue: still empty"
           | Ok (Some _) -> print_endline "queue: NOT empty"
           | Error err -> printf "queue read failed (%s)\n" (Error.to_string_hum err)))
    ();
  [%expect
    {|
    outcome: filling
    queue: still empty
    |}]
;;

let value_after s ~key ~until =
  let i = String.substr_index_exn s ~pattern:key in
  String.drop_prefix s (i + String.length key) |> String.take_while ~f:(Fn.non until)
;;

let seed_page_token handle =
  let target = sprintf "/%s/seed/100" (Served.to_string Served.current) in
  let response = handle (Dream.request ~method_:`GET ~target "") in
  let body = Lwt_main.run (Dream.body response) in
  let input =
    String.split body ~on:'<'
    |> List.find_exn ~f:(String.is_substring ~substring:"dream.csrf")
  in
  let token = value_after input ~key:"value=\"" ~until:(Char.equal '"') in
  let cookie =
    Dream.header response "Set-Cookie"
    |> Option.value_exn
    |> String.lsplit2_exn ~on:';'
    |> fst
  in
  token, cookie
;;

let%expect_test "the deepen form's token passes Dream's form check" =
  with_router ~f:(fun handle ->
    let token, cookie = seed_page_token handle in
    let target = sprintf "/%s/seed/100/deepen" (Served.to_string Served.current) in
    let response =
      handle
        (Dream.request
           ~method_:`POST
           ~target
           ~headers:
             [ "Cookie", cookie; "Content-Type", "application/x-www-form-urlencoded" ]
           ("dream.csrf=" ^ token))
    in
    printf "%d\n" (status_of response));
  [%expect {| 200 |}]
;;

(* Dream's default token lifetime is an hour, and a seed page is a tab readers
   leave open and come back to. Observed in production 2026-09-23: a POST from a
   page rendered 17h earlier was refused as expired. *)
let%expect_test "a deepen token lives as long as the session" =
  with_router ~f:(fun handle ->
    let token, _ = seed_page_token handle in
    let plaintext =
      Dream.from_base64url token
      |> Option.value_exn
      |> Dream.decrypt ~associated_data:"dream.csrf" (Dream.request "")
      |> Option.value_exn
    in
    let expires_at =
      value_after plaintext ~key:"\"expires_at\":" ~until:(fun c ->
        not (Char.is_digit c || Char.equal c '.'))
      |> Float.of_string
    in
    let days = (expires_at -. Core_unix.time ()) /. 86_400. in
    printf "valid for more than 13 days: %b\n" Float.(days > 13.));
  [%expect {| valid for more than 13 days: true |}]
;;

(* [/health]'s read-only body must be a database signal, not the compiled-in
   served set: the fixture ingests only [Served.current] (0.34.1), while
   [Served.all] lists all three served builds, so an implementation that
   echoed [Served.all] unconditionally would print three versions here and
   fail. That asymmetry is the entire point of this test -- a bare prefix
   check on "read-only" cannot catch it, which is why the body is asserted in
   full. Also keeps the serving-side "no generator" coverage from the same
   stale-heartbeat fixture, showing the two branches disagree on the same
   corpus. *)
let%expect_test "/health on a read-only instance answers what the corpus holds" =
  with_corpus
    ~heartbeat:`Stale
    ~f:(fun ~handle ~writer:_ ~lock_path:_ ->
      let get () = handle (Dream.request ~method_:`GET ~target:"/health" "") in
      let disabled = !Seed_web.Params.deepen_disabled in
      Fun.protect
        ~finally:(fun () -> Seed_web.Params.deepen_disabled := disabled)
        (fun () ->
           Seed_web.Params.deepen_disabled := false;
           let response = get () in
           let body = Lwt_main.run (Dream.body response) in
           printf "serving:   %d %s\n" (status_of response) (String.strip body);
           Seed_web.Params.deepen_disabled := true;
           let response = get () in
           let body = Lwt_main.run (Dream.body response) in
           printf
             "read-only: %d %s\n"
             (status_of response)
             (String.strip body |> String.split ~on:'\n' |> String.concat ~sep:" ")))
    ();
  [%expect
    {|
    serving:   503 no generator
    read-only: 200 read-only 0.34.1
    |}]
;;

(* A schema-only corpus (no records, no heartbeat) must answer differently
   depending on why: 503 "no generator" is about liveness and does not apply
   read-only, where 503 "no seeds" says the database opened and answered but
   holds nothing this binary serves -- the case [populated_versions] exists to
   catch. Same fixture, both branches, so the distinction is provably real. *)
let%expect_test "/health on an empty corpus: no seeds, not no generator" =
  with_corpus
    ~records:false
    ~heartbeat:`None
    ~f:(fun ~handle ~writer:_ ~lock_path:_ ->
      let get () = handle (Dream.request ~method_:`GET ~target:"/health" "") in
      let disabled = !Seed_web.Params.deepen_disabled in
      Fun.protect
        ~finally:(fun () -> Seed_web.Params.deepen_disabled := disabled)
        (fun () ->
           Seed_web.Params.deepen_disabled := false;
           let response = get () in
           let body = Lwt_main.run (Dream.body response) in
           printf "serving:   %d %s\n" (status_of response) (String.strip body);
           Seed_web.Params.deepen_disabled := true;
           let response = get () in
           let body = Lwt_main.run (Dream.body response) in
           printf "read-only: %d %s\n" (status_of response) (String.strip body)))
    ();
  [%expect
    {|
    serving:   503 no generator
    read-only: 503 no seeds
    |}]
;;

let search_target has =
  sprintf
    "/%s/search?%s"
    (Served.to_string Served.current)
    (List.map has ~f:(fun t -> "has=" ^ Dream.to_percent_encoded t)
     |> String.concat ~sep:"&")
;;

let get ?(headers = []) handle target =
  let response = handle (Dream.request ~method_:`GET ~target ~headers "") in
  status_of response, Lwt_main.run (Dream.body response)
;;

let has body substring = String.is_substring body ~substring

(* A typo in one box must not cost the reader the others: logs show readers
   iterating one query five or six times in a row. *)
let%expect_test "a rejected search keeps every term in its box" =
  with_router ~f:(fun handle ->
    let status, body = get handle (search_target [ "potion:haste"; "potion:" ]) in
    printf "status %d\n" status;
    printf "valid term kept   %b\n" (has body {|value="potion:haste"|});
    printf "invalid term kept %b\n" (has body {|value="potion:"|});
    printf "error shown       %b\n" (has body "not a &lt;base&gt;:&lt;sub&gt; item");
    printf "announced         %b\n" (has body {|role="alert"|});
    printf "box marked        %b\n" (has body {|aria-invalid="true"|});
    printf "box described     %b\n" (has body {|aria-describedby="term-1-problem"|});
    printf "full page         %b\n" (has body "<!DOCTYPE html>"));
  [%expect
    {|
    status 400
    valid term kept   true
    invalid term kept true
    error shown       true
    announced         true
    box marked        true
    box described     true
    full page         true
    |}]
;;

(* htmx 4 swaps a 4xx like a 2xx (only 204 and 304 are in [noSwap]), so the
   fragment shape is what a scripted reader sees: the form out of band, since
   the swap targets the results. *)
let%expect_test "a rejected htmx search answers in the fragment's shape" =
  with_router ~f:(fun handle ->
    let status, body =
      get
        handle
        ~headers:[ "HX-Request", "true" ]
        (search_target [ "potion:haste"; "potion:" ])
    in
    printf "status %d\n" status;
    printf "fragment     %b\n" (not (has body "<!DOCTYPE html>"));
    printf "form oob     %b\n" (has body "hx-swap-oob");
    printf
      "terms kept   %b\n"
      (has body {|value="potion:haste"|} && has body {|value="potion:"|});
    printf "title        %b\n" (has body "<title>search within seeds</title>"));
  [%expect
    {|
    status 400
    fragment     true
    form oob     true
    terms kept   true
    title        true
    |}]
;;

let%expect_test "a rejected term is rendered as text, never markup" =
  with_router ~f:(fun handle ->
    let status, body = get handle (search_target [ "<script>alert(1)</script>:" ]) in
    printf "status %d\n" status;
    printf "raw markup %b\n" (has body "<script>alert"));
  [%expect
    {|
    status 400
    raw markup false
    |}]
;;

let%expect_test "a bad limit re-renders the form with the terms" =
  with_router ~f:(fun handle ->
    let status, body = get handle (search_target [ "potion:haste" ] ^ "&limit=ten") in
    printf "status %d\n" status;
    printf "term kept  %b\n" (has body {|value="potion:haste"|});
    printf "error      %b\n" (has body "not a number"));
  [%expect
    {|
    status 400
    term kept  true
    error      true
    |}]
;;

let with_indexed_router ~f =
  with_corpus
    ~f:(fun ~handle ~writer ~lock_path:_ ->
      Or_error.ok_exn
        (Db.build_search_index writer ~version:(Served.to_version Served.current));
      f handle)
    ()
;;

(* The fixture holds one item type, potion:haste. *)
let%expect_test "a bare word naming one item runs, and says what ran" =
  with_indexed_router ~f:(fun handle ->
    let status, body = get handle (search_target [ "haste" ]) in
    printf "status %d\n" status;
    printf "box teaches the term %b\n" (has body {|value="potion:haste"|});
    printf "echoed               %b\n" (has body "was read as");
    printf "matched              %b\n" (has body {|href="/0.34.1/seed/100"|}));
  [%expect
    {|
    status 200
    box teaches the term true
    echoed               true
    matched              true
    |}]
;;

let%expect_test "an unknown bare word offers name~ as a link, keeping the other terms" =
  with_indexed_router ~f:(fun handle ->
    let status, body = get handle (search_target [ "potion:haste"; "spectral" ]) in
    printf "status %d\n" status;
    printf "offer link %b\n" (has body "has=potion%3Ahaste&amp;has=name~spectral"));
  [%expect
    {|
    status 400
    offer link true
    |}]
;;
