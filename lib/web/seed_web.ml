open! Core
module Front_cache = Front_cache
module Gate = Gate
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
let temporarily_unavailable ?(retry_after = 300) message =
  Dream.html
    ~status:`Service_Unavailable
    ~headers:[ "Retry-After", Int.to_string retry_after ]
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

let served_builds db =
  List.filter_map Served.all ~f:(fun served ->
    let version = Served.to_version served in
    match Seed_corpus.Db.seed_count db ~version with
    | Ok count -> Some (served, count)
    | Error err ->
      Dream.error (fun log -> log "%s" (Error.to_string_hum err));
      None)
;;

(* The most-hit route renders nothing per request: pages are cached as strings
   because serialisation, not SQL, is most of the cost. Rotation rather than a
   random pick, so "More" walks every page before repeating one. *)
type front =
  { pages : string array
  ; pool : Seed_corpus.Level.Summary.t array
  ; builds : (Served.t * int) list
  ; mutable next : int
  }

let front_pool_size = 1000
let front_max_age = Time_ns.Span.of_sec 60.

let render_front ~version ~builds ~page summaries =
  render_html
    (Index.render
       ~version
       ~builds
       ~here:Index.Page.Seeds
       ~title:"dcss garden"
       (Views.seed_list ~version ~page summaries))
;;

let build_front ~reader ~pool ~gate key =
  match Seed_corpus.Query.Version.of_string key with
  | Error err -> Lwt.return (Error err)
  | Ok version ->
    let builds = served_builds reader in
    let page =
      Seed_corpus.Query.Page.create ~limit:Seed_corpus.Query.Page.default_limit ()
    in
    let%lwt outcome =
      Gate.with_permit gate ~timeout:!Params.pool_timeout ~f:(fun () ->
        Lwt_preemptive.detach
          (fun () ->
             match
               Seed_corpus.Pool.with_conn pool ~timeout:!Params.pool_timeout ~f:(fun db ->
                 Seed_corpus.Db.sample_seeds db ~version ~limit:front_pool_size)
             with
             | exception Seed_corpus.Pool.Saturated ->
               Or_error.error_string "search pool busy"
             | Error err -> Error err
             | Ok (summaries, _) ->
               let pages =
                 match List.chunks_of summaries ~length:page.limit with
                 | [] -> [ render_front ~version ~builds ~page [] ]
                 | chunks -> List.map chunks ~f:(render_front ~version ~builds ~page)
               in
               Ok
                 { pages = Array.of_list pages
                 ; pool = Array.of_list summaries
                 ; builds
                 ; next = 0
                 })
          ())
    in
    let result =
      match outcome with
      | `Admitted result -> result
      | `Saturated -> Or_error.error_string "search pool busy"
    in
    Result.iter_error result ~f:(fun err ->
      Dream.warning (fun log ->
        log "front page for %s not built: %s" key (Error.to_string_hum err)));
    Lwt.return result
;;

let seed_list_page front version request =
  match Params.page request with
  | Error err -> bad_request err
  | Ok page ->
    (match%lwt
       Front_cache.get front ~key:(Seed_corpus.Query.Version.to_string version)
     with
     | Error _ ->
       temporarily_unavailable
         ~retry_after:5
         "The seed list is still loading. Try again in a moment."
     | Ok front ->
       if page.limit = Seed_corpus.Query.Page.default_limit
       then (
         let html = front.pages.(front.next % Array.length front.pages) in
         front.next <- front.next + 1;
         Dream.html html)
       else
         Dream.html
           (render_front
              ~version
              ~builds:front.builds
              ~page
              (List.take (List.permute (Array.to_list front.pool)) page.limit)))
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

let deepen_paused ~lock_path = !Params.deepen_disabled || fill_in_progress ~lock_path

(* Queue read only for shallow seeds. Position taken only for waiting jobs.
   Both are covering seeks bounded by queue cap, run inline. A read-only
   instance drops every job row alike, queued or already finished, rather than
   distinguishing outstanding work from a record of a past attempt. *)
(* Dream's default CSRF lifetime is an hour, but a seed page is a tab readers
   leave open for days; the token is bound to the session anyway, so it lives
   as long as the session does. *)
let session_lifetime = 14. *. 86_400.

let deepen_state db ~version ~seed ~depth request =
  if Seed_corpus.Fill_depth.is_deep depth || !Params.deepen_disabled
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
    job, position, Some (Dream.csrf_token ~valid_for:session_lifetime request)
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
           ~filling:(deepen_paused ~lock_path)
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
        ~filling:(deepen_paused ~lock_path) )
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

(* Liveness probe. Serving: generator liveness. Read-only: what the corpus
   holds, since no generator will ever heartbeat there and that signal would
   503 forever. Intersected with [Served.all] because a corpus can hold a
   version this binary does not route to -- a half-ingested new build -- and
   reporting that would mislead. *)
let health reader _request =
  if !Params.deepen_disabled
  then (
    match Seed_corpus.Db.populated_versions reader with
    | Error err ->
      Dream.error (fun log -> log "%s" (Error.to_string_hum err));
      Dream.respond ~status:`Service_Unavailable "corpus unreadable\n"
    | Ok held ->
      (match
         List.filter_map Served.all ~f:(fun served ->
           let version = Served.to_string served in
           Option.some_if (List.mem held version ~equal:String.equal) version)
       with
       | [] -> Dream.respond ~status:`Service_Unavailable "no seeds\n"
       | served ->
         Dream.respond ~status:`OK (String.concat ~sep:"\n" ("read-only" :: served) ^ "\n")))
  else (
    match Seed_corpus.Db.servable_versions reader ~since:(now () - heartbeat_window) with
    | Error err ->
      Dream.error (fun log -> log "%s" (Error.to_string_hum err));
      Dream.respond ~status:`Service_Unavailable "corpus unreadable\n"
    | Ok [] -> Dream.respond ~status:`Service_Unavailable "no generator\n"
    | Ok versions -> Dream.respond ~status:`OK (String.concat ~sep:"\n" versions ^ "\n"))
;;

(* Absolute origin for sitemap. Default is the real host; every other link is
   host-relative. *)
let origin =
  match Sys.getenv "SEED_ORIGIN" with
  | Some s when not (String.equal (String.strip s) "") ->
    String.rstrip ~drop:(Char.equal '/') (String.strip s)
  | _ -> "https://dcss.garden"
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

(* Fill lock (or SEED_DISABLE_DEEPEN) gates the write, not just the button.
   POST route stays reachable with a valid token from a pre-fill or
   pre-restart page render. *)
let deepen_outcome writer ~lock_path ~version ~seed ~now =
  if deepen_paused ~lock_path
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
                 Some "The queue for deeper searches is full. Try again in a minute."
               (* Reachable from a pre-fill or pre-restart page render.
                  Generator heartbeats through a fill, so never
                  [`No_generator] here. *)
               | `Filling ->
                 Some
                   "Deeper searches are paused while new seeds are added to this build. \
                    Try again later."
               | `No_generator ->
                 Some "Deeper searches are unavailable right now. Try again later."
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

