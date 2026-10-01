open! Core

module Stats = struct
  type t =
    { seeds : int
    ; criteria : int
    ; blocks : int
    ; postings : int
    ; bytes : int
    }

  let zero = { seeds = 0; criteria = 0; blocks = 0; postings = 0; bytes = 0 }
end

let int_bind n = Sqlite3.Data.INT (Int64.of_int n)
let kind_bind kind = int_bind (Criterion_id.Kind.to_int kind)

let id_bind = function
  | None -> Sqlite3.Data.NULL
  | Some id -> int_bind id
;;

let column_blob row i =
  match (row : Sqlite3.Data.t array).(i) with
  | Sqlite3.Data.BLOB b | Sqlite3.Data.TEXT b -> Some b
  | Sqlite3.Data.NONE | Sqlite3.Data.NULL | Sqlite3.Data.INT _ | Sqlite3.Data.FLOAT _ ->
    None
;;

let bind_all stmt data =
  List.iteri data ~f:(fun i datum ->
    Sql.check_rc "bind" (Sqlite3.bind stmt (i + 1) datum))
;;

let step_reset stmt =
  Sql.check_rc "step" (Sqlite3.step stmt);
  Sql.check_rc "reset" (Sqlite3.reset stmt)
;;

let exec_bound db sql ~bind =
  Sql.with_stmt db sql ~bind ~f:(fun stmt ->
    match Sqlite3.step stmt with
    | Sqlite3.Rc.OK | Sqlite3.Rc.DONE -> Ok ()
    | rc -> Or_error.errorf "step: %s" (Sqlite3.Rc.to_string rc))
;;

let first_row db sql ~bind ~f =
  Sql.with_stmt db sql ~bind ~f:(fun stmt ->
    Sql.fold_rows stmt ~init:None ~f:(fun acc row ->
      match acc with
      | Some _ -> Ok acc
      | None -> f row))
;;

let scalar_int db sql ~bind =
  first_row db sql ~bind ~f:(fun row -> Ok (Sql.column_int row 0))
;;

let version_id_of db ~version =
  match
    scalar_int
      db
      "select id from versions where version = ?"
      ~bind:[ Sql.version_bind version ]
  with
  | Error _ as err -> err
  | Ok None -> Or_error.errorf "unknown version %s" (Query.Version.to_string version)
  | Ok (Some id) -> Ok id
;;

let max_entry_id_sql = {|select coalesce(max(id), 0) from entries|}

(* {1 Build} *)

let max_ord_sql =
  {|
  select coalesce(max(ord), -1)
    from seed_ordinals
   where version_id = ?
|}
;;

let assign_ordinals_sql =
  {|
insert into seed_ordinals
          ( version_id
          , seed
          , ord
          )
  select ?
       , s.seed
       , ? + row_number() over (order by length(s.seed), s.seed)
    from (select distinct seed from seed_levels where version_id = ?) s
   where not exists (select 1
                       from seed_ordinals o
                      where o.version_id = ?
                        and o.seed = s.seed)
|}
;;

let record_built_depth_sql =
  {|
update seed_ordinals
   set built_depth = f.depth
  from seed_fills f
 where seed_ordinals.version_id = ?
   and f.version_id = seed_ordinals.version_id
   and f.seed = seed_ordinals.seed
   and seed_ordinals.built_depth is not f.depth
|}
;;

let seed_ordinals_sql =
  {|
  select seed
       , ord
    from seed_ordinals
   where version_id = ?
|}
;;

let level_depth_ddl =
  {|
create temp table if not exists level_depth
          ( level_id integer primary key
          , depth integer not null
          );
delete from level_depth;
|}
;;

let level_names_sql =
  {|
  select distinct sl.level_id
       , s.val
    from seed_levels sl
    join strings s
      on s.id = sl.level_id
   where sl.version_id = ?
|}
;;

let insert_level_depth_sql = {|insert into level_depth (level_id, depth) values (?, ?)|}

let drop_postings_sql =
  {|
delete from search_postings
      where criterion_id in (select id from search_criteria where version_id = ?)
|}
;;

let drop_criteria_sql = {|delete from search_criteria where version_id = ?|}

let insert_criterion_sql =
  {|
insert into search_criteria
          ( version_id
          , kind
          , a_id
          , b_id
          , card
          )
     values
          ( ?
          , ?
          , ?
          , ?
          , ?
          )
|}
;;

let insert_posting_sql =
  {|
insert into search_postings
          ( criterion_id
          , first_ord
          , n
          , postings
          )
     values
          ( ?
          , ?
          , ?
          , ?
          )
|}
;;

let insert_state_sql =
  {|
insert or replace into search_index_state
          ( version_id
          , built_through
          , built_seeds
          )
     values
          ( ?
          , ?
          , ?
          )
|}
;;

let seed_count_sql =
  {|select coalesce((select seeds from seed_fill_counts where version_id = ?), 0)|}
;;

let item_lists_sql position =
  sprintf
    {|
  select e.base_type_id
       , e.sub_type_id
       , e.seed
       , min(ld.depth)
       , sum(coalesce(e.quantity, 1))
    from entries e
    join level_depth ld
      on ld.level_id = e.level_id
   where e.version_id = ?
     and e.sub_type_id is not null
     and e.base_type_id is not null
     and e.cost %s
group by e.base_type_id
       , e.sub_type_id
       , e.seed
|}
    position
