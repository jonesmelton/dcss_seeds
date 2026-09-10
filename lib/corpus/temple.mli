open! Core

(** The Ecumenical Temple's altar set, as a bitmask over crawl's temple god
    pool.

    A Temple holds 6-22 altars drawn from a fixed pool of 22 gods, so the set is
    bounded however large the corpus grows. Storing it as an integer on
    [seed_levels] replaces the 1,354,906 altar rows Temple levels contribute --
    64% of every altar row in the corpus -- with a column that never grows.

    The pool is crawl's [temple_god_list()] (religion.cc): every god except
    Lugonu, Beogh, Jiyva and Ignis. Crawl picks a size (6-22, mode 13) and takes
    that many from the shuffled pool, so a Temple is a fixed-size sample rather
    than an independent roll per god.

    Five altars reach a Temple level without being in the pool: the four
    excluded gods, placed by special vaults, and [altar_ecumenical], the faded
    altar feature. They are {b not} in the mask and stay ordinary [entries]
    rows, so a query for a rare god never touches bit logic and never silently
    misses one. [of_feat] returning [None] is how they are told apart. *)

type t [@@deriving compare, equal, sexp_of]

(** The 22 pool gods as their [entries.feat] spellings, in bit order. *)
val pool : string list

(** [None] for a feat outside the pool -- the four vault-placed gods and
    [altar_ecumenical]. A caller that gets [None] must keep the row. *)
val of_feat : string -> int option

val empty : t
val add : t -> string -> t
val mem : t -> string -> bool
val to_feats : t -> string list

(** A god's display name from its feat. Several are multi-word proper nouns
    ("The Shining One"), so every word is capitalised. [altar_ecumenical] is
    "Faded": crawl's own name for that feature is the one the game prints, and
    "ecumenical" is internal spelling the player never sees. *)
val god_name : string -> string

val to_int : t -> int
val of_int : int -> t
