open! Core
module Boon = Seed_corpus.Boon
module Depth = Seed_corpus.Depth
module Floor = Seed_corpus.Floor
module Level = Seed_corpus.Level
module Query = Seed_corpus.Query
module Record = Seed_corpus.Record
module Exclusion = Seed_corpus.Exclusion
module Temple = Seed_corpus.Temple
module Tile = Seed_corpus.Tile
module Fill_depth = Seed_corpus.Fill_depth
module Job = Seed_corpus.Job
module Heat = Seed_corpus.Heat
open Tyxml.Html
module Svg = Tyxml.Svg

let th_col label = th [ txt label ]
let th_num label = th ~a:[ a_class [ "num" ] ] [ txt label ]

let version_path version =
  "/" ^ Dream.to_percent_encoded (Query.Version.to_string version)
;;

let seed_href ~version ~seed =
  sprintf "%s/seed/%s" (version_path version) (Dream.to_percent_encoded seed)
;;

(* Copy-to-clipboard glyph. Accessible name and tooltip provide the label.
   Confirmation swaps glyph for check via class toggle (copy.js). *)
let clipboard_icon =
  svg
    ~a:
      [ Svg.a_viewBox (0., 0., 16., 16.)
      ; Svg.a_width (16., None)
      ; Svg.a_height (16., None)
      ; Svg.a_fill `None
      ; Svg.a_stroke (`Color ("currentColor", None))
      ; Svg.a_stroke_width (1.3, None)
      ; Svg.a_stroke_linejoin `Round
      ]
    [ Svg.rect
        ~a:
          [ Svg.a_x (5.25, None)
          ; Svg.a_y (5.25, None)
          ; Svg.a_width (7.5, None)
          ; Svg.a_height (9.5, None)
          ; Svg.a_rx (1.5, None)
          ]
        []
    ; Svg.path
        ~a:
          [ Svg.a_d
              "M10.75 5.25V2.75a1.5 1.5 0 0 0-1.5-1.5h-5a1.5 1.5 0 0 0-1.5 1.5v7a1.5 1.5 \
               0 0 0 1.5 1.5h1.5"
          ]
        []
    ]
;;

let check_icon =
  svg
    ~a:
      [ Svg.a_viewBox (0., 0., 16., 16.)
      ; Svg.a_width (16., None)
      ; Svg.a_height (16., None)
      ; Svg.a_fill `None
      ; Svg.a_stroke (`Color ("currentColor", None))
      ; Svg.a_stroke_width (1.6, None)
      ; Svg.a_stroke_linecap `Round
      ; Svg.a_stroke_linejoin `Round
      ]
    [ Svg.path ~a:[ Svg.a_d "M3 8.5 6.5 12 13 4.5" ] [] ]
;;

let copy_seed seed =
  button
    ~a:
      [ a_button_type `Button
      ; a_class [ "copy-seed" ]
      ; a_user_data "copy" seed
      ; a_user_data "copy-done" (sprintf "Copied seed %s" seed)
      ; a_user_data "copy-fail" (sprintf "Could not copy seed %s" seed)
      ; a_title (sprintf "Copy seed %s" seed)
      ; a_aria "label" [ sprintf "Copy seed %s" seed ]
      ]
    [ span ~a:[ a_class [ "icon"; "icon-copy" ] ] [ clipboard_icon ]
    ; span ~a:[ a_class [ "icon"; "icon-done" ] ] [ check_icon ]
    ]
;;

(* Native [details]: keyboard operable, open-on-print, htmx-safe. *)
let help_note ~label body =
  details
    ~a:[ a_class [ "help" ] ]
    (summary [ txt label ])
    [ div ~a:[ a_class [ "help-body" ] ] body ]
;;

(* Empty alt: name is beside it. No tile prints nothing; safe because
   [Floor.display_name] only trims names for items certain to have a tile. *)
let tile_of path =
  match path with
  | None -> []
  | Some path ->
    [ img
        ~src:(sprintf "/static/tiles/%s" (Tile.to_string path))
        ~alt:""
        ~a:[ a_class [ "tile" ]; a_width 32; a_height 32; a_aria "hidden" [ "true" ] ]
        ()
    ]
;;

let tile feat = tile_of (Option.bind feat ~f:Tile.of_feat)
let entry_tile e = tile_of (Tile.of_entry e)