;;

let typed_prop_lists_sql position =
  sprintf
    {|
  select e.base_type_id
       , p.prop_id
       , e.seed
       , min(ld.depth)
       , sum(coalesce(e.quantity, 1))
    from entry_props p
    join entries e
      on e.id = p.entry_id
    join level_depth ld
      on ld.level_id = e.level_id
   where p.version_id = ?
     and p.value >= ?
     and e.base_type_id is not null
     and e.cost %s
group by e.base_type_id
       , p.prop_id
       , e.seed
|}
    position
;;

let bare_prop_lists_sql position =
  sprintf
    {|
  select null
       , p.prop_id
       , e.seed
       , min(ld.depth)
       , sum(coalesce(e.quantity, 1))
    from entry_props p
    join entries e
      on e.id = p.entry_id
    join level_depth ld
      on ld.level_id = e.level_id
   where p.version_id = ?
     and p.value >= ?
     and e.cost %s
group by p.prop_id
       , e.seed
|}
    position
;;

let list_queries ~version_id =
  let version = [ int_bind version_id ] in
  let prop = [ int_bind version_id; int_bind Search.Prop.min_value ] in
  [ Criterion_id.Kind.Floor_item, item_lists_sql "is null", version
  ; Criterion_id.Kind.Shop_item, item_lists_sql "is not null", version
  ; Criterion_id.Kind.Floor_prop, typed_prop_lists_sql "is null", prop
  ; Criterion_id.Kind.Floor_prop, bare_prop_lists_sql "is null", prop
  ; Criterion_id.Kind.Shop_prop, typed_prop_lists_sql "is not null", prop
  ; Criterion_id.Kind.Shop_prop, bare_prop_lists_sql "is not null", prop
  ]
;;

let ordinals db ~version_id =
  let table = String.Table.create () in
  let%map.Or_error () =
    Sql.with_stmt
      db
      seed_ordinals_sql
      ~bind:[ int_bind version_id ]
      ~f:(fun stmt ->
        Sql.fold_rows stmt ~init:() ~f:(fun () row ->
          let%bind.Or_error seed = Sql.required row 0 ~field:"seed" in
          match Sql.column_int row 1 with
          | None -> Or_error.errorf "seed %s has a null ordinal" seed
          | Some ord -> Ok (Hashtbl.set table ~key:seed ~data:ord)))
  in
  table
;;

(* [level_id] is a strings id and carries no order, so depth comes from the
   level name through [Depth.of_level], which SQLite cannot call. *)
let fill_level_depth db ~version_id =
  let open Or_error.Let_syntax in
  Sql.exec_script db level_depth_ddl;
  let%bind levels =
    Sql.with_stmt
      db
      level_names_sql
      ~bind:[ int_bind version_id ]
      ~f:(fun stmt ->
        Sql.fold_rows stmt ~init:[] ~f:(fun acc row ->
          let%bind level = Sql.required row 1 ~field:"level" in
          match Sql.column_int row 0 with
          | None -> Or_error.errorf "level %s has a null id" level
          | Some level_id -> Ok ((level_id, level) :: acc)))
  in
  Sql.with_stmt db insert_level_depth_sql ~bind:[] ~f:(fun stmt ->
    List.iter levels ~f:(fun (level_id, level) ->
      bind_all stmt [ int_bind level_id; int_bind (Depth.of_level level) ];
      step_reset stmt);
    Ok ())
;;

let build_lists db ~version_id ~ords =
  let seen = Hash_set.Poly.create () in
  Sql.with_stmt db insert_criterion_sql ~bind:[] ~f:(fun criterion_stmt ->
    Sql.with_stmt db insert_posting_sql ~bind:[] ~f:(fun posting_stmt ->
      let flush ~kind ~a_id ~b_id ~postings =
        (* Each build query groups by its key, so a key arrives once and its rows
           arrive together; a repeat would mint a second catalog row for it and
           the read side would find only one. *)
        Hash_set.strict_add_exn seen (Criterion_id.Kind.to_int kind, a_id, b_id);
        let postings =
          List.sort postings ~compare:(fun (a : Posting.t) b -> Int.compare a.ord b.ord)
        in
        bind_all
          criterion_stmt
          [ int_bind version_id
          ; kind_bind kind
          ; id_bind a_id
          ; id_bind b_id
          ; int_bind (List.length postings)
          ];
        step_reset criterion_stmt;
        let criterion_id = Sqlite3.last_insert_rowid db in
        List.iter (List.chunks_of postings ~length:Posting.block_size) ~f:(fun block ->
          let first = List.hd_exn block in
          bind_all
            posting_stmt
            [ Sqlite3.Data.INT criterion_id
            ; int_bind first.Posting.ord
            ; int_bind (List.length block)
            ; Sqlite3.Data.BLOB (Posting.encode_block block)
            ];
          step_reset posting_stmt)
      in
      List.map (list_queries ~version_id) ~f:(fun (kind, sql, bind) ->
        Sql.with_stmt db sql ~bind ~f:(fun stmt ->
          let current = ref None in
          let buffer = ref [] in
          let flush_current () =
            match !current with
            | None -> ()
            | Some (a_id, b_id) ->
              flush ~kind ~a_id ~b_id ~postings:!buffer;
              current := None;
              buffer := []
          in
          let%map.Or_error () =
            Sql.fold_rows stmt ~init:() ~f:(fun () row ->
              let a_id = Sql.column_int row 0 in
              let b_id = Sql.column_int row 1 in
              let%bind.Or_error seed = Sql.required row 2 ~field:"seed" in
              match Hashtbl.find ords seed with
              | None -> Or_error.errorf "seed %s has no ordinal" seed
              | Some ord ->
                (match Sql.column_int row 3, Sql.column_int row 4 with
                 | Some depth, Some count ->
                   let key = a_id, b_id in
                   if not ([%equal: (int option * int option) option] !current (Some key))
                   then (
                     flush_current ();
                     current := Some key);
                   buffer := { Posting.ord; depth; count } :: !buffer;
                   Ok ()
                 | None, _ | _, None ->
                   Or_error.errorf "seed %s has a null depth or count" seed))
          in
          flush_current ()))
      |> Or_error.all_unit))
