open! Core

(** The builds this deployment routes to, as a closed set.

    Strictly smaller than {!Seed_corpus.Query.Version}, and deliberately a
    different type: a [Query.Version.t] is any build the corpus could hold or a
    generator could build, discovered by listing [builds/] on disk, so that set
    is open by construction. A [Served.t] is one of the handful a reader can ask
    for by URL.

    Compiled in rather than read from [versions], because adding a build is
    already a manual code-touching job. A database lookup would let the router
    serve a build the code has not been taught about -- a half-ingested corpus
    becoming publicly reachable. The cost is that ingesting a new build does not
    serve it until the binary is rebuilt.

    Closing the set also makes an unknown build a 404 at the parse boundary:
    "no such build" and "no seeds" are different answers. *)

type t [@@deriving compare, equal, sexp_of]

val all : t list

(** The build [/] redirects to.

    Set by hand when a new corpus is judged ready: "current" is an editorial
    claim, and the corpus holds nothing that could decide it. Not a default that
    requests fall back to -- no request resolves to it implicitly, so a URL
    naming no version is a redirect, never a silent assumption. *)
val current : t

(** Rejects anything outside the served set, which is what makes an unknown
    build a 404 rather than an empty listing. *)
val of_string : string -> t Or_error.t

val to_string : t -> string
val to_version : t -> Seed_corpus.Query.Version.t
