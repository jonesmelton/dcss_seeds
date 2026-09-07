open! Core

(** The unrandarts a build can generate, as the search form's suggestion
    vocabulary.

    A *declared* roster, not an observed one, because an unrand cannot be
    recovered from the corpus: the stored name carries a varying enchantment
    prefix and inscription, so the bare name is not a column, and an unrand
    nobody has rolled yet has no row at all -- 95 of 0.34.1's 112 appear in the
    2.0M-seed corpus. Frequency does not separate them from randarts either;
    randart books collide on shared title words at the same counts a rare unrand
    sits at.

    So the roster comes from crawl's [art-data.txt], filtered to the entries
    that enter the item pool, checked in per version under [data/unrand-names/]
    by [tools/unrand-roster] -- regenerate on a version bump. Embedded at build
    time so the webapp does not depend on a provisioned build tree, and per
    version because the roster moves: 110, 113 and 112 names across the three
    builds served.

    Suggesting an unrand no seed has yet is correct: it exists in the build, and
    a search for it is a legitimate question with an empty answer. *)

(** [None] for a version with no checked-in list -- an unknown build suggests
    nothing rather than another build's items. *)
val names : version:string -> string list option

val versions : string list