;;

let build db ~version =
  let ok = Or_error.ok_exn in
  match
    Sql.with_immediate_txn db ~f:(fun db ->
      let built_through =
        Option.value (ok (scalar_int db max_entry_id_sql ~bind:[])) ~default:0
      in
      let version_id = ok (version_id_of db ~version) in
      let built_seeds =
        Option.value
          (ok (scalar_int db seed_count_sql ~bind:[ int_bind version_id ]))
          ~default:0
      in
      let base =
        Option.value
          (ok (scalar_int db max_ord_sql ~bind:[ int_bind version_id ]))
          ~default:(-1)
      in
      ok
        (exec_bound
           db
           assign_ordinals_sql
           ~bind:
             [ int_bind version_id
             ; int_bind base
             ; int_bind version_id
             ; int_bind version_id
             ]);
      ok (exec_bound db record_built_depth_sql ~bind:[ int_bind version_id ]);
      ok (fill_level_depth db ~version_id);
      ok (exec_bound db drop_postings_sql ~bind:[ int_bind version_id ]);
      ok (exec_bound db drop_criteria_sql ~bind:[ int_bind version_id ]);
      let ords = ok (ordinals db ~version_id) in
      ok (build_lists db ~version_id ~ords);
      ok
        (exec_bound
           db
           insert_state_sql
           ~bind:[ int_bind version_id; int_bind built_through; int_bind built_seeds ]))
  with
  | exception exn -> Or_error.of_exn exn
  | () ->
    (* Outside the transaction, as [Db.rebuild_fts] does: a planner with no
       statistics for a new index has cost this corpus a 100x regression twice. *)
    (match Sql.exec_script db "analyze" with
     | exception exn -> Or_error.of_exn exn
     | () -> Ok ())
;;

(* {1 Currency} *)

let is_current_sql =
  sprintf
    {|
  select (select built_seeds
            from search_index_state
           where version_id = %s)
         = (select coalesce(sum(seeds), 0)
              from seed_fill_counts
             where version_id = %s)
|}
    Sql.version_id_sql
    Sql.version_id_sql
;;

let is_current db ~version =
  match
    scalar_int
      db
      is_current_sql
      ~bind:[ Sql.version_bind version; Sql.version_bind version ]
  with
  | Ok (Some flag) -> flag <> 0
  | Ok None | Error _ -> false
;;

(* {1 Read} *)

let string_id_sql = {|select id from strings where val = ?|}

let catalog_sql =
  {|
  select id
       , card
    from search_criteria
   where version_id = ?
     and kind = ?
     and a_id is ?
     and b_id is ?
|}
;;

let ordinal_of_seed_sql =
  {|
  select ord
    from seed_ordinals
   where version_id = ?
     and seed = ?
|}
;;

let block_at_sql =
  {|
  select first_ord
       , n
       , postings
    from search_postings
   where criterion_id = ?
     and first_ord <= ?
order by first_ord desc
   limit 1
|}
;;

let block_after_sql =
  {|
  select first_ord
    from search_postings
   where criterion_id = ?
     and first_ord > ?
order by first_ord
   limit 1
|}
;;

let driver_start_sql =
  {|
  select max(first_ord)
    from search_postings
   where criterion_id = ?
     and first_ord <= ?
|}
;;

let driver_blocks_sql =
  {|
  select n
       , postings
    from search_postings
   where criterion_id = ?
     and first_ord >= ?
order by first_ord
|}
;;

type source =
  | Stored of int
  | Memory

type probe =
  { source : source
  ; card : int
  ; mutable lo : int
  ; mutable hi : int
  ; mutable block : Posting.t array
  }

type resolved =
  { term : Search.Term.t
  ; exact : bool
  ; probes : probe list
  }

(* [n] is checked rather than trusted, which is the only thing that gives the
   column a purpose: the format carries no length, so a blob that lost or gained
   a posting still decodes, and a short block would read as a true answer about
   the corpus.

   The cached block covers the half-open ordinal range [[lo, hi)], so an ordinal
   falling in the gap between two blocks is answered from the cache rather than
   re-seeking. The driver advances monotonically and every list is ordinal
   sorted, which is what turns a probe per candidate per term into a merge. *)
