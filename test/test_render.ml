open! Core

let () = Seed_web.Views.canned_order := Fn.id

(* Format buffers output internally, so a renderer that reads its Buffer
   without flushing loses whatever is still held. Invisible while every render
   was a single element; it surfaced as soon as a fragment returned several and
   only the tail arrived. *)
let%expect_test "rendering several elements keeps all of them" =
  let open Tyxml.Html in
  let elements = [ h2 [ txt "heading" ]; div [ txt "body" ]; p [ txt "tail" ] ] in
  List.map elements ~f:Seed_web.render_fragment |> String.concat |> print_endline;
  [%expect {| <h2>heading</h2><div>body</div><p>tail</p> |}]
;;

let%expect_test "a whole document renders to its closing tag" =
  let html =
    Seed_web.render_html (Seed_web.Index.render ~title:"t" [ Tyxml.Html.txt "x" ])
  in
  printf "closes: %b\n" (String.is_suffix (String.strip html) ~suffix:"</html>");
  [%expect {| closes: true |}]
;;

(* The .ico stays first as the fallback for browsers that ignore rel=icon PNGs;
   the rest pick by sizes, which must serialise as WxH or they are skipped. *)
let%expect_test "the head offers every icon the static tree ships" =
  let html =
    Seed_web.render_html (Seed_web.Index.render ~title:"t" [ Tyxml.Html.txt "x" ])
  in
  let re = Re.Pcre.re "<link[^>]*icon[^>]*>" |> Re.compile in
  Re.all re html |> List.iter ~f:(fun g -> print_endline (Re.Group.get g 0));
  [%expect
    {|
    <link rel="icon" href="/favicon.ico" type="image/x-icon"/>
    <link rel="icon" href="/static/favicon-32.png" type="image/png" sizes="32x32"/>
    <link rel="icon" href="/static/favicon-16.png" type="image/png" sizes="16x16"/>
    <link rel="apple-touch-icon" href="/static/apple-touch-icon.png"/>
    |}]
;;

module Job = Seed_corpus.Job
module Query = Seed_corpus.Query

let v = Or_error.ok_exn (Query.Version.of_string "0.34.1")

let job ?started_at ?finished_at ?error () =
  { Job.seed = "300"
  ; version = v
  ; depth = "Swamp:4"
  ; queued_at = 1000
  ; started_at
  ; finished_at
  ; attempts = 0
  ; error
  ; origin = Job.Origin.Deepen
  }
;;

let note ?position ?(filling = false) ~depth ~job ~csrf () =
  Seed_web.Views.depth_note ~version:v ~seed:"300" ~depth ~job ~position ~csrf ~filling
  |> List.map ~f:Seed_web.render_fragment
  |> String.concat
;;

let shallow = Seed_corpus.Fill_depth.shallow
let deep = Seed_corpus.Fill_depth.of_levels [ "Swamp:4" ]

let%expect_test "a shallow seed states its depth, and offers the button" =
  let html =
    note ~depth:shallow ~job:None ~csrf:(Some "<input name=\"dream.csrf\"/>") ()
  in
  printf
    "says depth: %b\n"
    (String.is_substring
       html
       ~substring:"Searched to <strong><span class=\"level\">D:8</span></strong>");
  printf "has button: %b\n" (String.is_substring html ~substring:"</button>");
  printf "has token:  %b\n" (String.is_substring html ~substring:"dream.csrf");
  printf "polls:      %b\n" (String.is_substring html ~substring:"hx-trigger");
  [%expect
    {|
    says depth: true
    has button: true
    has token:  true
    polls:      false
    |}]
;;

(* A deep seed has nothing left to ask for, so no button and no token -- which
   is also why the handler skips the queue lookup for one. *)
let%expect_test "a deep seed states its depth and offers nothing" =
  let html = note ~depth:deep ~job:None ~csrf:None () in
  print_endline html;
  [%expect
    {| <div id="depth" class="depth-note"><p>Searched to <strong><span class="level">D:14</span></strong>.</p></div> |}]
;;

(* No progress bar in either waiting state: crawl emits nothing incremental.
   State is carried by text, never by colour alone. *)