let seed_list ~version ~(page : Query.Page.t) summaries =
  (* Em dash, not empty: every seed has a Temple; blank would read as "none". *)
  let unknown = span ~a:[ a_class [ "unknown" ] ] [ txt "—" ] in
  (* Four-tick gauge plus band word. Total match so a new band is a compile
     error. [None] renders as [unknown]: absence is about the corpus, [Cold]
     is about the seed. *)
  let heat_mark (band : Heat.Band.t option) =
    match band with
    | None -> unknown
    | Some band ->
      let modifier =
        match band with
        | Heat.Band.Cold -> "heat--cold"
        | Warm -> "heat--warm"
        | Hot -> "heat--hot"
        | Blazing -> "heat--blazing"
      in
      span
        ~a:[ a_class [ "heat-mark"; modifier ] ]
        [ span
            ~a:[ a_class [ "heat-gauge" ]; a_aria "hidden" [ "true" ] ]
            [ i []; i []; i []; i [] ]
        ; span ~a:[ a_class [ "heat-band" ] ] [ txt (Heat.Band.to_string band) ]
        ]
  in
  let row (s : Level.Summary.t) =
    let highlights =
      (* Boons lead: they are the one find worth the same to every character,
         where an altar and a portal are each worth a detour only to someone
         who wants what is behind them. *)
      List.map s.boons ~f:(fun (boon, count) ->
        let label =
          if count > 1 then sprintf "%d %s" count (Boon.label boon) else Boon.label boon
        in
        span
          ~a:[ a_class [ "tag"; "tag--boon" ]; a_title (Boon.name boon) ]
          (tile_of
             (Tile.of_item
                ~base_type:(Boon.base_type boon)
                ~sub_type:(Boon.sub_type boon)
                ~artefact:false)
           @ [ txt label ]))
      @ List.map s.rare_altars ~f:(fun feat ->
        span
          ~a:[ a_class [ "tag"; "tag--altar" ] ]
          (tile (Some feat) @ [ txt (Temple.god_name feat) ]))
      @ List.map s.portals ~f:(fun (level, parent) ->
        let where =
          match parent with
          | Some p -> sprintf "%s %s" level p
          | None -> level
        in
        span
          ~a:[ a_class [ "tag"; "tag--portal" ] ]
          (tile (Depth.feat_of_portal level) @ [ txt where ]))
    in
    tr
      [ td
          [ a
              ~a:[ a_href (seed_href ~version ~seed:s.seed); a_class [ "seed" ] ]
              [ txt s.seed ]
          ; copy_seed s.seed
          ]
      ; td
          ~a:[ a_class [ "num" ] ]
          [ (match s.temple with
             | Some level -> txt level
             | None -> unknown)
          ]
      ; td
          ~a:[ a_class [ "num" ] ]
          [ (if s.artefacts = 0 then unknown else txt (Int.to_string s.artefacts)) ]
      ; td ~a:[ a_class [ "heat" ] ] [ heat_mark s.heat ]
      ; td
          ~a:[ a_class [ "tags" ] ]
          (if List.is_empty highlights then [ unknown ] else highlights)
      ]
  in
  (* Not rel=next: re-samples, not an ordered set. *)
  let next =
    if List.is_empty summaries
    then []
    else
      [ p
          [ a
              ~a:[ a_href (sprintf "%s/?limit=%d" (version_path version) page.limit) ]
              [ txt "Show me some others →" ]
          ]
      ]
  in
  let jump =
    form
      ~a:[ a_action (version_path version ^ "/jump"); a_method `Get; a_class [ "jump" ] ]
      [ label ~a:[ a_label_for "jump-seed" ] [ txt "Go to seed" ]
      ; input
          ~a:
            [ a_input_type `Text
            ; a_id "jump-seed"
            ; a_name "seed"
            ; a_inputmode `Numeric
            ; a_autocomplete `Off
            ; a_placeholder "e.g. 1204"
            ]
          ()
      ; button ~a:[ a_button_type `Submit ] [ txt "Go" ]
      ]
  in
  [ jump ]
  @ (if List.is_empty summaries
     then [ p [ txt "No seeds have been ingested for this build yet." ] ]
     else
       [ div
           ~a:[ a_class [ "table-scroll"; "table-scroll--wide" ] ]
           [ table
               ~a:[ a_class [ "seed-list" ] ]
               ~caption:
                 (caption
                    [ help_note
                        ~label:"How to read this table"
                        [ p
                            [ txt
                                "A handful of seeds from this build, picked at random. A \
                                 seed number says nothing about what the seed holds, so \
                                 there is no first or last one. Search to find seeds by \
                                 their contents."
                            ]
                        ; p
                            [ txt
                                "Everything here is what the first eight floors (D:8) \
                                 hold: artefacts are the ones lying on the floor, not \
                                 shop stock, heat is a rough unsorted mark of how the \
                                 seed compares to others at that same D:8 depth, and a \
                                 dash means nothing that shallow rather than nothing at \
                                 all."
                            ]
                        ; p
                            [ txt "Under "
                            ; em [ txt "others" ]
                            ; txt
                                ": \"acq\" is a scroll of acquirement and \"xp\" \
                                 a                                  potion of \
                                 experience, both lying on the floor \
                                 rather                                  than for sale. \
                                 They lead the cell because they \
                                 are                                  worth the same to \
                                 every character, where an altar or \
                                 a                                  portal is worth a \
                                 detour only if you want what \
                                 is                                  behind it."
                            ]
                        ]
                    ])
               ~thead:
                 (thead
                    [ tr
                        [ th_col "seed"
                        ; th_num "temple"
                        ; th_num "artefacts"
                        ; th ~a:[ a_class [ "heat" ] ] [ txt "heat" ]
                        ; th ~a:[ a_class [ "tags" ] ] [ txt "others" ]
                        ]
                    ])
               (List.map summaries ~f:row)
           ]
       ])
  @ next
;;

(* Words and weight first, colour layered on top: the classes set weight and
   style as well as hue, so the distinction survives grayscale, print, and a
   colour vision deficiency.

   "enchantment" rather than crawl's "ego"/"brand". [ego] subsumes [branded],
   [implied] suppresses facts the surrounding context already states. *)
(* Coordinates are a game fact, not a page fact. [Record.Entry.position] owns
   the rule. Shown on seed page only, never search results. *)
let position (e : Record.Entry.t) =
  match Record.Entry.position e with
  | Some (x, y) -> [ txt (sprintf "%d,%d" x y) ]
  | None -> []
;;

(* Held open so the axis survives alternating uniques and floor items. *)
let xy e = span ~a:[ a_class [ "xy" ] ] (position e)

(* Crawl's own name already carries quantity -- "2 potions of haste" -- so a
   column would print the 2 twice and leave a blank on every singular row. *)

(* Crawl writes an artefact's properties as a braced clause on the end of its
   name. Splitting it lets the identity read first without inventing a second
   column that would be blank on every ordinary row. *)
let thing_name name =
  match String.lsplit2 name ~on:'{' with
  | Some (base, props) when String.is_suffix props ~suffix:"}" ->
    [ txt (String.rstrip base)
    ; txt " "
    ; span ~a:[ a_class [ "props" ] ] [ txt ("{" ^ props) ]
    ]
  | _ -> [ txt name ]
;;

(* One flag per line, naming the rarest thing about it. *)
let flag (e : Record.Entry.t) =
  let mark cls text = [ span ~a:[ a_class [ "flag"; cls ] ] [ txt text ] ] in
  match Boon.of_entry e with
  | Some boon -> mark "boon" (Boon.label boon)
  | None ->
    (match e.artefact, e.carried_by, e.ego, e.branded with
     | Some true, _, _, _ -> mark "gold" "artefact"
     | _, Some m, _, _ -> mark "ember" (sprintf "on %s" m)
     | _, _, Some ego, _ -> mark "ember" ego
     | _, _, _, Some true -> mark "ember" "enchanted"
     | _ -> [ span ~a:[ a_class [ "flag" ] ] [] ])
;;

(* Book spells shown inline; parchment's spell is already its name. *)
let spell_list (e : Record.Entry.t) =
  match e.spells with
  | [] -> []
  | [ spell ] when String.is_suffix e.name ~suffix:spell -> []
  | spells ->
    [ span ~a:[ a_class [ "spells" ] ] [ txt (String.concat ~sep:", " spells) ] ]
;;

(* Every line is the same three-column shape -- the thing, its flag, its
   coordinate -- so a reader can run down either axis or ignore both. *)
let line ?(extra = []) (e : Record.Entry.t) =
  div
    ~a:[ a_class [ "line" ] ]
    ([ span
         ~a:[ a_class [ "thing" ] ]
         (entry_tile e @ thing_name (Floor.display_name e) @ extra @ spell_list e)
     ]
     @ flag e
     @ [ xy e ])
;;

let lines entries = List.map entries ~f:(fun e -> line e)

(* Crawl names a portal entrance for how it looks, not where it goes -- "a
   sand-covered staircase" is an Ossuary -- so the destination is named beside
   it. A branch stair whose name already says the branch is left alone. *)
let ways_on_lines entries =
  List.map entries ~f:(fun (e : Record.Entry.t) ->
    let destination =
      match Option.bind e.feat ~f:Floor.Entrance.branch_of_feat with
      | Some branch
        when not
               (String.is_substring
                  (String.lowercase e.name)
                  ~substring:(String.lowercase branch)) ->
        [ span ~a:[ a_class [ "destination" ] ] [ txt (sprintf " (%s)" branch) ] ]
      | _ -> []
    in
    line ~extra:destination e)
;;

(* "unique" is the rail label, not a per-line mark. Carried loot shown inline. *)
let unique_line carried (e : Record.Entry.t) =
  let carrying =
    match Hashtbl.find carried e.name with
    | None | Some [] -> []
    | Some items ->
      [ span
          ~a:[ a_class [ "props" ] ]
          [ txt (sprintf "— carrying %s" (String.concat ~sep:", " (List.rev items))) ]
      ]
  in
  let flagged =
    match carrying with
    | [] -> [ span ~a:[ a_class [ "flag" ] ] [] ]
    | _ -> [ span ~a:[ a_class [ "flag"; "ember" ] ] [ txt "armed" ] ]
  in
  div
    ~a:[ a_class [ "line" ] ]
    ([ span ~a:[ a_class [ "thing" ] ] (entry_tile e @ [ txt e.name ] @ carrying) ]
     @ flagged
     @ [ span ~a:[ a_class [ "xy" ] ] [] ])
;;

(* Consumables rendered inline; each keeps its tile for class identification. *)
let run entries =
  List.map entries ~f:(fun (e : Record.Entry.t) ->
    let a =
      match Record.Entry.position e with
      | Some (x, y) -> [ a_title (sprintf "%d, %d" x y) ]
      | None -> []
    in
    span
      ~a:(a_class [ "sundry" ] :: a)
      (entry_tile e @ [ i [ txt (Floor.display_name e) ] ]))
;;

(* A god outside crawl's temple pool is the altar worth crossing a floor for; a
   pool god stands in every seed's Temple. Also set bold, because the palette
   must never be the only thing saying so. *)
let altar_field altars =
  List.map altars ~f:(fun (a : Floor.Altar.t) ->
    let cls = if a.in_pool then [] else [ a_class [ "rare" ] ] in
    span ~a:cls (tile (Some a.feat) @ [ txt a.god ]))
;;

(* Shop rendered as a bill: stock above, total ruled off. *)
let bill (s : Floor.Shop.t) =
  let where =
    match s.x, s.y with
    | Some x, Some y -> [ span ~a:[ a_class [ "xy" ] ] [ txt (sprintf "%d,%d" x y) ] ]
    | _ -> []
  in
  (* Shop type shown when the name does not already contain it. *)
  let kind =
    match s.shop_type with
    | Some shop_type
      when not
             (String.is_substring
                (String.lowercase s.name)
                ~substring:(String.lowercase shop_type)) ->
      [ span ~a:[ a_class [ "destination" ] ] [ txt (sprintf " (%s)" shop_type) ] ]
    | _ -> []
  in
  let row (e : Record.Entry.t) =
    let tick =
      if Option.value e.artefact ~default:false
      then [ span ~a:[ a_class [ "tick" ] ] [ txt "artefact" ] ]
      else []
    in
    tr
      [ td (entry_tile e @ thing_name (Floor.display_name e) @ tick)
      ; td
          ~a:[ a_class [ "amt" ] ]
          [ txt (Option.value_map e.cost ~default:"" ~f:Int.to_string) ]
      ]
  in
  let count = List.length s.stock in
  let summary =
    if count = 0
    then "no notable stock"
    else if s.artefacts = count
    then sprintf "%d items, all artefacts" count
    else sprintf "%d items" count
  in
  let foot =
    tfoot
      [ tr
          [ td [ txt summary ]
          ; td
              ~a:[ a_class [ "amt" ] ]
              [ (if count = 0 then txt "" else txt (sprintf "%d gp" s.total)) ]
          ]
      ]
  in
  div
    ~a:[ a_class [ "bill-wrap" ] ]
    [ table
        ~a:[ a_class [ "bill" ] ]
        ~caption:
          (caption
             [ div
                 ~a:[ a_class [ "bill-head" ] ]
                 (span ~a:[ a_class [ "shop-name" ] ] (txt s.name :: kind) :: where)
             ])
        ~tfoot:foot
        (List.map s.stock ~f:row)
    ]
;;

(* Rail carries part label; cell carries content. Empty parts omitted. *)
let sheet_row ?(cell_class = []) label body =
  if List.is_empty body
  then []
  else
    [ div
        ~a:[ a_class [ "row" ] ]
        [ div ~a:[ a_class [ "rail" ] ] [ txt label ]
        ; div ~a:[ a_class ("cell" :: cell_class) ] body
        ]
    ]
;;

(* A second shop on one floor repeats a label already set directly above it,
   as a repeated grouping value is elided in a table. The rail is emitted rather
   than hidden so the grid keeps its column. *)
let sheet_row_cont label body =
  [ div
      ~a:[ a_class [ "row" ] ]
      [ div ~a:[ a_class [ "rail"; "cont" ] ] [ txt label ]
      ; div ~a:[ a_class [ "cell" ] ] body
      ]
  ]
;;

let level_heading (l : Level.t) =
  match l.parent_level with
  | None -> [ txt l.level ]
  | Some parent ->
    [ txt l.level
    ; txt " "
    ; span ~a:[ a_class [ "sc"; "from"; "portal" ] ] [ txt (sprintf "from %s" parent) ]
    ]
;;

let level_section (l : Level.t) =
  let f = Floor.of_level l in
  (* Gather carried items back onto their unique. *)
  let carried = Hashtbl.create (module String) in
  List.iter (f.notable @ f.sundries) ~f:(fun (e : Record.Entry.t) ->
    Option.iter e.carried_by ~f:(fun m -> Hashtbl.add_multi carried ~key:m ~data:e.name));
  let shops =
    match f.shops with
    | [] -> []
    | first :: rest ->
      let label = if List.is_empty rest then "shop" else "shops" in
      sheet_row label [ bill first ]
      @ List.concat_map rest ~f:(fun s -> sheet_row_cont label [ bill s ])
  in
  let body =
    (* Reading order: threats, exits, loot, shops. *)
    sheet_row
      (if List.length f.monsters = 1 then "unique" else "uniques")
      (List.map f.monsters ~f:(unique_line carried))
    @ sheet_row "stairs and portals" (ways_on_lines f.ways_on)
    @ sheet_row "altars" ~cell_class:[ "field" ] (altar_field f.altars)
    @ sheet_row "notable" (lines f.notable)
    @ sheet_row "also here" ~cell_class:[ "run" ] (run f.sundries)
    @ sheet_row "features" (lines f.features)
    @ shops
  in
  match body with
  | [] -> []
  | body ->
    let facts =
      match Floor.standing_facts f l with
      | [] -> []
      | facts ->
        [ div ~a:[ a_class [ "ledger-facts" ] ] [ txt (String.concat ~sep:" · " facts) ] ]
    in
    (* One breakout for the whole floor. *)
    [ section
        ~a:[ a_class [ "floor" ] ]
        (div
           ~a:[ a_class [ "ledger-head" ] ]
           (h2 ~a:[ a_class [ "ledger-depth" ] ] (level_heading l) :: facts)
         :: body)
    ]
;;

(* Branch and portal entrances, collected from per-level rows into one block.

   A portal is distinguished by its timer: the one entrance a player can arrive
   at too late. A trove's toll sits beside the timer for the same reason. *)
let branch_index entrances =
  if List.is_empty entrances
  then
    [ p
        ~a:[ a_class [ "subtitle" ] ]
        [ txt
            "No branch or portal entrance within the extracted floors. Deeper than them, \
             not absent."
        ]
    ]
  else
    [ ul
        ~a:[ a_class [ "branches" ] ]
        (List.map entrances ~f:(fun (e : Floor.Entrance.t) ->
           let timer =
             match e.timeout_turns with
             | None -> []
             | Some turns ->
               [ span
                   ~a:[ a_class [ "timer" ] ]
                   [ span ~a:[ a_class [ "sc" ] ] [ txt "expires in " ]
                   ; span ~a:[ a_class [ "num" ] ] [ txt (Int.to_string turns) ]
                   ; txt " turns"
                   ]
               ]
           in
           let toll =
             match e.toll_note with
             | None -> []
             | Some note ->
               [ span
                   ~a:[ a_class [ "toll" ] ]
                   [ span ~a:[ a_class [ "sc" ] ] [ txt "toll " ]; txt note ]
               ]
           in
           li
             ([ span
                  ~a:[ a_class [ "branch-name" ] ]
                  (tile (Some e.feat) @ [ txt e.branch ])
              ; span ~a:[ a_class [ "num"; "branch-level" ] ] [ txt e.level ]
              ]
              @ timer
              @ toll)))
    ]
;;

(* Exclusive draws as axes with values. Unseen groups keep their row. Caption
   distinguishes absence at this depth from exclusion. *)
let exclusive_draws draws =
  let row ((g : Exclusion.Group.t), (draw : Exclusion.Draw.t)) =
    let value, ruled_out =
      match draw with
      | Exclusion.Draw.Drew member ->
        ( [ span ~a:[ a_class [ "drew" ] ] [ txt member ] ]
        , List.filter g.members ~f:(fun m -> not (String.equal m member)) )
      (* Nothing is ruled out by a group that has not been answered. *)
      | Exclusion.Draw.Unseen ->
        [ span ~a:[ a_class [ "unknown" ] ] [ txt "—" ] ], g.members
      (* Exclusivity holds across every seed measured, so this row is a broken
         model rather than an interesting seed. *)
      | Exclusion.Draw.Conflict members ->
        ( [ span
              ~a:[ a_class [ "flag"; "ember" ] ]
              [ txt (sprintf "both: %s" (String.concat ~sep:", " members)) ]
          ]
        , [] )
    in
    li
      [ span ~a:[ a_class [ "branch-name" ] ] [ txt g.name ]
      ; span ~a:[ a_class [ "draw-value" ] ] value
      ; span ~a:[ a_class [ "draw-alts" ] ] [ txt (String.concat ~sep:" / " ruled_out) ]
      ]
  in
  [ ul ~a:[ a_class [ "branches"; "draws" ] ] (List.map draws ~f:row) ]
;;

let depth_note_id = "depth"

(* Depth.t is an integer; D:n is the level at reach depth n. *)
let depth_as_level depth = sprintf "D:%d" depth

let deepen_button ~version ~seed ~csrf =
  match csrf with
  | None -> []
  | Some csrf ->
    [ form
        ~a:
          [ a_method `Post
          ; a_action (seed_href ~version ~seed ^ "/deepen")
          ; a_class [ "deepen" ]
          ; Tyxml_htmx.hx_post (seed_href ~version ~seed ^ "/deepen")
          ; Tyxml_htmx.hx_target ("#" ^ depth_note_id)
          ; Tyxml_htmx.hx_swap_raw "outerHTML"
          ]
        [ (* CSRF tag spliced as raw markup; server-generated, no reader input. *)
          Unsafe.data csrf
        ; button
            ~a:[ a_button_type `Submit ]
            [ txt (sprintf "Search down to %s" Fill_depth.deep_cap) ]
        ]
    ]
;;

(* Polling, not SSE: jobs take tens of seconds, few readers have one
   outstanding, and synchronous storage should not hold connections. *)
let polling_attrs ~seed ~version =
  [ Tyxml_htmx.hx_get (seed_href ~version ~seed ^ "/depth")
  ; Tyxml_htmx.hx_trigger "every 5s"
  ; Tyxml_htmx.hx_swap_raw "outerHTML"
  ]
;;

(* The levels are the authority on how deep a seed is; the job row only records
   that someone asked. They disagree in a real window -- ingest commits the
   levels and the generator can die before it sets finished_at -- so a deep seed
   is reported deep whatever its job says. *)
(* Position 0 is "next", not "0 ahead": a count of nothing is the one case the
   number reads worse than the word. The build is named because the count is per
   build -- a generator claims per version, so an unqualified "3 ahead" would be
   a claim about a queue that does not exist. *)
let queue_place position =
  match position with
  | None -> []
  | Some 0 -> [ txt " It is next in line for this build." ]
  | Some 1 -> [ txt " One request is ahead of it on this build." ]
  | Some n -> [ txt (sprintf " %d requests are ahead of it on this build." n) ]
;;

(* Fill holds the write lock for hours; button withdrawn with reason rather
   than letting enqueue succeed and strand the reader on the wrong cause. *)
let filling_note =
  p
    [ txt
        "Deeper searches are paused: this build is busy building out the corpus. They \
         resume when it finishes."
    ]
;;

let depth_note ~version ~seed ~depth ~job ~position ~csrf ~filling =
  let wrap ?(extra = []) children =
    [ div ~a:(a_id depth_note_id :: a_class [ "depth-note" ] :: extra) children ]
  in
  let searched_to = depth_as_level depth in
  let job = if Fill_depth.is_deep depth then None else job in
  match (job : Job.t option) with
  | Some job when Job.State.equal (Job.state job) Job.State.Running ->
    wrap
      ~extra:(polling_attrs ~seed ~version)
      [ p
          [ txt
              (sprintf
                 "Searching this seed down to %s. It takes a few seconds."
                 Fill_depth.deep_cap)
          ]
      ]
  | Some job when Job.State.equal (Job.state job) Job.State.Queued ->
    wrap
      ~extra:(polling_attrs ~seed ~version)
      [ p
          (txt
             (sprintf
                "Queued for a deeper search, down to %s. Waiting for a free generator."
                Fill_depth.deep_cap)
           :: queue_place position)
      ]
  | Some { error = Some error; _ } ->
    wrap
      ([ p
           ~a:[ a_class [ "failed" ] ]
           [ txt "That deeper search did not finish: "; txt error ]
       ]
       @ if filling then [ filling_note ] else deepen_button ~version ~seed ~csrf)
  | _ when Fill_depth.is_deep depth ->
    wrap
      [ p
          [ txt "Searched down to "
          ; strong [ txt searched_to ]
          ; txt ", past the usual cap. The branches below are the whole of it."
          ]
      ]
  | _ ->
    (* Without this sentence, absence reads as fact about the seed. *)
    wrap
      ([ p
           [ txt "Searched down to "
           ; strong [ txt searched_to ]
           ; txt
               ". The levels end there because that is how far this seed was searched, \
                not because the dungeon does."
           ]
       ]
       @ if filling then [ filling_note ] else deepen_button ~version ~seed ~csrf)
;;

let refusal ~seed ~version message =
  [ div
      ~a:[ a_id depth_note_id; a_class [ "depth-note" ] ]
      [ p [ txt message ]
      ; p [ a ~a:[ a_href (seed_href ~version ~seed) ] [ txt "Reload this seed" ] ]
      ]
  ]
;;

let seed_detail ~version ~seed ~job ~position ~csrf ~filling levels =
  let depth = Fill_depth.of_levels (List.map levels ~f:(fun (l : Level.t) -> l.level)) in
  [ h1 [ span ~a:[ a_class [ "seed" ] ] [ txt seed ]; copy_seed seed ]
  ; p [ a ~a:[ a_href (version_path version ^ "/") ] [ txt "← All seeds" ] ]
  ]
  @ depth_note ~version ~seed ~depth ~job ~position ~csrf ~filling
  @ [ h2 [ txt "Ways on" ] ]
  @ branch_index (Floor.entrances levels)
  @ [ h2 [ txt "Exclusive draws" ]
    ; help_note
        ~label:"What is an exclusive draw?"
        [ p
            [ txt
                "Crawl draws one member of each group per game, so a seed holding one \
                 cannot hold the others anywhere, at any depth. The trailing names are \
                 what this seed's draw rules out. A dash means no member turned up in \
                 the extracted floors, which is not the same as the group being \
                 excluded, since only a drawn member is evidence."
            ]
        ]
    ]
  @ exclusive_draws (Exclusion.draws levels)
  @ List.concat_map (Floor.in_reach_order levels) ~f:level_section
;;

module Search = Seed_corpus.Search

let search_query_string (search : Search.t) ~rank ~after =
  let param key value = sprintf "%s=%s" key (Dream.to_percent_encoded value) in
  [ List.map search.terms ~f:(fun term -> param "has" (Search.Term.to_query_string term))
  ; (match rank with
     | rank when Search.Rank.equal rank Search.Rank.default -> []
     | rank -> [ param "rank" (Search.Rank.to_string rank) ])
  ; (match after with
     | None -> []
     | Some seed -> [ param "after" seed ])
  ]
  |> List.concat
  |> String.concat ~sep:"&"
;;

let search_help_path version = version_path version ^ "/search/help"

(* GET form: result sets are links, works without scripting. htmx removes
   round-trip flash. [hx_push_url] keeps results linkable across swaps; morph
   swap preserves focus in the term box. *)
let results_id = "results"
let form_id = "search"
let suggestions_id = "term-suggestions"

(* Indicator in the form, not results: the swap replaces results' children. *)
let busy_id = "search-busy"

let search_form ?(oob = false) (search : Search.t) ~suggestions =
  let list_attr =
    match suggestions with
    | Some _ -> [ a_list suggestions_id ]
    | None -> []
  in
  let existing =
    List.map search.terms ~f:(fun term ->
      let value = Search.Term.to_query_string term in
      li [ input ~a:([ a_input_type `Text; a_name "has"; a_value value ] @ list_attr) () ])
  in
  let blank =
    li
      [ input
          ~a:
            ([ a_input_type `Text; a_name "has"; a_placeholder "potion:haste" ]
             @ list_attr)
          ()
      ]
  in
  let action = version_path search.version ^ "/search" in
  let suggestion_list =
    match suggestions with
    | Some options ->
      [ datalist
          ~a:[ a_id suggestions_id ]
          ~children:
            (`Options (List.map options ~f:(fun v -> option ~a:[ a_value v ] (txt ""))))
          ()
      ]
    | None -> []
  in
  form
    ~a:
      ([ a_method `Get
       ; a_action action
       ; a_id form_id
       ; a_class [ "search" ]
       ; Tyxml_htmx.hx_get action
       ; Tyxml_htmx.hx_target ("#" ^ results_id)
       ; Tyxml_htmx.hx_swap Tyxml_htmx.Swap.InnerMorph
       ; Tyxml_htmx.hx_push_url "true"
       ; Tyxml_htmx.hx_indicator ("#" ^ busy_id)
       ; Tyxml_htmx.hx_disabled_elt "find button"
       ]
       @ if oob then [ Tyxml_htmx.hx_swap_oob "outerMorph" ] else [])
    (suggestion_list
     @ [ ul ~a:[ a_class [ "terms" ] ] (existing @ [ blank ])
       ; p
           ~a:[ a_id "search-help"; a_class [ "subtitle" ] ]
           [ txt
               "One term per box: potion:haste, 3x potion:haste, floor potion:haste, \
                shop wand:digging, enter_shop, artefact, unique:Sigmund, \
                name~Throatcutter. "
           ; a
               ~a:[ a_href (search_help_path search.version) ]
               [ txt "Full syntax, with examples" ]
           ]
       ; div
           ~a:[ a_class [ "search-controls" ] ]
           [ button ~a:[ a_button_type `Submit ] [ txt "Search" ]
           ; span ~a:[ a_id busy_id; a_class [ "busy" ] ] [ txt "searching…" ]
           ]
       ])
