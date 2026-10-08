open! Core
module S = Sqlite3_utils

type t = S.t

let check_rc = Sql.check_rc
let exec_script = Sql.exec_script
let with_txn = Sql.with_txn
let with_immediate_txn = Sql.with_immediate_txn
let version_id_sql = Sql.version_id_sql
let string_id_sql = Sql.string_id_sql
let column_text = Sql.column_text
let column_int = Sql.column_int
let column_bool = Sql.column_bool
let required = Sql.required
let fold_rows = Sql.fold_rows
let with_stmt = Sql.with_stmt
let version_bind = Sql.version_bind

(* WAL and mmap pragmas are reads of connection state, permitted under
   [`READONLY]. *)
let open_ ?(readonly = false) path =
  let t =
    if readonly then Sqlite3.db_open ~mode:`READONLY path else Sqlite3.db_open path
  in
  (* Per-connection and default off. The cascade from seed_levels to entries
     requires foreign_keys on for idempotent re-ingest. *)
  exec_script t "pragma journal_mode = wal";
  exec_script t "pragma foreign_keys = on";
  exec_script t "pragma synchronous = normal";
  (* 30s: a fill runs eight ingest processes against one writer. *)
  exec_script t "pragma busy_timeout = 30000";
  (* 1 GB: this SQLite build clamps `mmap_size` there; larger values are
     silently truncated. Address space, not resident memory. *)
  exec_script t "pragma mmap_size = 1073741824";
  t
;;

(* Without sqlite_stat1 the planner underestimates partial indexes and may
   choose a full-table walk over a seek. `pragma optimize` re-analyzes only
   stale tables, so it is free on a connection that read nothing.

   Skipped on [readonly] handles: this SQLite build returns OK for `pragma
   optimize` on read-only connections even when statistics are stale, so the
   pragma silently does nothing. *)
let close ?(readonly = false) t =
  if not readonly
  then (
    try exec_script t "pragma optimize" with
    | Failure _ -> ());
  ignore (Sqlite3.db_close t : bool)
;;

let with_db path ~f =
  let t = open_ path in
  Exn.protect ~f:(fun () -> f t) ~finally:(fun () -> close t)
;;

let query (t : t) sql =
  let rows = ref [] in
  let rc =
    Sqlite3.exec_no_headers t sql ~cb:(fun row ->
      rows
      := (Array.map row ~f:(Option.value ~default:"") |> String.concat_array ~sep:"|")
         :: !rows)
  in
  (match rc with
   | Sqlite3.Rc.OK -> ()
   | rc -> failwithf "query failed: %s" (Sqlite3.Rc.to_string rc) ());
  List.rev !rows
;;

(* Seeds only; summary columns are separate lookups. Correlated rather than
   [not in], because the submitted set grows without bound and a sampler issues
   this once per draw. *)
let list_seeds_sql =
  sprintf
    {|
  select distinct sl.seed
    from seed_levels sl
   where sl.version_id = %s
     and sl.seed > ?
     and not exists (select 1 from seed_fills f where f.seed = sl.seed and f.version_id = sl.version_id and f.origin = 'submit')
order by sl.seed
   limit ?
|}
    version_id_sql
;;

(* One query per summary column for a whole page. Seeds are named by `in` list
   rather than range because the sampler's seeds are scattered. *)
let summary_feats_sql seeds =
  sprintf
    {|
select e.seed
     , s_feat.val
     , s_level.val
  from entries e
  join strings s_feat
    on s_feat.id = e.feat_id
  join strings s_level
    on s_level.id = e.level_id
 where e.version_id = %s
   and e.feat_id in (select id
                       from strings
                      where val in (
                                'enter_temple'
                              , 'altar_lugonu'
                              , 'altar_beogh'
                              , 'altar_jiyva'
                              , 'altar_ignis'
                            ))
   and e.seed in (%s)
|}
    version_id_sql
    seeds
;;

(* `cost is null` separates floor loot from shop stock. Not in
   entries_search_artefact, so this reads the table for the test. Requires
   sqlite_stat1; see [close]. *)
let summary_artefacts_sql seeds =
  sprintf
    {|
  select seed
       , count(*)
    from entries
   where version_id = %s
     and artefact = 1
     and cost is null
     and seed in (%s)
group by seed
|}
    version_id_sql
    seeds
;;

(* Seeks on entries_seed like the other summary columns, not on the sub_type
   index: a page is fifty known seeds, which is far more selective than two
   sub_types across a whole version. *)
let summary_boons_sql seeds =
  sprintf
    {|
  select e.seed
       , s_base.val
       , s_sub.val
       , sum(coalesce(e.quantity, 1))
    from entries e
    join strings s_base
      on s_base.id = e.base_type_id
    join strings s_sub
      on s_sub.id = e.sub_type_id
   where e.version_id = %s
     and e.cost is null
     and e.sub_type_id in (select id
                             from strings
                            where val in (%s))
     and e.seed in (%s)
group by e.seed
       , s_base.val
       , s_sub.val
|}
    version_id_sql
    (List.map Boon.all ~f:(fun b -> sprintf "'%s'" (Boon.sub_type b))
     |> String.concat ~sep:", ")
    seeds
;;

let summary_portals_sql seeds =
  sprintf
    {|
select sl.seed
     , s_level.val
     , s_parent.val
  from seed_levels sl
  join strings s_level
    on s_level.id = sl.level_id
  join strings s_parent
    on s_parent.id = sl.parent_level_id
 where sl.version_id = %s
   and sl.seed in (%s)
   and sl.parent_level_id is not null
|}
    version_id_sql
    seeds
;;

(* One list generates the select (or insert) list and resolves every read
   offset and bind position, so a reorder cannot desynchronise SQL from reader.
   [check_header] closes the residual gap: a column list edited apart from the
   skeleton around it fails loudly on the statement's own header rather than
   returning a shifted row. *)
module Columns = struct
  type t =
    { names : string array
    ; index : int String.Map.t
    }

  let unqualified name =
    match String.substr_index name ~pattern:" as " with
    | Some i -> String.drop_prefix name (i + 4) |> String.strip
    | None ->
      (match String.rsplit2 name ~on:'.' with
       | Some (_, bare) -> bare
       | None -> name)
  ;;

  let of_list names =
    let names = Array.of_list names in
    let index =
      Array.foldi names ~init:String.Map.empty ~f:(fun i acc name ->
        match Map.add acc ~key:(unqualified name) ~data:i with
        | `Ok acc -> acc
        | `Duplicate -> failwithf "duplicate column: %s" name ())
    in
    { names; index }
  ;;

  let length t = Array.length t.names

  (* The bare names, in order: what a generated values-list iterates over to
     decide which positions resolve through the dictionary. *)
  let names t = Array.to_list t.names |> List.map ~f:unqualified

  let at t name =
    match Map.find t.index name with
    | Some i -> i
    | None -> failwithf "unknown column: %s" name ()
  ;;

  (* River-aligned to match the sqlbrook style of the skeleton it lands in:
     [lead] is the keyword the first name follows, [sep] the comma column. *)
  let render t ~lead ~sep =
    Array.to_list t.names
    |> List.mapi ~f:(fun i name -> if i = 0 then lead ^ name else sep ^ ", " ^ name)
    |> String.concat ~sep:"\n"
  ;;

  let check_header t stmt =
    let n = Sqlite3.column_count stmt in
    if n <> length t
    then Or_error.errorf "column count: expected %d, statement reports %d" (length t) n
    else
      Array.foldi t.names ~init:(Ok ()) ~f:(fun i acc name ->
        let%bind.Or_error () = acc in
        let expected = unqualified name in
        let actual = Sqlite3.column_name stmt i in
        if String.equal expected actual
        then Ok ()
        else
          Or_error.errorf "column %d: expected %s, statement reports %s" i expected actual)
  ;;
end

(* Left join, not inner: [name_id] is null on derivable rows, and an inner join
   would drop them. Each join is a rowid probe. *)
let seed_levels_columns =
  Columns.of_list
    [ "s_level.val as level"
    ; "e.cat"
    ; "s_name.val as name"
    ; "s_base_type.val as base_type"
    ; "s_sub_type.val as sub_type"
    ; "e.quantity"
    ; "e.artefact"
    ; "e.branded"
    ; "e.plus"
    ; "e.cost"
    ; "s_ego.val as ego"
    ; "s_feat.val as feat"
    ; "e.timeout_turns"
    ; "e.unique_mons"
    ; "e.native"
    ; "s_type_name.val as type_name"
    ; "e.x"
    ; "e.y"
    ; "s_carried_by.val as carried_by"
    ; "e.id"
    ; "s_parent.val as parent_level"
    ; "s_shop_type.val as shop_type"
    ; "s_toll_note.val as toll_note"
    ]
;;

(* Ordered by ids, which carry no meaning: a string id is assigned in insertion
   order, so this orders nothing a reader would recognise. It is here only to
   make the row order deterministic for grouping. The order a reader sees --
   category, then rendered display name -- is imposed by [Level.of_rows], where
   it belongs: after interning there is nothing in storage left to sort on. *)
let seed_levels_sql =
  sprintf
    {|
%s
    from entries e
    join seed_levels sl
      on sl.seed = e.seed
     and sl.version_id = e.version_id
     and sl.level_id = e.level_id
    join strings s_level
      on s_level.id = e.level_id
    left join strings s_name
      on s_name.id = e.name_id
    left join strings s_base_type
      on s_base_type.id = e.base_type_id
    left join strings s_sub_type
      on s_sub_type.id = e.sub_type_id
    left join strings s_ego
      on s_ego.id = e.ego_id
    left join strings s_feat
      on s_feat.id = e.feat_id
    left join strings s_type_name
      on s_type_name.id = e.type_name_id
    left join strings s_carried_by
      on s_carried_by.id = e.carried_by_id
    left join strings s_shop_type
      on s_shop_type.id = e.shop_type_id
    left join strings s_toll_note
      on s_toll_note.id = e.toll_note_id
    left join strings s_parent
      on s_parent.id = sl.parent_level_id
   where e.seed = ?
     and e.version_id = %s
order by e.level_id
       , e.cat
       , e.id
|}
    (Columns.render seed_levels_columns ~lead:"  select " ~sep:"       ")
    version_id_sql
;;

(* seed_levels is the authority on which levels a seed has, not entries: a
   Temple holding only pool-god altars has no entry rows. *)
let seed_level_list_sql =
  sprintf
    {|
  select s_level.val
       , s_parent.val
       , sl.temple_altars
       , sl.gold
    from seed_levels sl
    join strings s_level
      on s_level.id = sl.level_id
    left join strings s_parent
      on s_parent.id = sl.parent_level_id
   where sl.seed = ?
     and sl.version_id = %s
order by sl.level_id
|}
    version_id_sql
;;

(* Children fetched per seed, not joined: a join multiplies rows by spell and
   property counts. *)
let seed_spells_sql =
  sprintf
    {|
  select es.entry_id
       , s_spell.val
    from entry_spells es
    join strings s_spell
      on s_spell.id = es.spell_id
   where es.seed = ?
     and es.version_id = %s
|}
    version_id_sql
;;

(* Every named book's spell set for a build. Bounded by the build's book list
   (76 titles on 0.34.1), not by the corpus, so it is read whole rather than
   joined per entry. *)
let version_book_spells_sql =
  sprintf
    {|
  select s_sub_type.val
       , s_spell.val
    from book_spells bs
    join strings s_sub_type
      on s_sub_type.id = bs.sub_type_id
    join strings s_spell
      on s_spell.id = bs.spell_id
   where bs.version_id = %s
order by s_sub_type.val
       , s_spell.val
|}
    version_id_sql
;;

let seed_props_sql =
  sprintf
    {|
  select ep.entry_id
       , s_prop.val
       , ep.value
    from entry_props ep
    join strings s_prop
      on s_prop.id = ep.prop_id
   where ep.seed = ?
     and ep.version_id = %s
|}
    version_id_sql
;;

let page_seeds t ~version ~(page : Query.Page.t) =
  with_stmt
    t
    list_seeds_sql
    ~bind:
      [ version_bind version
      ; Sqlite3.Data.TEXT (Option.value page.after ~default:"")
      ; Sqlite3.Data.INT (Int64.of_int (page.limit + 1))
      ]
    ~f:(fun stmt ->
      fold_rows stmt ~init:[] ~f:(fun acc row ->
        let%map.Or_error seed = required row 0 ~field:"seed" in
        seed :: acc)
      |> Or_error.map ~f:List.rev)
;;

(* The only thing interpolated into the SQL is the placeholder list, whose
   length is the page size; every seed is bound. *)
let over_seeds t sql ~version ~seeds ~f =
  match seeds with
  | [] -> Ok (Hashtbl.create (module String))
  | _ ->
    let placeholders = List.map seeds ~f:(fun _ -> "?") |> String.concat ~sep:", " in
    with_stmt
      t
      (sql placeholders)
      ~bind:(version_bind version :: List.map seeds ~f:(fun s -> Sqlite3.Data.TEXT s))
      ~f:(fun stmt ->
        fold_rows stmt ~init:[] ~f:(fun acc row ->
          let open Or_error.Let_syntax in
          let%bind seed = required row 0 ~field:"seed" in
          let%map value = f row in
          (seed, value) :: acc)
        |> Or_error.map ~f:(fun rows ->
          Hashtbl.of_alist_multi (module String) (List.rev rows)))
;;

(* D:8 is the widest cap every listed seed can carry a mark at. *)
let heat_marks_sql seeds =
  sprintf
    {|
select seed
     , band
  from seed_scores
 where version_id = %s
   and cap = ?
   and seed in (%s)
|}
    version_id_sql
    seeds
;;

let heat_marks t ~version ~(cap : Depth.t) ~seeds =
  match seeds with
  | [] -> Ok String.Map.empty
  | _ ->
    let placeholders = List.map seeds ~f:(fun _ -> "?") |> String.concat ~sep:", " in
    let sql = heat_marks_sql placeholders in
    with_stmt
      t
      sql
      ~bind:
        ([ version_bind version; Sqlite3.Data.INT (Int64.of_int cap) ]
         @ List.map seeds ~f:(fun seed -> Sqlite3.Data.TEXT seed))
      ~f:(fun stmt ->
        fold_rows stmt ~init:[] ~f:(fun acc row ->
          let open Or_error.Let_syntax in
          let%bind seed = required row 0 ~field:"seed" in
          let%bind band_int =
            match column_int row 1 with
            | Some i -> Ok i
            | None -> Or_error.error_string "band is null"
          in
          let%map band =
            match Heat.Band.of_int band_int with
            | Some band -> Ok band
            | None -> Or_error.errorf "corrupt band value: %d" band_int
          in
          (seed, band) :: acc)
        |> Or_error.map ~f:(fun rows -> String.Map.of_alist_exn rows))
;;

let summary_heat_cap = Fill_depth.shallow

let summarize t ~version ~seeds =
  let open Or_error.Let_syntax in
  let%bind feats =
    over_seeds t summary_feats_sql ~version ~seeds ~f:(fun row ->
      let%map.Or_error feat = required row 1 ~field:"feat" in
      feat, column_text row 2)
  in
  let%bind artefacts =
    over_seeds t summary_artefacts_sql ~version ~seeds ~f:(fun row ->
      Ok (Option.value (column_int row 1) ~default:0))
  in
  let%bind portals =
    over_seeds t summary_portals_sql ~version ~seeds ~f:(fun row ->
      let%map.Or_error level = required row 1 ~field:"level" in
      level, column_text row 2)
  in
  let%bind boons =
    over_seeds t summary_boons_sql ~version ~seeds ~f:(fun row ->
      let open Or_error.Let_syntax in
      let%bind base = required row 1 ~field:"base_type" in
      let%bind sub = required row 2 ~field:"sub_type" in
      let%map boon =
        match
          List.find Boon.all ~f:(fun b ->
            String.equal (Boon.base_type b) base && String.equal (Boon.sub_type b) sub)
        with
        | Some boon -> Ok boon
        | None -> Or_error.errorf "not a boon: %s of %s" base sub
      in
      boon, Option.value (column_int row 3) ~default:1)
  in
  let%map heat = heat_marks t ~version ~cap:summary_heat_cap ~seeds in
  List.map seeds ~f:(fun seed ->
    let feats = Hashtbl.find_multi feats seed in
    let temple =
      List.find_map feats ~f:(fun (feat, level) ->
        if String.equal feat "enter_temple" then level else None)
    in
    let rare_altars =
      List.filter_map feats ~f:(fun (feat, _) ->
        if String.is_prefix feat ~prefix:"altar_" then Some feat else None)
      |> List.dedup_and_sort ~compare:String.compare
    in
    { Level.Summary.seed
    ; temple
    ; artefacts = List.hd (Hashtbl.find_multi artefacts seed) |> Option.value ~default:0
    ; rare_altars
    ; portals =
        Hashtbl.find_multi portals seed
        |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b)
    ; boons =
        Hashtbl.find_multi boons seed
        |> List.sort ~compare:(fun (a, _) (b, _) -> Boon.compare a b)
    ; heat = Map.find heat seed
    })
;;

let list_seeds_unlocked t ~version ~(page : Query.Page.t) =
  let open Or_error.Let_syntax in
  let%bind seeds = page_seeds t ~version ~page in
  let seeds, more =
    match List.split_n seeds page.limit with
    | seeds, [] -> seeds, `End
    | seeds, _ -> seeds, `More
  in
  let%map summaries = summarize t ~version ~seeds in
  summaries, more
;;

let list_seeds t ~version ~page =
  with_txn t ~f:(fun t -> list_seeds_unlocked t ~version ~page)
;;

(* [limit] independent seeks, one per seed. A contiguous run samples
   neighbourhoods (9402, 9403, 9404), which restores the appearance of order
   the sampler exists to avoid.

   Each seek is a covering lookup, so cost is [limit] index seeks. Ordering by
   random() would be uniform but scans the whole version: 88ms over 10k seeds,
   linear.

   A cursor past the last seed returns nothing and restarts from the beginning,
   biasing slightly toward the low end of the keyspace. Crawl's seeds are
   near-uniform over leading digits, so the bias is small. Draws are
   independent, so a sample can repeat a seed. *)
let sample_seeds_unlocked t ~version ~limit =
  let draw () =
    let cursor = Int.to_string (Random.int 900_000_000 + 100_000_000) in
    let%bind.Or_error found =
      page_seeds t ~version ~page:(Query.Page.create ~after:cursor ~limit:1 ())
    in
    match found with
    | [] -> page_seeds t ~version ~page:(Query.Page.create ~limit:1 ())
    | found -> Ok found
  in
  let%bind.Or_error sampled =
    List.init limit ~f:(fun _ -> ()) |> List.map ~f:draw |> Or_error.all
  in
  (* Summarised in one pass over the drawn seeds rather than per draw: the
     summary lookups are range-bounded, so doing them inside [draw] would issue
     three queries per seed for a range of one. Sorted first because that range
     is [first, last] and the draws arrive scattered. *)
  let seeds = List.concat sampled |> List.dedup_and_sort ~compare:String.compare in
  let%map.Or_error summaries = summarize t ~version ~seeds in
  (* Shuffle after dedup to avoid re-imposing seed order. *)
  List.permute summaries, `End
;;

let sample_seeds t ~version ~limit =
  with_txn t ~f:(fun t -> sample_seeds_unlocked t ~version ~limit)
;;

(* Membership in the cohort, not in [entries]: a seed whose levels were filled
   has a [seed_fills] row whether or not any entry survived pruning. *)
let present_seeds_sql seeds =
  sprintf
    {|
select seed
  from seed_fills
 where version_id = %s
   and seed in (%s)
|}
    version_id_sql
    seeds
;;

let present_seeds t ~version ~seeds =
  match seeds with
  | [] -> Ok String.Set.empty
  | _ ->
    let placeholders = List.map seeds ~f:(fun _ -> "?") |> String.concat ~sep:", " in
    with_stmt
      t
      (present_seeds_sql placeholders)
      ~bind:(version_bind version :: List.map seeds ~f:(fun s -> Sqlite3.Data.TEXT s))
      ~f:(fun stmt ->
        fold_rows stmt ~init:String.Set.empty ~f:(fun acc row ->
          let%map.Or_error seed = required row 0 ~field:"seed" in
          Set.add acc seed))
;;

let summarize_seeds t ~version ~seeds =
  with_txn t ~f:(fun t ->
    let open Or_error.Let_syntax in
    let%bind present = present_seeds t ~version ~seeds in
    let%map summaries =
      summarize
        t
        ~version
        ~seeds:(List.filter seeds ~f:(fun seed -> Set.mem present seed))
    in
    summaries)
;;

module Seed_levels_col = struct
  let at = Columns.at seed_levels_columns
  let level = at "level"
  let cat = at "cat"
  let name = at "name"
  let base_type = at "base_type"
  let sub_type = at "sub_type"
  let quantity = at "quantity"
  let artefact = at "artefact"
  let branded = at "branded"
  let plus = at "plus"
  let cost = at "cost"
  let ego = at "ego"
  let feat = at "feat"
  let timeout_turns = at "timeout_turns"
  let unique_mons = at "unique_mons"
  let native = at "native"
  let type_name = at "type_name"
  let x = at "x"
  let y = at "y"
  let carried_by = at "carried_by"
  let id = at "id"
  let shop_type = at "shop_type"
  let toll_note = at "toll_note"
end

(* [name] is stored only where [Display_name.of_entry] cannot rebuild it; null
   is the normal case. If the derivation answers [Irreducible] on a row that
   stored no name, the row is corrupt. *)
let entry_of_row row =
  let open Or_error.Let_syntax in
  let%bind cat_int =
    match column_int row Seed_levels_col.cat with
    | Some i -> Ok i
    | None -> Or_error.error_string "cat is null"
  in
  let%bind cat =
    match Record.Cat.of_int cat_int with
    | Some cat -> Ok cat
    | None -> Or_error.errorf "unknown cat: %d" cat_int
  in
  let stored_name = column_text row Seed_levels_col.name in
  let entry =
    { Record.Entry.cat
    ; name = Option.value stored_name ~default:""
    ; base_type = column_text row Seed_levels_col.base_type
    ; sub_type = column_text row Seed_levels_col.sub_type
    ; quantity = column_int row Seed_levels_col.quantity
    ; artefact = column_bool row Seed_levels_col.artefact
    ; branded = column_bool row Seed_levels_col.branded
    ; plus = column_int row Seed_levels_col.plus
    ; cost = column_int row Seed_levels_col.cost
    ; ego = column_text row Seed_levels_col.ego
    ; feat = column_text row Seed_levels_col.feat
    ; timeout_turns = column_int row Seed_levels_col.timeout_turns
    ; unique_mons = column_bool row Seed_levels_col.unique_mons
    ; native = column_bool row Seed_levels_col.native
    ; type_name = column_text row Seed_levels_col.type_name
    ; x = column_int row Seed_levels_col.x
    ; y = column_int row Seed_levels_col.y
    ; carried_by = column_text row Seed_levels_col.carried_by
    ; shop_type = column_text row Seed_levels_col.shop_type
    ; toll_note = column_text row Seed_levels_col.toll_note
    ; spells = []
    ; props = []
    }
  in
  match stored_name with
  | Some _ -> Ok entry
  | None ->
    (match Display_name.of_entry entry with
     | Display_name.Derived name -> Ok { entry with name }
     | Display_name.Irreducible ->
       Or_error.error_s
         [%message
           "entry stores no name and none can be derived"
             ~cat:(Record.Cat.to_string entry.cat)
             ~feat:(entry.feat : string option)
             ~base_type:(entry.base_type : string option)
             ~sub_type:(entry.sub_type : string option)])
;;

let children_by_entry t sql ~version ~seed ~f =
  with_stmt
    t
    sql
    ~bind:[ Sqlite3.Data.TEXT seed; version_bind version ]
    ~f:(fun stmt ->
      fold_rows stmt ~init:[] ~f:(fun acc row ->
        let open Or_error.Let_syntax in
        let%bind entry_id =
          match column_int row 0 with
          | Some id -> Ok id
          | None -> Or_error.error_string "entry_id is null"
        in
        let%map child = f row in
        (entry_id, child) :: acc)
      |> Or_error.map ~f:(fun rows -> Hashtbl.of_alist_multi (module Int) (List.rev rows)))
;;

(* Reunites the three places a book's spells can live (derived from name, fixed
   for the build, stored per entry) into the one field the record carries. *)
let spells_of_entry (e : Record.Entry.t) ~book_spells ~stored =
  match Option.bind e.sub_type ~f:Book.spells_of_sub_type with
  | Some derived -> derived
  | None ->
    (match Option.bind e.sub_type ~f:(fun sub_type -> Map.find book_spells sub_type) with
     | Some fixed -> fixed
     | None -> stored)
;;

(* Test hook: a writer installed here proves the enclosing transaction holds
   across all child reads. Without it, a mid-read commit reassigns entries.id
   and the hashtables key on stale ids. *)
let between_reads : (unit -> unit) ref = ref (fun () -> ())

let seed_levels_unlocked t ~version ~seed =
  let open Or_error.Let_syntax in
  let%bind spells =
    children_by_entry t seed_spells_sql ~version ~seed ~f:(fun row ->
      required row 1 ~field:"spell")
  in
  let%bind book_spells =
    with_stmt
      t
      version_book_spells_sql
      ~bind:[ version_bind version ]
      ~f:(fun stmt ->
        fold_rows stmt ~init:[] ~f:(fun acc row ->
          let%bind sub_type = required row 0 ~field:"sub_type" in
          let%map spell = required row 1 ~field:"spell" in
          (sub_type, spell) :: acc)
        |> Or_error.map ~f:(fun rows ->
          List.rev rows |> Map.of_alist_multi (module String)))
  in
  let%bind props =
    children_by_entry t seed_props_sql ~version ~seed ~f:(fun row ->
      let%bind prop = required row 1 ~field:"prop" in
      match column_int row 2 with
      | Some value -> Ok { Record.Prop.prop; value }
      | None -> Or_error.errorf "%s: value is null" prop)
  in
  let%bind infos =
    with_stmt
      t
      seed_level_list_sql
      ~bind:[ Sqlite3.Data.TEXT seed; version_bind version ]
      ~f:(fun stmt ->
        fold_rows stmt ~init:[] ~f:(fun acc row ->
          let%map level = required row 0 ~field:"level" in
          { Level.Info.level
          ; parent_level = column_text row 1
          ; temple_altars = column_int row 2
          ; gold = column_int row 3
          }
          :: acc)
        |> Or_error.map ~f:List.rev)
  in
  !between_reads ();
  with_stmt
    t
    seed_levels_sql
    ~bind:[ Sqlite3.Data.TEXT seed; version_bind version ]
    ~f:(fun stmt ->
      let%bind () = Columns.check_header seed_levels_columns stmt in
      fold_rows stmt ~init:[] ~f:(fun acc row ->
        let%bind level = required row Seed_levels_col.level ~field:"level" in
        let%map entry = entry_of_row row in
        let stored, props =
          match column_int row Seed_levels_col.id with
          | None -> [], []
          | Some id ->
            (* find_multi returns insertion order reversed; sort both. *)
            ( Hashtbl.find_multi spells id |> List.sort ~compare:String.compare
            , Hashtbl.find_multi props id
              |> List.sort ~compare:(fun (a : Record.Prop.t) b ->
                String.compare a.prop b.prop) )
        in
        let entry =
          { entry with spells = spells_of_entry entry ~book_spells ~stored; props }
        in
        (level, entry) :: acc)
      |> Or_error.map ~f:(fun rows -> Level.of_rows ~infos (List.rev rows)))
;;

let seed_levels t ~version ~seed =
  with_txn t ~f:(fun t -> seed_levels_unlocked t ~version ~seed)
;;

module Counts = struct
  type t =
    { levels : int
    ; entries : int
    ; rejected : int
    }
  [@@deriving sexp_of, fields]

  let zero = { levels = 0; entries = 0; rejected = 0 }

  let add a b =
    { levels = a.levels + b.levels
    ; entries = a.entries + b.entries
    ; rejected = a.rejected + b.rejected
    }
  ;;

  let to_string { levels; entries; rejected } =
    Printf.sprintf
      "%d levels ingested, %d entries written, %d lines rejected"
      levels
      entries
      rejected
  ;;
end

let insert_version_sql =
  "insert into versions (version) values (?) on conflict do nothing"
;;

let version_id_of_sql = "select id from versions where version = ?"

(* insert-or-ignore then read back, not an OCaml-side cache: a cache would need
   invalidation against concurrent writers for a saving the ingest path does
   not wait on (182k writes/sec vs crawl's ~1,700 rows/sec). *)
let insert_string_sql = "insert or ignore into strings (val) values (?)"

(* The level name must be interned before the delete. The idempotency delete
   resolves the level through the dictionary; if the name is not yet in
   `strings`, the subquery yields null, the delete matches nothing, and the
   insert adds a duplicate instead of replacing. *)
(* [version_id] binds as the resolved integer. Binding the string against an
   integer column would match nothing and silently break re-ingest idempotency. *)
let delete_level_sql =
  sprintf
    "delete from seed_levels where seed = ? and version_id = ? and level_id = %s"
    string_id_sql
;;

let insert_level_sql =
  sprintf
    {|
insert into seed_levels
          ( seed
          , version_id
          , level_id
          , format
          , parent_level_id
          , temple_altars
          , gold
          )
     values
          ( ?
          , ?
          , %s
          , ?
          , %s
          , ?
          , ?
          )
|}
    string_id_sql
    string_id_sql
;;

(* Interned columns resolve through the dictionary in the insert. A null value
   yields null from the subquery, which is the column's meaning. *)
let insert_entry_columns =
  Columns.of_list
    [ "seed"
    ; "version_id"
    ; "level_id"
    ; "cat"
    ; "name_id"
    ; "base_type_id"
    ; "sub_type_id"
    ; "quantity"
    ; "artefact"
    ; "branded"
    ; "plus"
    ; "cost"
    ; "ego_id"
    ; "feat_id"
    ; "timeout_turns"
    ; "unique_mons"
    ; "native"
    ; "type_name_id"
    ; "x"
    ; "y"
    ; "carried_by_id"
    ; "shop_type_id"
    ; "toll_note_id"
    ]
;;

let insert_entry_interned =
  String.Set.of_list
    [ "level_id"
    ; "name_id"
    ; "base_type_id"
    ; "sub_type_id"
    ; "ego_id"
    ; "feat_id"
    ; "type_name_id"
    ; "carried_by_id"
    ; "shop_type_id"
    ; "toll_note_id"
    ]
;;

let insert_entry_sql =
  let values =
    Columns.names insert_entry_columns
    |> List.map ~f:(fun name ->
      if Set.mem insert_entry_interned name then string_id_sql else "?")
    |> String.concat ~sep:", "
  in
  sprintf
    {|
insert into entries
%s )
     values (%s)
|}
    (Columns.render insert_entry_columns ~lead:"          ( " ~sep:"          ")
    values
;;

(* Recomputed from seed_levels after a batch lands rather than tracked per
   batch: a seed's levels can split across batches, so only the stored level
   list is authoritative about how deep the seed actually got. Portals are
   excluded here for the same reason Fill_depth.of_levels drops them -- a
   portal ranks at its parent's depth and never extends a seed's reach. *)
let seed_fill_levels_sql =
  {|
select s_level.val
  from seed_levels sl
  join strings s_level
    on s_level.id = sl.level_id
 where sl.seed = ?
   and sl.version_id = ?
|}
;;

(* A fill reaching a submitted seed takes it into the sample; a request never
   takes a seed out of it. *)
let upsert_seed_fill_sql =
  {|
insert into seed_fills
          ( seed
          , version_id
          , depth
          , origin
          )
     values
          ( ?
          , ?
          , ?
          , ?
          )
on conflict
          ( seed
          , version_id
          )
  do update
        set depth
            = excluded.depth
          , filled_at
            = unixepoch()
          , origin
            = case when excluded.origin = 'fill' then 'fill' else origin end
|}
;;

let insert_spell_sql =
  sprintf
    {|
insert into entry_spells
          ( entry_id
          , seed
          , version_id
          , level_id
          , spell_id
          )
     values
          ( ?
          , ?
          , ?
          , %s
          , %s
          )
|}
    string_id_sql
    string_id_sql
;;

let insert_book_spell_sql =
  sprintf
    "insert into book_spells (version_id, sub_type_id, spell_id) values (?, %s, %s) on \
     conflict do nothing"
    string_id_sql
    string_id_sql
;;

let book_spells_sql =
  {|
  select s_spell.val
    from book_spells bs
    join strings s_spell
      on s_spell.id = bs.spell_id
   where bs.version_id = ?
     and bs.sub_type_id = (select id from strings where val = ?)
order by s_spell.val
|}
;;

let insert_prop_sql =
  sprintf
    {|
insert into entry_props
          ( entry_id
          , seed
          , version_id
          , level_id
          , prop_id
          , value
          )
     values
          ( ?
          , ?
          , ?
          , %s
          , %s
          , ?
          )
|}
    string_id_sql
    string_id_sql
;;

let text_or_null = function
  | Some s -> Sqlite3.Data.TEXT s
  | None -> Sqlite3.Data.NULL
;;

let int_or_null = function
  | Some i -> Sqlite3.Data.INT (Int64.of_int i)
  | None -> Sqlite3.Data.NULL
;;

(* strict mode has no boolean type, and the entries_search_artefact partial index is
   defined on [artefact = 1], so booleans must land as 0/1 integers. *)
let bool_or_null = function
  | Some b -> Sqlite3.Data.INT (if b then 1L else 0L)
  | None -> Sqlite3.Data.NULL
;;

(* SQLite numbers parameters from one, the column list from zero. *)
module Entry_param = struct
  let param name = Columns.at insert_entry_columns name + 1
  let seed = param "seed"
  let version_id = param "version_id"
  let level = param "level_id"
  let cat = param "cat"
  let name = param "name_id"
  let base_type = param "base_type_id"
  let sub_type = param "sub_type_id"
  let quantity = param "quantity"
  let artefact = param "artefact"
  let branded = param "branded"
  let plus = param "plus"
  let cost = param "cost"
  let ego = param "ego_id"
  let feat = param "feat_id"
  let timeout_turns = param "timeout_turns"
  let unique_mons = param "unique_mons"
  let native = param "native"
  let type_name = param "type_name_id"
  let x = param "x"
  let y = param "y"
  let carried_by = param "carried_by_id"
  let shop_type = param "shop_type_id"
  let toll_note = param "toll_note_id"
end

(* Interned values bind as text; the insert's subquery resolves them. [intern]
   must run before the statement that looks the value up.

   [name_id] stores a name only for the irreducible tail (artefacts, monsters,
   unrecognised feats); derivable rows store null. *)
let bind_entry stmt ~intern ~version_id ~(record : Record.t) ~(e : Record.Entry.t) =
  let bind i data = check_rc "bind" (Sqlite3.bind stmt i data) in
  let bind_interned i value =
    Option.iter value ~f:intern;
    bind i (text_or_null value)
  in
  bind Entry_param.seed (Sqlite3.Data.TEXT record.seed);
  bind Entry_param.version_id (Sqlite3.Data.INT (Int64.of_int version_id));
  bind_interned Entry_param.level (Some record.level);
  bind Entry_param.cat (Sqlite3.Data.INT (Int64.of_int (Record.Cat.to_int e.cat)));
  bind_interned
    Entry_param.name
    (match Display_name.of_entry e with
     | Display_name.Derived _ -> None
     | Display_name.Irreducible -> Some e.name);
  bind_interned Entry_param.base_type e.base_type;
  bind_interned Entry_param.sub_type e.sub_type;
  bind Entry_param.quantity (int_or_null e.quantity);
  bind Entry_param.artefact (bool_or_null e.artefact);
  bind Entry_param.branded (bool_or_null e.branded);
  bind Entry_param.plus (int_or_null e.plus);
  bind Entry_param.cost (int_or_null e.cost);
  bind_interned Entry_param.ego e.ego;
  bind_interned Entry_param.feat e.feat;
  bind Entry_param.timeout_turns (int_or_null e.timeout_turns);
  bind Entry_param.unique_mons (bool_or_null e.unique_mons);
  bind Entry_param.native (bool_or_null e.native);
  bind_interned Entry_param.type_name e.type_name;
  bind Entry_param.x (int_or_null e.x);
  bind Entry_param.y (int_or_null e.y);
  bind_interned Entry_param.carried_by e.carried_by;
  bind_interned Entry_param.shop_type e.shop_type;
  bind_interned Entry_param.toll_note e.toll_note
;;

let step_reset stmt =
  check_rc "step" (Sqlite3.step stmt);
  check_rc "reset" (Sqlite3.reset stmt)
;;

(* A named book's spells are a property of the build. First sighting records
   them; later sightings check against that record. A disagreement means the
   version string covers two builds, and the batch is refused. *)
let sync_book_spells t ~insert_stmt ~intern ~version ~version_id ~sub_type ~spells =
  let stored =
    with_stmt
      t
      book_spells_sql
      ~bind:[ Sqlite3.Data.INT (Int64.of_int version_id); Sqlite3.Data.TEXT sub_type ]
      ~f:(fun stmt ->
        fold_rows stmt ~init:[] ~f:(fun acc row ->
          let%map.Or_error spell = required row 0 ~field:"spell" in
          spell :: acc)
        |> Or_error.map ~f:List.rev)
    |> Or_error.ok_exn
  in
  let sorted = List.sort spells ~compare:String.compare in
  if List.is_empty stored
  then
    List.iter sorted ~f:(fun spell ->
      let bind i data = check_rc "bind" (Sqlite3.bind insert_stmt i data) in
      intern sub_type;
      intern spell;
      bind 1 (Sqlite3.Data.INT (Int64.of_int version_id));
      bind 2 (Sqlite3.Data.TEXT sub_type);
      bind 3 (Sqlite3.Data.TEXT spell);
      step_reset insert_stmt)
  else if not (List.equal String.equal stored sorted)
  then
    Error.raise
      (Error.create_s
         [%message
           "a book's spells disagree with the version's recorded set"
             (version : string)
             (sub_type : string)
             ~got:(sorted : string list)
             ~recorded:(stored : string list)])
;;

let refresh_seed_fill t ~seed ~version_id ~requested =
  let levels =
    with_stmt
      t
      seed_fill_levels_sql
      ~bind:[ Sqlite3.Data.TEXT seed; Sqlite3.Data.INT (Int64.of_int version_id) ]
      ~f:(fun stmt ->
        fold_rows stmt ~init:[] ~f:(fun acc row ->
          let%map.Or_error level = required row 0 ~field:"level" in
          level :: acc))
    |> Or_error.ok_exn
  in
  let depth = Fill_depth.of_levels levels in
  with_stmt
    t
    upsert_seed_fill_sql
    ~bind:
      [ Sqlite3.Data.TEXT seed
      ; Sqlite3.Data.INT (Int64.of_int version_id)
      ; Sqlite3.Data.INT (Int64.of_int depth)
      ; Sqlite3.Data.TEXT (if requested then "submit" else "fill")
      ]
    ~f:(fun stmt ->
      check_rc "step" (Sqlite3.step stmt);
      Ok ())
  |> Or_error.ok_exn
;;

let write_batch ?(requested = false) (t : t) (records : Record.t list) : Counts.t =
  if List.is_empty records
  then Counts.zero
  else
    (* Immediate: a batch reads before it writes, so a deferred transaction
       risks losing the write lock mid-batch. *)
    with_immediate_txn t ~f:(fun t ->
      let version_stmt = Sqlite3.prepare t insert_version_sql in
      let version_id_stmt = Sqlite3.prepare t version_id_of_sql in
      let string_stmt = Sqlite3.prepare t insert_string_sql in
      let delete_stmt = Sqlite3.prepare t delete_level_sql in
      let level_stmt = Sqlite3.prepare t insert_level_sql in
      let entry_stmt = Sqlite3.prepare t insert_entry_sql in
      let spell_stmt = Sqlite3.prepare t insert_spell_sql in
      let prop_stmt = Sqlite3.prepare t insert_prop_sql in
      let book_stmt = Sqlite3.prepare t insert_book_spell_sql in
      let finalize () =
        List.iter
          [ version_stmt
          ; version_id_stmt
          ; string_stmt
          ; delete_stmt
          ; level_stmt
          ; entry_stmt
          ; spell_stmt
          ; prop_stmt
          ; book_stmt
          ]
          ~f:(fun stmt -> ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t))
      in
      Exn.protect ~finally:finalize ~f:(fun () ->
        (* Intern all values before the statements that look them up. *)
        let intern value =
          check_rc "bind string" (Sqlite3.bind string_stmt 1 (Sqlite3.Data.TEXT value));
          step_reset string_stmt
        in
        (* Register versions first: seed_levels has a foreign key to versions. *)
        let version_ids =
          List.map records ~f:Record.version
          |> List.dedup_and_sort ~compare:String.compare
          |> List.map ~f:(fun version ->
            check_rc
              "bind version"
              (Sqlite3.bind version_stmt 1 (Sqlite3.Data.TEXT version));
            step_reset version_stmt;
            check_rc
              "bind version"
              (Sqlite3.bind version_id_stmt 1 (Sqlite3.Data.TEXT version));
            let id =
              match Sqlite3.step version_id_stmt with
              | Sqlite3.Rc.ROW -> Sqlite3.column_int version_id_stmt 0
              | rc -> failwithf "version id: %s" (Sqlite3.Rc.to_string rc) ()
            in
            check_rc "reset" (Sqlite3.reset version_id_stmt);
            version, id)
          |> String.Map.of_alist_exn
        in
        let entries =
          List.fold records ~init:0 ~f:(fun acc (record : Record.t) ->
            let version_id = Map.find_exn version_ids record.version in
            (* Intern level and parent before the delete resolves them. *)
            intern record.level;
            Option.iter record.parent_level ~f:intern;
            let bind_key stmt =
              check_rc "bind" (Sqlite3.bind stmt 1 (Sqlite3.Data.TEXT record.seed));
              check_rc
                "bind"
                (Sqlite3.bind stmt 2 (Sqlite3.Data.INT (Int64.of_int version_id)));
              check_rc "bind" (Sqlite3.bind stmt 3 (Sqlite3.Data.TEXT record.level))
            in
            (* Delete-then-insert makes re-ingesting a (seed, version, level)
               idempotent; entries cascade from the seed_levels row. *)
            bind_key delete_stmt;
            step_reset delete_stmt;
            bind_key level_stmt;
            check_rc
              "bind format"
              (Sqlite3.bind level_stmt 4 (Sqlite3.Data.INT (Int64.of_int record.format)));
            check_rc
              "bind parent_level"
              (Sqlite3.bind level_stmt 5 (text_or_null record.parent_level));
            check_rc
              "bind temple_altars"
              (Sqlite3.bind level_stmt 6 (int_or_null record.temple_altars));
            check_rc "bind gold" (Sqlite3.bind level_stmt 7 (int_or_null record.gold));
            step_reset level_stmt;
            List.iter record.entries ~f:(fun e ->
              bind_entry entry_stmt ~intern ~version_id ~record ~e;
              step_reset entry_stmt;
              (* Named book spells go to book_spells, not entry_spells. *)
              let fixed_book =
                (not (List.is_empty e.spells))
                && Book.spells_are_fixed ~sub_type:e.sub_type ~artefact:e.artefact
              in
              if fixed_book
              then
                sync_book_spells
                  t
                  ~insert_stmt:book_stmt
                  ~intern
                  ~version:record.version
                  ~version_id
                  ~sub_type:(Option.value_exn e.sub_type)
                  ~spells:e.spells;
              let spells = if fixed_book then [] else e.spells in
              if (not (List.is_empty spells)) || not (List.is_empty e.props)
              then (
                let entry_id = Sqlite3.last_insert_rowid t in
                let bind_child stmt =
                  let bind i data = check_rc "bind" (Sqlite3.bind stmt i data) in
                  bind 1 (Sqlite3.Data.INT entry_id);
                  bind 2 (Sqlite3.Data.TEXT record.seed);
                  bind 3 (Sqlite3.Data.INT (Int64.of_int version_id));
                  bind 4 (Sqlite3.Data.TEXT record.level)
                in
                List.iter spells ~f:(fun spell ->
                  intern spell;
                  bind_child spell_stmt;
                  check_rc "bind" (Sqlite3.bind spell_stmt 5 (Sqlite3.Data.TEXT spell));
                  step_reset spell_stmt);
                List.iter e.props ~f:(fun (p : Record.Prop.t) ->
                  intern p.prop;
                  bind_child prop_stmt;
                  check_rc "bind" (Sqlite3.bind prop_stmt 5 (Sqlite3.Data.TEXT p.prop));
                  check_rc
                    "bind"
                    (Sqlite3.bind prop_stmt 6 (Sqlite3.Data.INT (Int64.of_int p.value)));
                  step_reset prop_stmt)));
            acc + List.length record.entries)
        in
        List.map records ~f:(fun (r : Record.t) -> r.seed, r.version)
        |> List.dedup_and_sort ~compare:[%compare: string * string]
        |> List.iter ~f:(fun (seed, version) ->
          refresh_seed_fill
            t
            ~seed
            ~version_id:(Map.find_exn version_ids version)
            ~requested);
        { Counts.levels = List.length records; entries; rejected = 0 }))
;;

let ingest_channel ?requested t input ~batch_size ~on_reject =
  let totals = ref Counts.zero in
  let batch = ref [] in
  let pending = ref 0 in
  let flush () =
    if !pending > 0
    then (
      let counts = write_batch ?requested t (List.rev !batch) in
      totals := Counts.add !totals counts;
      batch := [];
      pending := 0)
  in
  let line_number = ref 0 in
  In_channel.iter_lines input ~f:(fun line ->
    incr line_number;
    match Reader.parse_line line with
    | Ok record ->
      batch := record :: !batch;
      incr pending;
      if !pending >= batch_size then flush ()
    | Error e ->
      on_reject !line_number e;
      totals := Counts.add !totals { Counts.zero with rejected = 1 });
  flush ();
  !totals
;;

(* A substring search must escape the wildcards, or a name containing '%' or
   '_' silently matches more than the reader asked for. The escape character
   itself goes first, or escaping it would double-escape the others. *)
let like_contains fragment =
  let escaped =
    String.concat_map fragment ~f:(function
      | ('\\' | '%' | '_') as c -> sprintf "\\%c" c
      | c -> String.of_char c)
  in
  "%" ^ escaped ^ "%"
;;

(* One criterion becomes one predicate over an aliased [entries] row. The alias
   lets the same fragment serve as driver [where] or correlated [exists]. *)
(* [cost is not null] looks redundant against entries_search_shop's partial
   index qualifier, but dropping it makes SQLite choose entries_search_type
   instead, which has no shop qualifier and returns floor stock too (335,174
   vs 30,870 rows, wand:digging, 1.3M, 0.34.1, 2026-09-05, prod).

   [cost] trails entries_search_type, so the [Floor] test stays covering
   there. It does not trail entries_search_name, so [Name_like] pays a table
   lookup per candidate name that the other positions do not. *)
let position_where ~alias (position : Search.Criterion.position) =
  match position with
  | Search.Criterion.Floor -> sprintf "%s.cost is null" alias
  | Search.Criterion.Shop -> sprintf "%s.cost is not null" alias
;;

(* One [exists] per property, correlated on [alias.id] -- the shape both
   [criterion_where]'s [Props] branch and [props_seek]'s non-seeking remainder
   need, factored out so the two stay in sync.

   [value >= min_value] excludes the penalty rows: about one row in five of
   [Str], [rF], [Slay] and their kin is negative, and a reader asking for [rF]
   does not mean [rF-]. It is also what makes [rF] cover [rF++] without a
   grouping mechanism. *)
let props_exist ~alias props =
  let where =
    List.map props ~f:(fun _ ->
      sprintf
        "exists (select 1 from entry_props p where p.entry_id = %s.id and p.prop_id = %s \
         and p.value >= ?)"
        alias
        string_id_sql)
  in
  let bind =
    List.concat_map props ~f:(fun p ->
      [ Sqlite3.Data.TEXT p; Sqlite3.Data.INT (Int64.of_int Search.Prop.min_value) ])
  in
  where, bind
;;

(* One criterion becomes one predicate over an aliased [entries] row. The alias
   lets the same fragment serve as driver [where] or correlated [exists].

   [~version] is the search's own build: the one criterion that needs it is
   [Brand], whose word resolves to the code spelling that build stores. Every
   caller has the version already -- a search is never version-less. *)
let criterion_where ~version (criterion : Search.Criterion.t) ~alias =
  let col name = sprintf "%s.%s" alias name in
  match criterion with
  | Search.Criterion.Item ({ base_type; sub_type }, position) ->
    ( sprintf
        "%s = %s and %s = %s and %s"
        (col "base_type_id")
        string_id_sql
        (col "sub_type_id")
        string_id_sql
        (position_where ~alias position)
    , [ Sqlite3.Data.TEXT base_type; Sqlite3.Data.TEXT sub_type ] )
  | Search.Criterion.Feature feat ->
    sprintf "%s = %s" (col "feat_id") string_id_sql, [ Sqlite3.Data.TEXT feat ]
  (* [unique_mons = 1] implies [cat = Monsters]; the extra predicate is not in
     entries_search_unique and costs a table lookup per row. *)
  | Search.Criterion.Unique name ->
    ( sprintf "%s = 1 and %s = %s" (col "unique_mons") (col "name_id") string_id_sql
    , [ Sqlite3.Data.TEXT name ] )
  (* Substring match runs over the dictionary, not entries: yields ids of every
     distinct name containing the fragment, then entries_search_name turns each
     into a covering seek.

     Two stages, both load-bearing. The inner `like` against strings_fts must
     carry no `escape` clause: fts5 declines the trigram optimisation when one
     is present and silently falls back to the scan (measured 0.005s against
     1.056s, 3.53.2). So trigram reads `%` and `_` as live wildcards, making
     that stage a superset; the outer escaped `like` against `strings`
     re-checks survivors literally by primary key. *)
  | Search.Criterion.Name_like (fragment, position) ->
    ( sprintf
        "%s in (select id from strings where id in (select rowid from strings_fts where \
         val like ?) and val like ? escape '\\') and %s"
        (col "name_id")
        (position_where ~alias position)
    , [ Sqlite3.Data.TEXT ("%" ^ fragment ^ "%")
      ; Sqlite3.Data.TEXT (like_contains fragment)
      ] )
  (* One [exists] per property, every one correlated on the *same* entry row, so
     the whole set is carried by one item. That correlation is the criterion's
     entire point; see [Search.Criterion].

     Correlating on [id] rather than on [seed] is also what keeps this
     alias-clean: the subqueries reach into the aliased row and never mention
     [e], so the fragment works unchanged as a driver, as a correlated
     non-driver, and inside [term_hits_sql]. [entry_props_entry (entry_id)]
     serves the seek here; [driver_select]/[correlated_select] use [props_seek]
     instead, which drives off [entry_props_search] rather than scanning
     [entries] with every property carried as one of these. *)
  | Search.Criterion.Props { base_type; props; position } ->
    let prop_exists, prop_bind = props_exist ~alias props in
    (* An empty set is rejected at the parse boundary and cannot arrive from a
       URL, but the constructor is public. Read as "an artefact, unconstrained"
       rather than as a predicate over no properties: only an artefact carries
       properties at all, so it is the weakest true reading rather than a
       different question. *)
    let where, bind =
      match base_type with
      | None ->
        if List.is_empty prop_exists
        then [ sprintf "%s = 1" (col "artefact") ], []
        else prop_exists, prop_bind
      | Some base_type ->
        ( sprintf "%s = %s" (col "base_type_id") string_id_sql :: prop_exists
        , Sqlite3.Data.TEXT base_type :: prop_bind )
    in
    String.concat (where @ [ position_where ~alias position ]) ~sep:" and ", bind
  (* The word resolves to the build's own code spelling; an unknown word has
     no code, and "matches nothing" is the honest reading of a criterion the
     parse boundary would have refused. Binding the word itself would instead
     hit any code that happens to equal it -- half the vocabulary does
     ([chaos], [speed], [venom]). *)
  | Search.Criterion.Brand { base_type; sub_type; word; position } ->
    (match Search.Brand.code ~base_type ~version word with
     | None -> "1 = 0", []
     | Some code ->
       let sub_where, sub_bind =
         match sub_type with
         | None -> "", []
         | Some sub_type ->
           ( sprintf "%s = %s and " (col "sub_type_id") string_id_sql
           , [ Sqlite3.Data.TEXT sub_type ] )
       in
       ( sprintf
           "%s = %s and %s%s = %s and %s"
           (col "base_type_id")
           string_id_sql
           sub_where
           (col "ego_id")
           string_id_sql
           (position_where ~alias position)
       , (Sqlite3.Data.TEXT base_type :: sub_bind) @ [ Sqlite3.Data.TEXT code ] ))
;;

(* [driver_select] and [correlated_select] scan the whole build for any bare
   [Props] search -- confirmed via [explain query plan] and measured (67-69s
   for [props:Conj] alone under a bounded [Rank.Shallowest] fetch, 1.3M,
   0.34.1, prod clone, 2026-09-17; fossil ticket 1e34af034b) -- because
   [criterion_where]'s [exists]es are filters on a driving row, not a seek of
   their own. [entry_props] is two orders of magnitude smaller than [entries]
   (AGENTS.md), so seeking any one property there and joining back beats
   scanning every entry; which property drives does not affect the result, so
   the first one in the list does.

   Returns the extra [from] clause, the alias [entry_props] row that carries
   the version scope, and a [where] fragment scoped to [entries_alias] --
   everything [criterion_where] returns except the version, which the caller
   adds itself the same way it already does for every other criterion.
   [None] for the bare-artefact reading (no properties), which already seeks
   [entries_search_artefact] and needs no rewrite.

   Not used by [verify_terms], [cohort_depths_sql], or [term_hits_sql]: those
   are bounded to a known seed batch already (an indexed seek on
   [entries_seed], confirmed via [explain query plan] and flat at 16.4M rows
   scaled locally, 2026-09-17) and stay on [criterion_where]. *)
let props_seek ~base_type ~props ~position ~entries_alias ~props_alias =
  match props with
  | [] -> None
  | first :: rest ->
    let from_ =
      sprintf
        "entry_props %s join entries %s on %s.id = %s.entry_id"
        props_alias
        entries_alias
        entries_alias
        props_alias
    in
    let rest_where, rest_bind = props_exist ~alias:entries_alias rest in
    let base_type_where, base_type_bind =
      match base_type with
      | None -> [], []
      | Some base_type ->
        ( [ sprintf "%s.base_type_id = %s" entries_alias string_id_sql ]
        , [ Sqlite3.Data.TEXT base_type ] )
    in
    let where =
      String.concat
        (sprintf "%s.prop_id = %s and %s.value >= ?" props_alias string_id_sql props_alias
         :: (base_type_where
             @ rest_where
             @ [ position_where ~alias:entries_alias position ]))
        ~sep:" and "
    in
    let bind =
      (Sqlite3.Data.TEXT first
       :: Sqlite3.Data.INT (Int64.of_int Search.Prop.min_value)
       :: base_type_bind)
      @ rest_bind
    in
    Some (from_, where, bind)
;;

(* Static driver preference: rare things first. [Unique] and shop stock narrow
   hardest -- a shop holds a fraction of what the floor does, which is why
   [Item (_, Shop)] outranks its floor twin; [Props] is least selective. Ties
   keep caller's order. *)
let criterion_driver_rank (criterion : Search.Criterion.t) =
  match criterion with
  (* A brand term narrows at least as hard as a unique: it is an item term plus
     an ego test, so it belongs in the rarest class. *)
  | Search.Criterion.Unique _ | Search.Criterion.Brand _
  | Search.Criterion.Item (_, Search.Criterion.Shop) -> 0
  | Search.Criterion.Item (_, Search.Criterion.Floor)
  | Search.Criterion.Feature _ | Search.Criterion.Name_like _ -> 1
  (* Last. The property [exists]es are filters on a driving row rather than a
     seek of their own, so [Props] drives only when nothing else can. With a
     base type that fallback is an ordinary type seek; without one it is a scan
     of the build, which is what [is_cheap] answers for.

     Declining to promote [Props (_, Shop)] the way [Item (_, Shop)] is promoted
     is the decision, not the oversight: that would be a fresh static-rank
     judgement in a function the posting-list index deletes outright (postings
     merge shortest-list-first, so order comes from list length), and the whole
     cost of getting it wrong is a different result order over the same set. *)
  | Search.Criterion.Props _ -> 2
;;

(* [min_count > 1] pushes a term to the back: as driver it streams a
   [group by ... having] over the whole table rather than seeking. *)
let driver_rank (term : Search.Term.t) =
  (if term.min_count > 1 then 1 else 0), criterion_driver_rank term.criterion
;;

(* The driver term, rendered against the outer query's own [entries e] row --
   decided by the caller (see [search_seeds_sql]/[driver_rank]), not here.

   For [min_count <= 1] this is just the criterion's own [where] clause,
   returned as [`Where]. For [min_count > 1] there is no single-row predicate
   that expresses "sum of quantity across this seed's matching rows meets a
   threshold" -- that needs every row for the seed, so the driver instead
   reshapes the *whole* query into a [group by ... having] over the bare
   [entries] table, returned as [`Group_by]. The flat group-by streams off the
   index order; a subquery form made SQLite walk all of [entries]. *)
let driver_select ~version (term : Search.Term.t) =
  if term.min_count > 1
  then (
    let where, bind = criterion_where ~version term.criterion ~alias:"e" in
    `Group_by (where, bind, Sqlite3.Data.INT (Int64.of_int term.min_count)))
  else (
    match term.criterion with
    | Search.Criterion.Props { base_type; props; position } ->
      (match
         props_seek ~base_type ~props ~position ~entries_alias:"e" ~props_alias:"p0"
       with
       | Some (from_, where, bind) -> `Props_seek (from_, "p0", where, bind)
       | None ->
         let where, bind = criterion_where ~version term.criterion ~alias:"e" in
         `Where (where, bind))
    | criterion ->
      let where, bind = criterion_where ~version criterion ~alias:"e" in
      `Where (where, bind))
;;

(* Non-driver terms constrain [e.seed] against a second aliased row. Correct
   under both [where] and [group by] driver shapes.

   For [min_count <= 1] the shape is an *uncorrelated* [in (select ...)]. Any
   correlation makes SQLite re-run the inner select per candidate seed, which
   for [Name_like] means an fts5 dictionary scan per seed. Both decorrelations
   are needed and neither is sufficient: seed only, 26.3s; version only, 105s;
   both, 0.14s (`bear` + `hat`, 1.3M, 2026-09-09).

   The inner keyset bound is redundant against the outer [e.seed > ?], but it
   caps what gets materialised -- a term matching most of the build as a
   non-driver materialises 1.13M seeds without it (4.7s vs 1.1s; [artefact],
   since removed).

   [entries.seed] is not null, so [in] and [exists] agree; that is a
   precondition of the rewrite, not an incidental property. *)
let correlated_select (term : Search.Term.t) ~alias ~version ~after =
  if term.min_count <= 1
  then (
    let from_, version_alias, where, bind =
      match term.criterion with
      | Search.Criterion.Props { base_type; props; position } ->
        let props_alias = alias ^ "p" in
        (match
           props_seek ~base_type ~props ~position ~entries_alias:alias ~props_alias
         with
         | Some (from_, where, bind) -> from_, props_alias, where, bind
         | None ->
           let where, bind = criterion_where ~version term.criterion ~alias in
           sprintf "entries %s" alias, alias, where, bind)
      | criterion ->
        let where, bind = criterion_where ~version criterion ~alias in
        sprintf "entries %s" alias, alias, where, bind
    in
    ( sprintf
        "e.seed in (select %s.seed from %s where %s.version_id = %s and %s and %s.seed > \
         ?)"
        alias
        from_
        version_alias
        version_id_sql
        where
        alias
    , (version_bind version :: bind) @ [ Sqlite3.Data.TEXT after ] ))
  else (
    let where, bind = criterion_where ~version term.criterion ~alias in
    ( sprintf
        "(select sum(coalesce(%s.quantity, 1)) from entries %s where %s.version_id = \
         e.version_id and %s and %s.seed = e.seed) >= ?"
        alias
        alias
        alias
        where
        alias
    , bind @ [ Sqlite3.Data.INT (Int64.of_int term.min_count) ] ))
;;

(* A submitted seed the search store has not taken in yet. Both search paths
   hide these -- the store by their absence, SQL by this filter -- so they agree
   until a rebuild absorbs them. The filter is added only when the set is
   non-empty, so with nothing pending the SQL is exactly what it was. *)
let pending_exists_sql =
  sprintf
    {|
select exists (select 1 from seed_fills where version_id = %s and origin = 'submit' and indexed_at is null)
|}
    version_id_sql
;;

let has_pending t ~version =
  with_stmt
    t
    pending_exists_sql
    ~bind:[ version_bind version ]
    ~f:(fun stmt ->
      fold_rows stmt ~init:false ~f:(fun _ row ->
        Ok (Option.value_map (column_int row 0) ~default:false ~f:(fun n -> n <> 0))))
;;

let pending_filter ~hide ~version ~alias =
  if hide
  then
    ( sprintf
        " and %s not in (select seed from seed_fills where version_id = %s and origin = \
         'submit' and indexed_at is null)"
        alias
        version_id_sql
    , [ version_bind version ] )
  else "", []
;;

(* The matched seeds, before evidence. Terms are flattened into one query: one
   term (the coarse-rare-first pick, see [driver_rank]) drives a seek on
   [entries e], and every other term becomes a correlated [exists] (or, for
   [min_count > 1], a scalar-sum comparison) against a second aliased row.

   The old shape used [intersect] of per-term [distinct] subqueries wrapped in
   an outer [order by ... limit]. SQLite materialised each arm in a temp b-tree
   and then materialised the merged result before applying the limit. Flattening
   removes both: the driver's index returns seeds in order, [exists] and the
   scalar subquery are correlated seeks per candidate seed, and [distinct] on
   the flattened select is served directly off the index order. Measured 1-4ms
   per query at 1.3M against 1.4-3.5s for the old shape (2026-09-05, prod).

   [distinct] prevents a seed with several matching entries from appearing
   multiple times and shrinking the keyset page; see "dedup" in
   test/test_search.ml.

   An empty search degenerates to the flattened seed-listing keyset. *)
let search_seeds_sql (search : Search.t) ~hide =
  let indexed, unindexed = Search.partition_terms search in
  let terms = indexed @ unindexed in
  match terms with
  | [] ->
    let hidden, hidden_bind =
      pending_filter ~hide ~version:search.version ~alias:"seed"
    in
    ( sprintf
        "select distinct seed from seed_levels where version_id = %s and seed > ?%s \
         order by seed limit ?"
        version_id_sql
        hidden
    , [ version_bind search.version
      ; Sqlite3.Data.TEXT (Option.value search.page.after ~default:"")
      ]
      @ hidden_bind
      @ [ Sqlite3.Data.INT (Int64.of_int (search.page.limit + 1)) ] )
  | terms ->
    (* Stable sort: within a driver_rank class, caller's order survives. *)
    let driver, rest =
      match
        List.mapi terms ~f:(fun i term -> i, term)
        |> List.sort ~compare:(fun (i1, t1) (i2, t2) ->
          match
            Tuple2.compare
              ~cmp1:Int.compare
              ~cmp2:Int.compare
              (driver_rank t1)
              (driver_rank t2)
          with
          | 0 -> Int.compare i1 i2
          | c -> c)
      with
      | [] -> assert false
      | (_, driver) :: rest -> driver, List.map rest ~f:snd
    in
    let after = Option.value search.page.after ~default:"" in
    let rest_selects =
      List.mapi rest ~f:(fun i term ->
        correlated_select term ~alias:(sprintf "a%d" i) ~version:search.version ~after)
    in
    let rest_wheres, rest_binds = List.unzip rest_selects in
    let version_bind = version_bind search.version in
    let after_bind = Sqlite3.Data.TEXT after in
    let limit_bind = Sqlite3.Data.INT (Int64.of_int (search.page.limit + 1)) in
    let hidden, hidden_bind =
      pending_filter ~hide ~version:search.version ~alias:"e.seed"
    in
    (match driver_select ~version:search.version driver with
     | `Where (driver_where, driver_bind) ->
       let where_clauses = driver_where :: rest_wheres in
       let sql =
         sprintf
           "select distinct e.seed from entries e where e.version_id = %s and e.seed > ? \
            and %s%s order by e.seed limit ?"
           version_id_sql
           (String.concat where_clauses ~sep:" and ")
           hidden
       in
       ( sql
       , (version_bind :: after_bind :: driver_bind)
         @ List.concat rest_binds
         @ hidden_bind
         @ [ limit_bind ] )
     | `Group_by (driver_where, driver_bind, min_count_bind) ->
       (* [group by seed] yields one row per seed; no outer [distinct] needed.
          Correlated predicates compose into [where]; [having] evaluates after
          grouping. [min_count_bind] comes after rest placeholders in the SQL. *)
       let where_clauses = driver_where :: rest_wheres in
       let sql =
         sprintf
           "select seed from entries e where e.version_id = %s and e.seed > ? and %s%s \
            group by e.seed having sum(coalesce(e.quantity, 1)) >= ? order by e.seed \
            limit ?"
           version_id_sql
           (String.concat where_clauses ~sep:" and ")
           hidden
       in
       ( sql
       , (version_bind :: after_bind :: driver_bind)
         @ List.concat rest_binds
         @ hidden_bind
         @ [ min_count_bind; limit_bind ] )
     | `Props_seek (from_, props_alias, driver_where, driver_bind) ->
       let where_clauses = driver_where :: rest_wheres in
       let sql =
         sprintf
           "select distinct e.seed from %s where %s.version_id = %s and e.seed > ? and \
            %s%s order by e.seed limit ?"
           from_
           props_alias
           version_id_sql
           (String.concat where_clauses ~sep:" and ")
           hidden
       in
       ( sql
       , (version_bind :: after_bind :: driver_bind)
         @ List.concat rest_binds
         @ hidden_bind
         @ [ limit_bind ] ))
;;

(* Evidence for one term over matched seeds. Fetched per term, not joined: a
   join across N terms multiplies rows. One row per matching entry; grouping
   happens in OCaml (bounded by page size). *)
let term_hits_columns =
  Columns.of_list
    [ "e.seed"
    ; "s_level.val as level"
    ; "e.cat"
    ; "s_name.val as name"
    ; "s_base_type.val as base_type"
    ; "s_sub_type.val as sub_type"
    ; "e.quantity"
    ; "e.artefact"
    ; "e.plus"
    ; "s_ego.val as ego"
    ; "s_feat.val as feat"
    ; "s_shop_type.val as shop_type"
    ]
;;

module Term_hit_col = struct
  let at = Columns.at term_hits_columns
  let seed = at "seed"
  let level = at "level"
  let cat = at "cat"
  let name = at "name"
  let base_type = at "base_type"
  let sub_type = at "sub_type"
  let quantity = at "quantity"
  let artefact = at "artefact"
  let plus = at "plus"
  let ego = at "ego"
  let feat = at "feat"
  let shop_type = at "shop_type"
end

let term_hits_sql (term : Search.Term.t) ~version ~seed_count =
  let where, bind = criterion_where ~version term.criterion ~alias:"e" in
  let placeholders = List.init seed_count ~f:(fun _ -> "?") |> String.concat ~sep:", " in
  ( sprintf
      {|
%s
    from entries e
    join strings s_level
      on s_level.id = e.level_id
    left join strings s_name
      on s_name.id = e.name_id
    left join strings s_base_type
      on s_base_type.id = e.base_type_id
    left join strings s_sub_type
      on s_sub_type.id = e.sub_type_id
    left join strings s_ego
      on s_ego.id = e.ego_id
    left join strings s_feat
      on s_feat.id = e.feat_id
    left join strings s_shop_type
      on s_shop_type.id = e.shop_type_id
   where e.version_id = %s
     and %s
     and e.seed in (%s)
|}
      (Columns.render term_hits_columns ~lead:"  select " ~sep:"       ")
      version_id_sql
      (String.substr_replace_all where ~pattern:"entries." ~with_:"e.")
      placeholders
  , bind )
;;

let seeds_of_stmt stmt =
  fold_rows stmt ~init:[] ~f:(fun acc row ->
    let%map.Or_error seed = required row 0 ~field:"seed" in
    seed :: acc)
  |> Or_error.map ~f:List.rev
;;

(* Fallback label when no row supplied a name. *)
let term_label (term : Search.Term.t) = Search.Criterion.to_string term.criterion

(* Rebuilds a matching entry's name: stored name if present, [Display_name]
   otherwise. *)
let term_hit_name row ~term =
  match column_text row Term_hit_col.name with
  | Some name -> name
  | None ->
    let entry =
      { Record.Entry.cat =
          (match column_int row Term_hit_col.cat with
           | Some i -> Option.value (Record.Cat.of_int i) ~default:Record.Cat.Items
           | None -> Record.Cat.Items)
      ; name = ""
      ; base_type = column_text row Term_hit_col.base_type
      ; sub_type = column_text row Term_hit_col.sub_type
      ; quantity = column_int row Term_hit_col.quantity
      ; artefact = column_bool row Term_hit_col.artefact
      ; branded = None
      ; plus = column_int row Term_hit_col.plus
      ; cost = None
      ; ego = column_text row Term_hit_col.ego
      ; feat = column_text row Term_hit_col.feat
      ; timeout_turns = None
      ; unique_mons = None
      ; native = None
      ; type_name = None
      ; x = None
      ; y = None
      ; carried_by = None
      ; shop_type = column_text row Term_hit_col.shop_type
      ; toll_note = None
      ; spells = []
      ; props = []
      }
    in
    (match Display_name.of_entry entry with
     | Display_name.Derived name -> name
     | Display_name.Irreducible -> term_label term)
;;

(* Grouped by seed, not by level or name.

   A term satisfied across three levels is one fact about the seed; reporting
   only the shallowest level's share understates why it matched.

   Crawl renders a stack with a pluralised name ("2 potions of haste"), so a
   single sub_type reaches the corpus under several names; grouping by name
   would split one term's evidence.

   The shallowest contributing name is the label, and [distinct] says how many
   names the total spans -- a term matching unrelated items cannot attribute
   its total to that one label. *)
let group_term_hits rows ~term =
  let totals = String.Table.create () in
  let names = String.Table.create () in
  let shallowest = String.Table.create () in
  List.iter rows ~f:(fun (seed, level, name, quantity) ->
    Hashtbl.update totals seed ~f:(function
      | None -> quantity
      | Some existing -> existing + quantity);
    Hashtbl.update names seed ~f:(function
      | None -> String.Set.singleton name
      | Some seen -> Set.add seen name);
    let depth = Depth.of_level level in
    Hashtbl.update shallowest seed ~f:(function
      | Some existing when Tuple3.get1 existing <= depth -> existing
      | _ -> depth, level, name));
  Hashtbl.fold totals ~init:[] ~f:(fun ~key:seed ~data:count acc ->
    let level, name =
      match Hashtbl.find shallowest seed with
      | Some (_, level, name) -> level, name
      | None -> "", term_label term
    in
    let distinct = Hashtbl.find names seed |> Option.value_map ~default:1 ~f:Set.length in
    (seed, { Search.Match.term; level; name; count; distinct }) :: acc)
  |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b)
