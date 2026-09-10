open! Core
module Index = Index
module Params = Params
module Served = Served
module Views = Views

let render_html elt =
  let buf = Buffer.create 4096 in
  let fmt = Format.formatter_of_buffer buf in
  Tyxml.Html.pp () fmt elt;
  Format.pp_print_flush fmt ();
  Buffer.contents buf
;;

(* Format buffers internally; flush or the tail is silently lost. *)
let render_fragment elt =
  let buf = Buffer.create 1024 in
  let fmt = Format.formatter_of_buffer buf in
  Tyxml.Html.pp_elt () fmt elt;
  Format.pp_print_flush fmt ();
  Buffer.contents buf
;;

(* [Dream.router] dispatches on method, so a table of [Dream.get] routes sends
   every HEAD to the catch-all 404 -- which unfurlers, uptime monitors and link
   checkers all read as the site being down, while a browser sees nothing wrong.
   Rewriting to GET and dropping the body keeps one route table answering both
   methods, so a route cannot be added for GET and forgotten for HEAD.

   The body is dropped here rather than by the HTTP layer: httpaf's
   [Response.body_length] takes the request method but only special-cases
   CONNECT and the bodiless statuses, so a HEAD response left with a body sends
   it. Content-Length is set from what GET would have returned, since RFC 9110
   asks for the headers GET would send. *)
let head_as_get inner request =
  match Dream.method_ request with
  | `HEAD ->
    Dream.set_method_ request `GET;
    let%lwt response = inner request in
    let%lwt body = Dream.body response in
    Dream.set_header response "Content-Length" (Int.to_string (String.length body));
    Dream.set_body response "";
    Lwt.return response
  | _ -> inner request
;;

let security_headers inner request =
  let%lwt response = inner request in
  Dream.set_header
    response
    "Content-Security-Policy"
    "default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'; \
     frame-ancestors 'none'";
  Dream.set_header response "X-Content-Type-Options" "nosniff";
  Dream.set_header response "Referrer-Policy" "same-origin";
  Lwt.return response
;;

(* Server fault page. No cause detail; that belongs in the log. *)
let server_error_html =
  render_html
    (Index.render
       ~title:"Something went wrong"
       Tyxml.Html.
         [ h1 [ txt "Something went wrong" ]
         ; p [ txt "That query could not be answered. Try again." ]
         ; p [ a ~a:[ a_href "/" ] [ txt "Back to the start" ] ]
         ])
;;

(* Or_error boundary: storage is synchronous Core, handlers are Lwt. *)
let or_error_response = function
  | Ok elt -> Dream.html (render_html elt)
  | Error err ->
    Dream.error (fun log -> log "%s" (Error.to_string_hum err));
    Dream.html ~status:`Internal_Server_Error server_error_html
;;

(* Bad request: reader's typo, not a server fault. *)
let bad_request err =
  Dream.html
    ~status:`Bad_Request
    (render_html
       (Index.render
          ~title:"Bad request"
          Tyxml.Html.
            [ h1 [ txt "Bad request" ]
            ; p [ txt (Error.to_string_hum err) ]
            ; p [ a ~a:[ a_href "/" ] [ txt "Back to the start" ] ]
            ]))
;;

(* Not [bad_request]: the reader's query is well-formed and the fault is the
   corpus's, so this is a 503 with a retry hint rather than a 400 telling them
   they got it wrong. *)
let temporarily_unavailable message =
  Dream.html
    ~status:`Service_Unavailable
    ~headers:[ "Retry-After", "300" ]
    (render_html
       (Index.render
          ~title:"Temporarily unavailable"
          Tyxml.Html.
            [ h1 [ txt "Temporarily unavailable" ]
            ; p [ txt message ]
            ; p [ a ~a:[ a_href "/" ] [ txt "Back to the start" ] ]
            ]))
;;

let not_found _request =
  Dream.html
    ~status:`Not_Found
    (render_html
       (Index.render
          ~title:"Not found"
          Tyxml.Html.
            [ h1 [ txt "Not found" ]
            ; p [ txt "There is no page at that address." ]
            ; p [ a ~a:[ a_href "/" ] [ txt "Back to the start" ] ]
            ]))