;;

let hit_line (h : Search.Match.hit) =
  let count = if h.count > 1 then sprintf " ×%d" h.count else "" in
  li [ txt h.name; txt count; txt " on "; span ~a:[ a_class [ "sc" ] ] [ txt h.level ] ]
;;

let search_results ~(search : Search.t) ~rank ~more matches =
  let heading = h2 [ txt (Search.to_string search) ] in
  let row (m : Search.Match.t) =
    tr
      [ td
          [ a
              ~a:
                [ a_href (seed_href ~version:search.version ~seed:m.seed)
                ; a_class [ "seed" ]
                ]
              [ txt m.seed ]
          ; copy_seed m.seed
          ]
      ; td [ ul ~a:[ a_class [ "hits" ] ] (List.map m.hits ~f:hit_line) ]
      ]
  in
  let next =
    match List.last matches with
    | Some (last : Search.Match.t) when [%compare.equal: [ `More | `End ]] more `More ->
      (* Seed order pages by keyset, so the cursor is the last seed; any other
         ranking pages by offset into the ranked order, so it is a count. *)
      let after =
        if Search.Rank.equal rank Search.Rank.Seed
        then last.seed
        else (
          let consumed =
            Option.value_map search.page.after ~default:0 ~f:(fun s ->
              Option.value (Int.of_string_opt s) ~default:0)
          in
          Int.to_string (consumed + List.length matches))
      in
      [ p
          [ a
              ~a:
                [ a_href
                    (sprintf
                       "%s/search?%s"
                       (version_path search.version)
                       (search_query_string search ~rank ~after:(Some after)))
                ; a_rel [ `Next ]
                ]
              [ txt "Next page →" ]
          ]
      ]
    | _ -> []
  in
  let count = List.length matches in
  let tally =
    if count = 0
    then []
    else
      [ p
          ~a:[ a_class [ "subtitle" ] ]
          [ span ~a:[ a_class [ "num" ] ] [ txt (Int.to_string count) ]
          ; txt (if count = 1 then " seed" else " seeds")
          ; txt
              (match more with
               | `More -> " on this page, and more beyond it."
               | `End -> ".")
          ]
      ]
  in
  ([ heading ] @ tally)
  @
  if List.is_empty matches
  then
    [ p
        [ txt
            (if Search.is_empty search
             then "No seeds have been ingested for this build yet."
             else "No seed in this build matches every term.")
        ]
    ]
  else
    [ div
        ~a:[ a_class [ "table-scroll"; "table-scroll--wide" ] ]
        [ table
            ~thead:(thead [ tr [ th_col "seed"; th_col "what was found" ] ])
            (List.map matches ~f:row)
        ]
    ]
    @ next