;;

let term_hits t ~version ~(term : Search.Term.t) ~seeds =
  if List.is_empty seeds
  then Ok []
  else (
    let sql, bind = term_hits_sql term ~version ~seed_count:(List.length seeds) in
    with_stmt
      t
      sql
      ~bind:
        ((version_bind version :: bind)
         @ List.map seeds ~f:(fun seed -> Sqlite3.Data.TEXT seed))
      ~f:(fun stmt ->
        let%bind.Or_error () = Columns.check_header term_hits_columns stmt in
        fold_rows stmt ~init:[] ~f:(fun acc row ->
          let open Or_error.Let_syntax in
          let%bind seed = required row Term_hit_col.seed ~field:"seed" in
          let%map level = required row Term_hit_col.level ~field:"level" in
          let name = term_hit_name row ~term in
          let quantity = Option.value (column_int row Term_hit_col.quantity) ~default:1 in
          (seed, level, name, quantity) :: acc)
        |> Or_error.map ~f:(fun rows -> group_term_hits (List.rev rows) ~term)))
;;

(* [search_seeds_sql]'s driver shape restricted to a known seed list, one
   statement per term. Empty [terms] passes every seed: the store answered all
   of them exactly and left nothing to re-check. *)
let verify_terms t ~version ~seeds ~terms =
  match terms, seeds with
  | [], _ -> Ok (String.Set.of_list seeds)
  | _, [] -> Ok String.Set.empty
  | terms, seeds ->
    let placeholders = List.map seeds ~f:(fun _ -> "?") |> String.concat ~sep:", " in
    let seed_bind = List.map seeds ~f:(fun seed -> Sqlite3.Data.TEXT seed) in
    List.fold_result
      terms
      ~init:(String.Set.of_list seeds)
      ~f:(fun acc (term : Search.Term.t) ->
        let where, bind = criterion_where ~version term.criterion ~alias:"e" in
        let select, group, count_bind =
          if term.min_count <= 1
          then "select distinct e.seed", "", []
          else
            ( "select e.seed"
            , " group by e.seed having sum(coalesce(e.quantity, 1)) >= ?"
            , [ Sqlite3.Data.INT (Int64.of_int term.min_count) ] )
        in
        let sql =
          sprintf
            "%s from entries e where e.version_id = %s and %s and e.seed in (%s)%s"
            select
            version_id_sql
            where
            placeholders
            group
        in
        let%map.Or_error matched =
          with_stmt
            t
            sql
            ~bind:((version_bind version :: bind) @ seed_bind @ count_bind)
            ~f:seeds_of_stmt
        in
        Set.inter acc (String.Set.of_list matched))
