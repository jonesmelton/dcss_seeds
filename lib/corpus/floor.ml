open! Core

module Shop = struct
  type t =
    { name : string
    ; shop_type : string option
    ; x : int option
    ; y : int option
    ; stock : Record.Entry.t list
    ; total : int
    ; artefacts : int
    }
  [@@deriving sexp_of, fields]
end

module Altar = struct
  type t =
    { feat : string
    ; god : string
    ; in_pool : bool
    }
  [@@deriving compare, sexp_of, fields]
end

type t =
  { notable : Record.Entry.t list
  ; sundries : Record.Entry.t list
  ; monsters : Record.Entry.t list
  ; altars : Altar.t list
  ; ways_on : Record.Entry.t list
  ; features : Record.Entry.t list
  ; shops : Shop.t list
  }
[@@deriving sexp_of, fields]

let is_shop (e : Record.Entry.t) =
  match e.feat with
  | Some "enter_shop" -> true
  | _ -> false
;;

let is_altar (e : Record.Entry.t) =
  match e.feat with
  | Some feat -> String.is_prefix feat ~prefix:"altar_"
  | None -> false
;;

let is_way_on (e : Record.Entry.t) =
  match e.feat with
  | Some feat -> String.is_prefix feat ~prefix:"enter_" && not (is_shop e)
  | None -> false
;;

(* A named book carries no artefact flag and no enchantment, but its spell set
   is as much the reason to pick it up, and no part of its name says what the
   set holds. A parchment states its own contents and is an ordinary
   consumable. *)
let names_its_spells (e : Record.Entry.t) =
  match e.spells with
  | [] -> true
  | [ spell ] -> String.is_suffix e.name ~suffix:spell
  | _ -> false
;;