;;

(* Placeholder when search is disabled. No form, no query parsing. *)
let search_unavailable =
  [ h1 [ txt "Search" ]
  ; p ~a:[ a_class [ "subtitle" ] ] [ txt "Search is coming soon." ]
  ]
;;

(* htmx swaps 4xx responses and takes the title from them; a rejected query
   leaves "Bad request" in the tab. Title travels with every search response. *)
let search_title = "which seeds have…"
let search_title_element = Unsafe.node "title" [ txt search_title ]

let search_page ~(search : Search.t) ~suggestions ~rank ~more matches =
  [ search_form search ~suggestions
  ; div ~a:[ a_id results_id ] (search_results ~search ~rank ~more matches)
  ]
;;

(* Swap targets results; form travels out of band so scripted readers get new
   term boxes. *)
let search_fragment ~(search : Search.t) ~suggestions ~rank ~more matches =
  search_results ~search ~rank ~more matches
  @ [ search_form ~oob:true search ~suggestions; search_title_element ]
;;

(* Examples are live links, not inert syntax. Version-scoped: a parchment
   example is real on 0.34.1 and empty on 0.33.1. *)

let example_search ~version terms =
  let query =
    List.map terms ~f:(fun t -> sprintf "has=%s" (Dream.to_percent_encoded t))
    |> String.concat ~sep:"&"
  in
  version_path version ^ "/search?" ^ query
