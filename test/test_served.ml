open! Core
module Served = Seed_web.Served

(* The set is closed, so an unrecognised build is rejected at the parse
   boundary rather than becoming a query that returns nothing. Note trunk -- a
   real build the pipeline can produce, and still not served. *)
let%expect_test "only the served set parses" =
  List.iter
    [ "0.34.1"; "0.33.1"; "trunk"; "0.34-a0-1234-gabc"; ""; "../etc/passwd" ]
    ~f:(fun s ->
      match Served.of_string s with
      | Ok t -> printf "%-20s served as %s\n" s (Served.to_string t)
      | Error err -> printf "%-20s %s\n" s (Error.to_string_hum err));
  [%expect
    {|
    0.34.1               served as 0.34.1
    0.33.1               served as 0.33.1
    trunk                no such version: "trunk"
    0.34-a0-1234-gabc    no such version: "0.34-a0-1234-gabc"
                         no such version: ""
    ../etc/passwd        no such version: "../etc/passwd"
    |}]
;;

(* Every served build must round-trip through its own URL spelling and name a
   version the corpus vocabulary accepts; to_version is total, and this is what
   keeps it so as constructors are added. *)
let%expect_test "every served build round-trips and is a valid corpus version" =
  List.iter Served.all ~f:(fun t ->
    let s = Served.to_string t in
    printf
      "%-10s round-trips: %b  corpus version: %s\n"
      s
      ([%equal: Served.t Or_error.t] (Served.of_string s) (Ok t))
      (Seed_corpus.Query.Version.to_string (Served.to_version t)));
  printf "current: %s\n" (Served.to_string Served.current);
  [%expect
    {|
    0.34.1     round-trips: true  corpus version: 0.34.1
    0.33.1     round-trips: true  corpus version: 0.33.1
    0.32.1     round-trips: true  corpus version: 0.32.1
    current: 0.34.1
    |}]
;;

(* Every URL the app emits carries the build, because a seed number without one
   is not an address. A link that drops back to a bare path silently moves the
   reader to whichever build [current] names, onto a page that looks correct. *)
let attrs html ~pattern =
  String.substr_index_all html ~may_overlap:false ~pattern
  |> List.iter ~f:(fun i ->
    let start = i + String.length pattern in
    let stop = String.index_from_exn html start '"' in
    print_endline (String.sub html ~pos:start ~len:(stop - start)))
;;

let%expect_test "every emitted link carries the version" =
  let module Query = Seed_corpus.Query in
  let version = Served.to_version Served.current in
  let summary : Seed_corpus.Level.Summary.t =
    { seed = "12345"
    ; temple = Some "D:5"
    ; artefacts = 1
    ; rare_altars = []
    ; portals = []
    ; boons = []
    ; heat = None
    }
  in
  let html =
    Seed_web.Views.seed_list ~version ~page:Query.Page.first [ summary ]
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  attrs html ~pattern:"href=\"";
  [%expect
    {|
    /0.34.1/seed/12345
    /0.34.1/?limit=50
    |}]
;;

let%expect_test "list tags carry the tile of the thing they name, boons first" =
  let module Query = Seed_corpus.Query in
  let version = Served.to_version Served.current in
  let summary : Seed_corpus.Level.Summary.t =
    { seed = "12345"
    ; temple = Some "D:5"
    ; artefacts = 1
    ; rare_altars = [ "altar_lugonu" ]
    ; portals = [ "IceCv", Some "D:6"; "Sewer", Some "D:3" ]
    ; boons = [ Seed_corpus.Boon.Experience, 2; Seed_corpus.Boon.Acquirement, 1 ]
    ; heat = None
    }
  in
  let html =
    Seed_web.Views.seed_list ~version ~page:Query.Page.first [ summary ]
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  let tags = String.substr_index_all html ~may_overlap:false ~pattern:"class=\"tag " in
  List.iter tags ~f:(fun i ->
    let stop = String.index_from_exn html i '>' in
    let close = String.substr_index_exn html ~pos:stop ~pattern:"</span>" in
    let body = String.sub html ~pos:stop ~len:(close - stop) in
    let tile =
      match String.substr_index body ~pattern:"/static/tiles/" with
      | None -> "(no tile)"
      | Some j ->
        let start = j + String.length "/static/tiles/" in
        String.sub body ~pos:start ~len:(String.index_from_exn body start '"' - start)
    in
    let text =
      String.filter body ~f:(fun c -> not (Char.equal c '<'))
      |> String.split_on_chars ~on:[ '>' ]
      |> List.last_exn
      |> String.strip
    in
    printf "%-32s %s\n" tile text);
  [%expect
    {|
    items/potion_experience.png      2 xp
    items/scroll_acquirement.png     acq
    altars/lugonu.png                Lugonu
    gateways/ice_cave_portal.png     IceCv D:6
    gateways/sewer_portal.png        Sewer D:3
    |}]