;;

(* Unserved build is 404, not 400: the served set is closed. No handler below
   sees an unserved version. *)
let with_version handler request =
  match Params.version request with
  | Error _ -> not_found request
  | Ok version -> handler version request
;;

(* A URL naming no build is a redirect, never a silent assumption: which build
   a reader sees first is an editorial claim, and making it visible in the
   address bar is what keeps "no seeds on 0.34.1" from reading as "no seeds". *)
let current_version_redirect request =
  Dream.redirect request (Printf.sprintf "/%s/" (Served.to_string Served.current))
;;

(* Seed counts per build, cached for process lifetime. [Db.seed_count] is a
   covering seek linear in the cohort (~45ms at 1.3M). Cached rather than
   stored to avoid a second source of truth. A fill running alongside
   under-reports until restart; accepted while fills are manual. Failed reads
   are not cached so transient errors retry on next render. *)
let seed_count_cache : (string, int) Hashtbl.t = Hashtbl.create (module String)

let served_builds db =
  List.filter_map Served.all ~f:(fun served ->
    let version = Served.to_version served in
    let key = Seed_corpus.Query.Version.to_string version in
    match Hashtbl.find seed_count_cache key with
    | Some count -> Some (served, count)
    | None ->
      (match Seed_corpus.Db.seed_count db ~version with
       | Ok count ->
         Hashtbl.set seed_count_cache ~key ~data:count;
         Some (served, count)
       | Error err ->
         Dream.error (fun log -> log "%s" (Error.to_string_hum err));
         None))
;;

let seed_list_page db version request =
  match Params.page request with
  | Error err -> bad_request err
  | Ok page ->
    (* Front page samples; [after] re-samples, not resumes. *)
    Seed_corpus.Db.sample_seeds db ~version ~limit:page.limit
    |> Or_error.map ~f:(fun (summaries, _more) ->
      Index.render
        ~version
        ~builds:(served_builds db)
        ~here:Index.Page.Seeds
        ~title:"dcss seed explorer"
        (Views.seed_list ~version ~page summaries))
    |> or_error_response
;;

(* Missing seed 404s on the detail page, not here. *)
let jump_to_seed version request =
  let seed = Dream.query request "seed" |> Option.value ~default:"" |> String.strip in
  if String.is_empty seed || not (String.for_all seed ~f:Char.is_digit)
  then bad_request (Error.of_string "a seed is a number")
  else
    Dream.redirect
      request
      (Printf.sprintf
         "/%s/seed/%s"
         (Dream.to_percent_encoded (Seed_corpus.Query.Version.to_string version))
         (Dream.to_percent_encoded seed))
;;

(* Fill lock check. Shared-mode test is one open/flock/close, so not cached.
   Unreadable or absent means not filling. *)
let fill_in_progress ~lock_path =
  match Core_unix.openfile lock_path ~mode:[ O_RDONLY ] with
  | exception _ -> false
  | fd ->
    Exn.protect
      ~finally:(fun () ->
        try Core_unix.close fd with
        | _ -> ())
      ~f:(fun () ->
        match Core_unix.flock fd Core_unix.Flock_command.lock_shared with
        | true ->
          ignore (Core_unix.flock fd Core_unix.Flock_command.unlock : bool);
          false
        | false -> true
        | exception _ -> false)
;;

(* Queue read only for shallow seeds. Position taken only for waiting jobs.
   Both are covering seeks bounded by queue cap, run inline. *)