let decode_checked blob ~n =
  let%bind.Or_error block = Posting.decode_block blob in
  if Array.length block = n
  then Ok block
  else
    Or_error.error_s
      [%message
        "search_postings block decoded to the wrong length"
          (n : int)
          ~decoded:(Array.length block : int)]
;;

let load_block db p ~criterion_id ~ord =
  let open Or_error.Let_syntax in
  let%bind found =
    first_row
      db
      block_at_sql
      ~bind:[ int_bind criterion_id; int_bind ord ]
      ~f:(fun row ->
        match Sql.column_int row 0, Sql.column_int row 1, column_blob row 2 with
        | Some first, Some n, Some blob -> Ok (Some (first, n, blob))
        | _ -> Or_error.error_string "search_postings row is malformed")
  in
  let%bind next =
    scalar_int db block_after_sql ~bind:[ int_bind criterion_id; int_bind ord ]
  in
  let%map first, block =
    match found with
    | None -> Ok (Int.min_value, [||])
    | Some (first, n, blob) ->
      let%map block = decode_checked blob ~n in
      first, block
  in
  p.lo <- first;
  p.hi <- Option.value next ~default:Int.max_value;
  p.block <- block
;;

let probe db p ~ord =
  let%map.Or_error () =
    match p.source with
    | Memory -> Ok ()
    | Stored criterion_id ->
      if p.lo <= ord && ord < p.hi then Ok () else load_block db p ~criterion_id ~ord
  in
  Posting.find p.block ~ord
;;

(* [None] when the candidate fails, otherwise the shallowest depth over the
   terms' postings. A [Narrowing] term's counts are a superset's counts, not the
   criterion's, so only [Exact] terms have [min_count] settled here. *)
let candidate_depth db resolved ~driver ~driver_posting ~ord =
  List.fold_result resolved ~init:(Some Depth.unknown) ~f:(fun acc r ->
    match acc with
    | None -> Ok None
    | Some depth ->
      List.fold_result r.probes ~init:(Some depth) ~f:(fun acc p ->
        match acc with
        | None -> Ok None
        | Some depth ->
          let%map.Or_error posting =
            if phys_equal p driver then Ok (Some driver_posting) else probe db p ~ord
          in
          (match posting with
           | None -> None
           | Some (posting : Posting.t) ->
             if r.exact && posting.count < r.term.min_count
             then None
             else Some (Int.min depth posting.depth))))
;;

let scan_block block ~from ~init ~f ~next =
  let rec scan i acc =
    if i >= Array.length block
    then next acc
    else (
      match%bind.Or_error f acc block.(i) with
      | acc, `Stop -> Ok acc
      | acc, `Continue -> scan (i + 1) acc)
  in
  scan from init
;;

let walk_driver db driver ~start ~init ~f =
  let open Or_error.Let_syntax in
  match driver.source with
  | Memory ->
    scan_block
      driver.block
      ~from:(Posting.lower_bound driver.block ~ord:start)
      ~init
      ~f
      ~next:Or_error.return
  | Stored criterion_id ->
    let%bind first =
      let%map first =
        scalar_int db driver_start_sql ~bind:[ int_bind criterion_id; int_bind start ]
      in
      Option.value first ~default:start
    in
    Sql.with_stmt
      db
      driver_blocks_sql
      ~bind:[ int_bind criterion_id; int_bind first ]
      ~f:(fun stmt ->
        let rec loop acc =
          match Sqlite3.step stmt with
          | Sqlite3.Rc.DONE -> Ok acc
          | Sqlite3.Rc.ROW ->
            let row = Sqlite3.row_data stmt in
            (match Sql.column_int row 0, column_blob row 1 with
             | None, _ | _, None ->
               Or_error.error_string "search_postings row is malformed"
             | Some n, Some blob ->
               let%bind block = decode_checked blob ~n in
               scan_block
                 block
                 ~from:(Posting.lower_bound block ~ord:start)
                 ~init:acc
                 ~f
                 ~next:loop)
          | rc -> Or_error.errorf "step: %s" (Sqlite3.Rc.to_string rc)
        in
        loop init)
;;

let seeds_of_ords db ~version_id ords =
  match ords with
  | [] -> Ok []
  | ords ->
    let open Or_error.Let_syntax in
    let placeholders = List.map ords ~f:(fun _ -> "?") |> String.concat ~sep:", " in
    let sql =
      sprintf
        {|
  select ord
       , seed
    from seed_ordinals
   where version_id = ?
     and ord in (%s)
|}
        placeholders
    in
    let%bind found =
      Sql.with_stmt
        db
        sql
        ~bind:(int_bind version_id :: List.map ords ~f:int_bind)
        ~f:(fun stmt ->
          Sql.fold_rows stmt ~init:Int.Map.empty ~f:(fun acc row ->
            let%map seed = Sql.required row 1 ~field:"seed" in
            match Sql.column_int row 0 with
            | None -> acc
            | Some ord -> Map.set acc ~key:ord ~data:seed))
    in
    List.map ords ~f:(fun ord ->
      match Map.find found ord with
      | Some seed -> Ok seed
      | None -> Or_error.errorf "ordinal %d names no seed" ord)
    |> Or_error.all
;;

let operand_id db operand =
  match operand with
  | None -> Ok (Some Sqlite3.Data.NULL)
  | Some value ->
    let%map.Or_error id = scalar_int db string_id_sql ~bind:[ Sqlite3.Data.TEXT value ] in
    Option.map id ~f:int_bind
;;

let resolve_key db ~version_id (key : Criterion_id.key) =
  let open Or_error.Let_syntax in
  let%bind a = operand_id db key.a in
  let%bind b = operand_id db key.b in
  match a, b with
  | Some a, Some b ->
    first_row
      db
      catalog_sql
      ~bind:[ int_bind version_id; kind_bind key.kind; a; b ]
      ~f:(fun row ->
        match Sql.column_int row 0, Sql.column_int row 1 with
        | Some id, Some card -> Ok (Some (id, card))
        | None, _ | _, None -> Or_error.error_string "search_criteria row is malformed")
  | None, _ | _, None -> Ok None
;;

let is_exact (id : Criterion_id.t) =
  match id with
  | Criterion_id.Exact _ -> true
  | Criterion_id.Narrowing _ | Criterion_id.Unindexed -> false
;;

(* An [Unindexed] term other than [name~] declines the whole search: it has
   nothing to narrow with, and re-checking it per candidate batch would walk the
   driver's whole list. [name~] instead resolves to seeds first (see
   [resolve_names]). A [Narrowing] term keeps the two-stage shape: it has lists
   of its own, so [verify] only ever sees candidates the store already cut down. *)
