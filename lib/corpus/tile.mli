open! Core

(** Crawl's tile art, vendored under [static/tiles/] from crawl's [rltiles/]
    tree; see [static/tiles/ATTRIBUTION.md]. Three vocabularies: dungeon
    features, unique monsters, and the item types worth illustrating. This
    project renders no map, so walls, floors, ordinary monsters and player dolls
    have no tile here.

    {1 A table, not a derivation}

    A feat name mostly matches its tile's filename, but the art was named by
    artists over two decades. Against the corpus's 36 distinct feats, mechanical
    derivation resolves 26 and misses 10: [altar_hepliaklqana] is [hep0..5],
    [altar_jiyva] is zero-padded [jiyva01..12], [altar_makhleb] is
    [makhleb_flame1..8], [altar_the_shining_one] drops the article, portals
    invert the affix ([enter_sewer] is [sewer_portal]), and [transporter] sits
    loose in [dngn/].

    A near-miss derivation is worse than none: a wrong filename renders as a
    broken image rather than a caught error. *)

type t = string [@@deriving compare, equal, sexp_of]

val to_string : t -> string

(** [None] for a feat with no vendored tile, which callers render as text.
    Several features have numbered variants crawl picks between at random; this
    returns the first, since a catalog describes what is on a level rather than
    reproducing a particular frame of it. *)
val of_feat : string -> t option

val known_feats : string list

(** The tile for a unique monster, keyed by the name the corpus records.

    Derivation from the display name almost works and is wrong once:
    [Blorkula the orcula] is [blorkula.png], crawl's tile dropping the epithet.
    So the bridge runs through crawl's [MONS_*] enum instead -- [mon-data.h]
    binds enum to display name, [rltiles/dc-mon.txt] binds enum to file.

    Covers all 97 uniques carrying tile art, not merely the 27 a [D:8] corpus
    holds, so a deeper fill needs no tile work. *)
val of_unique : string -> t option

(** The tile for an item, keyed by the same [base_type]/[sub_type]/[artefact]
    triple the corpus stores.

    Crawl draws a second piece of art for the randart form of many base types,
    so [artefact:true] returns it where it exists; 67 of 158 types have one and
    the rest fall back to the base tile.

    Covers the artefact-bearing classes, the evokables, and the identified
    potions and scrolls. Ammunition and crawl's removed save-compat items have
    no tile here.

    {1 Potions and scrolls are composited, not copied}

    Crawl draws an identified potion or scroll as two layers, a [%back] and an
    [i-*.png] overlay glyph, and the glyph alone is unreadable. So the vendored
    PNG is the two composited at vendor time.

    The back is deliberately not the one crawl would pick: crawl's is
    [PCOLOUR(subtype_rnd)], the per-seed shuffle over the item's *unidentified*
    appearance, which is meaningless in a catalog naming the identified type.
    All 16 potions composite over [unknown.png] and all 18 scrolls over
    [scroll.png], so the glyph is the only thing that varies.

    Five of the 34 do not resolve by name ([cancellation] is [i-cancel],
    [enlightenment] is [i-flight], [lignification] is [i-lignify], [revelation]
    is [i-magic_mapping], [summoning] is [i-unholy_creation]). *)
val of_item : base_type:string -> sub_type:string -> artefact:bool -> t option

(** Dispatches on which vocabulary a row belongs to. Lives here rather than in
    a template because that is a fact about the record, not about the page. An
    entry outside all three has no tile. *)
val of_entry : Record.Entry.t -> t option

val known_uniques : string list
val known_items : (string * string) list
