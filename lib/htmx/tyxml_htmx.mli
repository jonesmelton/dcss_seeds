(** htmx attributes for TyXML.

    Each is a string-valued {!Tyxml.Html.Unsafe.string_attrib}. "Unsafe" is
    TyXML's term for an attribute outside its typed element model -- the value
    is still escaped on output. Typed [hx-swap]/[hx-trigger] vocabularies are
    deliberately not modelled beyond {!Swap}. *)

open Tyxml.Html

(** {1 Request-issuing attributes} *)

val hx_get : string -> 'a attrib
val hx_post : string -> 'a attrib
val hx_put : string -> 'a attrib
val hx_delete : string -> 'a attrib
val hx_patch : string -> 'a attrib

(** {1 Targeting and swapping} *)

val hx_target : string -> 'a attrib

(** Typed [hx-swap]. The style keyword and modifier vocabulary live here; use
    {!hx_swap} for the ergonomic call site. *)
module Swap : sig
  (** The swap-style keyword. Morphing is built into htmx 4, whose tokens are
      [innerMorph]/[outerMorph] -- there is no bare [morph]. A morph reconciles
      new content against the existing DOM instead of replacing it, so node
      identity (focus, open disclosures, running animations) survives. *)
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

  (** [scroll]/[show] vertical position. *)
  module Scroll : sig
    type t =
      | Top
      | Bottom

    val to_string : t -> string
  end

  val to_string : t -> string

  (** [swap]/[settle] are milliseconds. [extra] appends a raw modifier string
      for the long tail the typed args don't model; escaped on output but not
      validated. *)
  val to_attrib
    :  ?swap:float
    -> ?settle:float
    -> ?transition:bool
    -> ?scroll:Scroll.t
    -> ?show:Scroll.t
    -> ?focus_scroll:bool
    -> ?extra:string
    -> t
    -> 'a attrib
end

(** Typed [hx-swap]. [hx_swap ~swap:200. ~transition:true Swap.OuterHTML]
    renders [hx-swap="outerHTML swap:200ms transition:true"]. *)
val hx_swap
  :  ?swap:float
  -> ?settle:float
  -> ?transition:bool
  -> ?scroll:Swap.Scroll.t
  -> ?show:Swap.Scroll.t
  -> ?focus_scroll:bool
  -> ?extra:string
  -> Swap.t
  -> 'a attrib

(** Escape hatch: raw string [hx-swap]. Prefer {!hx_swap}. *)
val hx_swap_raw : string -> 'a attrib

val hx_swap_oob : string -> 'a attrib
val hx_select : string -> 'a attrib
val hx_select_oob : string -> 'a attrib

(** {1 Triggers and parameters} *)

val hx_trigger : string -> 'a attrib
val hx_vals : string -> 'a attrib
val hx_include : string -> 'a attrib
val hx_params : string -> 'a attrib
val hx_headers : string -> 'a attrib
val hx_request : string -> 'a attrib
val hx_sync : string -> 'a attrib

(** {1 History and URL} *)

val hx_boost : string -> 'a attrib
val hx_push_url : string -> 'a attrib
val hx_replace_url : string -> 'a attrib
val hx_history : string -> 'a attrib

(** Boolean-presence attribute; emitted with an empty value. *)
val hx_history_elt : 'a attrib

(** {1 UX} *)

val hx_confirm : string -> 'a attrib
val hx_prompt : string -> 'a attrib
val hx_indicator : string -> 'a attrib
val hx_disabled_elt : string -> 'a attrib
val hx_encoding : string -> 'a attrib
val hx_validate : string -> 'a attrib

(** {1 Extensions and inheritance} *)

val hx_ext : string -> 'a attrib
val hx_inherit : string -> 'a attrib
val hx_disinherit : string -> 'a attrib

(** Boolean-presence attribute; emitted with an empty value. *)
val hx_disable : 'a attrib

(** Boolean-presence attribute; emitted with an empty value. *)
val hx_preserve : 'a attrib

(** [hx_on ~event:"click" "alert(1)"] renders [hx-on:click="…"];
    htmx-namespaced events use a leading colon, e.g. [~event:":after-request"]. *)
val hx_on : event:string -> string -> 'a attrib

(** Renders [hx-headers:inherited] with a JSON object from [pairs]. Names and
    values are JSON-string-escaped before assembly; TyXML then HTML-escapes the
    attribute value.

    Use this instead of hand-building JSON inside [Unsafe.string_attrib]: the
    escaping is audited here rather than scattered across templates. *)
val hx_headers_inherited : (string * string) list -> 'a attrib
