open! Core

(** Parse [#SEED#] lines emitted by scripts/seed_dump_sexp.lua into {!Record.t}.

    S-expressions with lua conventions layered on: [t]/[nil] for booleans, and
    [nil] also for an absent field -- so [(artefact nil)] and an omitted
    [artefact] are indistinguishable and both read as "no". *)

(** The [format] this reader understands. Any other value is rejected rather
    than parsed, so a serializer change fails at the parse boundary instead of
    silently writing nulls. *)
val supported_format : int

val prefix : string

(** Returns [Error] for a line that is malformed, unprefixed, or carries an
    unsupported [format] -- callers count these rather than aborting, since a
    crawl crash mid-level can truncate a line. *)
val parse_line : string -> Record.t Or_error.t