(* Crawl builds a consumable's name as "[N ]<base>s of <sub_type>". Reconstructed
   from the stored pair and matched exactly rather than pattern-matched off the
   front, so a name of an unexpected shape keeps all of itself -- which is what
   keeps this from eating an unrand's name on some future item class. *)
let display_name (e : Record.Entry.t) =
  match e.base_type, e.sub_type with
  | Some "book", Some sub
    when String.equal e.name sub && Option.is_some (Spell.of_parchment sub) ->
    Option.value (String.chop_prefix sub ~prefix:"parchment of ") ~default:e.name
  | Some (("potion" | "scroll") as base), Some sub ->
    let singular = sprintf "%s of %s" base sub in
    if String.equal e.name singular
    then sub
    else (
      match String.lsplit2 e.name ~on:' ' with
      | Some (qty, rest)
        when String.for_all qty ~f:Char.is_digit
             && String.equal rest (sprintf "%ss of %s" base sub) -> qty ^ " " ^ sub
      | _ -> e.name)
  | _ -> e.name
;;

(* Boons first, then artefacts, then enchanted/books, then sundries.
   [stable_sort] keeps storage's order within a group. *)
let significance (e : Record.Entry.t) =
  if Option.is_some (Boon.of_entry e)
  then 0
  else (
    match e.artefact, e.ego, e.branded with
    | Some true, _, _ -> 1
    | _, Some _, _ | _, _, Some true -> 2
    | _ -> if names_its_spells e then 3 else 2)
;;

let of_level (l : Level.t) : t =
  let items, monsters, features =
    List.partition3_map l.entries ~f:(fun e ->
      match e.cat with
      | Record.Cat.Items -> `Fst e
      | Record.Cat.Monsters -> `Snd e
      (* Vaults are pruned at ingest, so they can only appear here from a corpus
         filled before that; they group with features rather than being silently
         dropped a second time. *)
      | Record.Cat.Features | Record.Cat.Vaults -> `Trd e)
  in
  let shop_feats, features = List.partition_tf features ~f:is_shop in
  let stock, items = List.partition_tf items ~f:(fun e -> Option.is_some e.cost) in
  let square (e : Record.Entry.t) = e.x, e.y in
  let stock_at =
    Hashtbl.of_alist_multi
      (module struct
        type t = int option * int option [@@deriving compare, hash, sexp_of]
      end)
      (List.map stock ~f:(fun e -> square e, e))
  in
  let shops =
    List.map shop_feats ~f:(fun (e : Record.Entry.t) ->
      let stock =
        Hashtbl.find_multi stock_at (square e)
        |> List.rev
        |> List.stable_sort
             ~compare:
               (Comparable.reverse
                  (Comparable.lift Int.compare ~f:(fun (e : Record.Entry.t) ->
                     Option.value e.cost ~default:0)))
      in
      { Shop.name = e.name
      ; shop_type = e.shop_type
      ; x = e.x
      ; y = e.y
      ; stock
      ; total = List.sum (module Int) stock ~f:(fun e -> Option.value e.cost ~default:0)
      ; artefacts =
          List.count stock ~f:(fun (e : Record.Entry.t) ->
            Option.value e.artefact ~default:false)
      })
  in
  let altar_feats, features = List.partition_tf features ~f:is_altar in
  let ways_on, features = List.partition_tf features ~f:is_way_on in
  (* A Temple's pool gods live in the mask and the rest live in rows, so nothing
     above this ever learns which god came from which storage. *)
  let altars =
    let of_feat feat =
      { Altar.feat
      ; god = Temple.god_name feat
      ; (* The faded altar is neither a god nor a rarity -- it stands on 59% of seeds.
           It is outside the pool only because crawl does not place it in a
           Temple. *)
        in_pool =
          Option.is_some (Temple.of_feat feat) || String.equal feat "altar_ecumenical"
      }
    in
    let from_rows =
      List.filter_map altar_feats ~f:(fun (e : Record.Entry.t) ->
        Option.map e.feat ~f:of_feat)
    in
    let from_mask =
      match l.temple_altars with
      | None -> []
      | Some mask -> Temple.to_feats (Temple.of_int mask) |> List.map ~f:of_feat
    in
    from_rows @ from_mask
    |> List.sort ~compare:(fun (a : Altar.t) b ->
      match Bool.compare a.in_pool b.in_pool with
      | 0 -> String.compare a.god b.god
      | c -> c)
  in
  let notable, sundries =
    List.stable_sort items ~compare:(Comparable.lift Int.compare ~f:significance)
    |> List.partition_tf ~f:(fun e -> significance e < 3)
  in
  { notable; sundries; monsters; altars; ways_on; features; shops }
;;

(* Phrases, not counts: each fact is a noun carrying its own number. Only what
   is true is printed -- an ordinary floor says nothing here. *)
let standing_facts (t : t) (l : Level.t) =
  let plural n singular = if n = 1 then singular else singular ^ "s" in
  let count n singular = sprintf "%d %s" n (plural n singular) in
  let artefacts =
    List.count t.notable ~f:(fun (e : Record.Entry.t) ->
      Option.value e.artefact ~default:false)
  in
  let shop_artefacts = List.sum (module Int) t.shops ~f:Shop.artefacts in
  (* A faded altar is a feature, so it is listed among the altars -- but it is not
     a god a reader can join. *)
  let named_altars =
    List.filter t.altars ~f:(fun (a : Altar.t) ->
      not (String.equal a.feat "altar_ecumenical"))
  in
  List.filter_opt
    [ (match artefacts + shop_artefacts with
       | 0 -> None
       | n ->
         let where =
           (* Where the artefacts are is the fact, not how many: a floor's worth
              behind a shop's prices is a different proposition from the same
              number lying on the ground. *)
           match artefacts, shop_artefacts with
           | 0, _ -> ", all for sale"
           | _, 0 -> ""
           | _, s -> sprintf ", %d of them for sale" s
         in
         Some (count n "artefact" ^ where))
      (* An altar on a dungeon floor is named whether or not its god is in the temple
         pool: the fact is that this god can be joined here rather than at the
         Temple. A Temple's own altars are the whole floor and are counted
         instead. *)
    ; (match l.temple_altars, named_altars with
       | Some _, _ | None, [] -> None
       | None, altars -> Some (String.concat ~sep:", " (List.map altars ~f:Altar.god)))
    ; (match t.monsters with
       | [] -> None
       | monsters ->
         Some (String.concat ~sep:", " (List.map monsters ~f:Record.Entry.name)))
    ; (match t.ways_on with
       | [] -> None
       | ways -> Some (count (List.length ways) "way on"))
    ; (match t.shops with
       | [] -> None
       | shops -> Some (count (List.length shops) "shop"))
    ; (match l.temple_altars with
       | None -> None
       | Some mask ->
         Some (count (List.length (Temple.to_feats (Temple.of_int mask))) "altar"))
      (* "floor gold", never "gold": the piles lying on the ground, so monster drops
         and Gozag are outside it and the number is a lower bound. *)
    ; (match l.gold with
       | None | Some 0 -> None
       | Some gold -> Some (sprintf "%d floor gold" gold))
    ]
;;

module Entrance = struct
  type t =
    { branch : string
    ; feat : string
    ; level : string
    ; name : string
    ; x : int option
    ; y : int option
    ; timeout_turns : int option
    ; toll_note : string option
    }
  [@@deriving sexp_of, fields]

  (* Read off the feat rather than looked up, so a build that adds a portal shows
     it without this table being touched. Multi-word feats capitalise only the
     first letter, which is crawl's own spelling of the level name. *)
  let branch_of_feat feat =
    String.chop_prefix feat ~prefix:"enter_"
    |> Option.map ~f:(fun rest -> String.capitalize rest)
  ;;
end

let branch_of_feat = Entrance.branch_of_feat

let entrances levels =
  List.concat_map levels ~f:(fun (l : Level.t) ->
    let depth = Depth.of_level_with_parent ~level:l.level ~parent:l.parent_level in
    List.filter_map l.entries ~f:(fun (e : Record.Entry.t) ->
      if is_shop e
      then None
      else (
        let%bind.Option feat = e.feat in
        branch_of_feat feat
        |> Option.map ~f:(fun branch ->
          ( depth
          , { Entrance.branch
            ; feat
            ; level = l.level
            ; name = e.name
            ; x = e.x
            ; y = e.y
            ; timeout_turns = e.timeout_turns
            ; toll_note = e.toll_note
            } )))))
  |> List.sort ~compare:(fun (d, (a : Entrance.t)) (d', (b : Entrance.t)) ->
    match Depth.compare d d' with
    | 0 -> String.compare a.branch b.branch
    | c -> c)
  |> List.map ~f:snd
;;

(* Storage orders levels by name, which strands every portal and the Temple
   after D:8 and orders D:10 before D:2. A level is placed after the floor its
   entrance stands on: the parent format 2 recorded, or the level holding the
   matching `enter_*` feature. A multi-level branch attaches at its first level,
   so the feat is derived from the branch alone and the rest trails it. *)
let entrance_feat level =
  let branch = Option.value (List.hd (String.split level ~on:':')) ~default:level in
  "enter_" ^ String.lowercase branch
;;

let branch_of level = Option.value (List.hd (String.split level ~on:':')) ~default:level

(* The unit of ordering is a branch, not a floor. A player clears Lair before
   descending the Shoals stair on Lair:2 and does not return to Lair:3 in
   between, so splitting Lair around its sub-branch reads as an interleaving
   that never happens. A portal is the opposite case -- a single excursion off
   one floor -- so it stays inline after the floor holding its entrance. *)
let in_reach_order levels =
  let holder_of feat =
    List.find_map levels ~f:(fun (l : Level.t) ->
      Option.some_if
        (List.exists l.entries ~f:(fun (e : Record.Entry.t) ->
           Option.exists e.feat ~f:(String.equal feat)))
        l.level)
  in
  let held = String.Hash_set.of_list (List.map levels ~f:Level.level) in
  let parent_floor (l : Level.t) =
    match l.parent_level with
    | Some _ as parent -> parent
    | None ->
      (match holder_of (entrance_feat l.level) with
       (* A branch whose own floor holds its entrance would be its own parent: the
          D-level feature row and the level it leads to share a name only for a
          single-level branch read wrongly. *)
       | Some holder when String.equal holder l.level -> None
       | holder -> holder)
  in
  let portals, branch_levels =
    List.partition_tf levels ~f:(fun (l : Level.t) -> Depth.is_portal l.level)
  in
  let portals_by_floor = Hashtbl.create (module String) in
  let orphan_portals =
    List.filter portals ~f:(fun (l : Level.t) ->
      match parent_floor l with
      | Some p when Hash_set.mem held p ->
        Hashtbl.add_multi portals_by_floor ~key:p ~data:l;
        false
      | _ -> true)
  in
  let by_branch = Hashtbl.create (module String) in
  List.iter branch_levels ~f:(fun (l : Level.t) ->
    Hashtbl.add_multi by_branch ~key:(branch_of l.level) ~data:l);
  let branches =
    Hashtbl.map by_branch ~f:(fun ls ->
      List.stable_sort ls ~compare:(fun (a : Level.t) b ->
        Depth.compare (Depth.of_level a.level) (Depth.of_level b.level)))
  in
  let branch_floor branch =
    match parent_floor (List.hd_exn (Hashtbl.find_exn branches branch)) with
    | Some floor when not (String.equal (branch_of floor) branch) -> Some floor
    | _ -> None
  in
  let branches_by_floor = Hashtbl.create (module String) in
  let roots =
    Hashtbl.keys branches
    |> List.filter ~f:(fun branch ->
      match branch_floor branch with
      | Some floor when Hash_set.mem held floor ->
        Hashtbl.add_multi branches_by_floor ~key:floor ~data:branch;
        false
      | _ -> true)
  in
  let depth_of branch =
    Depth.of_level (List.hd_exn (Hashtbl.find_exn branches branch)).level
  in
  let sort_branches =
    List.stable_sort ~compare:(fun a b -> Depth.compare (depth_of a) (depth_of b))
  in
  (* A cycle cannot arise from a tree built out of distinct branch names; the
     visited set makes that structural rather than assumed. *)
  let visited = Hash_set.create (module String) in
  (* Portals nest: a Bailey off an Ossuary follows it, still inside the one floor
     both hang from. *)
  let rec portals_from level =
    Hashtbl.find_multi portals_by_floor level
    |> List.rev
    |> List.concat_map ~f:(fun (l : Level.t) -> l :: portals_from l.level)
  in
  let rec place ~inline branch =
    if Hash_set.mem visited branch
    then []
    else (
      Hash_set.add visited branch;
      let floors = Hashtbl.find_exn branches branch in
      let kids_of (l : Level.t) =
        Hashtbl.find_multi branches_by_floor l.level
        |> List.rev
        |> sort_branches
        |> List.concat_map ~f:(place ~inline:false)
      in
      let floor_run (l : Level.t) = l :: portals_from l.level in
      if inline
      then List.concat_map floors ~f:(fun l -> floor_run l @ kids_of l)
      else List.concat_map floors ~f:floor_run @ List.concat_map floors ~f:kids_of)
  in
  List.concat_map (sort_branches roots) ~f:(place ~inline:true) @ orphan_portals
;;
