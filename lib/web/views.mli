open! Core

(** The catalog views. Each returns a fragment; a page handler wraps the same
    fragment in [Index.render], so a view renders identically whether it arrives
    by full page load or by htmx swap. *)

(** The front page: a random sample of seeds, plus the box for going straight to
    a seed you already know.

    [more] is whether the pool holds more than one page -- a fact about the
    pool, not about [summaries], and false withdraws the link rather than
    offering one with nothing behind it.

    [community] renders the same table over the seeds readers flagged as good,
    which is the community garden: only the caption, the "more" link and the
    empty-state sentence differ. *)
val seed_list
  :  ?community:bool
  -> more:bool
  -> version:Seed_corpus.Query.Version.t
  -> page:Seed_corpus.Query.Page.t
  -> Seed_corpus.Level.Summary.t list
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** What the seed page needs to offer the private "good seed" flag: the CSRF
    token, the search string the reader arrived from, if any, carried back
    verbatim in a hidden field, and whether this session already pressed it, in
    which case the acknowledgement stands where the button was. *)
type flag =
  { csrf : string
  ; from : string option
  ; flagged : bool
  }

(** One seed's catalog, prefaced by how deep it was searched.

    [job] is the outstanding deepen request, [position] how many are ahead of
    it, [csrf] the token Dream's form check requires -- [None] suppresses
    the button, which is what a deep seed gets. [filling] withdraws it for a
    different reason; see [depth_note]. [flag] is [None] when the feedback file
    is not configured, which withdraws the button entirely. *)
val seed_detail
  :  version:Seed_corpus.Query.Version.t
  -> seed:string
  -> job:Seed_corpus.Job.t option
  -> position:int option
  -> csrf:string option
  -> flag:flag option
  -> filling:bool
  -> Seed_corpus.Level.t list
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** How deep this seed was searched, and what can be done about it. Also what
    the deepen button swaps in, so a queued job renders identically whether the
    page was loaded fresh or polled.

    The shallow case matters most: without it the absence of a Lair reads as a
    fact about the seed rather than about the search. There is no progress bar;
    crawl emits nothing incremental. State is carried by text, not colour.

    A queued job says where it is in the line, and the sentence names the build,
    because a generator claims per version -- an unqualified "3 ahead" would
    describe a queue nothing works through.

    [filling] says a corpus fill holds the write lock. The generator skips its
    passes for the duration, so a request enqueued then waits hours: the button
    is withdrawn and the reason given, since the enqueue would otherwise succeed
    and strand the reader on a sentence naming the wrong cause. A job already
    queued still polls -- only the offer of new work is withdrawn. *)
val depth_note
  :  version:Seed_corpus.Query.Version.t
  -> seed:string
  -> depth:Seed_corpus.Fill_depth.t
  -> job:Seed_corpus.Job.t option
  -> position:int option
  -> csrf:string option
  -> filling:bool
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** A refused deepen request, rendered into the same slot the depth note
    occupies so the reason lands where the button was. A refusal is temporary by
    construction, so it says to try again rather than treating the seed as
    unservable. *)
val refusal
  :  seed:string
  -> version:Seed_corpus.Query.Version.t
  -> string
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** A submitted seed's state, in the slot the page for a seed the corpus does
    not hold puts it in -- also what the button and the poll swap in. A
    seed the corpus now holds has no note: the caller redirects to its page, and
    the levels decide that, not the job row. Polls while the job is queued or running and stops
    otherwise. [csrf = None] or [paused] withdraws the button with the reason,
    as [depth_note] does for a fill. *)
val submission_note
  :  version:Seed_corpus.Query.Version.t
  -> seed:string
  -> job:Seed_corpus.Job.t option
  -> position:int option
  -> csrf:string option
  -> paused:bool
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** A refused submission, in the same slot. *)
val submission_refusal
  :  seed:string
  -> version:Seed_corpus.Query.Version.t
  -> string
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** The page for a well-formed seed the corpus does not hold. Its
    {!submission_note} sits in a live region that stays put while the note
    inside it is swapped, so a screen reader hears the job move and finish. *)
val seed_missing
  :  version:Seed_corpus.Query.Version.t
  -> seed:string
  -> job:Seed_corpus.Job.t option
  -> position:int option
  -> csrf:string option
  -> paused:bool
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** The seed page's address, which the flag's no-script answer links back to. *)
val seed_path : version:Seed_corpus.Query.Version.t -> seed:string -> string

(** [D:n], the level at reach depth [n]: how a fill depth is spelled to a
    reader and in the feedback file. *)