;;

(* The picker is the densest source of build-carrying links on the site, so it
   gets the same guard the views do. The counts are rendered here too, since
   "0 seeds" and a dropped build read identically and mean opposite things. *)
let%expect_test "the build picker links to every served build with its count" =
  let version = Served.to_version Served.current in
  let builds = List.map Served.all ~f:(fun t -> t, 1234) in
  let html =
    Seed_web.render_fragment
      (Seed_web.Index.masthead
         ~version:(Some version)
         ~builds
         ~here:Seed_web.Index.Page.Seeds)
  in
  attrs html ~pattern:"href=\"";
  printf
    "showing marked once: %b\n"
    (List.length (String.substr_index_all html ~may_overlap:false ~pattern:"· showing")
     = 1);
  printf "counts formatted: %b\n" (String.is_substring html ~substring:"1,234 seeds");
  [%expect
    {|
    /0.34.1/
    /0.34.1/
    /0.34.1/search
    /0.34.1/about
    /0.34.1/
    /0.33.1/
    /0.32.1/
    showing marked once: true
    counts formatted: true
    |}]
;;

(* With no counts there is nothing to choose between, so the build falls back
   to a plain link. That is the error chrome's case. *)
let%expect_test "no counts means no picker" =
  let version = Served.to_version Served.current in
  let html =
    Seed_web.render_fragment
      (Seed_web.Index.masthead
         ~version:(Some version)
         ~builds:[]
         ~here:Seed_web.Index.Page.Seeds)
  in
  printf "picker present: %b\n" (String.is_substring html ~substring:"build-picker");
  attrs html ~pattern:"href=\"";
  [%expect
    {|
    picker present: false
    /0.34.1/
    /0.34.1/
    /0.34.1/search
    /0.34.1/about
    /0.34.1/
    |}]
;;

(* The seed page's deepen button and its poll are both paths now, so both are
   checked: a POST target that lost the version would enqueue against [current]
   rather than the build the reader is looking at. *)
let%expect_test "the deepen form and the poll carry the version" =
  let version = Served.to_version Served.current in
  let levels =
    Seed_corpus.Level.of_rows
      ~infos:[ { level = "D:1"; parent_level = None; temple_altars = None; gold = None } ]
      []
  in
  let html =
    Seed_web.Views.seed_detail
      ~version
      ~seed:"12345"
      ~job:None
      ~position:None
      ~csrf:(Some "t")
      ~filling:false
      levels
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  attrs html ~pattern:"action=\"";
  attrs html ~pattern:"hx-post=\"";
  (* A queued job is what renders the poll, so it takes its own render: the
     button and the poll are never on the page at the same time. *)
  let queued : Seed_corpus.Job.t =
    { seed = "12345"
    ; version
    ; depth = "Swamp:4"
    ; queued_at = 1000
    ; started_at = None
    ; finished_at = None
    ; attempts = 0
    ; error = None
    }
  in
  let polling =
    Seed_web.Views.depth_note
      ~version
      ~seed:"12345"
      ~depth:(Seed_corpus.Fill_depth.of_levels [ "D:1" ])
      ~job:(Some queued)
      ~position:None
      ~csrf:None
      ~filling:false
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  attrs polling ~pattern:"hx-get=\"";
  [%expect
    {|
    /0.34.1/seed/12345/deepen
    /0.34.1/seed/12345/deepen
    /0.34.1/seed/12345/depth
    |}]
;;

(* The about page is the one place that deliberately links off the site, so the
   guard is inverted: rather than checking every link carries the build, it pins
   exactly which links leave and which stay. crawl.develz.org appears twice
   because the page names the game in prose and cites the source separately. *)
let%expect_test "about links out three times and back into the build" =
  let version = Served.to_version Served.current in
  let html =
    Seed_web.Views.about ~version |> List.map ~f:Seed_web.render_fragment |> String.concat
  in
  attrs html ~pattern:"href=\"";
  [%expect
    {|
    https://crawl.develz.org/
    https://crawl.develz.org/
    https://github.com/jonesmelton/dcss_seeds
    https://jonesmelton.com
    /0.34.1/
    |}]
;;