let declines ~ids =
  List.exists ids ~f:(fun ((term : Search.Term.t), id) ->
    match term.criterion with
    | Search.Criterion.Name_like _ -> false
    | Search.Criterion.Item _
    | Search.Criterion.Feature _
    | Search.Criterion.Unique _
    | Search.Criterion.Props _ -> List.is_empty (Criterion_id.keys id))
;;

(* {1 [name~] as a posting list} *)

(* 97.5% of human fragment occurrences resolve to at most this many seeds, and
   resolution near it costs ~0.5s ([hat]: 23,639 seeds, 0.55s) (1.3M, 0.34.1,
   D:8, prod, 2026-09-26). *)
let max_name_seeds = 20_000

let name_rows_sql ~where =
  sprintf
    {|
   select o.ord
        , s_level.val
        , e.quantity
     from entries e
     join strings s_level
       on s_level.id = e.level_id
left join seed_ordinals o
       on o.version_id = e.version_id
      and o.seed = e.seed
    where e.version_id = ?
      and %s
|}
    where
;;

(* [None] past [cap] seeds, or for a seed with no ordinal ({!is_current} has
   ruled that out; belt and braces). Depth and count are the builder's:
   [Depth.of_level] of the level name, and [sum(coalesce(quantity, 1))]. *)
let resolve_name db ~version_id ~criterion_where ~cap criterion =
  let where, bind = criterion_where criterion ~alias:"e" in
  let postings = Int.Table.create () in
  Sql.with_stmt
    db
    (name_rows_sql ~where)
    ~bind:(int_bind version_id :: bind)
    ~f:(fun stmt ->
      let rec loop () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.DONE ->
          Ok
            (Some
               (Hashtbl.to_alist postings
                |> List.map ~f:(fun (ord, (depth, count)) ->
                  { Posting.ord; depth; count })
                |> List.sort ~compare:(fun (a : Posting.t) b -> Int.compare a.ord b.ord)
                |> Array.of_list))
        | Sqlite3.Rc.ROW ->
          let row = Sqlite3.row_data stmt in
          let%bind.Or_error level = Sql.required row 1 ~field:"level" in
          (match Sql.column_int row 0 with
           | None -> Ok None
           | Some ord ->
             let depth = Depth.of_level level in
             let quantity = Option.value (Sql.column_int row 2) ~default:1 in
             Hashtbl.update postings ord ~f:(function
               | None -> depth, quantity
               | Some (d, c) -> Int.min d depth, c + quantity);
             if Hashtbl.length postings > cap then Ok None else loop ())
        | rc -> Or_error.errorf "step: %s" (Sqlite3.Rc.to_string rc)
      in
      loop ())
;;

type term_source =
  | Catalog of Criterion_id.t
  | Resolved of Posting.t array

let resolve_names db ~version_id ~criterion_where ~cap ids =
  List.fold_result ids ~init:(Some []) ~f:(fun acc ((term : Search.Term.t), id) ->
    match acc with
    | None -> Ok None
    | Some acc ->
      (match term.criterion with
       | Search.Criterion.Name_like _ ->
         let%map.Or_error postings =
           resolve_name db ~version_id ~criterion_where ~cap term.criterion
         in
         Option.map postings ~f:(fun postings -> (term, Resolved postings) :: acc)
       | Search.Criterion.Item _
       | Search.Criterion.Feature _
       | Search.Criterion.Unique _
       | Search.Criterion.Props _ -> Ok (Some ((term, Catalog id) :: acc))))
  |> Or_error.map ~f:(Option.map ~f:List.rev)
;;