;;

(* Which of [seeds] satisfy every term, and the shallowest depth each does it
   at. Two callers, both needing the same same-item depth [verify_terms] alone
   cannot give: the deep-cohort overlay ([Search_index.resolve_overlay]) and
   [Search_index.ranked_page]'s narrowing-term batches, which is why this
   returns depth where [seed_page]'s cheaper [verify_terms] does not -- that
   path is bounded by page size and never needs one.

   Depth comes from the level *name* through [Depth.of_level], which SQLite
   cannot call -- the same reason the builder populates a temp [level_depth]
   table rather than taking [min(level_id)]. Min over terms is min over the
   union of their evidence, which is the fold [Search_index.candidate_depth]
   does over postings and [Search.rank_matches] does over hits.

   [min_count] is deliberately not applied here: a posting's depth is the
   shallowest level the criterion appears on regardless of how many it takes to
   meet the threshold, and the survivors have already been filtered on count by
   [verify_terms].

   Batched because both stages build an [in] list one placeholder per seed. At
   ~20 deepens a day an unbatched list passes SQLITE_MAX_VARIABLE_NUMBER
   eventually, and passes the point where the planner still likes it well before
   that. *)
let overlay_batch = 500

let cohort_depths_sql term ~version ~seed_count =
  let where, bind = criterion_where ~version term.Search.Term.criterion ~alias:"e" in
  let placeholders = List.init seed_count ~f:(fun _ -> "?") |> String.concat ~sep:", " in
  ( sprintf
      {|
  select distinct e.seed
       , s_level.val
    from entries e
    join strings s_level
      on s_level.id = e.level_id
   where e.version_id = %s
     and %s
     and e.seed in (%s)
|}
      version_id_sql
      where
      placeholders
  , bind )