;;

(* Term is the link; a second column of identical link text is noise. *)
let example_row ~version (terms, gloss) =
  tr
    [ td
        [ a
            ~a:[ a_href (example_search ~version terms); a_class [ "term-example" ] ]
            [ txt (String.concat terms ~sep:" + ") ]
        ]
    ; td [ txt gloss ]
    ]
;;

let example_table ~version rows =
  div
    ~a:[ a_class [ "table-scroll" ] ]
    [ table
        ~thead:(thead [ tr [ th_col "term"; th_col "what it asks" ] ])
        (List.map rows ~f:(example_row ~version))
    ]
;;

let search_help ~version =
  let examples = example_table ~version in
  [ h1 [ txt "How to search" ]
  ; p
      ~a:[ a_class [ "subtitle" ] ]
      [ txt
          "Every box is one term, and a seed must satisfy all of them. Each example \
           below is a link. Follow it to see what it returns on this build."
      ]
  ; h2 [ txt "Items" ]
  ; p
      [ txt "An item is named by its type, not by how it reads on the floor: "
      ; code [ txt "potion:haste" ]
      ; txt
          ", where the first half is the base type and the second is the bare sub type. \
           Type is the stable half: a display name carries enchantment, brand and \
           artefact epithet, so searching it finds one seed rather than the thousands \
           that hold the same item."
      ]
  ; examples
      [ [ "potion:haste" ], "a potion of haste, anywhere on the extracted floors"
      ; [ "wand:digging" ], "a wand of digging"
      ; [ "scroll:acquirement" ], "a scroll of acquirement"
      ; ( [ "weapon:executioner's axe" ]
        , "an executioner's axe. A sub type can contain spaces and apostrophes" )
      ]
  ; h2 [ txt "Floor or shop" ]
  ; p
      [ txt
          "A price is the only thing separating shop stock from loot lying on the \
           ground. An unqualified item term matches either; "
      ; code [ txt "floor " ]
      ; txt " and "
      ; code [ txt "shop " ]
      ; txt
          " ask for one side of that split. Prefer the floor form when the point is that \
           you can pick the thing up: a shop item costs gold a character on D:2 does not \
           have."
      ]
  ; examples
      [ [ "potion:haste" ], "a potion of haste on the floor or behind a counter"
      ; [ "floor potion:haste" ], "one lying on the ground, not for sale"
      ; [ "shop wand:digging" ], "a wand of digging in a shop's stock"
      ]
  ; help_note
      ~label:"Why a floor search can return fewer seeds than you expect"
      [ p
          [ txt
              "The split applies to counts as well. A seed with two potions on the \
               ground and a third in a shop satisfies "
          ; code [ txt "3x potion:haste" ]
          ; txt " but not "
          ; code [ txt "3x floor potion:haste" ]
          ; txt
              ", which wants three you can walk over. So a floor search is not the same \
               as running the plain search and ignoring the shop hits. It can match \
               strictly fewer seeds, and that is the question it is asking."
          ]
      ]
  ; h2 [ txt "How many" ]
  ; p
      [ txt "An affix qualifies any term. "
      ; code [ txt "3x " ]
      ; txt
          " in front sets a minimum count, and it counts items rather than piles: a \
           single stack of three satisfies it."
      ]
  ; examples
      [ [ "3x potion:haste" ], "at least three potions of haste"
      ; [ "3x floor potion:haste" ], "three potions of haste on the ground, not for sale"
      ]
  ; h2 [ txt "Features" ]
  ; p
      [ txt
          "Branch entrances and shops are named in crawl's own vocabulary, with no \
           prefix. The blank term box suggests them as you type. Altars are not \
           searchable."
      ]
  ; examples
      [ [ "enter_shop" ], "any shop at all"
      ; [ "enter_lair" ], "the Lair entrance"
      ; [ "enter_sewer" ], "a sewer portal"
      ]
  ; h2 [ txt "Artefacts, uniques and names" ]
  ; p
      [ txt "An unrand's display name carries a varying enchantment prefix, so "
      ; code [ txt "name~" ]
      ; txt
          " matches a substring of it (at least three characters). It reaches only the \
           names the corpus stores whole (artefacts, unrands and monsters), because an \
           ordinary item's name is rebuilt from its type rather than kept. For anything \
           with a type, the type is both faster and more accurate."
      ]
  ; examples
      [ [ "artefact" ], "any artefact, randart or unrand"
      ; [ "name~Throatcutter" ], "the unrand, at whatever enchantment it rolled"
      ; [ "unique:Sigmund" ], "Sigmund, generated somewhere in the extracted floors"
      ]
  ; help_note
      ~label:"Why name~ does not find a potion of haste"
      [ p
          [ txt
              "The corpus stores a name only where it cannot rebuild one from the other \
               columns, which is 92% of rows saved. A potion of haste has no stored \
               name; it is reconstructed from "
          ; code [ txt "potion" ]
          ; txt " and "
          ; code [ txt "haste" ]
          ; txt " when it is shown to you. So "
          ; code [ txt "name~potion of haste" ]
          ; txt " matches nothing, and "
          ; code [ txt "potion:haste" ]
          ; txt
              " is the term for that question, being a lookup on the type itself rather \
               than a search through every name."
          ]
      ]
  ; h2 [ txt "Combining terms" ]
  ; p
      [ txt
          "Every box is another condition the seed must meet. There is no \"or\": two \
           alternatives are two searches whose results you can compare, which keeps each \
           one a set intersection an index can answer quickly."
      ]
  ; examples
      [ ( [ "enter_lair"; "unique:Sigmund" ]
        , "the Lair entrance and Sigmund, both generated" )
      ; ( [ "shop wand:digging"; "artefact" ]
        , "a wand of digging for sale, and an artefact somewhere in the extracted floors"
        )
      ]
  ; h2 [ txt "What a search cannot tell you" ]
  ; p
      [ txt
          "A seed is only searched as deep as it has been extracted, and most are \
           extracted to D:8. \"No Wyrmbane here\" and \"not searched deep enough to \
           know\" are different answers, and a term matching nothing may be either. Each \
           seed's page says how deep it went, and offers to go deeper."
      ]
  ; p [ a ~a:[ a_href (version_path version ^ "/search") ] [ txt "← Back to search" ] ]
  ]
