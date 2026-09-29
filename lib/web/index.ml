open Tyxml.Html

(* The document chrome. Every page handler wraps a fragment in this; every
   fragment handler returns the fragment alone. *)

(* Which masthead link is the page you are on. A closed set rather than a path
   comparison: matching on the URL would have to decide what a seed detail page
   or a search result counts as, and both are somewhere the nav does not point.
   [Other] is that answer, and is the default. *)
module Page = struct
  type t =
    | Seeds
    | Search
    | About
    | Other
  [@@deriving equal]
end

(* Three states, not two: following the OS is a distinct choice from pinning a
   theme, and a reader who has pinned one needs a way back to automatic. *)
let theme_toggle =
  let choice value label_text =
    button
      ~a:
        [ a_button_type `Button
        ; a_user_data "theme-choice" value
        ; a_aria "pressed" [ "false" ]
        ]
      [ txt label_text ]
  in
  div
    ~a:[ a_class [ "theme-toggle" ] ]
    [ choice "auto" "auto"; choice "light" "light"; choice "dark" "dark" ]
;;

(* Links stay inside the build the reader is in, for the same reason the
   masthead link does: a nav that silently moves them to the current build is
   worse than no nav. Error chrome has no build to scope them to, so it gets
   none. *)
let nav_links ~version ~here =
  match version with
  | None -> txt ""
  | Some v ->
    let base = "/" ^ Dream.to_percent_encoded (Seed_corpus.Query.Version.to_string v) in
    let entry (page : Page.t) label path =
      let is_here = Page.equal page here in
      li
        [ a
            ~a:
              ([ a_href (base ^ path)
               ; a_class ("nav-link" :: (if is_here then [ "current" ] else []))
               ]
               @ if is_here then [ a_aria "current" [ "page" ] ] else [])
            [ txt label ]
        ]
    in
    nav
      ~a:[ a_class [ "masthead-nav" ] ]
      [ ul
          [ entry Page.Seeds "seeds" "/"
          ; entry Page.Search "search" "/search"
          ; entry Page.About "about" "/about"
          ]
      ]
;;

(* The masthead link stays inside the build the reader is already in. Falling
   back to "/" would silently move them onto a page that looks correct and
   describes a different dungeon. Error chrome has no build to stay in.

   Not marked up as a heading, though it is the largest text on the page: the
   picker is a [details], which is not valid inside a heading, and TyXML will
   not put a heading inside a [summary] either.

   The build is the masthead's dominant element rather than a per-page subtitle:
   the same seed number on two builds is two unrelated dungeons, and a seed
   quoted without its build is the most common way a shared seed becomes a wrong
   answer. *)
let masthead ~version ~builds ~here =
  let home =
    match version with
    | None -> "/"
    | Some v ->
      "/" ^ Dream.to_percent_encoded (Seed_corpus.Query.Version.to_string v) ^ "/"
  in
  let build_name v =
    [ span ~a:[ a_class [ "build-label" ] ] [ txt "crawl " ]
    ; txt (Seed_corpus.Query.Version.to_string v)
    ]
  in
  (* Without counts there is nothing to choose between, so the build stays a
     plain link. That is the error chrome's case: it has no corpus to ask. *)
  let chooser v =
    match builds with
    | [] -> [ a ~a:[ a_href home; a_class [ "build-version" ] ] (build_name v) ]
    | builds ->
      let entry (served, count) =
        let name = Served.to_string served in
        let is_current = Core.String.equal name (Seed_corpus.Query.Version.to_string v) in
        li
          [ a
              ~a:
                ([ a_href ("/" ^ Dream.to_percent_encoded name ^ "/")
                 ; a_class ("build-choice" :: (if is_current then [ "current" ] else []))
                 ]
                 @ if is_current then [ a_aria "current" [ "page" ] ] else [])
              [ span ~a:[ a_class [ "build-choice-name" ] ] [ txt name ]
              ; span
                  ~a:[ a_class [ "build-choice-count" ] ]
                  [ txt
                      (Printf.sprintf
                         "%s seeds"
                         (Core.Int.to_string_hum ~delimiter:',' count))
                  ; (* Marked by a word, not by colour alone. *)
                    (if is_current then txt " · showing" else txt "")
                  ]
              ]
          ]
      in
      [ details
          ~a:[ a_class [ "build-picker" ] ]
          (summary ~a:[ a_class [ "build-version" ] ] (build_name v))
          [ ul ~a:[ a_class [ "build-list" ] ] (Core.List.map builds ~f:entry) ]
      ]
  in
  let build =
    match version with
    | None -> []
    | Some v ->
      [ div
          ~a:[ a_class [ "build" ] ]
          (chooser v
           @ [ p
                 ~a:[ a_class [ "build-caveat" ] ]
                 [ txt
                     "Everything on this site is true of this build only. A seed number \
                      generates a different dungeon on every other version of crawl."
                 ]
             ])
      ]
  in
  header
    ~a:[ a_class [ "masthead" ] ]
    (div
       ~a:[ a_class [ "masthead-bar" ] ]
       [ a ~a:[ a_href home; a_class [ "site" ] ] [ txt "dcss garden" ]
       ; nav_links ~version ~here
       ; theme_toggle
       ]
     :: build)
;;

let render ?version ?(builds = []) ?(here = Page.Other) ~title:page_title content =
  html
    ~a:[ a_lang "en" ]
    (head
       (title (txt page_title))
       [ meta ~a:[ a_charset "utf-8" ] ()
       ; meta ~a:[ a_name "viewport"; a_content "width=device-width, initial-scale=1" ] ()
       ; link ~rel:[ `Icon ] ~href:"/favicon.ico" ~a:[ a_mime_type "image/x-icon" ] ()
       ; link
           ~rel:[ `Icon ]
           ~href:"/static/favicon-32.png"
           ~a:[ a_mime_type "image/png"; a_sizes (Some [ 32, 32 ]) ]
           ()
       ; link
           ~rel:[ `Icon ]
           ~href:"/static/favicon-16.png"
           ~a:[ a_mime_type "image/png"; a_sizes (Some [ 16, 16 ]) ]
           ()
       ; link ~rel:[ `Other "apple-touch-icon" ] ~href:"/static/apple-touch-icon.png" ()
       ; link ~rel:[ `Stylesheet ] ~href:"/static/style.css" ()
         (* Blocking, in head, before paint: a theme applied afterwards flashes. *)
       ; script ~a:[ a_src "/static/theme.js" ] (txt "")
       ; script ~a:[ a_src "/static/htmx.min.js" ] (txt "")
       ; script ~a:[ a_src "/static/copy.js" ] (txt "")
       ])
    (body [ masthead ~version ~builds ~here; main ~a:[ a_id "main" ] content ])
;;
