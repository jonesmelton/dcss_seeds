open! Core

(** Per-reader daily caps on seed submissions, held in memory.

    Fairness for honest readers, not a defence: a session costs a bot one GET,
    and an address costs a botnet nothing. The bound that holds is the global
    daily cap, which [Seed_corpus.Db.enqueue] enforces from [ingest_jobs] and
    survives a restart; these counters do not, which costs at most one more
    day's allowance per reader. Nothing here is written to disk, so no
    requester identity is either. *)

type t

val create : per_ip:int -> per_session:int -> t

(** [day] is any number that changes once a day; a new one clears every
    count. *)
val check
  :  t
  -> day:int
  -> ip:string
  -> session:string
  -> [ `Ok | `Ip_cap | `Session_cap ]

(** Count one accepted submission. Only an accepted one: a repeat of a seed
    already queued costs the generator nothing, so it costs the reader
    nothing. *)
val record : t -> day:int -> ip:string -> session:string -> unit

(** The address to count against: the last [X-Forwarded-For] entry, which is
    the one Caddy appended from its own socket peer, else the socket peer
    without its port. Only Caddy reaches the app (docs/prerelease.md), so the
    header is the proxy's, not the client's. *)
val client_address : forwarded_for:string option -> peer:string -> string