;;

(* Outbound links marked as leaving the site. *)
let outbound ~href label =
  a ~a:[ a_href href; a_class [ "outbound" ]; a_rel [ `Noopener ] ] [ txt label ]
;;

let about ~version =
  [ h1 [ txt "About" ]
  ; p
      ~a:[ a_class [ "subtitle" ] ]
      [ txt "A catalog of what "
      ; outbound ~href:"https://crawl.develz.org/" "Dungeon Crawl Stone Soup"
      ; txt
          " generates on a given seed, for browsing and comparing seeds against each \
           other."
      ]
  ; h2 [ txt "What this is" ]
  ; p
      [ txt
          "Start a seeded game and the dungeon is fixed before you take a step: the same \
           seed on the same build always lays out the same floors, with the same items \
           on them. This site reads the first several floors of many seeds ahead of time \
           and writes down what it found."
      ]
  ; h2 [ txt "The build is part of the seed" ]
  ; p
      [ txt
          "A seed number on its own tells you nothing. The same number generates an \
           entirely different dungeon on every version of crawl, so every page here is \
           scoped to one build named at the top."
      ]
  ; h2 [ txt "How much of the seed space is here" ]
  ; p
      [ txt
          "Very little! There are more possible seeds than anyone will ever play, even \
           billions of them would be something like 0.0000001% of the seeds. We got a \
           lot of them, hopefully you can find something cool. If you're looking for \
           something very very specific it may still be out there in the other \
           99.99999999% of the seeds."
      ]
  ; p
      [ txt
          "Each seed is also only searched down to dungeon floor 8 to start with. You \
           can deepen individual seeds down to the end of the main dungeon, including \
           Orc, Lair, and their branches. Seed heat is calculated based on the D:8 read, \
           not a total assessment of the seed."
      ]
  ; h2 [ txt "The game" ]
  ; p
      [ txt "Dungeon Crawl Stone Soup is free and open source, and lives at "
      ; outbound ~href:"https://crawl.develz.org/" "crawl.develz.org"
      ; txt
          ". This project is not affiliated with DCSS. It is produced by running the \
           game's own dungeon generator over a lot of seeds and reading the results."
      ]
  ; h2 [ txt "The code" ]
  ; p
      [ txt "The source lives at "
      ; outbound
          ~href:"https://github.com/jonesmelton/dcss_seeds"
          "github.com/jonesmelton/dcss_seeds"
      ; txt ". Bug reports, feature requests and PRs welcome."
      ]
  ; p [ a ~a:[ a_href (version_path version ^ "/") ] [ txt "← Back to the seeds" ] ]
  ]
;;