(* {1 The deep-cohort overlay}

   The dirty set is every seed whose [seed_fills.depth] exceeds the
   [seed_ordinals.built_depth] the build recorded for it. The mark is per seed
   and written in the build's own transaction, from the snapshot the postings
   were read from, so there is no window between the two for a deepen to land
   in -- the race the [strings_fts_state] comment warns about. A seed with no
   recorded depth counts as deepened. *)

(* The store declines past this and the caller takes the SQL path whole. Not
   measured as a crossover: the overlay cost ~13ms per term over 206 seeds (prod,
   1.3M, 2026-09-16), so this is a bound on a linear cost rather than the point
   where it loses. A rebuild empties the cohort, so it only grows between builds,
   and at ~20 deepens/day that is most of a year. *)
let max_overlay_cohort = 5_000

let cohort_sql =
  {|
  select f.seed
       , o.ord
    from seed_fills f
    left join seed_ordinals o
      on o.version_id = f.version_id
     and o.seed = f.seed
   where f.version_id = ?
     and f.depth > ?
     and (o.built_depth is null or f.depth > o.built_depth)
   limit ?
|}
;;

type overlay =
  { dirty : Int.Hash_set.t (* ordinals to subtract from the posting stream *)
  ; matched : (int * string * Depth.t) list (* ascending by ordinal *)
  }

let no_overlay = { dirty = Int.Hash_set.create (); matched = [] }

(* [None] declines the whole search. A cohort member without an ordinal is a
   corpus ingested into since the build, which {!is_current} has already ruled
   out -- belt and braces, as with the [Seed] cursor.

   The [limit] is [max_overlay_cohort + 1], which is what makes the safety valve
   a valve: one row over the cap is enough to decline, and the scan and the list
   are both bounded by the cap rather than by however deep the corpus got. *)
let load_cohort db ~version_id =
  let%bind.Or_error cohort =
    Sql.with_stmt
      db
      cohort_sql
      ~bind:
        [ int_bind version_id
        ; int_bind Fill_depth.shallow
        ; int_bind (max_overlay_cohort + 1)
        ]
      ~f:(fun stmt ->
        Sql.fold_rows stmt ~init:(Some []) ~f:(fun acc row ->
          let%map.Or_error seed = Sql.required row 0 ~field:"seed" in
          match acc, Sql.column_int row 1 with
          | None, _ | _, None -> None
          | Some acc, Some ord -> Some ((ord, seed) :: acc)))
  in
  match cohort with
  | Some cohort when List.length cohort <= max_overlay_cohort ->
    Ok (Some (List.sort cohort ~compare:(fun (a, _) (b, _) -> Int.compare a b)))
  | Some _ | None -> Ok None
;;

let cohort db ~version =
  let%bind.Or_error version_id = version_id_of db ~version in
  let%map.Or_error cohort = load_cohort db ~version_id in
  Option.map cohort ~f:(List.map ~f:snd)
;;

(* The cohort's seeds go in as one bound list: [max_overlay_cohort] is well under
   SQLite's 32,766-variable limit. *)
let catalog_pairs_sql =
  sprintf
    {|
  select b.val || ':' || s.val
    from search_criteria c
    join strings b
      on b.id = c.a_id
    join strings s
      on s.id = c.b_id
   where c.version_id = ?
     and c.kind in (%d, %d)
|}
    (Criterion_id.Kind.to_int Floor_item)
    (Criterion_id.Kind.to_int Shop_item)
;;

let item_pairs_sql ~seed_count =
  sprintf
    {|%s
   union
  select b.val || ':' || s.val
    from entries e
    join strings b
      on b.id = e.base_type_id
    join strings s
      on s.id = e.sub_type_id
   where e.version_id = ?
     and e.seed in (%s)
     and e.sub_type_id is not null
order by 1
|}
    catalog_pairs_sql
    (List.init seed_count ~f:(fun _ -> "?") |> String.concat ~sep:", ")
;;

let pairs_of_stmt stmt =
  Sql.fold_rows stmt ~init:[] ~f:(fun acc row ->
    let%map.Or_error pair = Sql.required row 0 ~field:"pair" in
    pair :: acc)
  |> Or_error.map ~f:List.rev
;;

let item_pairs db ~version =
  if not (is_current db ~version)
  then Ok None
  else (
    let%bind.Or_error version_id = version_id_of db ~version in
    match%bind.Or_error load_cohort db ~version_id with
    | None -> Ok None
    | Some cohort ->
      Sql.with_stmt
        db
        (item_pairs_sql ~seed_count:(List.length cohort))
        ~bind:
          (int_bind version_id
           :: int_bind version_id
           :: List.map cohort ~f:(fun (_, seed) -> Sqlite3.Data.TEXT seed))
        ~f:pairs_of_stmt
      |> Or_error.map ~f:Option.some)
;;

let catalog_item_pairs db ~version =
  if not (is_current db ~version)
  then Ok None
  else (
    let%bind.Or_error version_id = version_id_of db ~version in
    Sql.with_stmt
      db
      (catalog_pairs_sql ^ "order by 1")
      ~bind:[ int_bind version_id ]
      ~f:pairs_of_stmt
    |> Or_error.map ~f:Option.some)
;;

let resolve_overlay ~cohort ~terms ~cohort_matches =
  match cohort with
  | [] -> Ok no_overlay
  | cohort ->
    let%map.Or_error depths =
      cohort_matches ~seeds:(List.map cohort ~f:snd) ~terms
      |> Or_error.map ~f:String.Map.of_alist_exn
    in
    { dirty = Int.Hash_set.of_list (List.map cohort ~f:fst)
    ; matched =
        List.filter_map cohort ~f:(fun (ord, seed) ->
          Option.map (Map.find depths seed) ~f:(fun depth -> ord, seed, depth))
    }
;;

(* The store's contribution to a page: the resolved terms and the rarest of
   their lists to drive on. [None] when some term has no catalog row at all, in
   which case the overlay is the whole answer. *)
type store =
  { resolved : resolved list
  ; driver : probe
  }

let stored_candidates db { resolved; driver } ~dirty ~start ~init ~f =
  walk_driver db driver ~start ~init ~f:(fun acc (posting : Posting.t) ->
    if Hash_set.mem dirty posting.ord
    then Ok (acc, `Continue)
    else (
      let%bind.Or_error depth =
        candidate_depth db resolved ~driver ~driver_posting:posting ~ord:posting.ord
      in
      match depth with
      | None -> Ok (acc, `Continue)
      | Some depth -> f acc ~ord:posting.ord ~depth ~driver_posting:posting))