let deepen_state db ~version ~seed ~depth request =
  if Seed_corpus.Fill_depth.is_deep depth
  then Ok (None, None, None)
  else
    let open Or_error.Let_syntax in
    let%bind job = Seed_corpus.Db.job_for_seed db ~version ~seed in
    let waiting =
      match job with
      | Some job ->
        Seed_corpus.Job.State.equal
          (Seed_corpus.Job.state job)
          Seed_corpus.Job.State.Queued
      | None -> false
    in
    let%map position =
      if waiting then Seed_corpus.Db.queue_position db ~version ~seed else Ok None
    in
    job, position, Some (Dream.csrf_tag request)
;;

let depth_of_levels levels =
  Seed_corpus.Fill_depth.of_levels
    (List.map levels ~f:(fun (l : Seed_corpus.Level.t) -> l.level))
;;

let seed_detail_page db ~lock_path version request =
  let seed = Dream.param request "seed" in
  match Seed_corpus.Db.seed_levels db ~version ~seed with
  (* Uningested seed is 404: the queue extends, not creates. *)
  | Ok [] -> not_found request
  | result ->
    result
    |> Or_error.bind ~f:(fun levels ->
      let open Or_error.Let_syntax in
      let%map job, position, csrf =
        deepen_state db ~version ~seed ~depth:(depth_of_levels levels) request
      in
      Index.render
        ~version
        ~builds:(served_builds db)
        ~title:(Printf.sprintf "seed %s" seed)
        (Views.seed_detail
           ~version
           ~seed
           ~job
           ~position
           ~csrf
           ~filling:(fill_in_progress ~lock_path)
           levels))
    |> or_error_response
;;

(* Depth fragment polled while a job is outstanding; also the button's swap
   target. *)
(* Only the poll may refresh; [polling] separates this. The button's own
   response must not refresh: it would reload the page that rendered it. *)
let depth_fragment ?(polling = false) db ~lock_path version request =
  let seed = Dream.param request "seed" in
  match
    let open Or_error.Let_syntax in
    let%bind levels = Seed_corpus.Db.seed_levels db ~version ~seed in
    let depth = depth_of_levels levels in
    let%map job, position, csrf = deepen_state db ~version ~seed ~depth request in
    ( depth
    , Views.depth_note
        ~version
        ~seed
        ~depth
        ~job
        ~position
        ~csrf
        ~filling:(fill_in_progress ~lock_path) )
  with
  | Error err ->
    Dream.error (fun log -> log "%s" (Error.to_string_hum err));
    Dream.html ~status:`Internal_Server_Error ""
  | Ok (depth, fragment) ->
    let body = String.concat (List.map fragment ~f:render_fragment) in
    if polling && Seed_corpus.Fill_depth.is_deep depth
    then
      (* HX-Refresh reloads the whole page: levels changed outside the fragment. *)
      Dream.html ~headers:[ "HX-Refresh", "true" ] body
    else Dream.html body
;;

(* Queue cap. Disk-bound: 100k unattended requests is ~12 GB. *)
let now () = Float.to_int (Core_unix.time ())
let queue_cap = 32

(* Generator heartbeat window: wide enough for normal intervals, narrow enough
   to stop accepting work from a dead generator. *)
let heartbeat_window = 300

(* Liveness probe: process up and generators reachable. Runs on [reader]. *)
let health reader _request =
  match Seed_corpus.Db.servable_versions reader ~since:(now () - heartbeat_window) with
  | Error err ->
    Dream.error (fun log -> log "%s" (Error.to_string_hum err));
    Dream.respond ~status:`Service_Unavailable "corpus unreadable\n"
  | Ok [] -> Dream.respond ~status:`Service_Unavailable "no generator\n"
  | Ok versions -> Dream.respond ~status:`OK (String.concat ~sep:"\n" versions ^ "\n")
;;

(* Absolute origin for sitemap. Default is the real host; every other link is
   host-relative. *)
let origin =
  match Sys.getenv "SEED_ORIGIN" with
  | Some s when not (String.equal (String.strip s) "") ->
    String.rstrip ~drop:(Char.equal '/') (String.strip s)
  | _ -> "https://dcss.jonesmelton.com"
;;