val depth_as_level : Seed_corpus.Fill_depth.t -> string

(** The flag's slot after a press, and after a refusal. These are the inside of
    the [aria-live] region the button sits in, which stays put across the swap so
    the change is announced; the confirmation takes focus, since the button it
    replaces had it. *)
val flag_noted : [> Html_types.flow5 ] Tyxml.Html.elt list

val flag_refusal
  :  version:Seed_corpus.Query.Version.t
  -> seed:string
  -> string
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

val search_unavailable : [> Html_types.flow5 ] Tyxml.Html.elt list

(** The search surface: the form prefilled with the search being shown, and the
    matches with their evidence. A plain GET whose fields are the query string,
    so a result set is a link and the page works with scripting off.
    [suggestions] feeds a datalist on the blank term box. [resolved] pairs a
    bare word with the term it was read as, echoed above the results. *)
val search_page
  :  ?resolved:(string * Seed_corpus.Search.Term.t) list
  -> ?ceiling:Seed_corpus.Search.Term.t * int
  -> search:Seed_corpus.Search.t
  -> suggestions:string list option
  -> rank:Seed_corpus.Search.Rank.t
  -> more:[ `More | `End ]
  -> Seed_corpus.Search.Match.t list
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** How the empty search page orders its canned searches before showing the
    first few. Shuffled by default; a test replaces it to pin the output. *)
val canned_order : (string list list -> string list list) ref

(** The document title of the search page.

    Shared with the htmx fragment rather than written at each render site: htmx
    swaps a 4xx like any other response and takes the title from it, so a
    rejected query leaves "Bad request" standing until something carries one. *)
val search_title : string

(** The results plus the form again, out of band, for an htmx swap.

    The form has to travel with the results: the swap targets the results, and a
    term box is added by rendering one more blank box than there are terms, so a
    form left untouched never grows one. The [<title>] travels for the same
    reason as in {!search_title}. *)
val search_fragment
  :  ?resolved:(string * Seed_corpus.Search.Term.t) list
  -> ?ceiling:Seed_corpus.Search.Term.t * int
  -> search:Seed_corpus.Search.t
  -> suggestions:string list option
  -> rank:Seed_corpus.Search.Rank.t
  -> more:[ `More | `End ]
  -> Seed_corpus.Search.Match.t list
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** One search box as the reader left it. *)
module Box : sig
  type offer =
    { prompt : string
    ; terms : string list (** Whole terms, each a link replacing this box. *)
    }

  type problem =
    { message : string
    ; offer : offer option
    }

  type t =
    { value : string
    ; problem : problem option
    }

  val of_terms : Seed_corpus.Search.Term.t list -> t list
end

(** A search that did not run: the form with every box as typed, a problem
    note tied to each box that has one, and an announced summary. [problems]
    are about the search rather than a box -- a bad [limit], too many terms, a
    match set too broad to rank. *)
val search_rejected
  :  version:Seed_corpus.Query.Version.t
  -> rank:Seed_corpus.Search.Rank.t
  -> boxes:Box.t list
  -> problems:string list
  -> suggestions:string list option
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** {!search_rejected} in {!search_fragment}'s shape. *)
val search_rejected_fragment
  :  version:Seed_corpus.Query.Version.t
  -> rank:Seed_corpus.Search.Rank.t
  -> boxes:Box.t list
  -> problems:string list
  -> suggestions:string list option
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** [ceiling] is a counted term and the most any seed holds of it, below that
    term's count: rendered under an empty result as the number to search for
    instead, with a link to that search. A record over this corpus at its fill
    depth, so the copy says "in this build", not "in the game". *)
val search_results
  :  ?ceiling:Seed_corpus.Search.Term.t * int
  -> search:Seed_corpus.Search.t
  -> rank:Seed_corpus.Search.Rank.t
  -> more:[ `More | `End ]
  -> Seed_corpus.Search.Match.t list
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** The search syntax, with worked examples.

    Every example is a link into a real search on [version] rather than inert
    syntax. Version-scoped for the same reason every address is: an example
    naming an item a build does not generate would demonstrate the one mistake
    the site is arranged to prevent. *)
val search_help
  :  version:Seed_corpus.Query.Version.t
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** What this site is, for a reader who arrived from a link and knows the game
    but nothing about this. Version-scoped like every other address, though
    nothing on it varies by build, so the masthead's picker and the way back
    point at the build the reader was already in. *)
val about
  :  version:Seed_corpus.Query.Version.t
  -> [> Html_types.flow5 ] Tyxml.Html.elt list