;;

let ranked_page db ~store ~overlay ~version_id ~(search : Search.t) ~verify_depth =
  let open Or_error.Let_syntax in
  let%bind matched =
    match store with
    | None -> Ok []
    | Some ({ resolved; driver; _ } as store) ->
      (match List.filter resolved ~f:(fun r -> not r.exact) with
       | [] ->
         stored_candidates
           db
           store
           ~dirty:overlay.dirty
           ~start:0
           ~init:[]
           ~f:(fun acc ~ord ~depth ~driver_posting:_ ->
             Ok ((depth, ord) :: acc, `Continue))
       | narrowing ->
         let exact = List.filter resolved ~f:(fun r -> r.exact) in
         let narrowing_terms = List.map narrowing ~f:(fun r -> r.term) in
         (* [Db.overlay_batch]'s own budget for a SQL [in]-list, not
            [Posting.block_size] -- an unrelated codec constant that happened
            to be close. *)
         let batch_size = 500 in
         let pending = ref [] in
         let pending_n = ref 0 in
         let acc = ref [] in
         let flush () =
           let batch = List.rev !pending in
           pending := [];
           pending_n := 0;
           if List.is_empty batch
           then Ok ()
           else (
             let ords = List.map batch ~f:fst in
             let%bind seeds = seeds_of_ords db ~version_id ords in
             let%map depths =
               verify_depth ~seeds ~terms:narrowing_terms
               |> Or_error.map ~f:String.Map.of_alist_exn
             in
             List.iter (List.zip_exn batch seeds) ~f:(fun ((ord, exact_depth), seed) ->
               match Map.find depths seed with
               | None -> ()
               | Some narrowing_depth ->
                 acc := (Int.min exact_depth narrowing_depth, ord) :: !acc))
         in
         let%bind () =
           stored_candidates
             db
             store
             ~dirty:overlay.dirty
             ~start:0
             ~init:()
             ~f:(fun () ~ord ~depth:_ ~driver_posting ->
               let%bind exact_depth =
                 candidate_depth db exact ~driver ~driver_posting ~ord
               in
               match exact_depth with
               | None -> Ok ((), `Continue)
               | Some exact_depth ->
                 pending := (ord, exact_depth) :: !pending;
                 incr pending_n;
                 if !pending_n < batch_size
                 then Ok ((), `Continue)
                 else (
                   let%map () = flush () in
                   (), `Continue))
         in
         let%map () = flush () in
         !acc)
  in
  let sorted =
    List.map overlay.matched ~f:(fun (ord, _, depth) -> depth, ord) @ matched
    |> List.sort ~compare:(fun (d1, o1) (d2, o2) ->
      match Int.compare d1 d2 with
      | 0 -> Int.compare o1 o2
      | c -> c)
  in
  let after =
    match search.page.after with
    | None -> 0
    | Some cursor -> Option.value (Int.of_string_opt cursor) ~default:0
  in
  let page, more =
    match List.split_n (List.drop sorted after) search.page.limit with
    | page, [] -> page, `End
    | page, _ -> page, `More
  in
  let%map seeds = seeds_of_ords db ~version_id (List.map page ~f:snd) in
  seeds, more
;;

(* Ordinal order is the store's own order, so the overlay interleaves into it
   rather than being appended: its seeds are already verified, and each is
   drained into [kept] before the first stored candidate that outranks it. A
   batch's candidates come off the driver ascending, so draining per candidate
   at flush time is enough to keep the whole page ordinal-sorted -- which is
   what a keyset cursor over it needs to neither repeat nor skip. *)