(* Seed space has no natural end; crawlers enumerate forever. Real ceiling is
   in the proxy. Routes added to [router] belong here or are crawlable. *)
let robots_txt =
  Printf.sprintf
    "User-agent: *\n\
     Disallow: /*/seed/\n\
     Disallow: /*/search\n\
     Disallow: /*/jump\n\
     Crawl-delay: 10\n\n\
     Sitemap: %s/sitemap.xml\n"
    origin
;;

let robots _request =
  Dream.respond ~headers:[ "Content-Type", "text/plain; charset=utf-8" ] robots_txt
;;

(* Crawlable pages, derived from [Served.all]. Seed and search routes absent:
   both enumerate a growing set. No <lastmod>: corpus changes continuously. *)
let sitemap_xml =
  let url loc = Printf.sprintf "  <url><loc>%s%s</loc></url>\n" origin loc in
  let per_build =
    List.concat_map Served.all ~f:(fun t ->
      let v = Served.to_string t in
      [ url (Printf.sprintf "/%s/" v); url (Printf.sprintf "/%s/about" v) ])
  in
  String.concat
    ([ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
     ; "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
     ; url "/"
     ]
     @ per_build
     @ [ "</urlset>\n" ])
;;

let sitemap _request =
  Dream.respond ~headers:[ "Content-Type", "application/xml; charset=utf-8" ] sitemap_xml
;;

(* Fill lock gates the write, not just the button. POST route stays reachable
   with a valid token from a pre-fill page render. *)
let deepen_outcome writer ~lock_path ~version ~seed ~now =
  if fill_in_progress ~lock_path
  then `Filling
  else (
    match
      Seed_corpus.Db.enqueue
        writer
        ~version
        ~seed
        ~cap:queue_cap
        ~servable_since:(now - heartbeat_window)
    with
    | Error err -> `Failed err
    | Ok outcome ->
      (outcome
        :> [ `Queued
           | `Already_queued of Seed_corpus.Job.t
           | `Queue_full
           | `No_generator
           | `Filling
           | `Failed of Error.t
           ]))
;;

(* The one mutation the app makes, and so the only handler that goes through
   Dream's form check.

   Write takes its own connection: read path holds deferred transactions and
   searches may be detached, so enqueue on the shared handle would collide. *)
