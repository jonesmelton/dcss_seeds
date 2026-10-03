open! Core

(** Readers' private "this seed is good" flags, in a file of their own.

    Not in the corpus, for three reasons. A corpus is reproducible and a flag is
    not: every fill lands in a new file swapped in by rename, so flags kept there
    would need migrating on each cutover or be silently dropped. A fill is eight
    ingest writers, and a flag button that says "paused while seeds are added"
    would be absurd. And the corpus is not worth backing up while this file
    must be.

    [version] is the build name, not [versions.id]: ids are assigned per corpus
    file, so only the name survives a cutover. Nothing here ranks flags or
    counts them per seed: the community garden draws a sample of flagged seeds
    and nothing else reads them back. *)

type t

(** Creates the file and its table if absent. Same pragma contract as
    {!Db.open_}, bar [foreign_keys], which has nothing to apply to.

    [key] keys the HMAC a session id is stored as, for dedupe only: stable for
    one reader under one key, and no address is stored or derived from. *)
val open_ : key:string -> string -> t

val close : t -> unit

(** The longest [query] kept; longer is truncated rather than rejected, since
    the value is untrusted text that is only ever stored. *)
val max_query_length : int

(** Records one flag. A second flag for the same [(version, seed, session)] is a
    no-op, not an error. [query] is the raw search string that led to the seed,
    verbatim, or [None]. [depth] is the fill depth the reader was looking at. *)
val flag
  :  t
  -> version:Query.Version.t
  -> seed:string
  -> session_id:string
  -> query:string option
  -> depth:string
  -> unit Or_error.t

(** Whether this session has already flagged the seed, so a reload can show
    the acknowledgement instead of offering the button again. Answers only for
    the asking session; nothing here counts anyone else's. *)
val is_flagged
  :  t
  -> version:Query.Version.t
  -> seed:string
  -> session_id:string
  -> bool Or_error.t

(** Up to [limit] distinct seeds flagged on [version], in random order.

    Flags are per-session, so one seed can be flagged many times and the same
    seed number can appear under two sessions; the result is distinct. Fewer
    than [limit] when the build holds fewer flags, and empty when it holds
    none. *)
val sample_seeds : t -> version:Query.Version.t -> limit:int -> string list Or_error.t

type row =
  { version : string
  ; seed : string
  ; session : string
  ; query : string option
  ; depth : string
  }
[@@deriving sexp_of]

(** Every flag, oldest first. For tests; consumers use [sqlite3]. *)
val rows : t -> row list Or_error.t
