open! Core

type t =
  | Derived of string
  | Irreducible
[@@deriving compare, equal, sexp_of]

let to_string_opt = function
  | Derived s -> Some s
  | Irreducible -> None
;;

module Feature = struct
  let of_feat = function
    | "altar_ashenzari" -> Some "a broken altar of Ashenzari"
    | "altar_beogh" -> Some "a roughly hewn altar of Beogh"
    | "altar_cheibriados" -> Some "a snail-covered altar of Cheibriados"
    | "altar_dithmenos" -> Some "a shadowy altar of Dithmenos"
    | "altar_ecumenical" -> Some "a faded altar of an unknown god"
    | "altar_elyvilon" -> Some "a white marble altar of Elyvilon"
    | "altar_fedhas" -> Some "a blossoming altar of Fedhas"
    | "altar_gozag" -> Some "an opulent altar of Gozag"
    | "altar_hepliaklqana" -> Some "a hazy altar of Hepliaklqana"
    | "altar_ignis" -> Some "a candlelit altar of Ignis"
    | "altar_jiyva" -> Some "a viscous altar of Jiyva"
    | "altar_kikubaaqudgha" -> Some "an ancient bone altar of Kikubaaqudgha"
    | "altar_lugonu" -> Some "a corrupted altar of Lugonu"
    | "altar_makhleb" -> Some "a burning altar of Makhleb"
    | "altar_nemelex_xobeh" -> Some "a sparkling altar of Nemelex Xobeh"
    | "altar_okawaru" -> Some "an iron altar of Okawaru"
    | "altar_qazlal" -> Some "a stormy altar of Qazlal"
    | "altar_ru" -> Some "a sacrificial altar of Ru"
    | "altar_sif_muna" -> Some "a shimmering blue altar of Sif Muna"
    | "altar_the_shining_one" -> Some "a glowing golden altar of the Shining One"
    | "altar_trog" -> Some "a bloodstained altar of Trog"
    | "altar_uskayaw" -> Some "a hide-covered altar of Uskayaw"
    | "altar_vehumet" -> Some "a radiant altar of Vehumet"
    | "altar_wu_jian" -> Some "an ornate altar of the Wu Jian Council"
    | "altar_xom" -> Some "a shimmering altar of Xom"
    | "altar_yredelemnul" -> Some "a basalt altar of Yredelemnul"
    | "altar_zin" -> Some "a glowing silver altar of Zin"
    | "enter_abyss" -> Some "a one-way gate to the infinite horrors of the Abyss"
    | "enter_bailey" -> Some "a flagged portal"
    | "enter_bazaar" -> Some "a flickering gateway to a bazaar"
    | "enter_depths" -> Some "a staircase to the Depths"
    | "enter_elven_halls" -> Some "a staircase to the Elven Halls"
    | "enter_gauntlet" -> Some "a gate leading to a gauntlet"
    | "enter_hell" -> Some "a gateway to Hell"
    (* The tier this drops ("a glacial archway", 31%) is the one fact this module
       knowingly destroys; see the .mli. *)
    | "enter_ice_cave" -> Some "a frozen archway"
    | "enter_lair" -> Some "a staircase to the Lair"
    | "enter_necropolis" -> Some "a phantasmal passage"
    | "enter_orcish_mines" -> Some "a staircase to the Orcish Mines"
    | "enter_ossuary" -> Some "a sand-covered staircase"
    | "enter_pandemonium" -> Some "a one-way gate leading to the halls of Pandemonium"
    | "enter_sewer" -> Some "a glowing drain"
    | "enter_shoals" -> Some "a staircase to the Shoals"
    | "enter_slime_pits" -> Some "a staircase to the Slime Pits"
    | "enter_snake_pit" -> Some "a staircase to the Snake Pit"
    | "enter_spider_nest" -> Some "a hole to the Spider Nest"
    | "enter_swamp" -> Some "a staircase to the Swamp"
    | "enter_temple" -> Some "a staircase to the Ecumenical Temple"
    | "enter_trove" -> Some "a portal to a secret trove of treasure"
    | "enter_vaults" -> Some "a gate to the Vaults"
    | "enter_volcano" -> Some "a dark tunnel"
    | "transporter" -> Some "a transporter"
    | _ -> None
  ;;

  (* [shop_type] is a bare classification; some name a shop outright and some
     name only its wares. An empty string is the wire saying nothing, exactly as
     a missing field is. *)
  let shop shop_type =
    match shop_type with
    | None | Some "" -> "a shop"
    | Some "General Store" -> "a General Store"
    | Some "Distillery" -> "a Distillery"
    | Some ty ->
      let article =
        match Char.uppercase ty.[0] with
        | 'A' | 'E' | 'I' | 'O' | 'U' -> "an"
        | _ -> "a"
      in
      sprintf "%s %s Shop" article ty
  ;;
