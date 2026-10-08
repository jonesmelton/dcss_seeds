open! Core

(** What it means for a seed to *contain* something, and how such questions
    compose. Pure -- no SQL, no I/O. See [Db.search_seeds]. *)

module Item_type : sig
  (** An item identified by its type rather than its name.

      [name] is a display string carrying enchantment, brand and artefact
      epithet, so it has roughly eighteen times the cardinality of the type and
      nearly every artefact name is distinct -- searching it exactly finds one
      seed or none. The type pair is what "a seed with a wand of digging" means.

      [sub_type] is the bare type (["haste"]); [base_type] disambiguates it. *)
  type t =
    { base_type : string
    ; sub_type : string
    }
  [@@deriving compare, equal, sexp_of]

  val to_string : t -> string
end

module Prop : sig
  (** Which artefact properties a reader may search for.

      Drawbacks are excluded on domain grounds: nobody picks a seed for one.
      Whether an item's [*Slow] is worth living with is decided after you have
      it, and the answer changes what you carry rather than what you play. This
      is not a limitation waiting on a missing operator -- there is no negative
      form we are unable to offer, because the positive form is already the
      question nobody asks.

      [nupgr] is excluded on different grounds again: it is an engine flag, not
      a property, and is never shown to a player. *)
  val excluded : string list

  (** [false] for everything in {!excluded}. Applied to the search vocabulary
      and to the parse boundary alike, so a rejected property is rejected
      wherever it is typed. *)
  val searchable : string -> bool

  (** Why a property is not searchable, phrased for a reader, or [None] if it
      is. The two reasons are not interchangeable: calling [nupgr] a drawback
      would tell the reader their artefact is worse than it is. *)
  val why_excluded : string -> string option

  (** Crawl's whole artefact property vocabulary, including the excluded ones.

      Closed and small, so it is listed rather than queried: the parse boundary
      is synchronous, and an unknown property must be rejected there. A property
      search that runs and matches nothing would report that the build holds no
      such artefact -- a false statement about the corpus, indistinguishable
      from a true one.

      Per build, because crawl renames properties between releases and a
      build's vocabulary holds only its own spelling. *)
  val known : version:Query.Version.t -> string list

  (** The canonical spelling of a property named case-insensitively, or [None]
      if [version] has no such property. Crawl mixes case within a name ([rF],
      [SInv]), which no reader should have to reproduce from memory. *)
  val canonical : version:Query.Version.t -> string -> string option

  (** For a property [version] does not know but another build does under a
      rename, the spelling [version] uses -- [Some "Alchemy"] for [Alch] on
      0.32.1. [None] otherwise. For telling a reader, never for resolving: a
      term is searched as typed or refused. *)
  val spelling : version:Query.Version.t -> string -> string option

  (** The floor a bare property must meet.

      [entry_props.value] is crawl's raw integer and runs negative on every
      property that can be a penalty -- [Str] spans -5..10, [rF] -2..3, [Slay]
      -6..6, and about one row in five of those is below zero. Matching
      [rF-] for a reader who asked for [rF] would be a true-looking answer to a
      question they did not ask.

      It is also what makes [rF] mean "[rF+] or better" without a grouping
      mechanism: every positive value of a resistance is a stronger form of the
      same property, so a floor is the grouping. *)
  val min_value : int
end

module Brand : sig
  (** Which item brands a reader may search for, and how a word becomes the
      code a given build stores.

      A brand is an item's ego: a weapon's brand ("quick blade of
      distortion") or an armour's ("robe of fire resistance"). The corpus
      stores crawl's terse code ([distort], [rF+]) in [entries.ego_id], which
      no reader types and whose spelling has itself renamed across builds
      (crawl capitalised eleven armour codes in 0.34.1) -- so the searchable
      vocabulary is the *display word*, resolved to the build's code at query
      time. Keying on the word is what lets ["protection"] mean a weapon
      brand beside an armour ego: the criterion's base type decides which
      table answers.

      The word tables mirror [Display_name.Ego] and are tied to it by an
      expect test, so a rename in one forces the rekey in the other. Codes
      that never roll on a non-artefact item (reaping, penetration) are listed
      for that test and [tools/corpus-check] but refused at the parse
      boundary: an artefact's brand is part of the name [name~] searches. *)

  (** ["weapon"; "armour"] -- the base types whose ego is orthogonal to the
      sub type. Jewellery's ego is already its sub type ("ring of protection
      from fire"), so an ego term there would answer the item term's own
      question. *)
  val base_types : string list

  (** The words this base type accepts, in table order; the union over
      {!base_types} is the whole vocabulary, artefact-only words included. *)
  val words : base_type:string -> string list

  (** The canonical spelling of a word named case-insensitively, or [None].
      Canonicalisation is per base type: ["protection"] is a weapon word and
      an armour word, and the caller names which. *)
  val canonical : base_type:string -> string -> string option

  (** [canonical] without a base type, for messages: any table's word. *)
  val canonical_any : string -> string option

  (** The word a code spells, or [None] -- for telling a reader who typed the
      code ([ego:distort]) what the word is. *)
  val word_of_code : base_type:string -> string -> string option

  (** Why a brand is not searchable, phrased for a reader, or [None] if it is.
      The one reason is artefact-only (see the module doc); unlike properties
      there are no drawbacks and no engine flags to distinguish. *)
  val why_excluded : base_type:string -> string -> string option

  (** The code a given build stores for a word, or [None] if the word is
      unknown. Version-aware for the 0.34.1 armour capitalisation, the one
      rename in the served set; weapon codes are stable across all three
      builds. [None] is distinguishable from a code because the criterion is
      public-API-constructible and storage must not bind a word where a code
      is expected. *)
  val code : base_type:string -> version:Query.Version.t -> string -> string option
end

module Criterion : sig
  (** Where an item sits. [cost] being present is the only thing telling shop
      stock from floor loot, and the two values partition that union totally --
      every entry is one or the other, never both and never neither. *)
  type position =
    | Floor
    | Shop
  [@@deriving compare, equal, sexp_of]

  (** One atomic containment question. No partial credit, which is what lets
      conjunction be a set intersection rather than a scoring pass.

      [Floor] is the default: [potion:haste] means [Item (_, Floor)], and shop
      stock is reached only by a term that asks for it. Since [Floor] and [Shop]
      partition the union, the union itself is no longer expressible -- a real
      loss taken deliberately, because "is it there" and "can I afford it" are
      different questions and the second is the rarer one.

      That partition is what [min_count] reaches, and it is the visible break: a
      seed with two potions of haste on the floor and a third behind a counter
      satisfies neither [3x potion:haste] nor [3x shop potion:haste]. A floor
      search is not a union search with the shop hits struck off -- it can match
      strictly fewer seeds. The partition is total: every criterion names a
      position, so the union is not expressible at all and there is no term to
      qualify.

      [Name_like] is the escape hatch for what the type vocabulary cannot name:
      an unrand is identified by a substring of its display name, its
      enchantment prefix varying. Since interning it matches only the
      irreducible tail -- artefacts, unrands, monsters -- and no longer reaches
      a name the columns imply. [Name_like "potion of haste"] finds nothing;
      [Item ({base_type = "potion"; sub_type = "haste"}, Floor)] is that
      question.

      [Props] asks for properties carried by *one* item, which is what makes it
      a criterion of its own rather than a conjunction of simpler ones. "A staff
      with Conj and Alch" is not "a Conj item somewhere and an Alch item
      somewhere": the latter is satisfied by a Conj ring on D:3 and an Alch
      staff on D:5, and the evidence rendering cannot tell the reader that is
      what happened -- two hit lines, two unrelated items, nothing saying so.

      [base_type] folds into the criterion for the same reason. Two terms
      ([item:staff] beside [props:Conj,Alch]) reintroduces the leak one level
      up, and it is not a rare case: school enhancers roll off-staff about 45%
      of the time (staff 223, armour 170, jewellery 15 across the ten school
      properties, 10k local corpus, 0.34.1). [None] means any artefact.

      [Brand] is the same shape one level down: the brand and the *whole item*
      (not just a base type) are one criterion, because [weapon:quick blade]
      beside [weapon ego:distortion] would match a quick blade on D:3 beside a
      distortion spear on D:9 -- the [Props] leak again, and [hit_line] cannot
      show it. The item is required rather than optional, and a general brand
      search is refused: 9,971 of 10,000 seeds hold *some* ego'd weapon or
      armour (10k, 0.34.1, D:8, local, 2026-10-01), so the unqualified form is
      nearly unfiltered. One term carries one brand, because an item carries
      one ego -- there is no set to spell. [word] is the display word; [Brand.code] resolves it to
      the build's own code spelling, which is why storage is version-aware
      here and nowhere else. *)
  type t =
    | Item of Item_type.t * position
    | Name_like of string * position
    | Feature of string
    | Unique of string
    | Props of
        { base_type : string option
        ; props : string list
        ; position : position
        }
    | Brand of
        { base_type : string
        ; sub_type : string option
        ; word : string
        ; position : position
        }
  [@@deriving compare, sexp_of]

  (** A short human-readable rendering, for echoing a query back. [Shop] is
      qualified, [Floor] is not: prose mirrors the query, where the floor
      default also goes unspoken. *)
  val to_string : t -> string

  (** The noun for counting several matches, where one reads naturally. [None]
      for criteria that name no category -- a name fragment, a unique, an item
      type whose plural depends on the stack name crawl rendered. *)
  val plural_noun : t -> string option

  (** Whether an index can serve this criterion.

      Constantly [true] since names were interned: the substring match that was
      the sole exception now runs over the dictionary, through a trigram index.
      Kept, with {!partition_terms}, because it names a distinction a future
      criterion could reintroduce. *)
  val is_indexed : t -> bool

  (** Whether this criterion is cheap enough to run on the Lwt scheduler thread.

      Two are not. No [Name_like] is, at any fragment length: cost scales with
      how much of the dictionary the fragment matches rather than with the
      lookup, and the search store declines every one of them, so they are the
      terms that still reach the SQL fallback. A selective fragment is
      milliseconds today; that is a property of the corpus, not of the query.

      [Props] is cheap only with a [base_type]. That seek drives the query and
      the properties filter its output; without one the query drives the whole
      build and the page limit does not stop it early, since a rare property
      pair matches too few seeds to fill a page. Everything else is a single
      covering-index seek. *)
  val is_cheap : t -> bool

  (** Whether "the most any seed holds is [n]" answers the question a count on
      this criterion asks. [false] for two criteria, both on grounds of meaning
      rather than cost.

      [Name_like]: a fragment's count totals a family of unrelated items
      ([name~golden] reaches a bow and a ring), so its maximum is a true
      sentence about a question nobody asked.

      [Props]: counting properties is not a question anyone asks, which is why
      [Params] refuses the count outright, and this keeps the two in step. It
      also keeps a slow shape behind that refusal rather than beside it: a
      multi-property ceiling has no store branch, and its SQL is 4.6-4.8s for a
      common pair ([props:rF,Str], 1.3M, 0.34.1, prod, 2026-10-01).

      Cost is not otherwise judged here -- a static model of it
      ([search_is_cheap]) was wrong before, because cost is set by the matched
      set rather than the plan. *)
  val has_count_ceiling : t -> bool

  (** Minimum fragment length accepted for [Name_like]. Enforced at the parse
      boundary in [Params]; this constant is the source of truth. *)
  val min_name_like_length : int
end

module Term : sig
  (** A criterion plus the thresholds that qualify it.

      [min_count] counts *items*, not rows: a stack of three potions is one
      [entries] row with [quantity = 3] and satisfies [min_count = 3]. A row
      with no quantity counts as one.

      A term carries no depth cap -- the corpus's own fill depth bounds every
      result; see {!Fill_depth}. *)
  type t =
    { criterion : Criterion.t
    ; min_count : int
    }
  [@@deriving compare, sexp_of]

  (** Clamps [min_count] to at least 1: a term demanding zero of something is not
      a containment question and would match every seed. *)
  val create : ?min_count:int -> Criterion.t -> t

  val to_string : t -> string

  (** The inverse of the web layer's [has=] syntax, so a term round-trips through
      a link. [to_string] is prose and does not.

      Lossy in spelling, exact in meaning: a [Floor] criterion comes back
      unprefixed whether or not the reader typed [floor ], and a [Shop] one
      re-parses to itself. *)
  val to_query_string : t -> string
end

(** A search: every term must hold, of one build, one page at a time.

    Disjunction is deliberately absent -- "seeds with a shop or Sigmund" is two
    searches, and supporting it inside one query would cost the set-intersection
    shape that makes conjunction an index merge.

    An empty [terms] is a listing, and every seed of the version satisfies
    it. *)
type t =
  { version : Query.Version.t
  ; terms : Term.t list
  ; page : Query.Page.t
  }
[@@deriving sexp_of]

val create
  :  version:Query.Version.t
  -> ?terms:Term.t list
  -> ?page:Query.Page.t
  -> unit
  -> t

val is_empty : t -> bool

(** The term an empty result can be explained by: the search's one counted
    term, when {!Criterion.has_count_ceiling} holds for it. [None] with no
    counted term, and with two or more -- the summed-scalar shape that would
    explain a second is the known-slow one, and a reader with two counts out of
    reach already has the worse problem. See {!Db.count_ceiling}. *)
val ceiling_term : t -> Term.t option

(** Terms an index can serve, then terms it cannot. Storage evaluates the
    indexed ones first so the rest run against a narrowed set.

    The second list is currently always empty -- see {!Criterion.is_indexed} --
    so the ordering is a no-op today, kept for the criterion that needs it
    next. *)
val partition_terms : t -> Term.t list * Term.t list

val to_string : t -> string

module Match : sig
  (** One seed that satisfied a search, with the evidence.

      [hits] names, per term, what was found and the shallowest level it sits
      on -- the difference between a Trog altar on D:2 and one on D:8.

      [name] is one exemplar: the shallowest matching item. [count] totals
      quantity across every matching row on the seed, and [distinct] counts how
      many differently-named items that total is spread over. They are only the
      same fact when [distinct = 1]; a term matching unrelated items -- a name
      fragment reaching several artefacts -- would otherwise have [count]
      attributed to [name], claiming sixteen of one storm bow. *)
  type hit =
    { term : Term.t
    ; level : string
    ; name : string
    ; count : int
    ; distinct : int
    }
  [@@deriving sexp_of]

  type t =
    { seed : string
    ; hits : hit list
    }
  [@@deriving sexp_of]
end

module Rank : sig
  (** How a result set is ordered.

      [Seed] is the corpus's own order and the only one that paginates by
      keyset, so it is the default and stays flat at a hundred thousand seeds.
      [Shallowest] is the question a player actually asks, but must sort the
      whole matched set before paging, so storage caps it. *)
  type t =
    | Seed
    | Shallowest
  [@@deriving compare, equal, sexp_of, enumerate]

  val to_string : t -> string
  val of_string : string -> t option
  val default : t

  (** The largest match set [Shallowest] will sort. Beyond it the caller is told
      to narrow rather than served a slow query. *)
  val sort_limit : int

  (** Whether an error came from exceeding {!sort_limit} -- a bad request the
      reader can act on, not a fault. *)
  val is_too_broad : Error.t -> bool

  val too_broad_tag : string
end

(** Whether an error came from searching a name substring while the trigram
    index is mid-rebuild -- like {!Rank.is_too_broad}, a state the reader can
    act on (by retrying later) rather than a fault.

    [Name_like] is refused outright in that window rather than served from the
    dictionary scan it replaced: the scan is correct but costs seconds of disk
    per request on a public endpoint, so falling back would leave an
    amplification factor reachable from a query parameter. Every other criterion
    is unaffected. *)
val is_index_rebuilding : Error.t -> bool

val stale_index_tag : string

(** [Seed] is already the order storage returns, so this is a no-op for it;
    [Shallowest] compares by earliest hit, breaking ties by seed so the order is
    total and pagination stable. *)
val rank_matches
  :  Match.t list
  -> rank:Rank.t
  -> depth_of_level:(string -> int)
  -> Match.t list