let deepen_seed ~reader ~writer ~lock_path version request =
  let seed = Dream.param request "seed" in
  let%lwt form = Dream.form request in
  match form with
  | `Ok _fields ->
    (match Ok version with
     | Error err -> bad_request err
     | Ok version ->
       (* A seed the corpus does not hold has nothing to deepen. *)
       (match Seed_corpus.Db.seed_levels reader ~version ~seed with
        | Error err ->
          Dream.error (fun log -> log "%s" (Error.to_string_hum err));
          or_error_response (Or_error.error_string "could not read that seed")
        | Ok [] -> not_found request
        | Ok levels ->
          let depth = depth_of_levels levels in
          let outcome =
            if Seed_corpus.Fill_depth.is_deep depth
            then Ok `Already_deep
            else (
              match deepen_outcome writer ~lock_path ~version ~seed ~now:(now ()) with
              | `Failed err -> Error err
              | (`Queued | `Already_queued _ | `Queue_full | `No_generator | `Filling) as
                outcome -> Ok outcome)
          in
          (match outcome with
           | Error err ->
             Dream.error (fun log -> log "%s" (Error.to_string_hum err));
             or_error_response (Or_error.error_string "could not queue that request")
           | Ok outcome ->
             let refusal =
               match outcome with
               | `Queue_full ->
                 Some "The deepening queue is full just now. Try again in a minute."
               (* Reachable from a pre-fill page render. Generator heartbeats
                  through a fill, so never [`No_generator] here. *)
               | `Filling ->
                 Some
                   "That deeper search is unavailable right now: this build is busy \
                    building out the corpus. Try again when it finishes."
               | `No_generator ->
                 Some
                   "Nothing can search that build deeper at the moment. Try again later."
               | `Already_deep | `Queued | `Already_queued _ -> None
             in
             (match refusal with
              | Some message ->
                Dream.html
                  ~status:`Service_Unavailable
                  (String.concat
                     (List.map (Views.refusal ~seed ~version message) ~f:render_fragment))
              | None -> depth_fragment reader ~lock_path version request))))
  | _ ->
    (* Missing or stale token: reload and retry. Answers in the slot's shape,
       not [bad_request]: htmx swaps 4xx into the depth note and takes its
       title. *)
    Dream.html
      ~status:`Bad_Request
      (String.concat
         (List.map
            (Views.refusal
               ~seed
               ~version
               "That request could not be verified. Reload the seed page and try again.")
            ~f:render_fragment))
;;

(* Search runs detached unless every term is cheap. Blocking SQLite stalls all
   concurrent requests.

   Two conditions, and the second is about the set rather than any one term.
   Only one term becomes the driver, and [driver_select] renders a
   [min_count > 1] driver as its own flat group-by; a second such term has no
   driver slot left and falls back to the correlated scalar-sum, which the
   2026-09-09 decorrelation did not rewrite (it covers [min_count <= 1] only).
   Measured on prod at 1.3M: one counted term 0.20s, two 23.2s. *)
let search_is_cheap (search : Seed_corpus.Search.t) =
  let counted =
    List.count search.terms ~f:(fun (term : Seed_corpus.Search.Term.t) ->
      term.min_count > 1)
  in
  counted <= 1
  && List.for_all search.terms ~f:(fun (term : Seed_corpus.Search.Term.t) ->
    Seed_corpus.Search.Criterion.is_cheap term.criterion)
;;

(* Non-default ranking reads the whole matched set, never cheap. Cheap path
   stays on [reader]; detached path checks out of [pool] to avoid serializing
   on the shared connection. *)
let run_search reader pool search ~rank =
  if
    search_is_cheap search
    && Seed_corpus.Search.Rank.equal rank Seed_corpus.Search.Rank.Seed
  then Lwt.return (Seed_corpus.Db.search_seeds reader search ~rank)
  else
    Lwt_preemptive.detach
      (fun () ->
         Seed_corpus.Pool.with_conn pool ~f:(fun db ->
           Seed_corpus.Db.search_seeds db search ~rank))
      ()
;;

(* Datalist vocabulary is a scan; detached and cached per version for process
   lifetime. Fill between restarts costs a missing suggestion, not a failure.
   Unrands prefixed with [name~]: bare name would parse as item. *)
let criteria_cache : (string, string list) Hashtbl.t = Hashtbl.create (module String)

(* The scan is minutes long at corpus scale and holds a pool connection
   throughout, so a miss starts it in the background and renders without
   suggestions rather than awaiting it. Awaiting it made the first search after
   a restart -- a deploy during a traffic spike -- block for the whole scan, and
   four concurrent cold searches launch four scans and exhaust the pool. This
   table is what makes it one: a version present here has a scan in flight. *)
let criteria_pending : (string, unit Lwt.t) Hashtbl.t = Hashtbl.create (module String)

let unrand_options version =
  match
    Seed_corpus.Unrand.names ~version:(Seed_corpus.Query.Version.to_string version)
  with
  | None -> []
  | Some names -> List.map names ~f:(fun name -> "name~" ^ name)
;;

let criteria_scan pool version ~key =
  let%lwt computed =
    Lwt_preemptive.detach
      (fun () ->
         Seed_corpus.Pool.with_conn pool ~f:(fun db ->
           Seed_corpus.Db.distinct_criteria db ~version))
      ()
  in
  (match computed with
   | Error err ->
     Dream.warning (fun log ->
       log "datalist vocabulary unavailable: %s" (Error.to_string_hum err))
   | Ok items ->
     let options = List.concat [ items; unrand_options version ] in
     Hashtbl.set criteria_cache ~key ~data:options);
  (* Cleared whether or not the scan succeeded, so a failure is retried by the
     next miss rather than wedging the version out of ever having a datalist. *)
  Hashtbl.remove criteria_pending key;
  Lwt.return_unit
;;

let criteria_for pool version =
  let key = Seed_corpus.Query.Version.to_string version in
  match Hashtbl.find criteria_cache key with
  | Some options -> Some options
  | None ->
    if not (Hashtbl.mem criteria_pending key)
    then Hashtbl.set criteria_pending ~key ~data:(criteria_scan pool version ~key);
    None
;;

(* Test hooks: the scan is background work with no handle in the response, so a
   test that needs it settled has no other way to wait for it. *)
let criteria_cache_clear () =
  Hashtbl.clear criteria_cache;
  Hashtbl.clear criteria_pending
;;

let criteria_cache_wait () = Lwt_main.run (Lwt.join (Hashtbl.data criteria_pending))

(* Body reads no corpus; db threaded through for masthead. *)
let search_help_page db version _request =
  Dream.html
    (render_html
       (Index.render
          ~version
          ~builds:(served_builds db)
          ~here:Index.Page.Search
          ~title:"how to search"
          (if !Params.search_disabled
           then Views.search_unavailable
           else Views.search_help ~version)))
;;

(* Reads no corpus of its own; the db is threaded through for the masthead. *)
let about_page db version _request =
  Dream.html
    (render_html
       (Index.render
          ~version
          ~builds:(served_builds db)
          ~here:Index.Page.About
          ~title:"about dcss seed explorer"
          (Views.about ~version)))
;;

let search_page db ~pool version request =
  if !Params.search_disabled
  then
    if Option.is_some (Dream.header request "HX-Request")
    then Dream.html (String.concat (List.map Views.search_unavailable ~f:render_fragment))
    else
      Dream.html
        (render_html
           (Index.render
              ~version
              ~builds:(served_builds db)
              ~here:Index.Page.Search
              ~title:"search"
              Views.search_unavailable))
  else (
    match
      let open Or_error.Let_syntax in
      let%bind search = Params.search ~version request in
      let%map rank = Params.rank request in
      search, rank
    with
    | Error err -> bad_request err
    | Ok (search, rank) ->
      (* No terms means nothing was asked; the views render a prompt, so there is
         no query to run and no unfiltered scan to pay for. *)
      let%lwt result =
        if Seed_corpus.Search.is_empty search
        then Lwt.return (`Answered (Ok ([], `End)))
        else
          (* Bounds what the client waits for, not what the query occupies: the
             abandoned search runs on to completion still holding its pool
             connection, since there is no [sqlite3_interrupt] to bind. Enough
             against an accidental or probing hang, not against a determined
             one -- that needs the interrupt. *)
          Lwt.pick
            [ Lwt.map (fun r -> `Answered r) (run_search db pool search ~rank)
            ; Lwt.map (fun () -> `Timed_out) (Lwt_unix.sleep !Params.search_timeout)
            ]
      in
      (match result with
       | `Timed_out ->
         Dream.warning (fun log -> log "search over %.0fs budget" !Params.search_timeout);
         temporarily_unavailable
           "That search took too long to answer and was stopped. Narrowing it with \
            another term will usually make it fast enough."
       | `Answered result ->
         (match result with
          (* A rebuild in progress is a transient state of the corpus, not a bad
          query: the reader's search is well-formed and will work shortly. *)
          | Error err when Seed_corpus.Search.is_index_rebuilding err ->
            temporarily_unavailable
              "Searching by name is briefly unavailable while the name index rebuilds \
               after a corpus update. Every other kind of search still works; try this \
               one again in a few minutes."
          (* Too broad to rank is a reader query issue, not a fault. *)
          | Error err when Seed_corpus.Search.Rank.is_too_broad err ->
            bad_request
              (Error.of_string
                 (Printf.sprintf
                    "That search matches more than %d seeds, which is too many to rank \
                     by %s. Add another term to narrow it, or rank by seed."
                    Seed_corpus.Search.Rank.sort_limit
                    (Seed_corpus.Search.Rank.to_string rank)))
          | Error err ->
            Dream.error (fun log -> log "%s" (Error.to_string_hum err));
            or_error_response (Or_error.error_string "search failed")
          | Ok (matches, more) ->
            let suggestions = criteria_for pool version in
            let body = Views.search_page ~search ~suggestions ~rank ~more matches in
            if Option.is_some (Dream.header request "HX-Request")
            then
              Dream.html
                (String.concat
                   (List.map
                      (Views.search_fragment ~search ~suggestions ~rank ~more matches)
                      ~f:render_fragment))
            else
              Dream.html
                (render_html
                   (Index.render
                      ~version
                      ~builds:(served_builds db)
                      ~here:Index.Page.Search
                      ~title:Views.search_title
                      body)))))
;;

(* Styled 404 as trailing catch-all route; [Dream.router] gives bare bodiless
   404 for unmatched paths. Must stay last. *)
let router ~reader ~writer ~pool ~lock_path =
  Dream.router
    [ Dream.get "/" current_version_redirect
    ; Dream.get "/health" (health reader)
    ; Dream.get "/robots.txt" robots
    ; Dream.get "/sitemap.xml" sitemap
    ; Dream.get "/:version/" (with_version (seed_list_page reader))
    ; Dream.get "/:version/jump" (with_version jump_to_seed)
    ; Dream.get "/:version/search" (with_version (search_page reader ~pool))
    ; Dream.get "/:version/search/help" (with_version (search_help_page reader))
    ; Dream.get "/:version/about" (with_version (about_page reader))
      (* Scoped rather than global because a session is a Set-Cookie on every
         response it touches, and these three routes are the only ones that need
         one: the CSRF token is bound to a session, and the deepen button is the
         only mutation. Global, it also cookied the index, search, /health and
         every static file -- a credential handed to readers who never post, and
         one that suppresses caching downstream. Scope middlewares run only on a
         match, so the prefix is what keeps them off everything else. *)
    ; Dream.scope
        ""
        [ Dream.cookie_sessions ]
        [ Dream.get
            "/:version/seed/:seed"
            (with_version (seed_detail_page reader ~lock_path))
        ; Dream.get
            "/:version/seed/:seed/depth"
            (with_version (depth_fragment ~polling:true reader ~lock_path))
        ; Dream.post
            "/:version/seed/:seed/deepen"
            (with_version (deepen_seed ~reader ~writer ~lock_path))
        ]
    ; Dream.get "/static/**" (Dream.static "static")
    ; Dream.any "/**" not_found
    ]
;;

(* Last barrier: catches exceptions that escaped handlers. Without it Dream
   answers empty 500. No fault detail reaches the client; Dream already logged
   the backtrace. [debug_dump] dropped to prevent backtrace leakage. Only
   server faults get this page; 4xx already carry a body. *)
let error_page =
  Dream.error_template (fun error _debug_dump suggested_response ->
    let status = Dream.status suggested_response in
    (* [is_server_error] covers 503, and a handler that answered 503 on purpose
       -- the stale name~ index -- has already written the page it wants. This
       template exists to keep an *unhandled* fault from leaking detail, so it
       only fills in a body that is not there. *)
    let%lwt existing_body = Dream.body suggested_response in
    if (not (Dream.is_server_error status)) || not (String.is_empty existing_body)
    then Lwt.return suggested_response
    else (
      let from_htmx =
        match error.Dream.request with
        | Some request -> Option.is_some (Dream.header request "HX-Request")
        | None -> false
      in
      Dream.set_body
        suggested_response
        (if from_htmx then Dream.status_to_string status else server_error_html);
      Dream.set_header suggested_response "Content-Type" "text/html; charset=utf-8";
      Lwt.return suggested_response))
;;