end

module Ego = struct
  (* [ego] is crawl's abbreviated code, not its display word, and a weapon brand
     renders on either side of the base depending only on which brand it is. *)
  let weapon = function
    | "antimagic" -> Some (`Prefix "antimagic")
    | "chaos" -> Some (`Suffix "chaos")
    | "concuss" -> Some (`Suffix "concussion")
    | "devious" -> Some (`Prefix "devious")
    | "distort" -> Some (`Suffix "distortion")
    | "drain" -> Some (`Suffix "draining")
    | "elec" -> Some (`Suffix "electrocution")
    | "entangle" -> Some (`Suffix "entangling")
    | "flame" -> Some (`Suffix "flaming")
    | "freeze" -> Some (`Suffix "freezing")
    | "heavy" -> Some (`Prefix "heavy")
    | "holy" -> Some (`Suffix "holy wrath")
    | "pain" -> Some (`Suffix "pain")
    | "protect" -> Some (`Suffix "protection")
    | "rebuke" -> Some (`Suffix "rebuke")
    | "spect" -> Some (`Prefix "spectral")
    | "speed" -> Some (`Suffix "speed")
    | "sunder" -> Some (`Suffix "sundering")
    | "valour" -> Some (`Suffix "valour")
    | "vamp" -> Some (`Prefix "vampiric")
    | "venom" -> Some (`Suffix "venom")
    | _ -> None
  ;;

  let rec armour = function
    | "+Inv" -> Some "invisibility"
    | "AC+3" -> Some "protection"
    | "Air" -> Some "air"
    | "Archery" -> Some "archery"
    | "Attunement" -> Some "attunement"
    | "Command" -> Some "command"
    | "Death" -> Some "death"
    | "Dex+3" -> Some "dexterity"
    | "Earth" -> Some "earth"
    | "Energy" -> Some "energy"
    | "Fire" -> Some "fire"
    | "Fly" -> Some "flying"
    | "Glass" -> Some "glass"
    | "Guile" -> Some "guile"
    | "Harm" -> Some "harm"
    | "Hurl" -> Some "hurling"
    | "Ice" -> Some "ice"
    | "Infuse" -> Some "infusion"
    | "Int+3" -> Some "intelligence"
    | "Light" -> Some "light"
    | "Mayhem" -> Some "mayhem"
    | "Mesmerism" -> Some "mesmerism"
    | "Parrying" -> Some "parrying"
    | "Ponderous" -> Some "ponderousness"
    | "Pyromania" -> Some "pyromania"
    | "Rampage" -> Some "rampaging"
    | "Reflect" -> Some "reflection"
    | "Repulsion" -> Some "repulsion"
    | "Resonance" -> Some "resonance"
    | "SInv" -> Some "see invisible"
    | "Shadows" -> Some "shadows"
    | "Snipe" -> Some "sniping"
    | "Stardust" -> Some "stardust"
    | "Stlth+" -> Some "stealth"
    | "Str+3" -> Some "strength"
    | "Will+" -> Some "willpower"
    | "rC+" -> Some "cold resistance"
    | "rC+ rF+" -> Some "resistance"
    | "rCorr" -> Some "corrosion resistance"
    | "rF+" -> Some "fire resistance"
    | "rN+" -> Some "positive energy"
    | "rPois" -> Some "poison resistance"
    (* Crawl capitalised these in 0.34.1; earlier builds store the lowercase
       code, and no build stores both. *)
    | ( "harm"
      | "guile"
      | "mayhem"
      | "infuse"
      | "light"
      | "hurl"
      | "repulsion"
      | "reflect"
      | "ponderous"
      | "rampage"
      | "shadows" ) as code -> armour (String.capitalize code)
    | _ -> None
  ;;
end

module Item = struct
  (* An evoker's charge counter is a per-type constant crawl prints in the name
     and stores in no column. *)
  let evoker_charges = function
    | "Gell's gravitambourine" -> Some 2
    | "lightning rod" -> Some 4
    | "tin of tremorstones" -> Some 2
    | _ -> None
  ;;

  let pluralize base = base ^ "s"

  let quantified ~quantity ~singular ~plural =
    match quantity with
    | Some n when n > 1 -> sprintf "%d %s" n (plural ())
    | _ -> singular ()
  ;;

  let enchanted ~plus base =
    match plus with
    | None -> base
    | Some n -> sprintf "%+d %s" n base
  ;;

  (* Crawl pluralizes a paired armour slot and keeps the enchantment outside it
     ("+0 pair of gloves of fire"). *)
  let armour_base sub_type =
    match sub_type with
    | "gloves" | "boots" -> sprintf "pair of %s" sub_type
    | _ -> sub_type
  ;;

  let unenchantable_armour = function
    | "orb" | "scarf" -> true
    | _ -> false
  ;;

  let weapon ~sub_type ~plus ~ego =
    let base =
      match ego with
      | None -> sub_type
      | Some code ->
        (match Ego.weapon code with
         | None -> sub_type
         | Some (`Prefix word) -> sprintf "%s %s" word sub_type
         | Some (`Suffix word) -> sprintf "%s of %s" sub_type word)
    in
    Some (enchanted ~plus:(Some (Option.value plus ~default:0)) base)
  ;;

  let armour ~sub_type ~plus ~ego =
    let base = armour_base sub_type in
    let base =
      match ego with
      | None -> base
      | Some code ->
        (match Ego.armour code with
         | None -> base
         | Some word -> sprintf "%s of %s" base word)
    in
    if unenchantable_armour sub_type
    then Some base
    else Some (enchanted ~plus:(Some (Option.value plus ~default:0)) base)
  ;;

  let of_columns ~base_type ~sub_type ~quantity ~plus ~ego =
    match base_type with
    | ("potion" | "scroll") when not (String.is_empty sub_type) ->
      Some
        (quantified
           ~quantity
           ~singular:(fun () -> sprintf "%s of %s" base_type sub_type)
           ~plural:(fun () -> sprintf "%s of %s" (pluralize base_type) sub_type))
    | "wand" -> Some (sprintf "wand of %s (%d)" sub_type (Option.value plus ~default:0))
    | "staff" -> Some (sprintf "staff of %s" sub_type)
    | "weapon" -> weapon ~sub_type ~plus ~ego
    | "armour" -> armour ~sub_type ~plus ~ego
    | "jewellery" ->
      (* [sub_type] already spells the whole item ("ring of slaying"); only a nonzero
         enchantment is added, and only rings carry one. *)
      (match plus with
       | Some n when n <> 0 -> Some (sprintf "%+d %s" n sub_type)
       | _ -> Some sub_type)
    | "book" | "talisman" -> Some sub_type
    | "miscellaneous" ->
      (match evoker_charges sub_type with
       | None -> Some sub_type
       | Some n -> Some (sprintf "%s (%d/%d)" sub_type n n))
    | _ -> None
  ;;
end

let of_entry (e : Record.Entry.t) =
  match e.cat with
  | Record.Cat.Monsters | Record.Cat.Vaults -> Irreducible
  | Record.Cat.Features ->
    (match e.feat with
     | Some "enter_shop" -> Derived (Feature.shop e.shop_type)
     | Some feat ->
       (match Feature.of_feat feat with
        | Some name -> Derived name
        | None -> Irreducible)
     | None -> Irreducible)
  | Record.Cat.Items ->
    (match e.artefact with
     | Some true -> Irreducible
     | Some false | None ->
       (match e.base_type, e.sub_type with
        | Some base_type, Some sub_type ->
          (match
             Item.of_columns
               ~base_type
               ~sub_type
               ~quantity:e.quantity
               ~plus:e.plus
               ~ego:e.ego
           with
           | Some name -> Derived name
           | None -> Irreducible)
        | _ -> Irreducible))
;;

let render e =
  match of_entry e with
  | Derived name -> name
  | Irreducible -> e.name
;;
