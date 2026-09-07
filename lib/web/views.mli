open! Core

(** The catalog views. Each returns a fragment; a page handler wraps the same
    fragment in [Index.render], so a view renders identically whether it arrives
    by full page load or by htmx swap. *)

(** The front page: a random sample of seeds, plus the box for going straight to
    a seed you already know. Takes no [more] flag because a sample has no end to
    reach. *)
val seed_list
  :  version:Seed_corpus.Query.Version.t
  -> page:Seed_corpus.Query.Page.t
  -> Seed_corpus.Level.Summary.t list
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

(** One seed's catalog, prefaced by how deep it was searched.

    [job] is the outstanding deepen request, [position] how many are ahead of
    it, [csrf] the hidden field Dream's form check requires -- [None] suppresses
    the button, which is what a deep seed gets. [filling] withdraws it for a
    different reason; see [depth_note]. *)
val seed_detail
  :  version:Seed_corpus.Query.Version.t
  -> seed:string
  -> job:Seed_corpus.Job.t option
  -> position:int option
  -> csrf:string option
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

val search_unavailable : [> Html_types.flow5 ] Tyxml.Html.elt list

(** The search surface: the form prefilled with the search being shown, and the
    matches with their evidence. A plain GET whose fields are the query string,
    so a result set is a link and the page works with scripting off.
    [suggestions] feeds a datalist on the blank term box. *)
val search_page
  :  search:Seed_corpus.Search.t
  -> suggestions:string list option
  -> rank:Seed_corpus.Search.Rank.t
  -> more:[ `More | `End ]
  -> Seed_corpus.Search.Match.t list
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

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
  :  search:Seed_corpus.Search.t
  -> suggestions:string list option
  -> rank:Seed_corpus.Search.Rank.t
  -> more:[ `More | `End ]
  -> Seed_corpus.Search.Match.t list
  -> [> Html_types.flow5 ] Tyxml.Html.elt list

val search_results
  :  search:Seed_corpus.Search.t
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