let%expect_test "a waiting job says what is happening and polls for the answer" =
  List.iter
    [ "queued", job (); "running", job ~started_at:1010 () ]
    ~f:(fun (label, j) ->
      let html = note ~depth:shallow ~job:(Some j) ~csrf:(Some "") () in
      printf
        "%-8s polls:%b button:%b\n"
        label
        (String.is_substring html ~substring:"hx-trigger=\"every 5s\"")
        (String.is_substring html ~substring:"</button>"));
  [%expect
    {|
    queued   polls:true button:false
    running  polls:true button:false
    |}]
;;

(* seed_levels is the authority on how deep a seed is; ingest_jobs only records
   that someone asked. The two disagree in a real window -- ingest commits the
   levels and the generator can die before it sets finished_at. *)
let%expect_test "a deep seed is deep even while its job still reads running" =
  List.iter
    [ "running", job ~started_at:1010 ()
    ; "queued", job ()
    ; "failed", job ~started_at:1010 ~error:"crawl exited 1" ()
    ]
    ~f:(fun (label, j) ->
      let html = note ~depth:deep ~job:(Some j) ~csrf:(Some "") () in
      printf
        "%-8s deep:%b polls:%b button:%b\n"
        label
        (String.is_substring
           html
           ~substring:"Searched to <strong><span class=\"level\">D:14</span></strong>")
        (String.is_substring html ~substring:"hx-trigger")
        (String.is_substring html ~substring:"</button>"));
  [%expect
    {|
    running  deep:true polls:false button:false
    queued   deep:true polls:false button:false
    failed   deep:true polls:false button:false
    |}]
;;