;;

let verify_terms_with_depth t ~version ~seeds ~terms =
  let open Or_error.Let_syntax in
  List.chunks_of seeds ~length:overlay_batch
  |> List.map ~f:(fun seeds ->
    let%bind survived = verify_terms t ~version ~seeds ~terms in
    match List.filter seeds ~f:(Set.mem survived) with
    | [] -> Ok []
    | seeds ->
      let seed_bind = List.map seeds ~f:(fun seed -> Sqlite3.Data.TEXT seed) in
      let%map depths =
        List.fold_result terms ~init:String.Map.empty ~f:(fun acc term ->
          let sql, bind =
            cohort_depths_sql term ~version ~seed_count:(List.length seeds)
          in
          with_stmt
            t
            sql
            ~bind:((version_bind version :: bind) @ seed_bind)
            ~f:(fun stmt ->
              fold_rows stmt ~init:acc ~f:(fun acc row ->
                let open Or_error.Let_syntax in
                let%bind seed = required row 0 ~field:"seed" in
                let%map level = required row 1 ~field:"level" in
                let depth = Depth.of_level level in
                Map.update acc seed ~f:(function
                  | None -> depth
                  | Some existing -> Int.min existing depth))))
      in
      List.map seeds ~f:(fun seed ->
        seed, Option.value (Map.find depths seed) ~default:Depth.unknown))
  |> Or_error.all
  |> Or_error.map ~f:List.concat
