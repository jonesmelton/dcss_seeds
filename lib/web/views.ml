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
let level_name name = span ~a:[ a_class [ "level" ] ] [ txt name ]
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
          | Some p -> [ level_name level; txt " "; level_name p ]
          | None -> [ level_name level ]
        in
        span
          ~a:[ a_class [ "tag"; "tag--portal" ] ]
          (tile (Depth.feat_of_portal level) @ where))
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
             | Some level -> level_name level
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
              [ txt "More →" ]
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
     then [ p [ txt "No seeds for this build yet." ] ]
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
                                "A random sample of seeds from this build. Use search to \
                                 find seeds by what they contain."
                            ]
                        ; p
                            [ txt "Every column covers "
                            ; level_name "D:1"
                            ; txt " to "
                            ; level_name "D:8"
                            ; txt
                                ". Heat roughly ranks a seed against the others at that \
                                 depth. A dash means none found by "
                            ; level_name "D:8"
                            ; txt "."
                            ]
                        ; p
                            [ txt "In "
                            ; em [ txt "others" ]
                            ; txt
                                ", \"acq\" is a scroll of acquirement and \"xp\" a \
                                 potion of experience, both on the floor."
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
        [ span ~a:[ a_class [ "destination" ] ] [ txt " ("; level_name branch; txt ")" ] ]
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
  then [ p ~a:[ a_class [ "subtitle" ] ] [ txt "No branch or portal entrances found." ] ]
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
              ; span ~a:[ a_class [ "num"; "branch-level"; "level" ] ] [ txt e.level ]
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
        [ input ~a:[ a_input_type `Hidden; a_name "dream.csrf"; a_value csrf ] ()
        ; button
            ~a:[ a_button_type `Submit ]
            [ txt "Search to "; level_name Fill_depth.deep_cap ]
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

let queue_place position =
  match position with
  | None -> []
  | Some 0 -> [ txt " Next in queue." ]
  | Some n -> [ txt (sprintf " %d ahead in queue." n) ]
;;

(* Fill holds the write lock for hours; button withdrawn with reason rather
   than letting enqueue succeed and strand the reader on the wrong cause. *)
let filling_note =
  p [ txt "Deeper searches are paused while new seeds are added to this build." ]
;;

(* The levels are the authority on how deep a seed is; the job row only records
   that someone asked. They disagree in a real window -- ingest commits the
   levels and the generator can die before it sets finished_at -- so a deep seed
   is reported deep whatever its job says. *)
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
          [ txt "Searching to "
          ; level_name Fill_depth.deep_cap
          ; txt ". This takes a few seconds."
          ]
      ]
  | Some job when Job.State.equal (Job.state job) Job.State.Queued ->
    wrap
      ~extra:(polling_attrs ~seed ~version)
      [ p
          ([ txt "Queued to search to "; level_name Fill_depth.deep_cap; txt "." ]
           @ queue_place position)
      ]
  | Some { error = Some error; _ } ->
    wrap
      ([ p ~a:[ a_class [ "failed" ] ] [ txt "Deeper search failed: "; txt error ] ]
       @ if filling then [ filling_note ] else deepen_button ~version ~seed ~csrf)
  | _ when Fill_depth.is_deep depth ->
    wrap [ p [ txt "Searched to "; strong [ level_name searched_to ]; txt "." ] ]
  | _ ->
    wrap
      ([ p [ txt "Searched to "; strong [ level_name searched_to ]; txt "." ] ]
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
  @ [ h2 [ txt "Branches and portals" ] ]
  @ branch_index (Floor.entrances levels)
  @ [ h2 [ txt "Exclusive draws" ]
    ; help_note
        ~label:"What is an exclusive draw?"
        [ p
            [ txt
                "Crawl draws one member of each group per game, so a seed with one \
                 cannot have the others. A dash means we haven't seen any from that \
                 group yet in this seed so it's still unknown."
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

module Box = struct
  type offer =
    { prompt : string
    ; terms : string list
    }

  type problem =
    { message : string
    ; offer : offer option
    }

  type t =
    { value : string
    ; problem : problem option
    }

  let of_terms terms =
    List.map terms ~f:(fun term ->
      { value = Search.Term.to_query_string term; problem = None })
  ;;
end

let problem_id i = sprintf "term-%d-problem" i

(* An offer replaces its own box and keeps the rest as typed, so taking one
   never costs the reader another term. *)
let offer_href ~version ~rank ~(boxes : Box.t list) ~at offer =
  let param key value = sprintf "%s=%s" key (Dream.to_percent_encoded value) in
  let has =
    List.mapi boxes ~f:(fun i (box : Box.t) ->
      param "has" (if i = at then offer else box.value))
  in
  let rank =
    if Search.Rank.equal rank Search.Rank.default
    then []
    else [ param "rank" (Search.Rank.to_string rank) ]
  in
  sprintf "%s/search?%s" (version_path version) (String.concat ~sep:"&" (has @ rank))
;;

let search_form
      ?(oob = false)
      ?(problems = [])
      ~version
      ~rank
      ~(boxes : Box.t list)
      ~suggestions
      ()
  =
  let list_attr =
    match suggestions with
    | Some _ -> [ a_list suggestions_id ]
    | None -> []
  in
  (* Every box carries an id and a value attribute, the empty one included.
     Morph reuses a node by id and syncs an input's value property only on the
     branch that *sets* an attribute -- where the new node has none it calls
     removeAttribute and stops, leaving a box that lost its term still showing
     it. Unkeyed and valueless, both halves bite: the new blank box soft-matches
     the old blank the reader just typed the submitted term into. *)
  (* Placeheld only on an empty form, where it is the sole box. The suggestion
     list is ~580 options the browser filters by prefix, so a reader who has
     typed nothing sees its head (armour:...) and no properties at all -- those
     sit past option 400 and cannot be reached without already knowing the word.
     The placeholder is the only surface that shows before the first keystroke,
     which is exactly when the vocabulary is unknown.

     Not on the trailing blank box once a term exists: a term-shaped placeholder
     directly under a term reads as a duplicate of it. That is why the box takes
     this rather than deciding from its own index. *)
  let box ?(value = "") ?(placeheld = false) ?(invalid = false) i =
    let placeholder =
      if placeheld
      then [ a_placeholder "potion:haste, scroll:acquirement, staff props:Conj" ]
      else []
    in
    let invalid =
      if invalid
      then [ a_aria "invalid" [ "true" ]; a_aria "describedby" [ problem_id i ] ]
      else []
    in
    input
      ~a:
        ([ a_input_type `Text; a_id (sprintf "term-%d" i); a_name "has"; a_value value ]
         @ placeholder
         @ invalid
         @ list_attr)
      ()
  in
  let problem_note i (problem : Box.problem) =
    let offer =
      match problem.offer with
      | None -> []
      | Some { prompt; terms } ->
        [ p [ txt prompt ]
        ; ul
            ~a:[ a_class [ "offers" ] ]
            (List.map terms ~f:(fun term ->
               li
                 [ a
                     ~a:[ a_href (offer_href ~version ~rank ~boxes ~at:i term) ]
                     [ code [ txt term ] ]
                 ]))
        ]
    in
    div
      ~a:[ a_id (problem_id i); a_class [ "term-problem" ] ]
      (p [ txt problem.message ] :: offer)
  in
  (* Remove is a submit button, not a link: a link would carry only what the
     last search held and discard whatever is typed in the other boxes. It names
     the term and which of the boxes holding it this is, counting from the top
     -- not the box's position. See Params.without_dropped. *)
  let seen = String.Table.create () in
  let existing =
    List.mapi boxes ~f:(fun i { Box.value; problem } ->
      let nth = Hashtbl.find_or_add seen value ~default:(fun () -> ref 0) in
      let this = !nth in
      incr nth;
      li
        ~a:[ a_id (sprintf "term-row-%d" i) ]
        ([ box i ~value ~invalid:(Option.is_some problem)
         ; button
             ~a:
               [ a_button_type `Submit
               ; a_name "drop"
               ; a_text_value (sprintf "%d:%s" this value)
               ; a_class [ "drop-term" ]
               ; a_title (sprintf "Remove %s" value)
               ; a_aria "label" [ sprintf "Remove %s" value ]
               ]
             [ txt "×" ]
         ]
         @ Option.value_map problem ~default:[] ~f:(fun problem ->
           [ problem_note i problem ])))
  in
  let last = List.length boxes in
  let blank =
    li
      ~a:[ a_id (sprintf "term-row-%d" last) ]
      [ box last ~placeheld:(List.is_empty boxes) ]
  in
  (* The GOV.UK error-summary shape: announced once, each entry a link to the
     box it is about, whose own note is tied to it by aria-describedby. *)
  let summary =
    let about_boxes =
      List.filter_mapi boxes ~f:(fun i { Box.problem; _ } ->
        Option.map problem ~f:(fun (problem : Box.problem) ->
          li [ a ~a:[ a_href (sprintf "#term-%d" i) ] [ txt problem.message ] ]))
    in
    match List.map problems ~f:(fun message -> li [ txt message ]) @ about_boxes with
    | [] -> []
    | entries ->
      [ div
          ~a:[ a_class [ "search-problems" ]; a_role [ "alert" ] ]
          [ p [ txt "This search could not run:" ]; ul entries ]
      ]
  in
  let action = version_path version ^ "/search" in
  (* A datalist filters by prefix, so a reader who has not typed the word
     "props" never sees a property: they sit past option 400 of ~580 behind the
     item pairs. Labelling them says what the entry is at the moment it is
     finally visible, which is the only help a datalist can give -- the ordering
     is the browser's, not ours. *)
  let suggestion_option v =
    let label =
      match String.chop_prefix v ~prefix:"props:" with
      | Some prop -> [ a_label (sprintf "%s — artefact property" prop) ]
      | None -> []
    in
    option ~a:(a_value v :: label) (txt "")
  in
  let suggestion_list =
    match suggestions with
    | Some options ->
      [ datalist
          ~a:[ a_id suggestions_id ]
          ~children:(`Options (List.map options ~f:suggestion_option))
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
    (* Implicit submission activates the first submit button in tree order, and
       every remove button precedes the search button. Without this one ahead of
       them, Enter in a term box submits a drop and silently deletes the first
       term. Hidden from pointer, tab order and the accessibility tree: it is
       not a control, it is the definition of what Enter means here. *)
    ((button
        ~a:
          [ a_button_type `Submit
          ; a_class [ "default-submit" ]
          ; a_tabindex (-1)
          ; a_aria "hidden" [ "true" ]
          ]
        []
      :: suggestion_list)
     @ summary
     @ [ ul ~a:[ a_class [ "terms" ] ] (existing @ [ blank ])
         (* Grouped by what each form asks rather than run together as one list.
            Seven comma-separated examples read as undifferentiated grey and put
            the newest form last, where it looks like an afterthought; naming the
            three kinds makes properties a peer of items rather than a footnote.
            Ligatures are off here -- see the note on name~. *)
       ; p
           ~a:[ a_id "search-help"; a_class [ "subtitle" ] ]
           [ txt "One term per box. Terms search the floor unless prefixed with "
           ; code [ txt "shop " ]
           ; txt ". Items: "
           ; code [ txt "potion:haste" ]
           ; txt ", "
           ; code [ txt "3x potion:haste" ]
           ; txt ", "
           ; code [ txt "shop potion:haste" ]
           ; txt ". Artefact properties: "
           ; code [ txt "props:Conj" ]
           ; txt ", "
           ; code [ txt "staff props:Conj,Alch" ]
           ; txt ". Also "
           ; code [ txt "scroll:acquirement" ]
           ; txt " and "
           ; code [ txt "name~Throatcutter" ]
           ; txt ". A bare word like "
           ; code [ txt "haste" ]
           ; txt " is looked up for you. "
           ; a
               ~a:[ a_href (search_help_path version) ]
               [ txt "Full syntax, with examples" ]
           ]
       ; div
           ~a:[ a_class [ "search-controls" ] ]
           [ button ~a:[ a_button_type `Submit ] [ txt "Search" ]
           ; span ~a:[ a_id busy_id; a_class [ "busy" ] ] [ txt "searching…" ]
           ]
       ])
;;

(* [count] belongs to the term, not to [name], and the two coincide only when
   one item supplied the whole total. Spread over several names -- a property
   search, a name fragment matching a family -- [name] is an exemplar, and
   quantifying it would claim sixteen of one storm bow. *)
let hit_line (h : Search.Match.hit) =
  (* Crawl's name already spells a stack's quantity ("2 potions of haste"), so
     a multiplier after it reads as multiplying that: "×2" would claim four. *)
  let stack =
    match String.lsplit2 h.name ~on:' ' with
    | Some (digits, _) when String.for_all digits ~f:Char.is_digit ->
      Option.value (Int.of_string_opt digits) ~default:1
    | _ -> 1
  in
  let quantity =
    if h.distinct = 1 && stack = 1 && h.count > 1 then sprintf " ×%d" h.count else ""
  in
  let total =
    if h.distinct = 1 && stack > 1 && h.count <> stack
    then [ span ~a:[ a_class [ "hit-total" ] ] [ txt (sprintf "%d in all" h.count) ] ]
    else if h.distinct > 1
    then (
      let noun =
        match Search.Criterion.plural_noun h.term.criterion with
        | Some noun -> noun
        | None -> "matches"
      in
      [ span ~a:[ a_class [ "hit-total" ] ] [ txt (sprintf "%d %s" h.count noun) ] ])
    else []
  in
  li ([ txt h.name; txt quantity; txt " on "; level_name h.level ] @ total)
;;

(* A term-less search is an unasked question, not a request for the corpus.
   Rendering the first page of it lists seeds in string order -- 1, 10, 100 --
   which answers nothing and costs an unfiltered scan to produce. *)
let search_prompt = [ p [ txt "Enter a term to find seeds. Results match every term." ] ]

let search_results ~(search : Search.t) ~rank ~more matches =
  if Search.is_empty search
  then search_prompt
  else (
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
                 | `More -> " on this page."
                 | `End -> ".")
            ]
        ]
    in
    ([ heading ] @ tally)
    @
    if List.is_empty matches
    then [ p [ txt "No matching seeds." ] ]
    else
      [ div
          ~a:[ a_class [ "table-scroll"; "table-scroll--wide" ] ]
          [ table
              ~thead:(thead [ tr [ th_col "seed"; th_col "matches" ] ])
              (List.map matches ~f:row)
          ]
      ]
      @ next)
;;

(* Placeholder when search is disabled. No form, no query parsing. *)
let search_unavailable =
  [ h1 [ txt "Search" ]
  ; p ~a:[ a_class [ "subtitle" ] ] [ txt "Search is temporarily unavailable." ]
  ]
;;

(* htmx swaps 4xx responses and takes the title from them; a rejected query
   leaves "Bad request" in the tab. Title travels with every search response. *)
let search_title = "search within seeds"
let search_title_element = Unsafe.node "title" [ txt search_title ]

let resolution_note resolved =
  List.map resolved ~f:(fun (typed, term) ->
    p
      ~a:[ a_class [ "subtitle"; "resolved" ] ]
      [ txt (sprintf "%S was read as " typed)
      ; code [ txt (Search.Term.to_query_string term) ]
      ; txt "."
      ])
;;

let search_page ?(resolved = []) ~(search : Search.t) ~suggestions ~rank ~more matches =
  [ search_form
      ~version:search.version
      ~rank
      ~boxes:(Box.of_terms search.terms)
      ~suggestions
      ()
  ; div
      ~a:[ a_id results_id ]
      (resolution_note resolved @ search_results ~search ~rank ~more matches)
  ]
;;

(* Swap targets results; form travels out of band so scripted readers get new
   term boxes. *)
let search_fragment ?(resolved = []) ~(search : Search.t) ~suggestions ~rank ~more matches
  =
  resolution_note resolved
  @ search_results ~search ~rank ~more matches
  @ [ search_form
        ~oob:true
        ~version:search.version
        ~rank
        ~boxes:(Box.of_terms search.terms)
        ~suggestions
        ()
    ; search_title_element
    ]
;;

(* The results are emptied rather than left standing: under a query that did
   not run, the last one's results read as its answer. *)
let search_rejected ~version ~rank ~boxes ~problems ~suggestions =
  [ search_form ~version ~rank ~boxes ~problems ~suggestions ()
  ; div ~a:[ a_id results_id ] []
  ]
;;

let search_rejected_fragment ~version ~rank ~boxes ~problems ~suggestions =
  [ search_form ~oob:true ~version ~rank ~boxes ~problems ~suggestions ()
  ; search_title_element
  ]
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
          "One term per box; results match every term. Each example below links to its \
           search on this build."
      ]
  ; h2 [ txt "Items" ]
  ; p
      [ txt "Items are searched by type, written base:sub, as in "
      ; code [ txt "potion:haste" ]
      ; txt "."
      ]
  ; examples
      [ [ "potion:haste" ], "a potion of haste"
      ; [ "wand:digging" ], "a wand of digging"
      ; [ "scroll:acquirement" ], "a scroll of acquirement"
      ; ( [ "weapon:executioner's axe" ]
        , "an executioner's axe; spaces and apostrophes are fine" )
      ]
  ; h2 [ txt "A bare word" ]
  ; p
      [ txt
          "A word without a colon is matched against item types and properties. If \
           exactly one matches, that is what gets searched, and the page says so. \
           Otherwise you get a list of candidates, or a "
      ; code [ txt "name~" ]
      ; txt " search to try."
      ]
  ; examples
      [ [ "haste" ], "read as potion:haste"
      ; [ "flight" ], "read as jewellery:ring of flight"
      ; [ "Shatter" ], "read as the parchment of Shatter"
      ; [ "conj" ], "read as props:Conj"
      ; [ "axe" ], "several axes to choose from"
      ; [ "Throatcutter" ], "offers name~Throatcutter"
      ]
  ; p
      [ txt "Counts and "
      ; code [ txt "shop " ]
      ; txt " still work: "
      ; code [ txt "3x shop haste" ]
      ; txt " becomes "
      ; code [ txt "3x shop potion:haste" ]
      ; txt "."
      ]
  ; h2 [ txt "Floor and shop" ]
  ; p
      [ txt "Terms search floor items by default. Put "
      ; code [ txt "shop " ]
      ; txt " at the start of a term to search shop stock instead. "
      ; code [ txt "floor " ]
      ; txt " is also accepted and changes nothing."
      ]
  ; examples
      [ [ "potion:haste" ], "on the floor"
      ; [ "shop potion:haste" ], "in a shop"
      ; [ "floor potion:haste" ], "same as potion:haste"
      ; [ "shop staff props:Conj" ], "a staff enhancing Conjurations, in a shop"
      ]
  ; p
      [ txt
          "A term can't search both, and counts don't combine across them: two potions \
           of haste on the floor and one in a shop match neither "
      ; code [ txt "3x potion:haste" ]
      ; txt " nor "
      ; code [ txt "3x shop potion:haste" ]
      ; txt ". "
      ; code [ txt "name~" ]
      ; txt " only searches the floor."
      ]
  ; h2 [ txt "How many" ]
  ; p
      [ txt "Put "
      ; code [ txt "3x " ]
      ; txt " in front of an item or "
      ; code [ txt "name~" ]
      ; txt " term to require at least that many, counted across the whole seed. "
      ; code [ txt "props:" ]
      ; txt " terms don't take a count."
      ]
  ; examples
      [ [ "3x potion:haste" ], "at least three potions of haste on the floor"
      ; [ "3x shop potion:haste" ], "at least three in shops"
      ]
  ; h2 [ txt "Artefact names" ]
  ; p
      [ code [ txt "name~" ]
      ; txt
          " matches part of an artefact's name, at least three characters. Use it for \
           unrands; for anything else, search the type."
      ]
  ; examples
      [ [ "name~Throatcutter" ], "Throatcutter, on the floor"
      ; [ "name~demon trident \"Rift\"" ], "the demon trident Rift"
      ; [ "name~hat of the Alchemist" ], "the hat of the Alchemist"
      ; [ "name~+9 hand cannon" ], "an artefact hand cannon at +9"
      ; [ "name~+20" ], "any artefact at exactly +20, whatever it is"
      ]
  ; help_note
      ~label:"Why a result shows one item and a different count"
      [ p
          [ txt
              "When a term matches several different items, the result shows the \
               shallowest one and the total. "
          ; code [ txt "props:rF" ]
          ; txt " might show "
          ; code [ txt "+2 ring mail of Gudd {rElec rF+} on D:2 · 2 artefacts" ]
          ; txt
              ": that ring mail and one other artefact. A term matching one kind of item \
               shows a count instead ("
          ; code [ txt "potion of haste ×3" ]
          ; txt ")."
          ]
      ]
  ; help_note
      ~label:"Why name~ does not find a potion of haste"
      [ p
          [ code [ txt "name~" ]
          ; txt " only matches artefact names. For anything else, search the type: "
          ; code [ txt "potion:haste" ]
          ; txt ", not "
          ; code [ txt "name~potion of haste" ]
          ; txt "."
          ]
      ]
  ; h2 [ txt "Artefact properties" ]
  ; p
      [ code [ txt "props:" ]
      ; txt
          " searches artefact properties. List several with commas; they must all be on \
           the same artefact. Put a base type in front to restrict the item: "
      ; code [ txt "staff props:Conj,Alch" ]
      ; txt ". Property names are case-insensitive."
      ]
  ; examples
      [ [ "props:Alch" ], "any artefact enhancing Alchemy"
      ; [ "props:rF,rC" ], "one artefact with rF and rC"
      ; [ "props:rF,rC,rN" ], "one artefact with rF, rC and rN"
      ; [ "staff props:Alch" ], "a staff enhancing Alchemy"
      ; [ "staff props:Conj,Alch" ], "a staff enhancing Conjurations and Alchemy"
      ; [ "staff props:Conj,Alch,rC" ], "the same, plus rC (rare)"
      ; [ "weapon props:rF" ], "a weapon with rF"
      ; [ "weapon props:rF,rC" ], "a weapon with rF and rC"
      ; [ "weapon props:rF,rC,Will" ], "a weapon with rF, rC and Will"
      ]
  ; help_note
      ~label:"Why some combinations return nothing"
      [ p
          [ txt "Some properties never roll on some item types. School enhancers ("
          ; code [ txt "Conj" ]
          ; txt ", "
          ; code [ txt "Alch" ]
          ; txt ", "
          ; code [ txt "Fire" ]
          ; txt ") never appear on weapons, and "
          ; code [ txt "Slay" ]
          ; txt " never appears on staves."
          ]
      ]
  ; help_note
      ~label:"Property strength and drawbacks"
      [ p
          [ code [ txt "props:rF" ]
          ; txt " matches "
          ; code [ txt "rF+" ]
          ; txt " and "
          ; code [ txt "rF++" ]
          ; txt ", but not "
          ; code [ txt "rF-" ]
          ; txt "."
          ]
      ; p
          [ txt "Drawbacks are not searchable at all. "
          ; code [ txt "*Rage" ]
          ; txt " is the exception and can be searched, because it's hilarious."
          ]
      ]
  ; h2 [ txt "Combining terms" ]
  ; p
      [ txt
          "Every box is another condition the seed must meet. There is no OR, you just \
           have to search twice and compare."
      ]
  ; examples
      [ ( [ "scroll:acquirement"; "armour:crystal plate armour" ]
        , "a scroll of acquirement and a crystal plate armour, on one seed" )
      ; ( [ "shop wand:digging"; "scroll:acquirement" ]
        , "a wand of digging in a shop, and a scroll of acquirement on the floor" )
      ]
  ; h2 [ txt "Depth" ]
  ; p
      [ txt "Most seeds are only searched to "
      ; level_name "D:8"
      ; txt ", so a seed that doesn't match may still have the item deeper down."
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
          "The dungeon is generated before you select your character. The same seed on \
           the same version always lays out the same floors, with the same items on \
           them. This site reads the first several floors of many seeds ahead of time \
           and writes down what it found."
      ]
  ; h2 [ txt "Versions" ]
  ; p
      [ txt
          "The same seed generates a different dungeon on each version of crawl, so \
           every page here is for the one build named at the top."
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
           can deepen individual seeds down to the end of the main dungeon, including "
      ; level_name "Orc"
      ; txt ", "
      ; level_name "Lair"
      ; txt ", and their branches. Seed heat is calculated based on the "
      ; level_name "D:8"
      ; txt " read, not a total assessment of the seed."
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
  ; p
      [ txt "Developed and maintained by "
      ; outbound ~href:"https://jonesmelton.com" "Jones Melton"
      ; txt "."
      ]
  ; p [ a ~a:[ a_href (version_path version ^ "/") ] [ txt "← Back to the seeds" ] ]
  ]
;;