let%expect_test "a queued job says where it is in the line" =
  List.iter [ None; Some 0; Some 1; Some 7 ] ~f:(fun position ->
    let html = note ?position ~depth:shallow ~job:(Some (job ())) ~csrf:(Some "") () in
    (* The sentence with the wrapper's markup stripped, so the test reads as
       the reader's line rather than as a div. *)
    let sentence =
      String.split html ~on:'<'
      |> List.filter_map ~f:(fun chunk ->
        match String.lsplit2 chunk ~on:'>' with
        | Some (_, text) when not (String.is_empty (String.strip text)) -> Some text
        | _ -> None)
      |> String.concat
      |> String.strip
    in
    printf
      "%-6s %s\n"
      (Option.value_map position ~default:"none" ~f:Int.to_string)
      sentence);
  [%expect
    {|
    none   Queued to search to Swamp:4.
    0      Queued to search to Swamp:4. Next in queue.
    1      Queued to search to Swamp:4. 1 ahead in queue.
    7      Queued to search to Swamp:4. 7 ahead in queue.
    |}]
;;

let%expect_test "a failed job shows the reason and offers the button again" =
  let html =
    note
      ~depth:shallow
      ~job:(Some (job ~started_at:1010 ~error:"crawl exited 1" ()))
      ~csrf:(Some "")
      ()
  in
  printf "shows why:  %b\n" (String.is_substring html ~substring:"crawl exited 1");
  printf "has button: %b\n" (String.is_substring html ~substring:"</button>");
  printf "polls:      %b\n" (String.is_substring html ~substring:"hx-trigger");
  [%expect
    {|
    shows why:  true
    has button: true
    polls:      false
    |}]
;;

module Level = Seed_corpus.Level
module Record = Seed_corpus.Record

let entry
      ?feat
      ?cost
      ?shop_type
      ?toll_note
      ?timeout_turns
      ?x
      ?y
      ?(spells = [])
      ?(cat = Record.Cat.Items)
      ~name
      ()
  : Record.Entry.t
  =
  { cat
  ; name
  ; base_type = None
  ; sub_type = None
  ; quantity = None
  ; artefact = None
  ; branded = None
  ; plus = None
  ; cost
  ; ego = None
  ; feat
  ; timeout_turns
  ; unique_mons = None
  ; native = None
  ; type_name = None
  ; x
  ; y
  ; carried_by = None
  ; shop_type
  ; toll_note
  ; spells
  ; props = []
  }
;;

let detail ?gold entries =
  Seed_web.Views.seed_detail
    ~version:v
    ~seed:"100"
    ~job:None
    ~position:None
    ~csrf:None
    ~flag:None
    ~filling:false
    [ { Level.level = "D:5"; parent_level = None; temple_altars = None; gold; entries } ]
  |> List.map ~f:Seed_web.render_fragment
  |> String.concat
;;

(* A vault may name a jewellery shop "Sanarr's Fire Supplies", so what it sells
   is a fact its name does not carry. Naming the type beside a shop whose name
   already says it would print the same word twice. *)
let%expect_test "a shop's type is named only when its name does not say it" =
  List.iter
    [ "John Lambton's Dragon-Slaying Spoils", "Armour"
    ; "Raing's General Store", "General Store"
    ; "Afalofit's Book Shoppe", "Book"
    ]
    ~f:(fun (name, shop_type) ->
      let html =
        detail
          [ entry
              ~cat:Record.Cat.Features
              ~feat:"enter_shop"
              ~name
              ~shop_type
              ~x:1
              ~y:1
              ()
          ]
      in
      printf
        "%-38s names it: %b\n"
        name
        (String.is_substring html ~substring:(sprintf "(%s)" shop_type)));
  [%expect
    {|
    John Lambton's Dragon-Slaying Spoils   names it: true
    Raing's General Store                  names it: false
    Afalofit's Book Shoppe                 names it: false
    |}]
;;

(* A book's spell set is the reason to pick it up and no name carries it. A
   parchment's single spell is already its name minus the prefix. *)
let%expect_test "a book lists its spells, a parchment does not repeat its own" =
  List.iter
    [ entry ~name:"Notes on Translocation" ~spells:[ "Apportation"; "Summon Forest" ] ()
    ; entry ~name:"parchment of Apportation" ~spells:[ "Apportation" ] ()
    ]
    ~f:(fun e ->
      let html = detail [ e ] in
      printf
        "%-28s lists spells: %b\n"
        e.name
        (String.is_substring html ~substring:"class=\"spells\""));
  [%expect
    {|
    Notes on Translocation       lists spells: true
    parchment of Apportation     lists spells: false
    |}]
;;

module Search = Seed_corpus.Search

(* The heterogeneous term these tests use is a bare property: it matches
   unrelated artefacts, which is what makes [count] and [distinct] come apart. *)
let props_term =
  Search.Term.create
    (Search.Criterion.Props
       { base_type = None; props = [ "Conj" ]; position = Search.Criterion.Floor })
;;

(* The results are swapped, so anything inside them is destroyed by the
   response it was waiting for -- the indicator has to live in the form. And it
   has to be a word: the site's reduced-motion rule strips every animation. *)
let%expect_test "the search form carries a busy indicator outside the results" =
  let html =
    Seed_web.Views.search_page
      ~search:(Search.create ~version:v ~terms:[] ())
      ~suggestions:None
      ~rank:Search.Rank.default
      ~more:`End
      []
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  let form, results =
    let i = Option.value_exn (String.substr_index html ~pattern:"id=\"results\"") in
    String.prefix html i, String.drop_prefix html i
  in
  printf
    "points at it:  %b\n"
    (String.is_substring html ~substring:"hx-indicator=\"#search-busy\"");
  printf "in the form:   %b\n" (String.is_substring form ~substring:"id=\"search-busy\"");
  printf
    "in the results: %b\n"
    (String.is_substring results ~substring:"id=\"search-busy\"");
  printf "is a word:     %b\n" (String.is_substring form ~substring:"searching");
  printf
    "guards double: %b\n"
    (String.is_substring html ~substring:"hx-disabled-elt=\"find button\"");
  [%expect
    {|
    points at it:  true
    in the form:   true
    in the results: false
    is a word:     true
    guards double: true
    |}]
;;

(* A trove is the only entrance whose price is the difference between one and
   another, so the toll rides in the branch index beside the timer. *)
let%expect_test "a trove's toll is named in the branch index" =
  let html =
    detail
      [ entry
          ~cat:Record.Cat.Features
          ~feat:"enter_trove"
          ~name:"a portal to a secret trove of treasure"
          ~timeout_turns:512
          ~toll_note:"give a scroll of acquirement"
          ~x:4
          ~y:9
          ()
      ]
  in
  List.iter
    [ "give a scroll of acquirement"; "toll "; "expires in " ]
    ~f:(fun substring ->
      printf "%-30s %b\n" substring (String.is_substring html ~substring));
  [%expect
    {|
    give a scroll of acquirement   true
    toll                           true
    expires in                     true
    |}]
;;

(* "floor gold", never "gold": the number counts the piles on the ground, so it
   excludes monster drops and Gozag and is a lower bound. *)
let%expect_test "floor gold is labelled as the lower bound it is" =
  let shown gold =
    let html = detail ?gold [ entry ~name:"potion of curing" ~x:1 ~y:1 () ] in
    ( String.is_substring html ~substring:"floor gold"
    , String.is_substring html ~substring:"431" )
  in
  List.iter [ Some 431; Some 0; None ] ~f:(fun gold ->
    let labelled, amount = shown gold in
    printf
      "%-8s labelled: %b amount: %b\n"
      (Sexp.to_string [%sexp (gold : int option)])
      labelled
      amount);
  [%expect
    {|
    (431)    labelled: true amount: true
    (0)      labelled: false amount: false
    ()       labelled: false amount: false
    |}]
;;

(* A fill holds the corpus write lock for hours and the generator yields to it,
   so a button pressed mid-fill enqueues a job nothing will claim until the fill
   ends. Saying so beats a control whose only outcome is a wait with no stated
   cause, and beats the older behaviour where the heartbeat went stale and the
   press came back "nothing can search that build deeper" -- which is false. *)
let%expect_test "a fill in progress explains itself instead of offering the button" =
  let html =
    Seed_web.Views.depth_note
      ~version:v
      ~seed:"300"
      ~depth:shallow
      ~job:None
      ~position:None
      ~csrf:(Some "")
      ~filling:true
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  printf
    "says depth: %b\n"
    (String.is_substring
       html
       ~substring:"Searched to <strong><span class=\"level\">D:8</span></strong>");
  printf
    "explains:   %b\n"
    (String.is_substring html ~substring:"Deeper searches are paused");
  printf "has button: %b\n" (String.is_substring html ~substring:"</button>");
  printf "polls:      %b\n" (String.is_substring html ~substring:"hx-trigger");
  [%expect
    {|
    says depth: true
    explains:   true
    has button: false
    polls:      false
    |}]
;;

(* A job already queued when the fill started still polls: it is genuinely
   waiting and will be served. Only the offer of new work is withdrawn. *)
let%expect_test "a fill does not silence a job already in the queue" =
  let html =
    Seed_web.Views.depth_note
      ~version:v
      ~seed:"300"
      ~depth:shallow
      ~job:(Some (job ()))
      ~position:(Some 0)
      ~csrf:(Some "")
      ~filling:true
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  printf "polls:   %b\n" (String.is_substring html ~substring:"hx-trigger");
  printf "queued:  %b\n" (String.is_substring html ~substring:"Queued to search");
  [%expect
    {|
    polls:   true
    queued:  true
    |}]
;;

(* The htmx response swaps only the results, so the form is whatever the last
   full page render left behind. A term box is added by rendering one more blank
   box than there are terms, which means the form has to come back with the
   results, out of band. Without it a scripted reader is stuck at one box while
   a scripting-off reader is not. *)
let%expect_test "the htmx response carries a form with a box for the next term" =
  let search = Search.create ~version:v ~terms:[ props_term ] () in
  let html =
    Seed_web.Views.search_fragment
      ~search
      ~suggestions:None
      ~rank:Search.Rank.default
      ~more:`End
      []
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  let boxes =
    String.substr_index_all html ~may_overlap:false ~pattern:"name=\"has\"" |> List.length
  in
  (* A morph, not a replace: the reader is typing in the blank box while the
     request is in flight, and an outerHTML swap would discard text and
     focus. *)
  printf
    "swaps the form:  %b\n"
    (String.is_substring html ~substring:"hx-swap-oob=\"outerMorph\"");
  printf "form is targeted: %b\n" (String.is_substring html ~substring:"id=\"search\"");
  printf "term boxes:      %d\n" boxes;
  [%expect
    {|
    swaps the form:  true
    form is targeted: true
    term boxes:      2
    |}]
;;

(* Each filled box gets a remove button naming its own term, so a reader can
   take one condition off a conjunction without retyping the rest. The blank box
   gets none -- there is nothing to remove -- and no placeholder either: a
   term-shaped placeholder in the box below a term reads as a duplicate of it. *)
let%expect_test "each term box carries a remove button, the blank box does not" =
  let term s = Or_error.ok_exn (Seed_web.Params.term_of_string ~version:v s) in
  let search =
    Search.create ~version:v ~terms:[ term "name~bear"; term "potion:experience" ] ()
  in
  let html =
    Seed_web.Views.search_page
      ~search
      ~suggestions:None
      ~rank:Search.Rank.default
      ~more:`End
      []
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  let count pattern =
    String.substr_index_all html ~may_overlap:false ~pattern |> List.length
  in
  printf "term boxes:       %d\n" (count "name=\"has\"");
  printf "remove buttons:   %d\n" (count "name=\"drop\"");
  printf
    "names its term:   %b\n"
    (String.is_substring html ~substring:"value=\"name~bear\"");
  printf
    "names its box:    %b\n"
    (String.is_substring html ~substring:"value=\"0:name~bear\"");
  (* Two boxes holding the same term get 0 and 1, so each X names its own. *)
  printf
    "dupes distinct:   %b\n"
    (let dupes =
       Search.create ~version:v ~terms:[ term "name~bear"; term "name~bear" ] ()
     in
     let html =
       Seed_web.Views.search_page
         ~search:dupes
         ~suggestions:None
         ~rank:Search.Rank.default
         ~more:`End
         []
       |> List.map ~f:Seed_web.render_fragment
       |> String.concat
     in
     String.is_substring html ~substring:"value=\"0:name~bear\""
     && String.is_substring html ~substring:"value=\"1:name~bear\"");
  printf "labelled:         %b\n" (String.is_substring html ~substring:"Remove name~bear");
  printf
    "no placeholder:   %b\n"
    (not (String.is_substring html ~substring:"placeholder"));
  (* Every box carries a value attribute, the blank one included. Morph syncs an
     input's value property only on the branch that *sets* an attribute; the
     branch that removes one calls removeAttribute and nothing else. A box going
     from a value to none -- which is what the last box does whenever a term is
     removed from the middle -- would keep showing the old term. *)
  printf
    "blank has value:  %b\n"
    (String.is_substring html ~substring:"name=\"has\" value=\"\"");
  [%expect
    {|
    term boxes:       3
    remove buttons:   2
    names its term:   true
    names its box:    true
    dupes distinct:   true
    labelled:         true
    no placeholder:   true
    blank has value:  true
    |}]
;;

(* Implicit submission activates the first submit button in tree order, and the
   remove buttons precede the search button. Without a default ahead of them,
   pressing Enter in a term box submits "drop=0:<first term>" -- the reader
   silently loses an unrelated term instead of searching. *)
let%expect_test "the first submit button in the form is a search, not a removal" =
  let term s = Or_error.ok_exn (Seed_web.Params.term_of_string ~version:v s) in
  let search =
    Search.create ~version:v ~terms:[ term "potion:haste"; term "wand:digging" ] ()
  in
  let html =
    Seed_web.Views.search_page
      ~search
      ~suggestions:None
      ~rank:Search.Rank.default
      ~more:`End
      []
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  let form =
    let i = Option.value_exn (String.substr_index html ~pattern:"<form") in
    let j = Option.value_exn (String.substr_index html ~pattern:"</form>") in
    String.sub html ~pos:i ~len:(j - i)
  in
  let first =
    let i = Option.value_exn (String.substr_index form ~pattern:"<button") in
    String.sub form ~pos:i ~len:(String.index_from_exn form i '>' - i + 1)
  in
  printf "%s\n" first;
  printf "carries no drop: %b\n" (not (String.is_substring first ~substring:"drop"));
  [%expect
    {|
    <button type="submit" class="default-submit" tabindex="-1" aria-hidden="true">
    carries no drop: true
    |}]
;;

(* Morph matches by id first and only falls back to a positional soft match, so
   without ids the blank box is matched onto the previous blank -- the one the
   reader typed the just-submitted term into -- and morph leaves a dirty input's
   value property alone. The result is the submitted term echoed into the empty
   box below it. Ids are positional, so box n only ever matches box n and the
   new blank comes back empty. *)
let%expect_test "term boxes carry positional ids, blank box included" =
  let term s = Or_error.ok_exn (Seed_web.Params.term_of_string ~version:v s) in
  let search =
    Search.create ~version:v ~terms:[ term "name~lance"; term "wand:digging" ] ()
  in
  let html =
    Seed_web.Views.search_page
      ~search
      ~suggestions:None
      ~rank:Search.Rank.default
      ~more:`End
      []
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  let ids =
    String.substr_index_all html ~may_overlap:false ~pattern:"id=\"term-"
    |> List.map ~f:(fun i ->
      let start = i + String.length "id=\"" in
      String.sub html ~pos:start ~len:(String.index_from_exn html start '"' - start))
  in
  List.iter ids ~f:(printf "%s\n");
  [%expect
    {|
    term-row-0
    term-0
    term-row-1
    term-1
    term-row-2
    term-2
    |}]
;;

(* htmx swaps a 4xx like any other response and takes the document title from
   it, so a rejected query leaves "Bad request" in the tab. The title is
   therefore a property of every search response, not only the full-page
   render. *)
let%expect_test "the htmx response carries the title, so an error does not stick" =
  let search = Search.create ~version:v ~terms:[ props_term ] () in
  let html =
    Seed_web.Views.search_fragment
      ~search
      ~suggestions:None
      ~rank:Search.Rank.default
      ~more:`End
      []
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  printf "carries a title: %b\n" (String.is_substring html ~substring:"<title>");
  [%expect {| carries a title: true |}]
;;

(* A term-less search is a reader who has not asked anything yet, not a request
   for the whole corpus. Answering it with the first page of an unfiltered scan
   prints seeds 1, 10, 100, 1000 -- string order, no relation to the reader --
   and pays for a full-table read to do it. *)
let%expect_test "a search with no terms prompts instead of listing seeds" =
  let html =
    Seed_web.Views.search_page
      ~search:(Search.create ~version:v ~terms:[] ())
      ~suggestions:None
      ~rank:Search.Rank.default
      ~more:`End
      []
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  printf "has a form:     %b\n" (String.is_substring html ~substring:"id=\"search\"");
  printf "prompts:        %b\n" (String.is_substring html ~substring:"Enter a term");
  printf "no results table: %b\n" (not (String.is_substring html ~substring:"<table"));
  printf
    "no all-seeds heading: %b\n"
    (not (String.is_substring html ~substring:"all seeds on"));
  printf
    "no empty-corpus claim: %b\n"
    (not (String.is_substring html ~substring:"No seeds for this build"));
  [%expect
    {|
    has a form:     true
    prompts:        true
    no results table: true
    no all-seeds heading: true
    no empty-corpus claim: true
    |}]
;;

(* A shop whose stock is entirely mundane emits no item rows: crawl's own
   item_ignore_boring drops unbranded, non-enchanted weapons and armour before
   the extractor sees them. The footer states what the corpus holds rather than
   diagnosing why. *)
let%expect_test "a shop with no notable stock says so without implying a gap" =
  let shop stock =
    detail
      (entry
         ~cat:Record.Cat.Features
         ~feat:"enter_shop"
         ~name:"an Armour Shop"
         ~x:53
         ~y:18
         ()
       :: stock)
  in
  List.iter
    [ "empty", shop []
    ; "stocked", shop [ entry ~name:"+2 plate armour" ~cost:1913 ~x:53 ~y:18 () ]
    ]
    ~f:(fun (label, html) ->
      printf
        "%-8s no notable stock: %b | not recorded: %b\n"
        label
        (String.is_substring html ~substring:"no notable stock")
        (String.is_substring html ~substring:"stock not recorded"));
  [%expect
    {|
    empty    no notable stock: true | not recorded: false
    stocked  no notable stock: false | not recorded: false
    |}]
;;

(* The exemplar carries no quantity when the term's total is spread over other
   items; only the seed-level total is stated, and its separator is decorative. *)
let%expect_test "a heterogeneous hit states its total apart from its exemplar" =
  let module Search = Seed_corpus.Search in
  let version = Or_error.ok_exn (Seed_corpus.Query.Version.of_string "0.34.1") in
  let term = props_term in
  let hit ~name ~count ~distinct =
    { Search.Match.term; level = "D:3"; name; count; distinct }
  in
  let matches =
    [ { Search.Match.seed = "1000158"
      ; hits = [ hit ~name:"+8 storm bow {elec, penet}" ~count:16 ~distinct:16 ]
      }
    ; { Search.Match.seed = "1000200"
      ; hits = [ hit ~name:"2 potions of haste" ~count:2 ~distinct:1 ]
      }
    ; { Search.Match.seed = "1000300"
      ; hits = [ hit ~name:"potion of haste" ~count:3 ~distinct:1 ]
      }
    ; { Search.Match.seed = "1000400"
      ; hits = [ hit ~name:"2 potions of haste" ~count:4 ~distinct:1 ]
      }
    ]
  in
  let search = Search.create ~version ~terms:[ term ] () in
  let html =
    Seed_web.Views.search_results ~search ~rank:Search.Rank.default ~more:`End matches
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  String.substr_index_all html ~may_overlap:false ~pattern:{|<ul class="hits">|}
  |> List.iter ~f:(fun pos ->
    let rest = String.subo html ~pos in
    let stop = Option.value_exn (String.substr_index rest ~pattern:"</ul>") in
    print_endline (String.sub rest ~pos:0 ~len:stop));
  [%expect
    {|
    <ul class="hits"><li>+8 storm bow {elec, penet} on <span class="level">D:3</span><span class="hit-total">16 artefacts</span></li>
    <ul class="hits"><li>2 potions of haste on <span class="level">D:3</span></li>
    <ul class="hits"><li>potion of haste ×3 on <span class="level">D:3</span></li>
    <ul class="hits"><li>2 potions of haste on <span class="level">D:3</span><span class="hit-total">4 in all</span></li>
    |}]
;;

(* The datalist is ~580 options the browser filters by prefix, so nothing about
   properties is reachable until the reader has typed "props". The placeholder
   is the only surface visible before the first keystroke, and it names a
   property form for that reason. It appears on an empty form only: under an
   existing term a term-shaped placeholder reads as a duplicate of it. *)
let%expect_test "the empty form is placeheld; a form with terms is not" =
  let render search =
    Seed_web.Views.search_page
      ~search
      ~suggestions:None
      ~rank:Search.Rank.default
      ~more:`End
      []
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  let empty = render (Search.create ~version:v ()) in
  printf
    "empty form placeheld:  %b\n"
    (String.is_substring empty ~substring:"placeholder");
  printf "names a prop form:     %b\n" (String.is_substring empty ~substring:"props:Conj");
  let term s = Or_error.ok_exn (Seed_web.Params.term_of_string ~version:v s) in
  let filled = render (Search.create ~version:v ~terms:[ term "potion:haste" ] ()) in
  printf
    "blank under a term:    %b\n"
    (not (String.is_substring filled ~substring:"placeholder"));
  [%expect
    {|
    empty form placeheld:  true
    names a prop form:     true
    blank under a term:    true
    |}]
;;

(* Property and brand suggestions are labelled, since a bare "props:Conj" in a
   list of item pairs does not say what kind of thing it is. Item pairs are
   not: they are the datalist's bulk and a label on every row is noise. *)
let%expect_test "property and brand suggestions carry a label, item pairs do not" =
  let html =
    Seed_web.Views.search_page
      ~search:(Search.create ~version:v ())
      ~suggestions:(Some [ "potion:haste"; "props:Conj"; "armour ego:fire resistance" ])
      ~rank:Search.Rank.default
      ~more:`End
      []
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  printf
    "prop labelled:    %b\n"
    (String.is_substring html ~substring:"Conj — artefact property");
  printf
    "brand labelled:   %b\n"
    (String.is_substring html ~substring:"fire resistance — armour brand");
  printf
    "pair unlabelled:  %b\n"
    (not (String.is_substring html ~substring:"potion:haste\" label"));
  [%expect
    {|
    prop labelled:    true
    brand labelled:   true
    pair unlabelled:  true
    |}]
;;

let%expect_test "an empty search offers three canned searches as links" =
  let html =
    Seed_web.Views.search_page
      ~search:(Search.create ~version:v ~terms:[] ())
      ~suggestions:None
      ~rank:Search.Rank.default
      ~more:`End
      []
    |> List.map ~f:Seed_web.render_fragment
    |> String.concat
  in
  let offers = String.substr_index_all html ~may_overlap:false ~pattern:"/search?has=" in
  printf "links: %d\n" (List.length offers);
  [%expect {| links: 3 |}]
;;
