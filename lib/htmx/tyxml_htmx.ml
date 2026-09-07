open Tyxml.Html

(* [Unsafe] only means "outside TyXML's typed element model" -- the value is
   still escaped on output. *)
let attr = Unsafe.string_attrib
let hx_get = attr "hx-get"
let hx_post = attr "hx-post"
let hx_put = attr "hx-put"
let hx_delete = attr "hx-delete"
let hx_patch = attr "hx-patch"
let hx_target = attr "hx-target"
let hx_trigger = attr "hx-trigger"

let ms_to_string f =
  if Float.equal (Float.rem f 1.) 0.
  then Printf.sprintf "%dms" (int_of_float f)
  else Printf.sprintf "%gms" f
;;

module Swap = struct
  type t =
    | InnerHTML
    | OuterHTML
    | TextContent
    | BeforeBegin
    | AfterBegin
    | BeforeEnd
    | AfterEnd
    | Delete
    | None
    | InnerMorph
    | OuterMorph

  let to_string = function
    | InnerHTML -> "innerHTML"
    | OuterHTML -> "outerHTML"
    | TextContent -> "textContent"
    | BeforeBegin -> "beforebegin"
    | AfterBegin -> "afterbegin"
    | BeforeEnd -> "beforeend"
    | AfterEnd -> "afterend"
    | Delete -> "delete"
    | None -> "none"
    (* htmx 4's swap-style dispatch parses [innerMorph]/[outerMorph]; there is no
       bare [morph] token (verified against the vendored static/htmx.min.js). *)
    | InnerMorph -> "innerMorph"
    | OuterMorph -> "outerMorph"
  ;;

  module Scroll = struct
    type t =
      | Top
      | Bottom

    let to_string = function
      | Top -> "top"
      | Bottom -> "bottom"
    ;;
  end

  let to_attrib
        ?swap
        ?settle
        ?(transition = false)
        ?scroll
        ?show
        ?focus_scroll
        ?extra
        style
    =
    let parts =
      [ Some (to_string style)
      ; Option.map (fun t -> "swap:" ^ ms_to_string t) swap
      ; Option.map (fun t -> "settle:" ^ ms_to_string t) settle
      ; (if transition then Some "transition:true" else Option.none)
      ; Option.map (fun p -> "scroll:" ^ Scroll.to_string p) scroll
      ; Option.map (fun p -> "show:" ^ Scroll.to_string p) show
      ; Option.map (fun b -> "focus-scroll:" ^ if b then "true" else "false") focus_scroll
      ; extra
      ]
    in
    attr "hx-swap" (String.concat " " (List.filter_map Fun.id parts))
  ;;
end

let hx_swap ?swap ?settle ?transition ?scroll ?show ?focus_scroll ?extra style =
  Swap.to_attrib ?swap ?settle ?transition ?scroll ?show ?focus_scroll ?extra style
;;

let hx_swap_raw = attr "hx-swap"
let hx_swap_oob = attr "hx-swap-oob"
let hx_select = attr "hx-select"
let hx_select_oob = attr "hx-select-oob"
let hx_vals = attr "hx-vals"
let hx_confirm = attr "hx-confirm"
let hx_boost = attr "hx-boost"
let hx_push_url = attr "hx-push-url"
let hx_replace_url = attr "hx-replace-url"
let hx_indicator = attr "hx-indicator"
let hx_include = attr "hx-include"
let hx_params = attr "hx-params"
let hx_headers = attr "hx-headers"
let hx_ext = attr "hx-ext"
let hx_disable = Unsafe.string_attrib "hx-disable" ""
let hx_disabled_elt = attr "hx-disabled-elt"
let hx_encoding = attr "hx-encoding"
let hx_history = attr "hx-history"
let hx_history_elt = Unsafe.string_attrib "hx-history-elt" ""
let hx_preserve = Unsafe.string_attrib "hx-preserve" ""
let hx_prompt = attr "hx-prompt"
let hx_request = attr "hx-request"
let hx_sync = attr "hx-sync"
let hx_validate = attr "hx-validate"
let hx_inherit = attr "hx-inherit"
let hx_disinherit = attr "hx-disinherit"
let hx_on ~event value = Unsafe.string_attrib ("hx-on:" ^ event) value

(* The six named short escapes plus \u00XX for the remaining U+0000-001F
   controls. *)
let json_escape s =
  let buf = Buffer.create (String.length s + 4) in
  String.iter
    (fun c ->
       match c with
       | '"' -> Buffer.add_string buf {|\"|}
       | '\\' -> Buffer.add_string buf {|\\|}
       | '\n' -> Buffer.add_string buf {|\n|}
       | '\r' -> Buffer.add_string buf {|\r|}
       | '\t' -> Buffer.add_string buf {|\t|}
       | '\b' -> Buffer.add_string buf {|\b|}
       | '\x0C' -> Buffer.add_string buf {|\f|}
       | c when Char.code c < 0x20 ->
         Buffer.add_string buf (Printf.sprintf {|\u%04X|} (Char.code c))
       | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf
;;

let hx_headers_inherited pairs =
  let members =
    List.map
      (fun (k, v) -> Printf.sprintf {|"%s":"%s"|} (json_escape k) (json_escape v))
      pairs
  in
  Unsafe.string_attrib "hx-headers:inherited" ("{" ^ String.concat "," members ^ "}")
;;
