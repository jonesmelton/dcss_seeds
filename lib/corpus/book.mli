open! Core

(** Spellbook contents, and which of them are worth storing per seed.

    Almost no book's spells are seed-determined. The discriminator is a column
    crawl already gives us:

    - {b Parchments} hold exactly one spell, always their [sub_type] minus the
      prefix. [Reader] drops it; this module puts it back on read.
    - {b Named books} hold a spell set fixed by the build, so it is stored once
      per [(version, sub_type)] in [book_spells] and the per-entry rows are
      dropped at write. Filled by ingest, since a title's spells are needed
      exactly when the title is in the corpus.
    - {b Manuals} hold none.
    - {b Randart books} carry [artefact = 1] under the single [sub_type] "book
      of Fixed Theme". Genuinely per-seed, stored row by row.

    A named book's set is invariant within a version -- a released build
    compiles in one spell list -- so a second sighting that disagrees means the
    version string describes two builds, and [Db] rejects it rather than
    recording one seed's book as every seed's. *)

(** The spell derivable from the name alone: [Some [ "Shock" ]] for "parchment
    of Shock", [None] for a named book and for anything that is not a book. *)
val spells_of_sub_type : string -> string list option

(** Whether a record's spell rows are redundant with its [sub_type], and so must
    not be stored. True for every parchment. *)
val spells_are_derivable : sub_type:string option -> bool

(** Whether an entry's spells are a property of the build rather than the seed.
    True for a named book -- a non-artefact book that is neither a parchment nor
    a manual; the [artefact] flag is what separates it from a randart book. *)
val spells_are_fixed : sub_type:string option -> artefact:bool option -> bool