let seed_page db ~store ~overlay ~version_id ~(search : Search.t) ~start ~verify =
  let open Or_error.Let_syntax in
  let verify_terms =
    match store with
    | None -> []
    | Some { resolved; _ } ->
      List.filter_map resolved ~f:(fun r -> Option.some_if (not r.exact) r.term)
  in
  let batch_size = Int.max search.page.limit 32 in
  let want = search.page.limit + 1 in
  let pending = ref [] in
  let pending_n = ref 0 in
  let kept = ref [] in
  let kept_n = ref 0 in
  let queue = ref (List.filter overlay.matched ~f:(fun (ord, _, _) -> ord >= start)) in
  let keep seed =
    kept := seed :: !kept;
    incr kept_n
  in
  let rec drain_before ord =
    match !queue with
    | (o, seed, _) :: rest when o < ord ->
      queue := rest;
      keep seed;
      drain_before ord
    | _ -> ()
  in
  let flush () =
    let ords = List.rev !pending in
    pending := [];
    pending_n := 0;
    let%bind seeds = seeds_of_ords db ~version_id ords in
    let%map candidates =
      let candidates = List.zip_exn ords seeds in
      if List.is_empty verify_terms
      then Ok candidates
      else (
        let%map survived = verify ~seeds ~terms:verify_terms in
        List.filter candidates ~f:(fun (_, seed) -> Set.mem survived seed))
    in
    List.iter candidates ~f:(fun (ord, seed) ->
      drain_before ord;
      keep seed)
  in
  let%bind () =
    match store with
    | None -> Ok ()
    | Some store ->
      stored_candidates
        db
        store
        ~dirty:overlay.dirty
        ~start
        ~init:()
        ~f:(fun () ~ord ~depth:_ ~driver_posting:_ ->
          pending := ord :: !pending;
          incr pending_n;
          if !pending_n < batch_size
          then Ok ((), `Continue)
          else (
            let%map () = flush () in
            (), if !kept_n >= want then `Stop else `Continue))
  in
  let%map () = if !pending_n > 0 then flush () else Ok () in
  (* Whatever the queue still holds outranks every candidate the driver
     reached, so it can only be drained once the walk is over. *)
  if !kept_n < want then List.iter !queue ~f:(fun (_, seed, _) -> keep seed);
  match List.split_n (List.rev !kept) search.page.limit with
  | page, [] -> page, `End
  | page, _ -> page, `More
;;

let resolve_store db ~version_id terms =
  let open Or_error.Let_syntax in
  let probes = Int.Table.create () in
  let stored (criterion_id, card) =
    Hashtbl.find_or_add probes criterion_id ~default:(fun () ->
      { source = Stored criterion_id
      ; card
      ; lo = Int.max_value
      ; hi = Int.min_value
      ; block = [||]
      })
  in
  let%map per_term =
    List.map terms ~f:(fun (term, source) ->
      match source with
      | Resolved postings ->
        Ok
          (Some
             { term
             ; exact = true
             ; probes =
                 [ { source = Memory
                   ; card = Array.length postings
                   ; lo = Int.min_value
                   ; hi = Int.max_value
                   ; block = postings
                   }
                 ]
             })
      | Catalog id ->
        let%map rows =
          List.map (Criterion_id.keys id) ~f:(resolve_key db ~version_id) |> Or_error.all
        in
        Option.map (Option.all rows) ~f:(fun rows ->
          { term; exact = is_exact id; probes = List.map rows ~f:stored }))
    |> Or_error.all
  in
  Option.bind (Option.all per_term) ~f:(fun resolved ->
    List.concat_map resolved ~f:(fun r -> r.probes)
    |> List.min_elt ~compare:(fun a b -> Int.compare a.card b.card)
    |> Option.map ~f:(fun driver -> { resolved; driver }))
;;

let page
      ?(name_cap = max_name_seeds)
      db
      (search : Search.t)
      ~rank
      ~criterion_where
      ~verify
      ~verify_depth
      ~cohort_matches
  =
  let open Or_error.Let_syntax in
  let ids =
    List.map search.terms ~f:(fun term ->
      term, Criterion_id.of_criterion term.Search.Term.criterion)
  in
  if
    List.is_empty search.terms
    || declines ~ids
    || not (is_current db ~version:search.version)
  then Ok None
  else (
    let%bind version_id = version_id_of db ~version:search.version in
    match%bind load_cohort db ~version_id with
    | None -> Ok None
    | Some cohort ->
      (match%bind resolve_names db ~version_id ~criterion_where ~cap:name_cap ids with
       | None -> Ok None
       | Some terms ->
         let%bind overlay = resolve_overlay ~cohort ~terms:search.terms ~cohort_matches in
         let%bind store = resolve_store db ~version_id terms in
         (* A key with no catalog row is a true answer about the *build*, which is
         no longer a true answer about the corpus: a deepened level can mint a
         criterion the build never saw. So the store contributing nothing is a
         page of overlay, not a page of nothing. *)
         (match (rank : Search.Rank.t) with
          | Search.Rank.Shallowest ->
            let%map page =
              ranked_page db ~store ~overlay ~version_id ~search ~verify_depth
            in
            Some page
          | Search.Rank.Seed ->
            let%bind start =
              match search.page.after with
              | None -> Ok (Some 0)
              | Some seed ->
                let%map ord =
                  scalar_int
                    db
                    ordinal_of_seed_sql
                    ~bind:[ int_bind version_id; Sqlite3.Data.TEXT seed ]
                in
                Option.map ord ~f:(fun ord -> ord + 1)
            in
            (match start with
             | None -> Ok None
             | Some start ->
               let%map page =
                 seed_page db ~store ~overlay ~version_id ~search ~start ~verify
               in
               Some page))))
;;