(* Every search takes a [Gate] permit before detaching, so a burst queues in
   Lwt behind [SEED_POOL_TIMEOUT] rather than in [Lwt_preemptive]'s unbounded
   worker queue. [Saturated] is the fifth concurrent search failing fast instead
   of waiting out the search budget, which is what [Pool]'s own deadline could
   never do: checkout runs inside the detached computation, after the worker
   slot is already held. Blocking SQLite on the scheduler thread would stall
   every concurrent request *and* the timeout below, which is an Lwt race the
   scheduler has to be free to lose. The old cheapness predicate was wrong in
   exactly that direction at corpus scale -- it asked about the plan when cost
   is set by the matched set -- so the inline shortcut is gone. See [Gate]. *)
let run_search pool gate search ~rank =
  let%lwt outcome =
    Gate.with_permit gate ~timeout:!Params.pool_timeout ~f:(fun () ->
      Lwt_preemptive.detach
        (fun () ->
           (* The pool's own deadline is the backstop behind the gate, so this
              arm should be unreachable -- but an uncaught [Saturated] here
              surfaces as a 500 where the reader is owed a 503. *)
           match
             Seed_corpus.Pool.with_conn pool ~timeout:!Params.pool_timeout ~f:(fun db ->
               Seed_corpus.Db.search_seeds db search ~rank)
           with
           | result -> `Answered result
           | exception Seed_corpus.Pool.Saturated -> `Saturated)
        ())
  in
  match outcome with
  | `Admitted result -> Lwt.return result
  | `Saturated -> Lwt.return `Saturated
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

let criteria_scan pool gate version ~key =
  let%lwt computed =
    let%lwt outcome =
      Gate.with_permit gate ~timeout:!Params.pool_timeout ~f:(fun () ->
        Lwt_preemptive.detach
          (fun () ->
             try
               Seed_corpus.Pool.with_conn pool ~timeout:!Params.pool_timeout ~f:(fun db ->
                 Seed_corpus.Db.distinct_criteria db ~version)
             with
             | Seed_corpus.Pool.Saturated -> Or_error.error_string "search pool busy")
          ())
    in
    match outcome with
    | `Admitted result -> Lwt.return result
    | `Saturated ->
      (* The scan yields its slot rather than occupying a worker waiting for
         one; the next miss retries because [criteria_pending] is cleared
         below. *)
      Lwt.return (Or_error.error_string "search pool busy")
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

let criteria_for pool gate version =
  let key = Seed_corpus.Query.Version.to_string version in
  match Hashtbl.find criteria_cache key with
  | Some options -> Some options
  | None ->
    if not (Hashtbl.mem criteria_pending key)
    then Hashtbl.set criteria_pending ~key ~data:(criteria_scan pool gate version ~key);
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
          ~title:"about dcss garden"
          (Views.about ~version)))
;;

(* The catalog when the store is current, else whatever the datalist cache
   holds. Neither may wait on the datalist scan: this runs inline. *)
let search_vocabulary db pool gate version =
  match Seed_corpus.Db.catalog_item_pairs db ~version with
  | Ok (Some pairs) -> Some pairs
  | Ok None -> criteria_for pool gate version
  | Error err ->
    Dream.warning (fun log ->
      log "search vocabulary unavailable: %s" (Error.to_string_hum err));
    criteria_for pool gate version
;;

(* A 400 that hands the search back, terms as typed: logs show readers
   iterating one query five or six times, and a bare error page cost them the
   whole query each time. Status stays 400; htmx 4 swaps it regardless. *)
let search_rejected db ~pool ~gate version request ~rank ~boxes ~problems =
  let suggestions = criteria_for pool gate version in
  if Option.is_some (Dream.header request "HX-Request")
  then
    Dream.html
      ~status:`Bad_Request
      (String.concat
         (List.map
            (Views.search_rejected_fragment ~version ~rank ~boxes ~problems ~suggestions)
            ~f:render_fragment))
  else
    Dream.html
      ~status:`Bad_Request
      (render_html
         (Index.render
            ~version
            ~builds:(served_builds db)
            ~here:Index.Page.Search
            ~title:Views.search_title
            (Views.search_rejected ~version ~rank ~boxes ~problems ~suggestions)))
;;

let view_box (box : Params.Box.t) =
  { Views.Box.value = box.typed
  ; problem =
      (match box.outcome with
       | Parsed _ | Resolved _ -> None
       | Rejected { message; offer } ->
         Some
           { Views.Box.message
           ; offer =
               Option.map offer ~f:(fun { prompt; terms } -> { Views.Box.prompt; terms })
           })
  }
;;

let answer_search db ~pool ~gate version request ~boxes ~page ~rank ~terms =
  let search = Seed_corpus.Search.create ~version ~terms ~page () in
  let resolved =
    List.filter_map boxes ~f:(fun (box : Params.Box.t) ->
      match box.outcome with
      | Resolved term -> Some (box.typed, term)
      | Parsed _ | Rejected _ -> None)
  in
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
         one -- that needs the interrupt. The gate permit is held for as long,
         because [Gate.with_permit] releases on resolution rather than on
         cancellation; the gate bounds the *wait*, not the work. *)
      Lwt.pick
        [ run_search pool gate search ~rank
        ; Lwt.map (fun () -> `Timed_out) (Lwt_unix.sleep !Params.search_timeout)
        ]
  in
  match result with
  | `Saturated ->
    temporarily_unavailable "Too many searches are running. Try again in a moment."
  | `Timed_out ->
    Dream.warning (fun log -> log "search over %.0fs budget" !Params.search_timeout);
    temporarily_unavailable
      "That search took too long and was stopped. Adding another term usually helps."
  | `Answered result ->
    (match result with
     (* A rebuild in progress is a transient state of the corpus, not a bad
      query: the reader's search is well-formed and will work shortly. *)
     | Error err when Seed_corpus.Search.is_index_rebuilding err ->
       temporarily_unavailable
         "name~ searches are unavailable for a few minutes while the name index \
          rebuilds. Other searches still work."
     (* Too broad to rank is a reader query issue, not a fault. *)
     | Error err when Seed_corpus.Search.Rank.is_too_broad err ->
       search_rejected
         db
         ~pool
         ~gate
         version
         request
         ~rank
         ~boxes:(Views.Box.of_terms terms)
         ~problems:
           [ Printf.sprintf
               "That search matches more than %d seeds, too many to rank by %s. Add \
                another term, or rank by seed."
               Seed_corpus.Search.Rank.sort_limit
               (Seed_corpus.Search.Rank.to_string rank)
           ]
     | Error err ->
       Dream.error (fun log -> log "%s" (Error.to_string_hum err));
       or_error_response (Or_error.error_string "search failed")
     | Ok (matches, more) ->
       if
         List.is_empty matches
         && (not (Seed_corpus.Search.is_empty search))
         && Option.is_none search.page.after
       then Dream.info (fun log -> log "%s" (Params.empty_search_line search));
       let suggestions = criteria_for pool gate version in
       let body = Views.search_page ~resolved ~search ~suggestions ~rank ~more matches in
       if Option.is_some (Dream.header request "HX-Request")
       then
         Dream.html
           (String.concat
              (List.map
                 (Views.search_fragment
                    ~resolved
                    ~search
                    ~suggestions
                    ~rank
                    ~more
                    matches)
                 ~f:render_fragment))
       else
         Dream.html
           (render_html
              (Index.render
                 ~version
                 ~builds:(served_builds db)
                 ~here:Index.Page.Search
                 ~title:Views.search_title
                 body)))
;;

let search_page db ~pool ~gate version request =
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
    let typed =
      Dream.queries request "has"
      |> Params.without_dropped ~drop:(Dream.query request "drop")
    in
    let boxes =
      Params.boxes ~vocabulary:(lazy (search_vocabulary db pool gate version)) typed
    in
    let page = Params.page request in
    let rank = Params.rank request in
    let problems =
      List.filter_map
        [ Result.error boxes; Result.error page; Result.error rank ]
        ~f:(Option.map ~f:Error.to_string_hum)
    in
    let rank = Result.ok rank |> Option.value ~default:Seed_corpus.Search.Rank.default in
    let rejected ~boxes ~problems =
      search_rejected db ~pool ~gate version request ~rank ~boxes ~problems
    in
    match boxes, page with
    | Error _, _ ->
      rejected
        ~boxes:
          (List.filter_map typed ~f:(fun value ->
             Option.some_if
               (not (String.is_empty (String.strip value)))
               { Views.Box.value; problem = None }))
        ~problems
    | Ok boxes, Ok page when List.is_empty problems ->
      (match Params.terms_of_boxes boxes with
       | None -> rejected ~boxes:(List.map boxes ~f:view_box) ~problems:[]
       | Some terms ->
         answer_search db ~pool ~gate version request ~boxes ~page ~rank ~terms)
    | Ok boxes, _ -> rejected ~boxes:(List.map boxes ~f:view_box) ~problems)
;;

(* Styled 404 as trailing catch-all route; [Dream.router] gives bare bodiless
   404 for unmatched paths. Must stay last. *)
let router ~reader ~writer ~pool ~lock_path =
  (* Sized from the pool, because the two are one budget: a permit is what a
     pool connection is taken under. Sizing them apart restores the unbounded
     queue in [Lwt_preemptive] with extra steps. *)
  let gate = Gate.create ~size:(Seed_corpus.Pool.size pool) in
  let front =
    Front_cache.create
      ~max_age:front_max_age
      ~now:Time_ns.now
      ~build:(build_front ~reader ~pool ~gate)
  in
  Dream.router
    [ Dream.get "/" current_version_redirect
    ; Dream.get "/health" (health reader)
    ; Dream.get "/robots.txt" robots
      (* Browsers request /favicon.ico at the root regardless of the <link>. *)
    ; Dream.get "/favicon.ico" (Dream.from_filesystem "static" "favicon.ico")
    ; Dream.get "/sitemap.xml" sitemap
    ; Dream.get "/:version/" (with_version (seed_list_page front))
    ; Dream.get "/:version/jump" (with_version jump_to_seed)
    ; Dream.get "/:version/search" (with_version (search_page reader ~pool ~gate))
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
        [ Dream.cookie_sessions ~lifetime:session_lifetime ]
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
