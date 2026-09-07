open! Core

(** The consumables worth the same to every character: potion of experience and
    scroll of acquirement. Shop stock is never a boon; callers filter on [cost]
    before asking. *)

type t =
  | Experience
  | Acquirement
[@@deriving compare, equal, enumerate, sexp_of]

val label : t -> string
val name : t -> string
val base_type : t -> string
val sub_type : t -> string

(** [None] for an entry that is not a boon, including shop stock. *)
val of_entry : Record.Entry.t -> t option
