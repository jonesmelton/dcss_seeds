open! Core

let () = Seed_web.Views.canned_order := Fn.id

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
(* [extra] appends raw records to the standard two-seed fixture, for a test
   that needs one thing the fixture does not carry. *)
let with_corpus
      ?(heartbeat = `Fresh)
      ?(records = true)
      ?(extra = [])
      ?feedback_path
      ?flag_limit
      ~f
      ()
  =
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
      @ List.map extra ~f:(fun line -> Or_error.ok_exn (Reader.parse_line line))
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
  let feedback =
    Option.map feedback_path ~f:(Seed_corpus.Feedback.open_ ~key:"test-key")
  in
  Fun.protect
    ~finally:(fun () ->
      Option.iter feedback ~f:Seed_corpus.Feedback.close;
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
                    (Seed_web.router
                       ?flag_limit
                       ~feedback
                       ~reader
                       ~writer
                       ~pool
                       ~lock_path))))
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
    /0.34.1/             GET body 5361  HEAD body 0  HEAD content-length 5361
    /0.34.1/about        GET body 4329  HEAD body 0  HEAD content-length 4329
    /0.34.1/search/help  GET body 7714  HEAD body 0  HEAD content-length 7714
    |}]
;;

(* Ranked [shallowest] so the timeout race is exercised on a path that runs a
   real query; every search detaches now, so any rank would do. The timeout is
   an Lwt race and the scheduler has to be free to lose it. *)
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

let%expect_test "the seed list serves the corpus, and ?limit= draws from the same pool" =
  with_router ~f:(fun handle ->
    let seeds target =
      let body =
        Lwt_main.run (Dream.body (handle (Dream.request ~method_:`GET ~target "")))
      in
      List.filter [ "100"; "200" ] ~f:(fun seed ->
        String.is_substring body ~substring:(sprintf "class=\"seed\">%s<" seed))
    in
    let v = Served.to_string Served.current in
    let show target = String.concat ~sep:" " (seeds target) in
    printf "default: %s\n" (show (sprintf "/%s/" v));
    printf "again: %s\n" (show (sprintf "/%s/" v));
    printf "limit=1 count: %d\n" (List.length (seeds (sprintf "/%s/?limit=1" v))));
  [%expect
    {|
    default: 100 200
    again: 100 200
    limit=1 count: 1
    |}]
;;

(* The vocabulary scan is minutes long on the real corpus, so a cold cache must
   render the page without it rather than await it. The datalist is absent on
   the first search and present once the background scan lands. *)