;;

let cohort_matches t ~version ~seeds ~terms =
  verify_terms_with_depth t ~version ~seeds ~terms
;;

(* The search's [group by e.seed] over the same predicate, without the
   [having]. A bare [Props] seeks through [props_seek] for the reason
   [driver_select] does; a seed list seeks [entries_seed] instead, as
   [verify_terms] does. *)
let count_ceiling_sql criterion ~version ~seeds ~hide =
  let from_, version_alias, where, bind =
    match (criterion : Search.Criterion.t), seeds with
    | Search.Criterion.Props { base_type; props; position }, None ->
      (match
         props_seek ~base_type ~props ~position ~entries_alias:"e" ~props_alias:"p0"
       with
       | Some (from_, where, bind) -> from_, "p0", where, bind
       | None ->
         let where, bind = criterion_where ~version criterion ~alias:"e" in
         "entries e", "e", where, bind)
    | criterion, _ ->
      let where, bind = criterion_where ~version criterion ~alias:"e" in
      "entries e", "e", where, bind
  in
  let seed_where, seed_bind =
    match seeds with
    | None -> pending_filter ~hide ~version ~alias:"e.seed"
    | Some seeds ->
      ( sprintf
          " and e.seed in (%s)"
          (List.map seeds ~f:(fun _ -> "?") |> String.concat ~sep:", ")
      , List.map seeds ~f:(fun seed -> Sqlite3.Data.TEXT seed) )
  in
  ( sprintf
      "select max(n) from (select sum(coalesce(e.quantity, 1)) as n from %s where \
       %s.version_id = %s and %s%s group by e.seed)"
      from_
      version_alias
      version_id_sql
      where
      seed_where
  , (version_bind version :: bind) @ seed_bind )
;;

let count_ceiling_of ?(hide = false) t criterion ~version ~seeds =
  let sql, bind = count_ceiling_sql criterion ~version ~seeds ~hide in
  with_stmt t sql ~bind ~f:(fun stmt ->
    fold_rows stmt ~init:None ~f:(fun _ row -> Ok (column_int row 0)))
;;

let cohort_ceiling t criterion ~version ~seeds =
  List.chunks_of seeds ~length:overlay_batch
  |> List.fold_result ~init:None ~f:(fun acc seeds ->
    let%map.Or_error n = count_ceiling_of t criterion ~version ~seeds:(Some seeds) in
    Option.merge acc n ~f:Int.max)
;;

(* A term's evidence may sit on several levels; the shallowest is the one worth
   reporting, since "how early" is the question a depth filter is asking. *)
let shallowest_hit hits =
  List.min_elt hits ~compare:(fun (a : Search.Match.hit) b ->
    Int.compare (Depth.of_level a.level) (Depth.of_level b.level))
;;

(* The level names actually present for a build, which is what a depth filter
   enumerates over. Read once per search rather than hardcoded: the vocabulary
   depends on the depth the corpus was extracted at, and a level nobody
   generated should not appear in a filter. *)
let levels_sql =
  sprintf
    {|
  select distinct s_level.val
    from seed_levels sl
    join strings s_level
      on s_level.id = sl.level_id
   where sl.version_id = %s
order by s_level.val
|}
    version_id_sql
;;

let version_levels t ~version =
  with_stmt t levels_sql ~bind:[ version_bind version ] ~f:seeds_of_stmt
;;

(* The distinct item type pairs a build's entries carry, for the search form's
   datalist. A covering seek over [entries_search_type] plus a temp b-tree for
   the distinct, over every entry of the build -- so it is *minutes*, not
   seconds, and must be cached per process by the caller rather than run per
   request. Measured 71.5s here, plus 3.8s for [feat_names_sql] (1.3M, 0.34.1,
   D:8, 2026-09-07, prod, warm, zfs 16K/lz4), against 10.5 KB of output. That is
   a ~75s cold start paid by whichever reader arrives first after a restart,
   growing linearly with the corpus. Superseded: ~~126s and 13.5s~~ at zfs
   64K/zstd, where most of the difference was record amplification rather than
   this query -- the cost is now 51s user against 20s sys, so what remains is
   the temp b-tree, not storage. The fallback for [Search_index.item_pairs],
   which answers from the store's catalog whenever the store is current. *)
let item_pairs_sql =
  sprintf
    {|
  select b.val || ':' || s.val
    from entries e
    join strings b
      on b.id = e.base_type_id
    join strings s
      on s.id = e.sub_type_id
   where e.version_id = %s
     and e.sub_type_id is not null
group by 1
order by 1
|}
    version_id_sql
;;

(* The property vocabulary, as the tokens a term uses. Cheap where
   [item_pairs_sql] is not: [entry_props] is two orders of magnitude smaller
   than [entries] (57,872 rows against 1,027,801 at 10k), so this is 0.11s
   against 71.5s and adds nothing meaningful to the cold start it shares. *)
let prop_names_sql =
  sprintf
    {|
  select s.val
    from entry_props p
    join strings s
      on s.id = p.prop_id
   where p.version_id = %s
     and p.value >= %d
group by 1
order by 1
|}
    version_id_sql
    Search.Prop.min_value
;;

(* Codes alone, not (base type, code): jewellery shares rF+, Reflect and others
   with armour, but the per-base form leaves the covering index and was 4m13s
   against 2.5s for this (1.3M, 0.34.1, prod, 2026-10-02). Only a stale store
   reaches it, and armour holds every code jewellery shares. *)
let ego_codes_sql =
  sprintf
    {|
  select distinct g.val
    from entries e
    join strings g
      on g.id = e.ego_id
   where e.version_id = %s
     and e.ego_id is not null
|}
    version_id_sql
;;

let brand_options ~version ~held =
  List.concat_map Search.Brand.base_types ~f:(fun base_type ->
    Search.Brand.words ~base_type
    |> List.filter ~f:(fun word ->
      Option.is_none (Search.Brand.why_excluded ~base_type word)
      && Option.exists (Search.Brand.code ~base_type ~version word) ~f:(fun code ->
        held ~base_type code))
    |> List.map ~f:(sprintf "%s ego:%s" base_type))
;;

let distinct_criteria t ~version =
  let%bind.Or_error pairs =
    match%bind.Or_error Search_index.item_pairs t ~version with
    | Some pairs -> Ok pairs
    | None -> with_stmt t item_pairs_sql ~bind:[ version_bind version ] ~f:seeds_of_stmt
  in
  let%bind.Or_error props =
    with_stmt t prop_names_sql ~bind:[ version_bind version ] ~f:seeds_of_stmt
  in
  let%map.Or_error held =
    match%bind.Or_error Search_index.catalog_brands t ~version with
    | Some brands ->
      Ok
        (fun ~base_type code ->
          List.mem brands (base_type, code) ~equal:[%equal: string * string])
    | None ->
      let%map.Or_error codes =
        with_stmt t ego_codes_sql ~bind:[ version_bind version ] ~f:seeds_of_stmt
      in
      fun ~base_type:_ code -> List.mem codes code ~equal:String.equal
  in
  (* Filtered here rather than in SQL: the exclusion is a judgement about the
     game, and [Search.Prop] is where that judgement lives. *)
  pairs
  @ (List.filter props ~f:Search.Prop.searchable |> List.map ~f:(sprintf "props:%s"))
  @ brand_options ~version ~held
;;

(* The distinct (portal, parent) pairs a version holds, which is what a depth
   cap needs to know which portals sit too deep. Distinct rather than per-seed:
   there are only as many pairs as portal types times D-levels, so this is a few
   dozen rows regardless of corpus size. *)
let parents_sql =
  sprintf
    {|
  select distinct s_level.val
       , s_parent.val
    from seed_levels sl
    join strings s_level
      on s_level.id = sl.level_id
    join strings s_parent
      on s_parent.id = sl.parent_level_id
   where sl.version_id = %s
     and sl.parent_level_id is not null
order by s_level.val
       , s_parent.val
|}
    version_id_sql
;;

let version_parents t ~version =
  with_stmt
    t
    parents_sql
    ~bind:[ version_bind version ]
    ~f:(fun stmt ->
      fold_rows stmt ~init:[] ~f:(fun acc row ->
        let open Or_error.Let_syntax in
        let%bind level = required row 0 ~field:"level" in
        let%map parent = required row 1 ~field:"parent_level" in
        (level, parent) :: acc)
      |> Or_error.map ~f:List.rev)
;;

(* Whether the trigram index covers every name in the dictionary.

   Compared per search, not once at startup: a fill can land while the server is
   up, and a startup-only answer would go stale mid-process -- the exact failure
   this defends against. Two integer scalars, one off a one-row table and one
   off the `strings` primary key, so it is cheap enough to pay per `name~`
   search, and `name~` is a small fraction of searches.

   Any error or missing row reads as "not current": failing that way refuses a
   search that could have been served, while failing the other way serves wrong
   answers from an index that does not cover the corpus. A corpus predating the
   index has no strings_fts_state row and lands here. *)
let fts_is_current t =
  let sql =
    "select (select built_through from strings_fts_state where id = 1) >= \
     coalesce((select max(id) from strings), 0)"
  in
  match
    with_stmt t sql ~bind:[] ~f:(fun stmt ->
      fold_rows stmt ~init:false ~f:(fun _ row ->
        Ok (Option.value (column_bool row 0) ~default:false)))
  with
  | Ok current -> current
  | Error _ -> false
;;

(* Index only what the mark does not yet cover, and move the mark to match.

   The rebuild's contract is that `strings` is append-only, and this leans on it
   harder: rows at or below the mark are never revisited, so a rewritten row
   would stay stale behind a mark that reads as current. `insert or ignore` is
   the only writer and never rewrites, so the property holds.

   Both statements go in one transaction because the mark is a claim about the
   index. Committing the mark without the rows indexed is the silent false
   negative the mechanism exists to prevent; the reverse costs a re-index of
   rows already covered, which is why the mark is read once, inside the
   transaction, rather than passed in.

   No `analyze` here, unlike the full rebuild: this runs per deepened seed, and
   a whole-database pass at that cadence costs more than the planner gains from
   a dictionary that grew by a few rows. *)
let catch_up_fts t =
  match
    with_immediate_txn t ~f:(fun t ->
      exec_script
        t
        "insert into strings_fts (rowid, val) select s.id, s.val from strings s where \
         s.id > coalesce((select built_through from strings_fts_state where id = 1), 0)";
      exec_script
        t
        "insert into strings_fts_state (id, built_through) values (1, coalesce((select \
         max(id) from strings), 0)) on conflict (id) do update set built_through = \
         excluded.built_through")
  with
  | exception exn -> Or_error.of_exn exn
  | () -> Ok ()
;;

(* Rebuild the trigram index and record how far it reached, in one transaction.

   The high-water mark must be taken *before* the rebuild and committed with it:
   taken after, a name inserted while the rebuild ran would be recorded as
   covered without being indexed, which is the silent false negative this whole
   mechanism exists to prevent. Recording an id lower than the index actually
   reached is the safe direction -- it costs a fallback, not a wrong answer.

   `analyze` is part of the procedure, not a separate step someone remembers:
   a new index the planner has no stats for has twice cost this corpus a 100x
   regression (see the unique:Sigmund note in schema.sql). *)
let rebuild_fts t =
  match
    with_immediate_txn t ~f:(fun t ->
      exec_script
        t
        "insert into strings_fts_state (id, built_through) values (1, coalesce((select \
         max(id) from strings), 0)) on conflict (id) do update set built_through = \
         excluded.built_through";
      exec_script t "insert into strings_fts (strings_fts) values ('rebuild')")
  with
  | exception exn -> Or_error.of_exn exn
  | () ->
    (* Outside the transaction: `analyze` is a whole-database pass and rolling
       it back with a failed rebuild would gain nothing. Stale statistics make
       the planner mis-size the new index, which is slow, not wrong. *)
    (match exec_script t "analyze" with
     | exception exn -> Or_error.of_exn exn
     | () -> Ok ())
;;

(* Only a name substring needs the index; every other criterion is a seek that a
   rebuild does not touch, so the refusal is scoped to searches that actually
   depend on it. Both search paths share it: a [name~] term reaches the trigram
   index through [verify_terms] too. *)
let refuse_stale_trigram t (search : Search.t) =
  if
    List.exists search.terms ~f:(fun term ->
      match term.criterion with
      (* Both positions. What goes stale is the dictionary lookup that turns a
         fragment into name ids; where the matching items sit is decided
         afterwards and cannot rescue it. *)
      | Search.Criterion.Name_like (_, _) -> true
      (* [Props] resolves property names through [strings] by primary key, not
         through the trigram index, so a rebuild cannot stale it. *)
      | Search.Criterion.Props _
      | Search.Criterion.Brand _
      | Search.Criterion.Item _
      | Search.Criterion.Feature _
      | Search.Criterion.Unique _ -> false)
    && not (fts_is_current t)
  then
    Or_error.errorf
      "%s: the name substring index is being rebuilt; searching by name is unavailable \
       until it finishes"
      Search.stale_index_tag
  else Ok ()
;;

let matches_of_seeds t (search : Search.t) seeds =
  let%map.Or_error hits_by_term =
    List.map search.terms ~f:(fun term ->
      term_hits t ~version:search.version ~term ~seeds)
    |> Or_error.all
  in
  let by_seed = String.Table.create () in
  List.iter hits_by_term ~f:(fun hits ->
    (* One hit per term per seed (the shallowest), so a seed with a Trog altar
       on four levels reports one line. *)
    List.map hits ~f:(fun (seed, hit) -> seed, hit)
    |> String.Table.of_alist_multi
    |> Hashtbl.iteri ~f:(fun ~key:seed ~data:hits ->
      match shallowest_hit hits with
      | None -> ()
      | Some hit -> Hashtbl.add_multi by_seed ~key:seed ~data:hit));
  List.map seeds ~f:(fun seed ->
    { Search.Match.seed
    ; hits = Hashtbl.find by_seed seed |> Option.value ~default:[] |> List.rev
    })
;;

let search_seeds_unranked t (search : Search.t) ~hide =
  let open Or_error.Let_syntax in
  let sql, bind = search_seeds_sql search ~hide in
  let%bind seeds = with_stmt t sql ~bind ~f:seeds_of_stmt in
  let seeds, more =
    match List.split_n seeds search.page.limit with
    | page, [] -> page, `End
    | page, _ -> page, `More
  in
  let%map matches = matches_of_seeds t search seeds in
  matches, more
;;

(* Shallowest ranking cannot page by keyset: the order is not the corpus's own,
   so the whole matched set must be fetched before any page is correct.
   [Rank.sort_limit] bounds that; a search matching more than the cap is
   refused rather than answered with a page-local order.

   The cursor is an offset into the ranked order, not a seed. *)
let search_seeds_ranked t (search : Search.t) ~rank ~hide =
  let open Or_error.Let_syntax in
  let whole =
    { search with page = { Query.Page.after = None; limit = Search.Rank.sort_limit + 1 } }
  in
  let%bind matches, _ = search_seeds_unranked t whole ~hide in
  if List.length matches > Search.Rank.sort_limit
  then
    Or_error.errorf
      "%s: too many seeds to rank by %s (over %d); narrow the search, or rank by seed"
      Search.Rank.too_broad_tag
      (Search.Rank.to_string rank)
      Search.Rank.sort_limit
  else (
    let ranked = Search.rank_matches matches ~rank ~depth_of_level:Depth.of_level in
    let after =
      match search.page.after with
      | None -> 0
      | Some cursor -> Option.value (Int.of_string_opt cursor) ~default:0
    in
    match List.split_n (List.drop ranked after) search.page.limit with
    | page, [] -> Ok (page, `End)
    | page, _ -> Ok (page, `More))
;;

let search_index_is_current t ~version = Search_index.is_current t ~version
let build_search_index t ~version = Search_index.build t ~version
let catalog_item_pairs t ~version = Search_index.catalog_item_pairs t ~version
let search_index_cohort t ~version = Search_index.cohort t ~version

let search_index_stats_sql =
  sprintf
    {|
  select (select count(*) from seed_ordinals where version_id = %s)
       , (select count(*) from search_criteria where version_id = %s)
       , (select count(*)
            from search_postings sp
            join search_criteria sc
              on sc.id = sp.criterion_id
           where sc.version_id = %s)
       , (select coalesce(sum(sp.n), 0)
            from search_postings sp
            join search_criteria sc
              on sc.id = sp.criterion_id
           where sc.version_id = %s)
       , (select coalesce(sum(length(sp.postings)), 0)
            from search_postings sp
            join search_criteria sc
              on sc.id = sp.criterion_id
           where sc.version_id = %s)
|}
    version_id_sql
    version_id_sql
    version_id_sql
    version_id_sql
    version_id_sql
;;

let search_index_stats t ~version =
  with_stmt
    t
    search_index_stats_sql
    ~bind:(List.init 5 ~f:(fun _ -> version_bind version))
    ~f:(fun stmt ->
      fold_rows stmt ~init:Search_index.Stats.zero ~f:(fun _ row ->
        let at i = Option.value (column_int row i) ~default:0 in
        Ok
          { Search_index.Stats.seeds = at 0
          ; criteria = at 1
          ; blocks = at 2
          ; postings = at 3
          ; bytes = at 4
          }))
;;

let sql_path t (search : Search.t) ~rank =
  let%bind.Or_error hide = has_pending t ~version:search.version in
  if Search.Rank.equal rank Search.Rank.Seed
  then search_seeds_unranked t search ~hide
  else search_seeds_ranked t search ~rank ~hide
;;

let search_seeds_sql t (search : Search.t) ~rank =
  with_txn t ~f:(fun t ->
    let open Or_error.Let_syntax in
    let%bind () = refuse_stale_trigram t search in
    sql_path t search ~rank)
;;

(* The store resolves [name~] through SQL, and a pending seed has no ordinal to
   resolve to, so it is filtered there rather than read as a reason to
   decline. *)
let store_path ?name_cap t (search : Search.t) ~rank =
  let open Or_error.Let_syntax in
  let%bind hide = has_pending t ~version:search.version in
  let criterion_where criterion ~alias =
    let where, bind = criterion_where ~version:search.version criterion ~alias in
    let hidden, hidden_bind =
      pending_filter ~hide ~version:search.version ~alias:(alias ^ ".seed")
    in
    where ^ hidden, bind @ hidden_bind
  in
  (* A current store that errors is a fault, so that propagates; a decline is
     [None]. *)
  match%bind
    Search_index.page
      ?name_cap
      t
      search
      ~rank
      ~criterion_where
      ~verify:(verify_terms t ~version:search.version)
      ~verify_depth:(verify_terms_with_depth t ~version:search.version)
      ~cohort_matches:(cohort_matches t ~version:search.version)
  with
  (* One page of a global order: ranking it again would sort a page against
     itself. *)
  | Some (seeds, more) ->
    let%map matches = matches_of_seeds t search seeds in
    Some (matches, more)
  | None -> Ok None
;;

let search_seeds_store ?name_cap t (search : Search.t) ~rank =
  with_txn t ~f:(fun t ->
    let open Or_error.Let_syntax in
    let%bind () = refuse_stale_trigram t search in
    store_path ?name_cap t search ~rank)
;;

(* Multi-statement reads need a transaction: WAL snapshots are per statement,
   so a mid-call commit is half-visible. A stale store falls back where a stale
   trigram index refuses: this fallback is the same semantics more slowly, where
   the trigram index's is a dictionary scan. *)
let search_seeds t (search : Search.t) ~rank =
  with_txn t ~f:(fun t ->
    let open Or_error.Let_syntax in
    let%bind () = refuse_stale_trigram t search in
    match%bind store_path t search ~rank with
    | Some page -> Ok page
    | None -> sql_path t search ~rank)
;;

let ceiling_store_path t ~version criterion =
  Search_index.ceiling
    t
    ~version
    criterion
    ~cohort_ceiling:(cohort_ceiling t criterion ~version)
;;

let count_ceiling_store t ~version criterion =
  with_txn t ~f:(fun t -> ceiling_store_path t ~version criterion)
;;

let count_ceiling_sql t ~version criterion =
  with_txn t ~f:(fun t ->
    let%bind.Or_error hide = has_pending t ~version in
    count_ceiling_of ~hide t criterion ~version ~seeds:None)
;;

let count_ceiling t ~version criterion =
  if not (Search.Criterion.has_count_ceiling criterion)
  then Ok None
  else
    with_txn t ~f:(fun t ->
      match%bind.Or_error ceiling_store_path t ~version criterion with
      | Some ceiling -> Ok ceiling
      | None ->
        let%bind.Or_error hide = has_pending t ~version in
        count_ceiling_of ~hide t criterion ~version ~seeds:None)
;;

(* Deepen queue: web process enqueues, generator claims and runs crawl. *)

let job_of_row row ~version =
  let open Or_error.Let_syntax in
  let%bind seed = required row 0 ~field:"seed" in
  let%bind depth = required row 2 ~field:"depth" in
  let%map origin = required row 8 ~field:"origin" >>= Job.Origin.of_string in
  { Job.seed
  ; version
  ; depth
  ; queued_at = Option.value (column_int row 3) ~default:0
  ; started_at = column_int row 4
  ; finished_at = column_int row 5
  ; attempts = Option.value (column_int row 6) ~default:0
  ; error = column_text row 7
  ; origin
  }
;;

let job_columns =
  {|
  select seed
       , version_id
       , depth
       , queued_at
       , started_at
       , finished_at
       , attempts
       , error
       , origin
    from ingest_jobs
|}
;;

let job_for_seed_sql =
  job_columns
  ^ sprintf
      {|
   where seed = ?
     and version_id = %s
|}
      version_id_sql
;;

let job_for_seed t ~version ~seed =
  with_stmt
    t
    job_for_seed_sql
    ~bind:[ Sqlite3.Data.TEXT seed; version_bind version ]
    ~f:(fun stmt ->
      fold_rows stmt ~init:[] ~f:(fun acc row ->
        let%map.Or_error job = job_of_row row ~version in
        job :: acc)
      |> Or_error.map ~f:List.hd)
;;

(* Jobs ahead of this one in the queue, same version only. Counted by
   (origin, queued_at, seed): deepens first, then age, then seed to break ties. Index-driven over ingest_jobs_pending;
   residual filters on started_at/error are bounded by the outstanding-jobs
   cap. *)
let queue_position_sql =
  sprintf
    {|
  select count(*)
    from ingest_jobs ahead
   where ahead.version_id = %s
     and ahead.started_at is null
     and ahead.finished_at is null
     and ahead.error is null
     and (ahead.origin = 'submit', ahead.queued_at, ahead.seed) < (select mine.origin = 'submit', mine.queued_at, mine.seed
                                                                    from ingest_jobs mine
                                                                   where mine.seed = ?
                                                                     and mine.version_id = %s
                                                                     and mine.started_at is null
                                                                     and mine.finished_at is null
                                                                     and mine.error is null)
|}
    version_id_sql
    version_id_sql
;;

(* [None] for non-queued jobs (running, finished, failed, absent). A 0 would
   read as "next up". *)
let queue_position t ~version ~seed =
  (* Transaction: state check and count must see one snapshot. *)
  with_txn t ~f:(fun t ->
    let open Or_error.Let_syntax in
    let%bind job = job_for_seed t ~version ~seed in
    match job with
    | None -> Ok None
    | Some job when not (Job.State.equal (Job.state job) Job.State.Queued) -> Ok None
    | Some _ ->
      let%map ahead =
        with_stmt
          t
          queue_position_sql
          ~bind:[ version_bind version; Sqlite3.Data.TEXT seed; version_bind version ]
          ~f:(fun stmt ->
            fold_rows stmt ~init:0 ~f:(fun _ row ->
              Ok (Option.value (column_int row 0) ~default:0)))
      in
      Some ahead)
;;

let outstanding_jobs_sql =
  {|
  select count(*)
    from ingest_jobs
   where finished_at is null
     and error is null
     and origin = coalesce(?, origin)
|}
;;

let outstanding_jobs ?origin t =
  with_stmt
    t
    outstanding_jobs_sql
    ~bind:
      [ Option.value_map origin ~default:Sqlite3.Data.NULL ~f:(fun origin ->
          Sqlite3.Data.TEXT (Job.Origin.to_string origin))
      ]
    ~f:(fun stmt ->
      fold_rows stmt ~init:0 ~f:(fun _ row ->
        Ok (Option.value (column_int row 0) ~default:0)))
;;

let submitted_since_sql =
  {|
  select count(*)
    from ingest_jobs
   where origin = 'submit'
     and queued_at >= ?
|}
;;

let submitted_since t ~since =
  with_stmt
    t
    submitted_since_sql
    ~bind:[ Sqlite3.Data.INT (Int64.of_int since) ]
    ~f:(fun stmt ->
      fold_rows stmt ~init:0 ~f:(fun _ row ->
        Ok (Option.value (column_int row 0) ~default:0)))
;;

let servable_versions_sql =
  {|
  select distinct v.version
    from generators g
    join versions v
      on v.id = g.version_id
   where g.heartbeat_at > ?
|}
;;

let servable_versions t ~since =
  with_stmt
    t
    servable_versions_sql
    ~bind:[ Sqlite3.Data.INT (Int64.of_int since) ]
    ~f:(fun stmt ->
      fold_rows stmt ~init:[] ~f:(fun acc row ->
        let%map.Or_error version = required row 0 ~field:"version" in
        version :: acc)
      |> Or_error.map ~f:List.rev)
;;

let populated_versions_sql =
  {|
  select v.version
    from versions v
   where exists (select 1 from seed_fills f where f.version_id = v.id)
|}
;;

let populated_versions t =
  with_stmt t populated_versions_sql ~bind:[] ~f:(fun stmt ->
    fold_rows stmt ~init:[] ~f:(fun acc row ->
      let%map.Or_error version = required row 0 ~field:"version" in
      version :: acc)
    |> Or_error.map ~f:List.rev)
;;

let enqueue_sql =
  sprintf
    {|
insert into ingest_jobs (seed, version_id, origin) values (?, %s, ?) on conflict do nothing
|}
    version_id_sql
;;

let heartbeat_sql =
  sprintf
    {|
insert into generators (generator_id, version_id, heartbeat_at) values (?, %s, ?) on
  conflict (generator_id, version_id) do update set heartbeat_at = excluded.heartbeat_at
|}
    version_id_sql
;;

(* Register the version before heartbeat: without a `versions` row the id
   subquery yields null. Registration is not a claim of ingest; `seed_levels`
   is the only evidence of that. *)
let register_version t version =
  with_stmt
    t
    insert_version_sql
    ~bind:[ version_bind version ]
    ~f:(fun stmt -> fold_rows stmt ~init:() ~f:(fun () _ -> Ok ()))
;;

(* [with_immediate_txn] raises on BUSY, and the generator heartbeats through a
   store rebuild that holds the write lock far past busy_timeout. *)
let heartbeat t ~generator_id ~versions ~now =
  Or_error.try_with_join (fun () ->
    with_immediate_txn t ~f:(fun t ->
      List.map versions ~f:(fun version ->
        let%bind.Or_error () = register_version t version in
        with_stmt
          t
          heartbeat_sql
          ~bind:
            [ Sqlite3.Data.TEXT generator_id
            ; version_bind version
            ; Sqlite3.Data.INT (Int64.of_int now)
            ]
          ~f:(fun stmt -> fold_rows stmt ~init:() ~f:(fun () _ -> Ok ())))
      |> Or_error.all_unit))
;;

(* Cap and generator checks inside the write transaction to avoid TOCTOU races. *)
let enqueue ?daily t ~version ~seed ~origin ~cap ~servable_since =
  with_immediate_txn t ~f:(fun t ->
    let open Or_error.Let_syntax in
    let%bind servable = servable_versions t ~since:servable_since in
    if not (List.mem servable (Query.Version.to_string version) ~equal:String.equal)
    then Ok `No_generator
    else (
      let%bind existing = job_for_seed t ~version ~seed in
      match existing with
      | Some job -> Ok (`Already_queued job)
      | None ->
        let%bind outstanding = outstanding_jobs ~origin t in
        let%bind over_daily =
          match daily with
          | None -> Ok false
          | Some (daily_cap, since) ->
            let%map today = submitted_since t ~since in
            today >= daily_cap
        in
        if over_daily
        then Ok `Daily_cap
        else if outstanding >= cap
        then Ok `Queue_full
        else (
          let%bind () = register_version t version in
          let%map () =
            with_stmt
              t
              enqueue_sql
              ~bind:
                [ Sqlite3.Data.TEXT seed
                ; version_bind version
                ; Sqlite3.Data.TEXT (Job.Origin.to_string origin)
                ]
              ~f:(fun stmt -> fold_rows stmt ~init:() ~f:(fun () _ -> Ok ()))
          in
          `Queued)))
;;

(* started_at is a liveness signal, not a start time. A stale claim means the
   worker vanished; no attempt is counted here. *)
let reclaim_sql =
  {|
update ingest_jobs
   set started_at = null
 where started_at is not null
   and finished_at is null
   and error is null
   and started_at < ?
|}
;;

(* A job over the attempt limit with no error keeps a claim and takes one, so
   it leaves the queue. Scoped to the version being claimed. *)
let give_up_sql =
  sprintf
    {|
update ingest_jobs
   set error = ?
     , started_at = ?
 where version_id = %s
   and started_at is null
   and finished_at is null
   and error is null
   and attempts >= ?
|}
    version_id_sql
;;

let claim_sql =
  sprintf
    {|
update ingest_jobs
   set started_at = ?
 where (seed, version_id) in (select seed
                                   , version_id
                                from ingest_jobs
                               where version_id = %s
                                 and started_at is null
                                 and finished_at is null
                                 and error is null
                               order by origin = 'submit'
                                      , queued_at
                               limit 1)
|}
    version_id_sql
;;

(* Reclaim sweep runs before the claim, in the same transaction. changes()
   makes two generators safe: under `begin immediate` they serialize, and the
   loser's update matches no row. *)
let claim_job t ~version ~now =
  with_immediate_txn t ~f:(fun t ->
    let open Or_error.Let_syntax in
    let stale =
      Sqlite3.Data.INT
        (Int64.of_int (now - Float.to_int (Time_float.Span.to_sec Job.reclaim_after)))
    in
    let attempts = Sqlite3.Data.INT (Int64.of_int Job.max_attempts) in
    let run sql ~bind =
      with_stmt t sql ~bind ~f:(fun stmt ->
        fold_rows stmt ~init:() ~f:(fun () _ -> Ok ()))
    in
    let%bind () = run reclaim_sql ~bind:[ stale ] in
    let%bind () =
      run
        give_up_sql
        ~bind:
          [ Sqlite3.Data.TEXT
              (sprintf "gave up after %d failed attempts" Job.max_attempts)
          ; Sqlite3.Data.INT (Int64.of_int now)
          ; version_bind version
          ; attempts
          ]
    in
    let%bind () =
      run claim_sql ~bind:[ Sqlite3.Data.INT (Int64.of_int now); version_bind version ]
    in
    if Sqlite3.changes t = 0
    then Ok None
    else (
      let%map claimed =
        with_stmt
          t
          (job_columns
           ^ sprintf
               {|
   where version_id = %s
     and started_at = ?
   order by queued_at
   limit 1
|}
               version_id_sql)
          ~bind:[ version_bind version; Sqlite3.Data.INT (Int64.of_int now) ]
          ~f:(fun stmt ->
            fold_rows stmt ~init:[] ~f:(fun acc row ->
              let%map.Or_error job = job_of_row row ~version in
              job :: acc)
            |> Or_error.map ~f:List.hd)
      in
      claimed))
;;

(* Finish resets attempts: max_attempts bounds consecutive failures, not
   lifetime claims. *)
let finish_sql =
  sprintf
    {|
update ingest_jobs
   set finished_at = ?
     , error = null
     , attempts = 0
 where seed = ?
   and version_id = %s
   and started_at = ?
|}
    version_id_sql
;;

(* Failure clears the claim for retry, unless over the attempt limit: then the
   error stands and the claim is kept, removing it from the queue. *)
let fail_sql =
  sprintf
    {|
update ingest_jobs
   set started_at = case when attempts + 1 >= ? then started_at else null end
     , attempts = attempts + 1
     , error = case when attempts + 1 >= ? then ? else null end
 where seed = ?
   and version_id = %s
   and started_at = ?
|}
    version_id_sql
;;

let refresh_claim_sql =
  sprintf
    {|
update ingest_jobs
   set started_at = ?
 where seed = ?
   and version_id = %s
   and started_at = ?
|}
    version_id_sql
;;

(* changes() arbitrates: zero rows means the claim was lost. Levels already
   committed via seed_fills stand regardless. *)
let refresh_claim t ~version ~seed ~started_at ~now =
  with_immediate_txn t ~f:(fun t ->
    let%bind.Or_error () =
      with_stmt
        t
        refresh_claim_sql
        ~bind:
          [ Sqlite3.Data.INT (Int64.of_int now)
          ; Sqlite3.Data.TEXT seed
          ; version_bind version
          ; Sqlite3.Data.INT (Int64.of_int started_at)
          ]
        ~f:(fun stmt -> fold_rows stmt ~init:() ~f:(fun () _ -> Ok ()))
    in
    if Sqlite3.changes t = 0 then Ok `Lost else Ok `Held)
;;

let finish_job t ~version ~seed ~started_at ~now ~error =
  with_immediate_txn t ~f:(fun t ->
    let run sql ~bind =
      with_stmt t sql ~bind ~f:(fun stmt ->
        fold_rows stmt ~init:() ~f:(fun () _ -> Ok ()))
    in
    let claim = Sqlite3.Data.INT (Int64.of_int started_at) in
    let%bind.Or_error () =
      match error with
      | None ->
        run
          finish_sql
          ~bind:
            [ Sqlite3.Data.INT (Int64.of_int now)
            ; Sqlite3.Data.TEXT seed
            ; version_bind version
            ; claim
            ]
      | Some message ->
        let attempts = Sqlite3.Data.INT (Int64.of_int Job.max_attempts) in
        run
          fail_sql
          ~bind:
            [ attempts
            ; attempts
            ; Sqlite3.Data.TEXT message
            ; Sqlite3.Data.TEXT seed
            ; version_bind version
            ; claim
            ]
    in
    if Sqlite3.changes t = 0 then Ok `Lost else Ok `Recorded)
;;

(* {1 Heat}
   Population statistics per (version, cap), recomputed by bin/rescore.ml after
   a fill. *)

(* The population is the random sample. A submitted seed is scored against it
   but never counted in it. *)
let eligible_seeds_sql =
  sprintf
    {|
select seed
  from seed_fills
 where version_id = %s
   and depth >= ?
   and origin = 'fill'
|}
    version_id_sql
;;

let eligible_seeds t ~version ~cap =
  with_stmt
    t
    eligible_seeds_sql
    ~bind:[ version_bind version; Sqlite3.Data.INT (Int64.of_int cap) ]
    ~f:seeds_of_stmt
  |> Or_error.ok_exn
;;

let submitted_seeds_sql =
  sprintf
    {|
select seed
  from seed_fills
 where version_id = %s
   and depth >= ?
   and origin = 'submit'
|}
    version_id_sql
;;

let submitted_seeds t ~version ~cap =
  with_stmt
    t
    submitted_seeds_sql
    ~bind:[ version_bind version; Sqlite3.Data.INT (Int64.of_int cap) ]
    ~f:seeds_of_stmt
  |> Or_error.ok_exn
;;

(* Heat's cap is a [Depth.t]; membership is a rank comparison. An unrankable
   level is admitted: the corpus cannot prove it sits deeper than the cap. *)
let level_within_cap ~level ~parent ~(cap : Depth.t) =
  let rank = Depth.of_level_with_parent ~level ~parent in
  rank = Depth.unknown || rank <= cap
;;

let qualifying_levels ~levels ~cap =
  List.filter levels ~f:(fun level -> level_within_cap ~level ~parent:None ~cap)
;;

(* Mirrors [portal_exclusion]: the per-seed half of a depth cap, expressed as
   [not exists] over the disqualifying (level, parent) pairs so a parentless
   row (predating format 2) stays admitted rather than being dropped for
   lacking data. *)
let heat_portal_exclusion ~parents ~cap =
  let too_deep =
    List.filter parents ~f:(fun (level, parent) ->
      not (level_within_cap ~level ~parent:(Some parent) ~cap))
  in
  if List.is_empty too_deep
  then None
  else (
    let placeholders =
      List.init (List.length too_deep) ~f:(fun _ ->
        sprintf "(%s, %s)" string_id_sql string_id_sql)
      |> String.concat ~sep:", "
    in
    Some
      ( sprintf
          "not exists (select 1 from seed_levels sl where sl.seed = e.seed and \
           sl.version_id = e.version_id and sl.level_id = e.level_id and (sl.level_id, \
           sl.parent_level_id) in (values %s))"
          placeholders
      , List.concat_map too_deep ~f:(fun (level, parent) ->
          [ Sqlite3.Data.TEXT level; Sqlite3.Data.TEXT parent ]) ))
;;

(* Floor and monster-carried items only ([cost is null]). Null quantity counts
   as 1, matching other count-threshold queries. *)
let surprise_counts_sql ~levels_filter ~portal_filter =
  sprintf
    {|
  select e.seed
       , s_base_type.val
       , s_sub_type.val
       , sum(coalesce(e.quantity, 1))
    from entries e
    join strings s_base_type
      on s_base_type.id = e.base_type_id
    join strings s_sub_type
      on s_sub_type.id = e.sub_type_id
   where e.version_id = %s
     and e.cost is null
     and e.base_type_id is not null
     and e.sub_type_id is not null
     and e.seed in (select seed
                      from seed_fills
                     where version_id = %s
                       and depth >= ?
                       and origin = 'fill')
     %s
     %s
group by e.seed
       , s_base_type.val
       , s_sub_type.val
|}
    version_id_sql
    version_id_sql
    levels_filter
    portal_filter
;;

(* The shared depth-cap filter. The [not exists] form keeps parentless rows
   (predating format 2) admitted rather than dropped for lacking data. *)
let cap_filter ~levels ~parents ~cap =
  let levels_filter, levels_bind =
    match levels with
    | [] -> "", []
    | levels ->
      let qualifying = qualifying_levels ~levels ~cap in
      let placeholders =
        List.init (List.length qualifying) ~f:(fun _ -> "?") |> String.concat ~sep:", "
      in
      ( sprintf "and e.level_id in (select id from strings where val in (%s))" placeholders
      , List.map qualifying ~f:(fun level -> Sqlite3.Data.TEXT level) )
  in
  let portal_filter, portal_bind =
    match heat_portal_exclusion ~parents ~cap with
    | None -> "", []
    | Some (filter, bind) -> "and " ^ filter, bind
  in
  (levels_filter, portal_filter), levels_bind @ portal_bind
;;

let build_surprise_counts_query ~levels ~parents ~cap =
  let (levels_filter, portal_filter), extra_bind = cap_filter ~levels ~parents ~cap in
  surprise_counts_sql ~levels_filter ~portal_filter, extra_bind
;;

(* Reunites the three spell sources (randart entry_spells, named book_spells,
   parchment sub_type) at population scale. *)
(* Joins seed_levels for level in-list and portal exclusion. *)
let book_rows_sql ~levels_filter ~portal_filter =
  sprintf
    {|
  select e.id
       , e.seed
       , s_sub_type.val
       , e.artefact
    from entries e
    join seed_levels sl
      on sl.seed = e.seed
     and sl.version_id = e.version_id
     and sl.level_id = e.level_id
    left join strings s_sub_type
      on s_sub_type.id = e.sub_type_id
   where e.version_id = %s
     and e.cost is null
     and e.base_type_id = %s
     and e.seed in (select seed
                      from seed_fills
                     where version_id = %s
                       and depth >= ?)
     %s
     %s
|}
    version_id_sql
    string_id_sql
    version_id_sql
    levels_filter
    portal_filter
;;

let randart_book_spells_sql =
  sprintf
    {|
select es.entry_id
     , s_spell.val
  from entry_spells es
  join entries e
    on e.id = es.entry_id
  join strings s_spell
    on s_spell.id = es.spell_id
 where e.version_id = %s
   and e.artefact = 1
   and e.base_type_id = %s
|}
    version_id_sql
    string_id_sql
;;

let seed_book_rows_sql =
  sprintf
    {|
   select e.id
        , e.seed
        , s_sub_type.val
        , e.artefact
        , s_level.val
        , s_parent.val
     from entries e
     join seed_levels sl
       on sl.seed = e.seed
      and sl.version_id = e.version_id
      and sl.level_id = e.level_id
     join strings s_level
       on s_level.id = e.level_id
left join strings s_parent
       on s_parent.id = sl.parent_level_id
left join strings s_sub_type
       on s_sub_type.id = e.sub_type_id
    where e.seed = ?
      and e.version_id = %s
      and e.cost is null
      and e.base_type_id = %s
|}
    version_id_sql
    string_id_sql
;;

let seed_randart_book_spells_sql = randart_book_spells_sql ^ "   and e.seed = ?\n"

let early_spells_of_rows ~book_spells ~randart_spells rows =
  let by_seed = String.Table.create () in
  List.iter rows ~f:(fun (entry_id, seed, sub_type, artefact) ->
    let spells =
      if Book.spells_are_fixed ~sub_type ~artefact
      then Option.bind sub_type ~f:(fun sub_type -> Map.find book_spells sub_type)
      else (
        match sub_type with
        | Some sub_type when Book.spells_are_derivable ~sub_type:(Some sub_type) ->
          Book.spells_of_sub_type sub_type
        | _ -> Hashtbl.find randart_spells entry_id)
    in
    match spells with
    | None -> ()
    | Some spells ->
      List.iter spells ~f:(fun spell ->
        match Spell.level spell with
        | Some level when level <= 4 -> Hashtbl.add_multi by_seed ~key:seed ~data:spell
        | _ -> ()));
  Hashtbl.map by_seed ~f:(fun spells ->
    List.dedup_and_sort spells ~compare:String.compare |> List.length)
;;

let version_book_spells t ~version =
  with_stmt
    t
    version_book_spells_sql
    ~bind:[ version_bind version ]
    ~f:(fun stmt ->
      fold_rows stmt ~init:[] ~f:(fun acc row ->
        let%bind.Or_error sub_type = required row 0 ~field:"sub_type" in
        let%map.Or_error spell = required row 1 ~field:"spell" in
        (sub_type, spell) :: acc)
      |> Or_error.map ~f:(fun rows -> List.rev rows |> Map.of_alist_multi (module String)))
;;

let randart_spells_of t sql ~bind =
  with_stmt t sql ~bind ~f:(fun stmt ->
    fold_rows stmt ~init:[] ~f:(fun acc row ->
      let%bind.Or_error entry_id =
        match column_int row 0 with
        | Some id -> Ok id
        | None -> Or_error.error_string "entry_id is null"
      in
      let%map.Or_error spell = required row 1 ~field:"spell" in
      (entry_id, spell) :: acc)
    |> Or_error.map ~f:(fun rows -> Int.Table.of_alist_multi (List.rev rows)))
;;

let early_spell_counts t ~version ~cap ~levels ~parents =
  let open Or_error.Let_syntax in
  let%bind book_spells = version_book_spells t ~version in
  let%bind randart_spells =
    randart_spells_of
      t
      randart_book_spells_sql
      ~bind:[ version_bind version; Sqlite3.Data.TEXT "book" ]
  in
  let (levels_filter, portal_filter), extra_bind = cap_filter ~levels ~parents ~cap in
  let%map rows =
    with_stmt
      t
      (book_rows_sql ~levels_filter ~portal_filter)
      ~bind:
        ([ version_bind version
         ; Sqlite3.Data.TEXT "book"
         ; version_bind version
         ; Sqlite3.Data.INT (Int64.of_int cap)
         ]
         @ extra_bind)
      ~f:(fun stmt ->
        fold_rows stmt ~init:[] ~f:(fun acc row ->
          let%bind entry_id =
            match column_int row 0 with
            | Some id -> Ok id
            | None -> Or_error.error_string "entry_id is null"
          in
          let%map seed = required row 1 ~field:"seed" in
          let sub_type = column_text row 2 in
          let artefact = column_bool row 3 in
          (entry_id, seed, sub_type, artefact) :: acc)
        |> Or_error.map ~f:List.rev)
  in
  early_spells_of_rows ~book_spells ~randart_spells rows
;;

let delete_surprise_sql =
  sprintf "delete from surprise where version_id = %s and cap = ?" version_id_sql
;;

let insert_surprise_sql =
  sprintf
    {|
insert into surprise (version_id, cap, base_type_id, sub_type_id, count, tail_p)
     values (%s, ?, %s, %s, ?, ?)
|}
    version_id_sql
    string_id_sql
    string_id_sql
;;

(* [tail_p] for observed count n: share of eligible population with total >= n
   at this (base_type, sub_type). Built from the full per-seed distribution. *)
let tail_probabilities counts_by_seed ~n =
  let sorted = List.sort counts_by_seed ~compare:Int.compare |> Array.of_list in
  let len = Array.length sorted in
  let distinct = List.dedup_and_sort counts_by_seed ~compare:Int.compare in
  List.map distinct ~f:(fun count ->
    (* Binary search for first index with count >= [count]. *)
    let ge =
      let rec bsearch lo hi =
        if lo >= hi
        then lo
        else (
          let mid = (lo + hi) / 2 in
          if sorted.(mid) >= count then bsearch lo mid else bsearch (mid + 1) hi)
      in
      bsearch 0 len
    in
    let qualifying = len - ge in
    count, Float.of_int qualifying /. Float.of_int n)
;;

module Item_key = struct
  module T = struct
    type t = string * string [@@deriving compare, hash, sexp_of]
  end

  include T
  include Comparator.Make (T)
end

(* The item key interns like every other value: rescore joins these ids against
   entries' own, so a key that never reached the dictionary would store null
   and match nothing. The book row's synthetic key ([Heat.book_surprise_key]) is
   in no entry, which is exactly why it has to be interned here rather than
   assumed present. *)
let insert_tails insert_stmt ~intern ~version ~cap_int ~base_type ~sub_type tails =
  intern base_type;
  intern sub_type;
  List.iter tails ~f:(fun (count, tail_p) ->
    let bind i data = check_rc "bind" (Sqlite3.bind insert_stmt i data) in
    bind 1 (Sqlite3.Data.TEXT (Query.Version.to_string version));
    bind 2 (Sqlite3.Data.INT cap_int);
    bind 3 (Sqlite3.Data.TEXT base_type);
    bind 4 (Sqlite3.Data.TEXT sub_type);
    bind 5 (Sqlite3.Data.INT (Int64.of_int count));
    bind 6 (Sqlite3.Data.FLOAT tail_p);
    step_reset insert_stmt)
;;

let recompute_surprise t ~version ~(cap : Depth.t) =
  let cap_int = Int64.of_int cap in
  with_txn t ~f:(fun t ->
    let eligible = eligible_seeds t ~version ~cap in
    let n = List.length eligible in
    with_stmt
      t
      delete_surprise_sql
      ~bind:[ version_bind version; Sqlite3.Data.INT cap_int ]
      ~f:(fun stmt -> fold_rows stmt ~init:() ~f:(fun () _ -> Ok ()))
    |> Or_error.ok_exn;
    if n > 0
    then (
      let levels = version_levels t ~version |> Or_error.ok_exn in
      let parents = version_parents t ~version |> Or_error.ok_exn in
      let sql, extra_bind = build_surprise_counts_query ~levels ~parents ~cap in
      let counts_by_key =
        with_stmt
          t
          sql
          ~bind:
            ([ version_bind version; version_bind version; Sqlite3.Data.INT cap_int ]
             @ extra_bind)
          ~f:(fun stmt ->
            fold_rows stmt ~init:[] ~f:(fun acc row ->
              let open Or_error.Let_syntax in
              let%bind base_type = required row 1 ~field:"base_type" in
              let%map sub_type = required row 2 ~field:"sub_type" in
              let count = Option.value (column_int row 3) ~default:1 in
              (base_type, sub_type, count) :: acc))
        |> Or_error.ok_exn
      in
      let by_key = Hashtbl.create (module Item_key) in
      List.iter counts_by_key ~f:(fun (base_type, sub_type, count) ->
        Hashtbl.add_multi by_key ~key:(base_type, sub_type) ~data:count);
      let insert_stmt = Sqlite3.prepare t insert_surprise_sql in
      let string_stmt = Sqlite3.prepare t insert_string_sql in
      let intern value =
        check_rc "bind string" (Sqlite3.bind string_stmt 1 (Sqlite3.Data.TEXT value));
        step_reset string_stmt
      in
      Exn.protect
        ~finally:(fun () ->
          ignore (Sqlite3.finalize insert_stmt : Sqlite3.Rc.t);
          ignore (Sqlite3.finalize string_stmt : Sqlite3.Rc.t))
        ~f:(fun () ->
          Hashtbl.iteri by_key ~f:(fun ~key:(base_type, sub_type) ~data:counts ->
            tail_probabilities counts ~n
            |> insert_tails insert_stmt ~intern ~version ~cap_int ~base_type ~sub_type);
          let early_spells =
            early_spell_counts t ~version ~cap ~levels ~parents |> Or_error.ok_exn
          in
          (* Every eligible seed contributes a count (0 if no early spell), so
             the book tail's population matches [n]. *)
          let counts =
            List.map eligible ~f:(fun seed ->
              Hashtbl.find early_spells seed |> Option.value ~default:0)
          in
          let book_base_type, book_sub_type = Heat.book_surprise_key in
          tail_probabilities counts ~n
          |> insert_tails
               insert_stmt
               ~intern
               ~version
               ~cap_int
               ~base_type:book_base_type
               ~sub_type:book_sub_type))
    else ())
;;

(* Per-(seed, base_type, sub_type) totals and shallowest contributing level.
   Shallowest is picked in OCaml; [min] over level names is meaningless. *)
(* A portal's parent is per (seed, level); the row carries its own parent via
   join. *)
let score_rows_sql ~levels_filter ~portal_filter ~shard_filter =
  sprintf
    {|
select e.seed
     , s_base_type.val
     , s_sub_type.val
     , s_level.val
     , coalesce(e.quantity, 1)
     , s_parent.val
  from entries e
  join seed_levels sl
    on sl.seed = e.seed
   and sl.version_id = e.version_id
   and sl.level_id = e.level_id
  join strings s_base_type
    on s_base_type.id = e.base_type_id
  join strings s_sub_type
    on s_sub_type.id = e.sub_type_id
  join strings s_level
    on s_level.id = e.level_id
  left join strings s_parent
    on s_parent.id = sl.parent_level_id
 where e.version_id = %s
   and e.cost is null
   and e.base_type_id is not null
   and e.sub_type_id is not null
   and e.seed in (select seed
                    from seed_fills
                   where version_id = %s
                     and depth >= ?)
   %s
   %s
   %s
|}
    version_id_sql
    version_id_sql
    levels_filter
    portal_filter
    shard_filter
;;

module Seed_item_key = struct
  module T = struct
    type t = string * string * string [@@deriving compare, hash, sexp_of]
  end

  include T
  include Comparator.Make (T)
end

(* Groups rows into one [Heat.observation] per (seed, base_type, sub_type):
   quantity summed, shallowest level ranked via [Depth.of_level_with_parent]. *)
let group_observations rows =
  let totals = Hashtbl.create (module Seed_item_key) in
  let shallowest = Hashtbl.create (module Seed_item_key) in
  List.iter rows ~f:(fun (seed, base_type, sub_type, level, count, parent) ->
    let key = seed, base_type, sub_type in
    Hashtbl.update totals key ~f:(function
      | None -> count
      | Some existing -> existing + count);
    let rank = Depth.of_level_with_parent ~level ~parent in
    Hashtbl.update shallowest key ~f:(function
      | None -> rank
      | Some existing -> min existing rank));
  Hashtbl.fold
    totals
    ~init:String.Map.empty
    ~f:(fun ~key:(seed, base_type, sub_type) ~data:count acc ->
      let shallowest_rank = Hashtbl.find_exn shallowest (seed, base_type, sub_type) in
      Map.add_multi
        acc
        ~key:seed
        ~data:{ Heat.base_type; sub_type; count; shallowest = shallowest_rank })
;;

module Count_key = struct
  module T = struct
    type t = string * string * int [@@deriving compare, hash, sexp_of]
  end

  include T
  include Comparator.Make (T)
end

let surprise_rows_sql =
  sprintf
    {|
select s_base_type.val
     , s_sub_type.val
     , sp.count
     , sp.tail_p
  from surprise sp
  join strings s_base_type
    on s_base_type.id = sp.base_type_id
  join strings s_sub_type
    on s_sub_type.id = sp.sub_type_id
 where sp.version_id = %s
   and sp.cap = ?
|}
    version_id_sql
;;

(* Exact match should always exist for observed counts. Fallback (largest
   stored n <= count, else 1/N) is defense against stale surprise tables. *)
let surprise_lookup t ~version ~(cap : Depth.t) ~n =
  let rows =
    with_stmt
      t
      surprise_rows_sql
      ~bind:[ version_bind version; Sqlite3.Data.INT (Int64.of_int cap) ]
      ~f:(fun stmt ->
        fold_rows stmt ~init:[] ~f:(fun acc row ->
          let open Or_error.Let_syntax in
          let%bind base_type = required row 0 ~field:"base_type" in
          let%bind sub_type = required row 1 ~field:"sub_type" in
          let count = Option.value (column_int row 2) ~default:0 in
          let%map tail_p =
            match Sqlite3.Data.to_float row.(3) with
            | Some f -> Ok f
            | None -> Or_error.error_string "tail_p is null"
          in
          ((base_type, sub_type, count), tail_p) :: acc))
    |> Or_error.ok_exn
  in
  let by_key = Hashtbl.create (module Count_key) in
  List.iter rows ~f:(fun (key, tail_p) -> Hashtbl.set by_key ~key ~data:tail_p);
  fun ~base_type ~sub_type ~count ->
    match Hashtbl.find by_key (base_type, sub_type, count) with
    | Some tail_p -> tail_p
    | None ->
      List.filter rows ~f:(fun ((bt, st, c), _) ->
        String.equal bt base_type && String.equal st sub_type && c <= count)
      |> List.max_elt ~compare:(fun ((_, _, a), _) ((_, _, b), _) -> Int.compare a b)
      |> (function
       | Some (_, tail_p) -> tail_p
       | None -> 1. /. Float.of_int n)
;;

let delete_seed_scores_sql =
  sprintf "delete from seed_scores where version_id = %s and cap = ?" version_id_sql
;;

let delete_heat_bands_sql =
  sprintf "delete from heat_bands where version_id = %s and cap = ?" version_id_sql
;;

let insert_seed_score_sql =
  sprintf
    {|
insert into seed_scores (seed, version_id, cap, score, band)
     values (?, %s, ?, ?, ?)
|}
    version_id_sql
;;

let insert_heat_band_sql =
  sprintf
    {|
insert into heat_bands (version_id, cap, band, min_score)
     values (%s, ?, ?, ?)
|}
    version_id_sql
;;

let delete_heat_cohort_sql =
  sprintf "delete from heat_cohorts where version_id = %s and cap = ?" version_id_sql
;;

let insert_heat_cohort_sql =
  sprintf
    "insert into heat_cohorts (version_id, cap, seeds) values (%s, ?, ?)"
    version_id_sql
;;

(* A tie lands in the lowest band that reaches it, which [max_elt] gives only
   over [cuts] in ascending band order. *)
let band_of_score cuts score =
  List.filter cuts ~f:(fun (_, min_score) -> Float.( >= ) score min_score)
  |> List.max_elt ~compare:(fun (_, a) (_, b) -> Float.compare a b)
  |> Option.value_map ~default:Heat.Band.Cold ~f:fst
;;

(* Percentile cut points for [Heat.Band.t]: band 0 (Cold) starts at the
   population minimum, each higher band at score [pct] up the sorted list. No
   interpolation; a stored min_score is a threshold test at read time. *)
let percentile sorted ~pct =
  match sorted with
  | [||] -> 0.
  | sorted ->
    let len = Array.length sorted in
    let idx = Int.min (len - 1) (Float.to_int (pct *. Float.of_int len)) in
    sorted.(idx)
;;

(* [seed] is TEXT, so lexicographic order is not numeric. Bounds derived from
   data via [ntile] rather than fixed-prefix cuts, which are unbalanced (leading
   digit 1 holds 413k of 1.3M). Balance bounds peak memory; correctness does
   not depend on it. *)
let shard_bounds_sql =
  sprintf
    {|
select min(seed), max(seed)
  from (select seed
             , ntile(?) over (order by seed) as bucket
          from seed_fills
         where version_id = %s
           and depth >= ?)
 group by bucket
 order by bucket
|}
    version_id_sql
;;

(* Ranges as (lo, hi, hi_inclusive). Every shard must be a closed range: an
   open upper bound makes SQLite abandon the primary-key seek (70s vs 2.7s at
   1.3M). Interior bounds chain: shard i's exclusive upper is shard i+1's
   inclusive lower. *)
let shard_ranges t ~version ~cap ~shards =
  let bounds =
    with_stmt
      t
      shard_bounds_sql
      ~bind:
        [ Sqlite3.Data.INT (Int64.of_int shards)
        ; version_bind version
        ; Sqlite3.Data.INT (Int64.of_int cap)
        ]
      ~f:(fun stmt ->
        fold_rows stmt ~init:[] ~f:(fun acc row ->
          let open Or_error.Let_syntax in
          let%bind lo = required row 0 ~field:"shard lower bound" in
          let%map hi = required row 1 ~field:"shard upper bound" in
          (lo, hi) :: acc))
    |> Or_error.ok_exn
    |> List.rev
  in
  let rec chain = function
    | [] -> []
    | [ (lo, hi) ] -> [ lo, hi, `Inclusive ]
    | (lo, _) :: ((next_lo, _) :: _ as rest) -> (lo, next_lo, `Exclusive) :: chain rest
  in
  chain bounds
;;

(* The scoring scan is entirely reads, and at 1.3M it is ~13 minutes of them.
   Holding a write transaction across it -- which taking the deletes first
   would do -- blocks WAL checkpointing for the whole pass and grows the WAL
   by every page the scan touches. So the pass reads first, outside any
   transaction, and opens one short write transaction at the end for the
   delete-then-insert.

   This keeps the property that a kill mid-pass leaves the previous scores
   intact rather than half-scored: deletes and inserts are one atomic unit,
   and everything before them is side-effect-free. The scan is read-only, so
   not committing per shard costs nothing. *)
let rescore ?(shards = 1) t ~version ~(cap : Depth.t) =
  let cap_int = Int64.of_int cap in
  let write_scores ~f =
    with_txn t ~f:(fun t ->
      with_stmt
        t
        delete_seed_scores_sql
        ~bind:[ version_bind version; Sqlite3.Data.INT cap_int ]
        ~f:(fun stmt -> fold_rows stmt ~init:() ~f:(fun () _ -> Ok ()))
      |> Or_error.ok_exn;
      with_stmt
        t
        delete_heat_bands_sql
        ~bind:[ version_bind version; Sqlite3.Data.INT cap_int ]
        ~f:(fun stmt -> fold_rows stmt ~init:() ~f:(fun () _ -> Ok ()))
      |> Or_error.ok_exn;
      with_stmt
        t
        delete_heat_cohort_sql
        ~bind:[ version_bind version; Sqlite3.Data.INT cap_int ]
        ~f:(fun stmt -> fold_rows stmt ~init:() ~f:(fun () _ -> Ok ()))
      |> Or_error.ok_exn;
      f t)
  in
  let eligible = eligible_seeds t ~version ~cap in
  let submitted = submitted_seeds t ~version ~cap in
  let n = List.length eligible in
  if n > 0
  then (
    let levels = version_levels t ~version |> Or_error.ok_exn in
    let parents = version_parents t ~version |> Or_error.ok_exn in
    let (levels_filter, portal_filter), extra_bind = cap_filter ~levels ~parents ~cap in
    let early_spells =
      early_spell_counts t ~version ~cap ~levels ~parents |> Or_error.ok_exn
    in
    let surprise = surprise_lookup t ~version ~cap ~n in
    (* [n] is computed once above the shard loop. Recomputing per shard would
       score each against its own population and change results. *)
    let ranges =
      match shards with
      | k when k <= 1 -> [ None ]
      | k -> shard_ranges t ~version ~cap ~shards:k |> List.map ~f:Option.some
    in
    let scores =
      List.concat_map ranges ~f:(fun range ->
        let shard_filter, shard_bind =
          match range with
          | None -> "", []
          | Some (lo, hi, bound) ->
            ( (match bound with
               | `Exclusive -> "and e.seed >= ? and e.seed < ?"
               | `Inclusive -> "and e.seed >= ? and e.seed <= ?")
            , [ Sqlite3.Data.TEXT lo; Sqlite3.Data.TEXT hi ] )
        in
        let score_sql = score_rows_sql ~levels_filter ~portal_filter ~shard_filter in
        let score_bind =
          [ version_bind version; version_bind version; Sqlite3.Data.INT cap_int ]
          @ extra_bind
          @ shard_bind
        in
        let rows =
          with_stmt t score_sql ~bind:score_bind ~f:(fun stmt ->
            fold_rows stmt ~init:[] ~f:(fun acc row ->
              let open Or_error.Let_syntax in
              let%bind seed = required row 0 ~field:"seed" in
              let%bind base_type = required row 1 ~field:"base_type" in
              let%bind sub_type = required row 2 ~field:"sub_type" in
              let%map level = required row 3 ~field:"level" in
              let count = Option.value (column_int row 4) ~default:1 in
              let parent = column_text row 5 in
              (seed, base_type, sub_type, level, count, parent) :: acc))
          |> Or_error.ok_exn
        in
        let observations_by_seed = group_observations rows in
        (* Shard's hashtables become garbage here; only (seed, score) pairs
           survive, bounding peak residency to one shard. *)
        Map.fold observations_by_seed ~init:[] ~f:(fun ~key:seed ~data:observations acc ->
          let early_spells = Hashtbl.find early_spells seed |> Option.value ~default:0 in
          (seed, Heat.score ~surprise ~n ~cap ~early_spells observations) :: acc))
    in
    (* Seeds with no scoring rows score 0; fill the gap explicitly. *)
    let scored = Hash_set.of_list (module String) (List.map scores ~f:fst) in
    let scores =
      List.fold (eligible @ submitted) ~init:scores ~f:(fun acc seed ->
        if Hash_set.mem scored seed
        then acc
        else (
          let early_spells = Hashtbl.find early_spells seed |> Option.value ~default:0 in
          (seed, Heat.score ~surprise ~n ~cap ~early_spells []) :: acc))
    in
    let sample = Hash_set.of_list (module String) eligible in
    let sorted_scores =
      List.filter_map scores ~f:(fun (seed, score) ->
        Option.some_if (Hash_set.mem sample seed) score)
      |> List.sort ~compare:Float.compare
      |> Array.of_list
    in
    let cut ~pct = percentile sorted_scores ~pct in
    let min_score_of : Heat.Band.t -> float = function
      | Cold -> Float.min (cut ~pct:0.) 0.
      | Warm -> cut ~pct:0.5
      | Hot -> cut ~pct:0.8
      | Blazing -> cut ~pct:0.95
    in
    let bands = [ Heat.Band.Cold; Warm; Hot; Blazing ] in
    let cuts = List.map bands ~f:(fun band -> band, min_score_of band) in
    write_scores ~f:(fun t ->
      let insert_score_stmt = Sqlite3.prepare t insert_seed_score_sql in
      let insert_band_stmt = Sqlite3.prepare t insert_heat_band_sql in
      Exn.protect
        ~finally:(fun () ->
          ignore (Sqlite3.finalize insert_score_stmt : Sqlite3.Rc.t);
          ignore (Sqlite3.finalize insert_band_stmt : Sqlite3.Rc.t))
        ~f:(fun () ->
          with_stmt
            t
            insert_heat_cohort_sql
            ~bind:
              [ version_bind version
              ; Sqlite3.Data.INT cap_int
              ; Sqlite3.Data.INT (Int64.of_int n)
              ]
            ~f:(fun stmt -> fold_rows stmt ~init:() ~f:(fun () _ -> Ok ()))
          |> Or_error.ok_exn;
          List.iter scores ~f:(fun (seed, score) ->
            let band = band_of_score cuts score in
            let bind i data = check_rc "bind" (Sqlite3.bind insert_score_stmt i data) in
            bind 1 (Sqlite3.Data.TEXT seed);
            bind 2 (Sqlite3.Data.TEXT (Query.Version.to_string version));
            bind 3 (Sqlite3.Data.INT cap_int);
            bind 4 (Sqlite3.Data.FLOAT score);
            bind 5 (Sqlite3.Data.INT (Int64.of_int (Heat.Band.to_int band)));
            step_reset insert_score_stmt);
          List.iter cuts ~f:(fun (band, min_score) ->
            let bind i data = check_rc "bind" (Sqlite3.bind insert_band_stmt i data) in
            bind 1 (Sqlite3.Data.TEXT (Query.Version.to_string version));
            bind 2 (Sqlite3.Data.INT cap_int);
            bind 3 (Sqlite3.Data.INT (Int64.of_int (Heat.Band.to_int band)));
            bind 4 (Sqlite3.Data.FLOAT min_score);
            step_reset insert_band_stmt))))
  else
    (* No eligible seeds: delete stale rows for this (version, cap). *)
    write_scores ~f:(fun _ -> ())
;;

let seed_count_sql =
  sprintf
    "select coalesce((select seeds from seed_fill_counts where version_id = %s), 0)"
    version_id_sql
;;

let seed_count t ~version =
  with_stmt
    t
    seed_count_sql
    ~bind:[ version_bind version ]
    ~f:(fun stmt ->
      fold_rows stmt ~init:0 ~f:(fun _ row ->
        Ok (Option.value (column_int row 0) ~default:0)))
;;

let searchable_seed_count_sql =
  sprintf
    {|
select coalesce((select seeds from seed_fill_counts where version_id = %s), 0)
     + (select count(*)
          from seed_fills
         where version_id = %s
           and origin = 'submit'
           and indexed_at is not null)
|}
    version_id_sql
    version_id_sql
;;

let searchable_seed_count t ~version =
  with_stmt
    t
    searchable_seed_count_sql
    ~bind:[ version_bind version; version_bind version ]
    ~f:(fun stmt ->
      fold_rows stmt ~init:0 ~f:(fun _ row ->
        Ok (Option.value (column_int row 0) ~default:0)))
;;

let fill_caps_sql =
  sprintf
    "select distinct depth from seed_fills where version_id = %s order by depth"
    version_id_sql
;;

(* Distinct fill depths for a version: the caps it needs scoring at. A seed
   filled to [Swamp:4] also needs a [D:8] score; eligibility is [depth >= cap]. *)
(* Delete heat rows for caps the version no longer holds. A cap stops existing
   when its last seed goes (e.g. a truncated fill repaired). Scoped per version. *)
let delete_stale_caps_sql table =
  sprintf
    {|
delete from %s
 where version_id = %s
   and cap not in (select depth from seed_fills where version_id = %s)
|}
    table
    version_id_sql
    version_id_sql
;;

let drop_stale_caps t ~version =
  with_immediate_txn t ~f:(fun t ->
    [ "seed_scores"; "heat_bands"; "heat_cohorts"; "surprise" ]
    |> List.map ~f:(fun table ->
      with_stmt
        t
        (delete_stale_caps_sql table)
        ~bind:[ version_bind version; version_bind version ]
        ~f:(fun stmt -> fold_rows stmt ~init:() ~f:(fun () _ -> Ok ())))
    |> Or_error.all_unit)
;;

let fill_caps t ~version =
  with_stmt
    t
    fill_caps_sql
    ~bind:[ version_bind version ]
    ~f:(fun stmt ->
      fold_rows stmt ~init:[] ~f:(fun acc row ->
        match column_int row 0 with
        | Some depth -> Ok (depth :: acc)
        | None -> Or_error.error_string "depth is null")
      |> Or_error.map ~f:List.rev)
;;

let heat_cohort_sql =
  sprintf
    "select seeds from heat_cohorts where version_id = %s and cap = ?"
    version_id_sql
;;

let heat_cuts_sql =
  sprintf
    "select band, min_score from heat_bands where version_id = %s and cap = ?"
    version_id_sql
;;

let seed_depth_sql =
  sprintf "select depth from seed_fills where seed = ? and version_id = %s" version_id_sql
;;

let upsert_seed_score_sql =
  sprintf
    {|
insert or replace
  into seed_scores
     ( seed
     , version_id
     , cap
     , score
     , band
     )
values
     ( ?
     , %s
     , ?
     , ?
     , ?
     )
|}
    version_id_sql
;;

(* The depth cap applied to rows already narrowed to one seed, in the terms
   [cap_filter] states it in SQL for a whole version: the level must be within
   the cap, and so must a portal's (level, parent) pair. Reading the version's
   level and parent lists to build that SQL is a scan of the build. *)
let row_within_cap ~level ~parent ~cap =
  level_within_cap ~level ~parent:None ~cap
  &&
  match parent with
  | None -> true
  | Some parent -> level_within_cap ~level ~parent:(Some parent) ~cap
;;

let score_seed t ~version ~seed =
  with_immediate_txn t ~f:(fun t ->
    let open Or_error.Let_syntax in
    let cap_bind cap = Sqlite3.Data.INT (Int64.of_int cap) in
    let%bind depth =
      with_stmt
        t
        seed_depth_sql
        ~bind:[ Sqlite3.Data.TEXT seed; version_bind version ]
        ~f:(fun stmt -> fold_rows stmt ~init:None ~f:(fun _ row -> Ok (column_int row 0)))
    in
    match depth with
    | None -> Ok []
    | Some depth ->
      let%bind caps = fill_caps t ~version in
      let%bind book_spells = version_book_spells t ~version in
      let%bind randart_spells =
        randart_spells_of
          t
          seed_randart_book_spells_sql
          ~bind:[ version_bind version; Sqlite3.Data.TEXT "book"; Sqlite3.Data.TEXT seed ]
      in
      let%bind book_rows =
        with_stmt
          t
          seed_book_rows_sql
          ~bind:[ Sqlite3.Data.TEXT seed; version_bind version; Sqlite3.Data.TEXT "book" ]
          ~f:(fun stmt ->
            fold_rows stmt ~init:[] ~f:(fun acc row ->
              let%bind entry_id =
                match column_int row 0 with
                | Some id -> Ok id
                | None -> Or_error.error_string "entry_id is null"
              in
              let%bind seed = required row 1 ~field:"seed" in
              let%map level = required row 4 ~field:"level" in
              ( (entry_id, seed, column_text row 2, column_bool row 3)
              , level
              , column_text row 5 )
              :: acc))
      in
      let%map scored =
        List.filter caps ~f:(fun cap -> cap <= depth)
        |> List.fold_result ~init:[] ~f:(fun scored cap ->
          let%bind n =
            with_stmt
              t
              heat_cohort_sql
              ~bind:[ version_bind version; cap_bind cap ]
              ~f:(fun stmt ->
                fold_rows stmt ~init:None ~f:(fun _ row -> Ok (column_int row 0)))
          in
          let%bind cuts =
            with_stmt
              t
              heat_cuts_sql
              ~bind:[ version_bind version; cap_bind cap ]
              ~f:(fun stmt ->
                fold_rows stmt ~init:[] ~f:(fun acc row ->
                  let%bind band =
                    match Option.bind (column_int row 0) ~f:Heat.Band.of_int with
                    | Some band -> Ok band
                    | None -> Or_error.error_string "corrupt band"
                  in
                  let%map min_score =
                    match Sqlite3.Data.to_float row.(1) with
                    | Some f -> Ok f
                    | None -> Or_error.error_string "min_score is null"
                  in
                  (band, min_score) :: acc))
          in
          match n, cuts with
          | None, _ | _, [] -> Ok scored
          | Some n, cuts ->
            let cuts =
              List.sort cuts ~compare:(fun (a, _) (b, _) ->
                Int.compare (Heat.Band.to_int a) (Heat.Band.to_int b))
            in
            let early_spells =
              List.filter_map book_rows ~f:(fun (row, level, parent) ->
                Option.some_if (row_within_cap ~level ~parent ~cap) row)
              |> early_spells_of_rows ~book_spells ~randart_spells
              |> Fn.flip Hashtbl.find seed
              |> Option.value ~default:0
            in
            let%bind rows =
              with_stmt
                t
                (score_rows_sql
                   ~levels_filter:""
                   ~portal_filter:""
                   ~shard_filter:"and e.seed >= ? and e.seed <= ?")
                ~bind:
                  [ version_bind version
                  ; version_bind version
                  ; cap_bind cap
                  ; Sqlite3.Data.TEXT seed
                  ; Sqlite3.Data.TEXT seed
                  ]
                ~f:(fun stmt ->
                  fold_rows stmt ~init:[] ~f:(fun acc row ->
                    let%bind seed = required row 0 ~field:"seed" in
                    let%bind base_type = required row 1 ~field:"base_type" in
                    let%bind sub_type = required row 2 ~field:"sub_type" in
                    let%map level = required row 3 ~field:"level" in
                    let count = Option.value (column_int row 4) ~default:1 in
                    let parent = column_text row 5 in
                    if row_within_cap ~level ~parent ~cap
                    then (seed, base_type, sub_type, level, count, parent) :: acc
                    else acc))
            in
            let observations =
              Map.find (group_observations rows) seed |> Option.value ~default:[]
            in
            let%bind surprise =
              Or_error.try_with (fun () -> surprise_lookup t ~version ~cap ~n)
            in
            let score = Heat.score ~surprise ~n ~cap ~early_spells observations in
            let%map () =
              with_stmt
                t
                upsert_seed_score_sql
                ~bind:
                  [ Sqlite3.Data.TEXT seed
                  ; version_bind version
                  ; cap_bind cap
                  ; Sqlite3.Data.FLOAT score
                  ; Sqlite3.Data.INT
                      (Int64.of_int (Heat.Band.to_int (band_of_score cuts score)))
                  ]
                ~f:(fun stmt -> fold_rows stmt ~init:() ~f:(fun () _ -> Ok ()))
            in
            cap :: scored)
      in
      List.rev scored)
;;