let%expect_test "cold datalist renders the search page without suggestions" =
  with_router ~f:(fun handle ->
    let target =
      sprintf "/%s/search?has=potion:haste" (Served.to_string Served.current)
    in
    Seed_web.criteria_cache_wait ();
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

let seed_page_token ?(seed = "100") handle =
  let target = sprintf "/%s/seed/%s" (Served.to_string Served.current) seed in
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

let brand_line ~seed ~level ~version =
  sprintf
    {|#SEED#((format 4)(version "%s")(seed "%s")(level "%s")(cats (items (((base_type "weapon")(branded t)(ego "distort")(kind "item")(name "quick blade of distortion")(plus 0)(quantity 1)(sub_type "quick blade")(text "quick blade of distortion")(x 3)(y 4))))))|}
    version
    seed
    level
;;

(* End to end: the parse, the store, and the rendered hit line, which names the
   item the way the game does rather than echoing the term. *)
let%expect_test "a brand search runs and names the item" =
  let version = Served.to_version Served.current in
  with_corpus
    ~extra:
      [ brand_line
          ~seed:"300"
          ~level:"D:1"
          ~version:(Seed_corpus.Query.Version.to_string version)
      ]
    ~f:(fun ~handle ~writer ~lock_path:_ ->
      Or_error.ok_exn (Db.build_search_index writer ~version);
      let status, body =
        get handle (search_target [ "weapon:quick blade ego:distortion" ])
      in
      printf "status %d\n" status;
      printf "hit          %b\n" (has body {|href="/0.34.1/seed/300?from=|});
      printf "named        %b\n" (has body "quick blade of distortion");
      printf "term echoed  %b\n" (has body {|value="weapon:quick blade ego:distortion"|}))
    ();
  [%expect
    {|
    status 200
    hit          true
    named        true
    term echoed  true
    |}]
;;

(* The fixture holds one item type, potion:haste. *)
let%expect_test "a bare word naming one item runs, and says what ran" =
  with_indexed_router ~f:(fun handle ->
    let status, body = get handle (search_target [ "haste" ]) in
    printf "status %d\n" status;
    printf "box teaches the term %b\n" (has body {|value="potion:haste"|});
    printf "echoed               %b\n" (has body "was read as");
    printf "matched              %b\n" (has body {|href="/0.34.1/seed/100?from=|}));
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

(* {1 The count ceiling}

   Seeds 100 and 200 each hold one potion of haste on D:1 and one on D:2, so
   the most any seed holds is 2. *)

let after s ~marker =
  Option.map (String.substr_index s ~pattern:marker) ~f:(fun i ->
    String.drop_prefix s (i + String.length marker))
;;

(* The [has=] value of the first link after the ceiling sentence, decoded. *)
let ceiling_link_term body =
  let open Option.Let_syntax in
  let%bind rest = after body ~marker:"the most any seed" in
  let%bind rest = after rest ~marker:{|href="|} in
  let href = String.take_while rest ~f:(fun c -> not (Char.equal c '"')) in
  let%bind query = after href ~marker:"?" in
  let%bind has =
    String.split query ~on:'&'
    |> List.find_map ~f:(fun kv -> String.chop_prefix kv ~prefix:"has=")
  in
  Some (Dream.from_percent_encoded has)
;;

let%expect_test "an impossible count names the build's ceiling, and links to it" =
  with_router ~f:(fun handle ->
    let status, body = get handle (search_target [ "3x potion:haste" ]) in
    [%expect.output] |> (ignore : string -> unit);
    printf "status %d\n" status;
    printf "no matches %b\n" (has body "No matching seeds.");
    printf "ceiling    %b\n" (has body "the most any seed");
    Option.iter (after body ~marker:{|<p class="ceiling">|}) ~f:(fun rest ->
      print_endline (String.prefix rest (String.substr_index_exn rest ~pattern:"</p>")));
    match ceiling_link_term body with
    | None -> print_endline "no link"
    | Some term ->
      printf "link term  %s\n" term;
      printf
        "parses to  %s\n"
        (match
           Seed_web.Params.term_of_string
             ~version:(Or_error.ok_exn (Seed_corpus.Query.Version.of_string "0.34.1"))
             term
         with
         | Ok term -> Seed_corpus.Search.Term.to_query_string term
         | Error err -> Error.to_string_hum err));
  [%expect
    {|
    status 200
    no matches true
    ceiling    true
    <strong>The count is out of reach on its own.</strong> For potion of haste, the most any seed in this build holds is <strong><span class="num">2</span></strong>, short of the <span class="num">3</span> asked for. <a href="/0.34.1/search?has=2x%20potion%3Ahaste">Search for <code>2x potion:haste</code> →</a>
    link term  2x potion:haste
    parses to  2x potion:haste
    |}]
;;

(* A swap replaces the results div, so the fragment has to carry it too. *)
let%expect_test "the htmx fragment carries the ceiling" =
  with_router ~f:(fun handle ->
    let status, body =
      get ~headers:[ "HX-Request", "true" ] handle (search_target [ "3x potion:haste" ])
    in
    [%expect.output] |> (ignore : string -> unit);
    printf "status %d\n" status;
    printf "ceiling %b\n" (has body "the most any seed"));
  [%expect
    {|
    status 200
    ceiling true
    |}]
;;

(* [2x] is reachable on its own, so the emptiness is the conjunction's and the
   ceiling would explain nothing. *)
let%expect_test "a satisfiable count beside an unmet term says nothing more" =
  with_router ~f:(fun handle ->
    let status, body =
      get handle (search_target [ "2x potion:haste"; "shop potion:haste" ])
    in
    [%expect.output] |> (ignore : string -> unit);
    printf "status %d\n" status;
    printf "no matches %b\n" (has body "No matching seeds.");
    printf "ceiling    %b\n" (has body "the most any seed"));
  [%expect
    {|
    status 200
    no matches true
    ceiling    false
    |}]
;;

let%expect_test "the store answers the ceiling too" =
  with_indexed_router ~f:(fun handle ->
    let status, body = get handle (search_target [ "3x potion:haste" ]) in
    [%expect.output] |> (ignore : string -> unit);
    printf "status %d\n" status;
    printf "link term %s\n" (Option.value (ceiling_link_term body) ~default:"none"));
  [%expect
    {|
    status 200
    link term 2x potion:haste
    |}]
;;

(* The budget is its own ref so this path is reachable: sharing
   [search_timeout] would time the search out first. *)
let%expect_test "a ceiling over its budget degrades to the plain message" =
  with_router ~f:(fun handle ->
    let budget = !Seed_web.Params.ceiling_timeout in
    Fun.protect
      ~finally:(fun () -> Seed_web.Params.ceiling_timeout := budget)
      (fun () ->
         Seed_web.Params.ceiling_timeout := 0.;
         let status, body = get handle (search_target [ "3x potion:haste" ]) in
         [%expect.output] |> (ignore : string -> unit);
         printf "status %d\n" status;
         printf "no matches %b\n" (has body "No matching seeds.");
         printf "ceiling    %b\n" (has body "the most any seed")));
  [%expect
    {|
    status 200
    no matches true
    ceiling    false
    |}]
;;

let deep_seed_line =
  line
    ~seed:"300"
    ~level:Seed_corpus.Fill_depth.deep_cap
    ~version:(Seed_corpus.Query.Version.to_string (Served.to_version Served.current))
;;

let with_feedback ?flag_limit ~f () =
  let path = Filename_unix.temp_file "flags" ".db" in
  Fun.protect
    ~finally:(fun () -> Sys_unix.remove path)
    (fun () ->
       with_corpus
         ?flag_limit
         ~feedback_path:path
         ~extra:[ deep_seed_line ]
         ~f:(fun ~handle ~writer:_ ~lock_path:_ -> f handle path)
         ())
;;

let flags_in path =
  let fb = Seed_corpus.Feedback.open_ ~key:"test-key" path in
  Fun.protect
    ~finally:(fun () -> Seed_corpus.Feedback.close fb)
    (fun () -> Or_error.ok_exn (Seed_corpus.Feedback.rows fb))
;;

let post_flag
      ?(version = Served.to_string Served.current)
      ?(seed = "100")
      handle
      ~cookie
      body
  =
  handle
    (Dream.request
       ~method_:`POST
       ~target:(sprintf "/%s/seed/%s/flag" version seed)
       ~headers:[ "Cookie", cookie; "Content-Type", "application/x-www-form-urlencoded" ]
       body)
;;

let%expect_test "a flag records the build name, seed, hashed session and query" =
  with_feedback () ~f:(fun handle path ->
    let token, cookie = seed_page_token handle in
    let response =
      post_flag
        handle
        ~cookie
        (sprintf "dream.csrf=%s&from=has%%3Dpotion%%253Ahaste" token)
    in
    printf "%d\n" (status_of response);
    List.iter (flags_in path) ~f:(fun row ->
      printf
        "%s %s session=%d chars query=%s depth=%s\n"
        row.version
        row.seed
        (String.length row.session)
        (Option.value row.query ~default:"-")
        row.depth));
  [%expect
    {|
    200
    0.34.1 100 session=64 chars query=has=potion%3Ahaste depth=D:2
    |}]
;;

let%expect_test "a second flag in the same session adds no row and still succeeds" =
  with_feedback () ~f:(fun handle path ->
    let token, cookie = seed_page_token handle in
    let body = sprintf "dream.csrf=%s" token in
    printf "%d\n" (status_of (post_flag handle ~cookie body));
    printf "%d\n" (status_of (post_flag handle ~cookie body));
    printf "rows %d\n" (List.length (flags_in path)));
  [%expect
    {|
    200
    200
    rows 1
    |}]
;;

let%expect_test "a flag without a valid token is refused and writes nothing" =
  let quiet sources level = List.iter sources ~f:(fun s -> Dream.set_log_level s level) in
  let sources = [ "dream.form"; "dream.csrf" ] in
  Fun.protect ~finally:(fun () -> quiet sources `Warning)
  @@ fun () ->
  quiet sources `Error;
  with_feedback () ~f:(fun handle path ->
    let _, cookie = seed_page_token handle in
    printf "no token  %d\n" (status_of (post_flag handle ~cookie "from=x"));
    printf "bad token %d\n" (status_of (post_flag handle ~cookie "dream.csrf=nope"));
    printf "rows %d\n" (List.length (flags_in path)));
  [%expect
    {|
    no token  400
    bad token 400
    rows 0
    |}]
;;

let%expect_test "an unserved build and an absent seed are 404 and write nothing" =
  with_feedback () ~f:(fun handle path ->
    let token, cookie = seed_page_token handle in
    let body = sprintf "dream.csrf=%s" token in
    printf "unserved %d\n" (status_of (post_flag handle ~cookie ~version:"9.99" body));
    printf "absent   %d\n" (status_of (post_flag handle ~cookie ~seed:"999" body));
    printf "rows %d\n" (List.length (flags_in path)));
  [%expect
    {|
    unserved 404
    absent   404
    rows 0
    |}]
;;

let%expect_test "with no feedback file the page has no button and the POST is a 404" =
  with_router ~f:(fun handle ->
    let token, cookie = seed_page_token handle in
    let target = sprintf "/%s/seed/100" (Served.to_string Served.current) in
    let body =
      Lwt_main.run (Dream.body (handle (Dream.request ~method_:`GET ~target "")))
    in
    printf "button %b\n" (String.is_substring body ~substring:"/flag");
    printf
      "post   %d\n"
      (status_of (post_flag handle ~cookie (sprintf "dream.csrf=%s" token))));
  [%expect
    {|
    button false
    post   404
    |}]
;;

(* A deep seed has no deepen offer and so no token of its own; the flag button
   needs one in exactly that case. *)
let%expect_test "a deep seed still renders the flag button, and its token works" =
  with_feedback () ~f:(fun handle path ->
    let target = sprintf "/%s/seed/300" (Served.to_string Served.current) in
    let body =
      Lwt_main.run (Dream.body (handle (Dream.request ~method_:`GET ~target "")))
    in
    printf "button %b\n" (String.is_substring body ~substring:"/seed/300/flag");
    printf "deepen %b\n" (String.is_substring body ~substring:"/deepen");
    let token, cookie = seed_page_token ~seed:"300" handle in
    printf
      "post   %d\n"
      (status_of (post_flag handle ~cookie ~seed:"300" (sprintf "dream.csrf=%s" token)));
    printf "rows   %d\n" (List.length (flags_in path)));
  [%expect
    {|
    button true
    deepen false
    post   200
    rows   1
    |}]
;;

let%expect_test "an overlong from is truncated, not rejected" =
  with_feedback () ~f:(fun handle path ->
    let token, cookie = seed_page_token handle in
    let response =
      post_flag
        handle
        ~cookie
        (sprintf "dream.csrf=%s&from=%s" token (String.make 600 'a'))
    in
    printf "%d\n" (status_of response);
    List.iter (flags_in path) ~f:(fun row ->
      printf "%d\n" (String.length (Option.value_exn row.query))));
  [%expect
    {|
    200
    500
    |}]
;;

let%expect_test "the seed page is canonical without its from parameter" =
  with_feedback () ~f:(fun handle _ ->
    let target =
      sprintf "/%s/seed/100?from=has%%3Dpotion" (Served.to_string Served.current)
    in
    let body =
      Lwt_main.run (Dream.body (handle (Dream.request ~method_:`GET ~target "")))
    in
    let link =
      String.split body ~on:'<'
      |> List.find_exn ~f:(String.is_substring ~substring:"canonical")
    in
    print_endline (String.strip link);
    printf "hidden from carried %b\n" (String.is_substring body ~substring:"has=potion"));
  [%expect
    {|
    link rel="canonical" href="https://dcss.garden/0.34.1/seed/100"/>
    hidden from carried true
    |}]
;;

let%expect_test "search results link to the seed carrying the query" =
  with_feedback () ~f:(fun handle _ ->
    let body =
      Lwt_main.run
        (Dream.body
           (handle
              (Dream.request ~method_:`GET ~target:(search_target [ "potion:haste" ]) "")))
    in
    String.split body ~on:'"'
    |> List.filter ~f:(String.is_substring ~substring:"/seed/100?from=")
    |> List.dedup_and_sort ~compare:String.compare
    |> List.iter ~f:print_endline);
  [%expect {| /0.34.1/seed/100?from=has%3Dpotion%253Ahaste |}]
;;

let%expect_test "a flagged seed shows the confirmation on reload, to that session only" =
  with_feedback () ~f:(fun handle _ ->
    let token, cookie = seed_page_token handle in
    ignore (post_flag handle ~cookie (sprintf "dream.csrf=%s" token) : Dream.response);
    let target = sprintf "/%s/seed/100" (Served.to_string Served.current) in
    let page headers =
      Lwt_main.run (Dream.body (handle (Dream.request ~method_:`GET ~target ~headers "")))
    in
    let describe label body =
      printf
        "%-7s noted %b  form %b\n"
        label
        (String.is_substring body ~substring:"Noted")
        (String.is_substring body ~substring:"/seed/100/flag")
    in
    describe "same" (page [ "Cookie", cookie ]);
    describe "other" (page []));
  [%expect
    {|
    same    noted true  form false
    other   noted false  form true
    |}]
;;

(* The community garden. Flags are written straight to the file rather than
   through the POST, so a test can create the duplicate-across-sessions case
   without minting two cookie jars. *)
let community_target = sprintf "/%s/community" (Served.to_string Served.current)

let flag_direct path ~seed ~session =
  let feedback = Seed_corpus.Feedback.open_ ~key:"test-key" path in
  Fun.protect
    ~finally:(fun () -> Seed_corpus.Feedback.close feedback)
    (fun () ->
       Or_error.ok_exn
         (Seed_corpus.Feedback.flag
            feedback
            ~version:(Served.to_version Served.current)
            ~seed
            ~session_id:session
            ~query:None
            ~depth:"D:2"))
;;

(* No feedback store means no garden to point at, so no link either. *)
let%expect_test "with no feedback file the garden 404s and the nav offers no link" =
  with_router ~f:(fun handle ->
    let status, _ = get handle community_target in
    let _, index = get handle (sprintf "/%s/" (Served.to_string Served.current)) in
    printf "garden %d\n" status;
    printf "link   %b\n" (has index "community garden"));
  [%expect
    {|
    garden 404
    link   false
    |}]
;;

(* One seed flagged by two sessions is one row, not two: the garden is a set of
   seeds, and [sample_seeds] has to collapse the per-session flags. *)
let%expect_test "the garden lists each flagged seed once, and links to itself" =
  with_feedback () ~f:(fun handle path ->
    flag_direct path ~seed:"100" ~session:"s1";
    flag_direct path ~seed:"100" ~session:"s2";
    flag_direct path ~seed:"200" ~session:"s3";
    let status, body = get handle community_target in
    let rows seed =
      String.substr_index_all
        body
        ~may_overlap:false
        ~pattern:(sprintf "class=\"seed\">%s<" seed)
      |> List.length
    in
    printf "status %d\n" status;
    printf "seed 100 rows %d\n" (rows "100");
    printf "seed 200 rows %d\n" (rows "200");
    printf "nav link %b\n" (has body "/community"));
  [%expect
    {|
    status 200
    seed 100 rows 1
    seed 200 rows 1
    nav link true
    |}]
;;

(* The feedback file outlives the corpus it was written against, so a flag can
   name a seed the served build does not hold. It is dropped, not rendered as
   an empty row pointing at a 404. *)
let%expect_test "a flag for a seed the corpus does not hold is not listed" =
  with_feedback () ~f:(fun handle path ->
    flag_direct path ~seed:"100" ~session:"s1";
    flag_direct path ~seed:"999" ~session:"s2";
    let _, body = get handle community_target in
    printf "held    %b\n" (has body "class=\"seed\">100<");
    printf "unheld  %b\n" (has body "class=\"seed\">999<"));
  [%expect
    {|
    held    true
    unheld  false
    |}]
;;

(* "No seeds for this build yet" would be false -- the build has seeds, none
   flagged -- so the empty garden says what it actually knows. *)
let%expect_test "an empty garden says so rather than claiming the build is empty" =
  with_feedback () ~f:(fun handle _ ->
    let status, body = get handle community_target in
    printf "status %d\n" status;
    printf "empty  %b\n" (has body "marked good on this build yet"));
  [%expect
    {|
    status 200
    empty  true
    |}]
;;

(* The garden reuses the front page's shape, so "community" has to be two
   questions kept apart: whether the nav link exists (the store is configured)
   and whether this wall *is* the garden. Conflated, the front page titled
   itself "community garden" and claimed its seeds were reader-picked. *)
let%expect_test "the front page keeps its own title and caption with the store on" =
  with_feedback () ~f:(fun handle _ ->
    let _, body = get handle (sprintf "/%s/" (Served.to_string Served.current)) in
    printf "title    %b\n" (has body "<title>dcss garden</title>");
    printf "caption  %b\n" (has body "A random sample of seeds from this build.");
    printf "nav link %b\n" (has body "/community"));
  [%expect
    {|
    title    true
    caption  true
    nav link true
    |}]
;;

(* The href of the anchor whose text is [More →]. *)
let more_href body =
  let text = String.substr_index_exn body ~pattern:"More →" in
  let close = String.rindex_from_exn body text '"' in
  let open_ = String.rindex_from_exn body (close - 1) '"' in
  String.sub body ~pos:(open_ + 1) ~len:(close - open_ - 1)
;;

(* The garden's "more" link is an address a reader can follow, and it 404'd
   twice over: the href carried a trailing slash the route does not have, and it
   was offered on a build holding fewer flags than a page -- where the pool is
   one page and there is nothing behind it. *)
let%expect_test "the garden offers more only when there is more, and it resolves" =
  with_feedback () ~f:(fun handle path ->
    flag_direct path ~seed:"100" ~session:"s1";
    flag_direct path ~seed:"200" ~session:"s2";
    let _, whole = get handle community_target in
    printf "one page: more %b\n" (has whole "More →");
    let _, paged = get handle (community_target ^ "?limit=1") in
    printf "paged:    more %b\n" (has paged "More →");
    let href = more_href paged in
    printf "href:     %s\n" href;
    let status, _ = get handle href in
    printf "follow:   %d\n" status);
  [%expect
    {|
    one page: more false
    paged:    more true
    href:     /0.34.1/community?limit=1
    follow:   200
    |}]
;;

(* {1 Submissions} *)

let submit handle ~token ~cookie seed =
  let target = sprintf "/%s/seed/%s/submit" (Served.to_string Served.current) seed in
  handle
    (Dream.request
       ~method_:`POST
       ~target
       ~headers:
         [ "Cookie", cookie
         ; "Content-Type", "application/x-www-form-urlencoded"
         ; "HX-Request", "true"
         ]
       ("dream.csrf=" ^ token))
;;

let body_of response = Lwt_main.run (Dream.body response)

let summarise response =
  let body = body_of response in
  printf
    "%d form=%b queued=%b to=%s paused=%b\n"
    (status_of response)
    (String.is_substring body ~substring:"/submit\"")
    (String.is_substring body ~substring:"Queued to generate")
    (Option.value
       ~default:"-"
       (Option.first_some
          (Dream.header response "HX-Redirect")
          (Dream.header response "Location")))
    (String.is_substring body ~substring:"is paused")
;;

let%expect_test "a missing seed offers to generate it; a malformed one does not" =
  with_router ~f:(fun handle ->
    List.iter [ "12345"; "007"; "0"; "18446744073709551616"; "abc" ] ~f:(fun seed ->
      let target = sprintf "/%s/seed/%s" (Served.to_string Served.current) seed in
      printf "%-22s " seed;
      summarise (handle (Dream.request ~method_:`GET ~target ""))));
  [%expect
    {|
    12345                  404 form=true queued=false to=- paused=false
    007                    404 form=false queued=false to=- paused=false
    0                      404 form=false queued=false to=- paused=false
    18446744073709551616   404 form=false queued=false to=- paused=false
    abc                    404 form=false queued=false to=- paused=false
    |}]
;;

let%expect_test "a submission queues a job, and polling follows it to the seed" =
  with_corpus
    ~f:(fun ~handle ~writer ~lock_path:_ ->
      let token, cookie = seed_page_token ~seed:"12345" handle in
      summarise (submit handle ~token ~cookie "12345");
      (match
         Or_error.ok_exn
           (Db.job_for_seed
              writer
              ~version:(Served.to_version Served.current)
              ~seed:"12345")
       with
       | None -> print_endline "no job"
       | Some job -> print_endline (Seed_corpus.Job.Origin.to_string job.origin));
      (* A second press is the same job, not a second one. *)
      summarise (submit handle ~token ~cookie "12345");
      let poll () =
        let target =
          sprintf "/%s/seed/12345/submission" (Served.to_string Served.current)
        in
        summarise
          (handle (Dream.request ~method_:`GET ~target ~headers:[ "Cookie", cookie ] ""))
      in
      poll ();
      ignore
        (Db.write_batch
           ~requested:true
           writer
           [ Or_error.ok_exn
               (Reader.parse_line
                  (line
                     ~seed:"12345"
                     ~level:"D:1"
                     ~version:
                       (Seed_corpus.Query.Version.to_string
                          (Served.to_version Served.current))))
           ]
         : Db.Counts.t);
      poll ();
      (* A held seed is the deepen path's: the page is the seed's own. *)
      summarise (submit handle ~token ~cookie "100"))
    ();
  [%expect
    {|
    200 form=false queued=true to=- paused=false
    submit
    200 form=false queued=true to=- paused=false
    200 form=false queued=true to=- paused=false
    303 form=false queued=false to=/0.34.1/seed/12345 paused=false
    200 form=false queued=false to=/0.34.1/seed/100 paused=false
    |}]
;;

let%expect_test "a session is capped per day, and the cap is said in words" =
  with_router ~f:(fun handle ->
    let token, cookie = seed_page_token ~seed:"12345" handle in
    (* In order: [List.init] makes no promise about evaluation order. *)
    let outcomes =
      List.fold (List.range 0 11) ~init:[] ~f:(fun acc i ->
        let response = submit handle ~token ~cookie (Int.to_string (5000 + i)) in
        (status_of response, body_of response) :: acc)
      |> List.rev
    in
    List.iter (List.drop outcomes 9) ~f:(fun (status, body) ->
      printf "%d limit=%b\n" status (String.is_substring body ~substring:"limit"));
    [%expect
      {|
      200 limit=false
      429 limit=true
      |}])
;;

(* The shape a browser took on dcss.garden 2026-10-04: each submission from a
   freshly loaded 404 page with its own token, then the poll, carrying whatever
   cookie the last response set. Thirteen were queued and none refused. *)
let%expect_test "the session cap holds across page loads, as a browser submits" =
  with_router ~f:(fun handle ->
    let jar = ref None in
    let cookies = ref [] in
    let send ~method_ ~target body =
      let headers =
        Option.value_map !jar ~default:[] ~f:(fun c -> [ "Cookie", c ])
        @ [ "Content-Type", "application/x-www-form-urlencoded" ]
      in
      let response = handle (Dream.request ~method_ ~target ~headers body) in
      Option.iter (Dream.header response "Set-Cookie") ~f:(fun set ->
        let c = fst (String.lsplit2_exn set ~on:';') in
        jar := Some c;
        cookies := c :: !cookies);
      response
    in
    let version = Served.to_string Served.current in
    let outcomes =
      List.fold (List.range 0 11) ~init:[] ~f:(fun acc i ->
        let seed = Int.to_string (6000 + i) in
        let page = send ~method_:`GET ~target:(sprintf "/%s/seed/%s" version seed) "" in
        let input =
          String.split (body_of page) ~on:'<'
          |> List.find_exn ~f:(String.is_substring ~substring:"dream.csrf")
        in
        let token = value_after input ~key:"value=\"" ~until:(Char.equal '"') in
        let response =
          send
            ~method_:`POST
            ~target:(sprintf "/%s/seed/%s/submit" version seed)
            ("dream.csrf=" ^ token)
        in
        let outcome = status_of response, body_of response in
        ignore
          (send ~method_:`GET ~target:(sprintf "/%s/seed/%s/submission" version seed) ""
           : Dream.response);
        outcome :: acc)
      |> List.rev
    in
    List.iter (List.drop outcomes 9) ~f:(fun (status, body) ->
      printf "%d limit=%b\n" status (String.is_substring body ~substring:"limit"));
    printf
      "distinct session cookies: %d\n"
      (List.length (List.dedup_and_sort !cookies ~compare:String.compare)));
  [%expect
    {|
    200 limit=false
    429 limit=true
    distinct session cookies: 1
    |}]
;;

let%expect_test "SEED_DISABLE_SUBMIT withdraws the button and refuses the write" =
  with_router ~f:(fun handle ->
    let token, cookie = seed_page_token ~seed:"12345" handle in
    let disabled = !Seed_web.Params.submit_disabled in
    Exn.protect
      ~finally:(fun () -> Seed_web.Params.submit_disabled := disabled)
      ~f:(fun () ->
        Seed_web.Params.submit_disabled := true;
        let target = sprintf "/%s/seed/12345" (Served.to_string Served.current) in
        summarise (handle (Dream.request ~method_:`GET ~target ""));
        summarise (submit handle ~token ~cookie "12345")));
  [%expect
    {|
    404 form=false queued=false to=- paused=true
    503 form=false queued=false to=- paused=true
    |}]
;;

(* Fossil ticket 92. Caps of two here; the real ones are in [Seed_web]. A
   repeat press is free, as it is for a submission: it adds no row. *)
let%expect_test "flags are capped per reader per day, and a repeat is free" =
  with_feedback
    ~flag_limit:(Seed_web.Reader_limit.create ~per_ip:5 ~per_session:2)
    ()
    ~f:(fun handle path ->
      let token, cookie = seed_page_token handle in
      let body = sprintf "dream.csrf=%s" token in
      List.iter [ "100"; "100"; "200"; "300" ] ~f:(fun seed ->
        let response = post_flag ~seed handle ~cookie body in
        printf
          "%s %d limit=%b\n"
          seed
          (status_of response)
          (String.is_substring (Lwt_main.run (Dream.body response)) ~substring:"limit"));
      printf "rows %d\n" (List.length (flags_in path)));
  [%expect
    {|
    100 200 limit=false
    100 200 limit=false
    200 200 limit=false
    300 429 limit=true
    rows 2
    |}]
;;
