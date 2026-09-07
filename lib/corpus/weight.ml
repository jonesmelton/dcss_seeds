open! Core

(* `note` is an audit trail, not API: it records why a row is priced where it
   is, and nothing reads it. The 15 rows outside their tier's anchor band and
   the 9 tier/weight collisions are deliberate -- the bands overlap by design. *)

module Tier = struct
  type t =
    | Run_defining
    | Strong
    | Bulk
    | Worthless
  [@@deriving compare, equal, sexp_of]

  let to_string = function
    | Run_defining -> "run_defining"
    | Strong -> "strong"
    | Bulk -> "bulk"
    | Worthless -> "worthless"
  ;;
end

type t =
  { tier : Tier.t
  ; weight : int
  }
[@@deriving compare, equal, sexp_of]

type row =
  { base_type : string
  ; sub_type : string
  ; tier : Tier.t
  ; weight : int
  ; note : string option
  }

let table : row list =
  [ { base_type = "potion"
    ; sub_type = "experience"
    ; tier = Run_defining
    ; weight = 60
    ; note = Some "unconditionally great"
    }
  ; { base_type = "potion"; sub_type = "haste"; tier = Strong; weight = 30; note = None }
  ; { base_type = "potion"
    ; sub_type = "invisibility"
    ; tier = Strong
    ; weight = 30
    ; note = None
    }
  ; { base_type = "potion"
    ; sub_type = "resistance"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "potion"; sub_type = "might"; tier = Strong; weight = 10; note = None }
  ; { base_type = "potion"
    ; sub_type = "berserk rage"
    ; tier = Strong
    ; weight = 10
    ; note = None
    }
  ; { base_type = "potion"; sub_type = "magic"; tier = Bulk; weight = 15; note = None }
  ; { base_type = "potion"
    ; sub_type = "cancellation"
    ; tier = Strong
    ; weight = 30
    ; note = None
    }
  ; { base_type = "potion"
    ; sub_type = "brilliance"
    ; tier = Bulk
    ; weight = 5
    ; note = None
    }
  ; { base_type = "potion"
    ; sub_type = "heal wounds"
    ; tier = Strong
    ; weight = 10
    ; note = None
    }
  ; { base_type = "potion"; sub_type = "curing"; tier = Strong; weight = 15; note = None }
  ; { base_type = "potion"
    ; sub_type = "enlightenment"
    ; tier = Bulk
    ; weight = 5
    ; note = None
    }
  ; { base_type = "potion"; sub_type = "ambrosia"; tier = Bulk; weight = 3; note = None }
  ; { base_type = "potion"
    ; sub_type = "mutation"
    ; tier = Strong
    ; weight = 10
    ; note = None
    }
  ; { base_type = "potion"
    ; sub_type = "lignification"
    ; tier = Bulk
    ; weight = 5
    ; note = None
    }
  ; { base_type = "potion"
    ; sub_type = "attraction"
    ; tier = Worthless
    ; weight = 5
    ; note = None
    }
  ; { base_type = "potion"; sub_type = "*"; tier = Bulk; weight = 3; note = None }
  ; { base_type = "scroll"
    ; sub_type = "acquirement"
    ; tier = Run_defining
    ; weight = 60
    ; note = Some "unconditionally great"
    }
  ; { base_type = "scroll"
    ; sub_type = "brand weapon"
    ; tier = Run_defining
    ; weight = 30
    ; note = None
    }
  ; { base_type = "scroll"
    ; sub_type = "enchant weapon"
    ; tier = Strong
    ; weight = 10
    ; note = None
    }
  ; { base_type = "scroll"
    ; sub_type = "enchant armour"
    ; tier = Strong
    ; weight = 10
    ; note = None
    }
  ; { base_type = "scroll"
    ; sub_type = "blinking"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "scroll"
    ; sub_type = "teleportation"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "scroll"; sub_type = "fear"; tier = Strong; weight = 10; note = None }
  ; { base_type = "scroll"
    ; sub_type = "revelation"
    ; tier = Strong
    ; weight = 15
    ; note = None
    }
  ; { base_type = "scroll"; sub_type = "fog"; tier = Bulk; weight = 10; note = None }
  ; { base_type = "scroll"; sub_type = "silence"; tier = Bulk; weight = 10; note = None }
  ; { base_type = "scroll"
    ; sub_type = "torment"
    ; tier = Bulk
    ; weight = 3
    ; note = Some "usable, but not by most early characters"
    }
  ; { base_type = "scroll"; sub_type = "amnesia"; tier = Bulk; weight = 10; note = None }
  ; { base_type = "scroll"; sub_type = "poison"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "scroll"
    ; sub_type = "immolation"
    ; tier = Bulk
    ; weight = 10
    ; note = None
    }
  ; { base_type = "scroll"
    ; sub_type = "noise"
    ; tier = Worthless
    ; weight = -2
    ; note = None
    }
  ; { base_type = "scroll"
    ; sub_type = "vulnerability"
    ; tier = Worthless
    ; weight = 5
    ; note = None
    }
  ; { base_type = "scroll"
    ; sub_type = "summoning"
    ; tier = Worthless
    ; weight = 10
    ; note = Some "dangerous to read unidentified"
    }
  ; { base_type = "scroll"
    ; sub_type = "butterflies"
    ; tier = Worthless
    ; weight = 1
    ; note = None
    }
  ; { base_type = "scroll"; sub_type = "*"; tier = Bulk; weight = 3; note = None }
  ; { base_type = "wand"
    ; sub_type = "digging"
    ; tier = Strong
    ; weight = 40
    ; note = Some "escape and vault access, useful to every build"
    }
  ; { base_type = "wand"
    ; sub_type = "paralysis"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "wand"; sub_type = "iceblast"; tier = Strong; weight = 20; note = None }
  ; { base_type = "wand"
    ; sub_type = "mindburst"
    ; tier = Strong
    ; weight = 15
    ; note = None
    }
  ; { base_type = "wand"; sub_type = "polymorph"; tier = Bulk; weight = 1; note = None }
  ; { base_type = "wand"; sub_type = "charming"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "wand"; sub_type = "flame"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "wand"; sub_type = "acid"; tier = Bulk; weight = 8; note = None }
  ; { base_type = "wand"; sub_type = "roots"; tier = Bulk; weight = 8; note = None }
  ; { base_type = "wand"; sub_type = "warping"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "wand"; sub_type = "quicksilver"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "wand"; sub_type = "light"; tier = Strong; weight = 10; note = None }
  ; { base_type = "wand"; sub_type = "*"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "weapon"
    ; sub_type = "demon whip"
    ; tier = Run_defining
    ; weight = 70
    ; note = Some "best-in-class flail; changes builds"
    }
  ; { base_type = "weapon"
    ; sub_type = "demon blade"
    ; tier = Run_defining
    ; weight = 70
    ; note = Some "best-in-class long blade; changes builds"
    }
  ; { base_type = "weapon"
    ; sub_type = "demon trident"
    ; tier = Run_defining
    ; weight = 70
    ; note = Some "best-in-class polearm; changes builds"
    }
  ; { base_type = "weapon"
    ; sub_type = "eveningstar"
    ; tier = Run_defining
    ; weight = 60
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "quick blade"
    ; tier = Run_defining
    ; weight = 50
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "triple sword"
    ; tier = Run_defining
    ; weight = 50
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "executioner's axe"
    ; tier = Run_defining
    ; weight = 50
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "bardiche"
    ; tier = Run_defining
    ; weight = 45
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "lajatang"
    ; tier = Run_defining
    ; weight = 50
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "double sword"
    ; tier = Run_defining
    ; weight = 45
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "eudemon blade"
    ; tier = Run_defining
    ; weight = 70
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "great mace"
    ; tier = Strong
    ; weight = 30
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "broad axe"
    ; tier = Strong
    ; weight = 30
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "battleaxe"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "great sword"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "weapon"; sub_type = "glaive"; tier = Strong; weight = 25; note = None }
  ; { base_type = "weapon"
    ; sub_type = "partisan"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "halberd"
    ; tier = Strong
    ; weight = 15
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "dire flail"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "trishula"
    ; tier = Run_defining
    ; weight = 70
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "scimitar"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "morningstar"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "war axe"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "trident"
    ; tier = Strong
    ; weight = 15
    ; note = None
    }
  ; { base_type = "weapon"; sub_type = "rapier"; tier = Strong; weight = 20; note = None }
  ; { base_type = "weapon"
    ; sub_type = "long sword"
    ; tier = Strong
    ; weight = 15
    ; note = None
    }
  ; { base_type = "weapon"; sub_type = "flail"; tier = Strong; weight = 15; note = None }
  ; { base_type = "weapon"
    ; sub_type = "quarterstaff"
    ; tier = Strong
    ; weight = 15
    ; note = None
    }
  ; { base_type = "weapon"; sub_type = "falchion"; tier = Bulk; weight = 8; note = None }
  ; { base_type = "weapon"
    ; sub_type = "hand cannon"
    ; tier = Run_defining
    ; weight = 60
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "arbalest"
    ; tier = Strong
    ; weight = 30
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "triple crossbow"
    ; tier = Run_defining
    ; weight = 40
    ; note = None
    }
  ; { base_type = "weapon"
    ; sub_type = "longbow"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "weapon"; sub_type = "orcbow"; tier = Strong; weight = 15; note = None }
  ; { base_type = "weapon"; sub_type = "shortbow"; tier = Bulk; weight = 8; note = None }
  ; { base_type = "weapon"; sub_type = "sling"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "weapon"; sub_type = "dagger"; tier = Bulk; weight = 3; note = None }
  ; { base_type = "weapon"
    ; sub_type = "short sword"
    ; tier = Bulk
    ; weight = 3
    ; note = None
    }
  ; { base_type = "weapon"; sub_type = "mace"; tier = Bulk; weight = 3; note = None }
  ; { base_type = "weapon"; sub_type = "hand axe"; tier = Bulk; weight = 3; note = None }
  ; { base_type = "weapon"; sub_type = "whip"; tier = Bulk; weight = 3; note = None }
  ; { base_type = "weapon"; sub_type = "spear"; tier = Bulk; weight = 3; note = None }
  ; { base_type = "weapon"; sub_type = "club"; tier = Worthless; weight = 0; note = None }
  ; { base_type = "weapon"
    ; sub_type = "staff"
    ; tier = Worthless
    ; weight = 0
    ; note = None
    }
  ; { base_type = "weapon"; sub_type = "*"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "armour"
    ; sub_type = "golden dragon scales"
    ; tier = Run_defining
    ; weight = 80
    ; note = Some "run-defining; resistances plus heavy AC"
    }
  ; { base_type = "armour"
    ; sub_type = "pearl dragon scales"
    ; tier = Run_defining
    ; weight = 70
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "shadow dragon scales"
    ; tier = Run_defining
    ; weight = 70
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "storm dragon scales"
    ; tier = Run_defining
    ; weight = 70
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "crystal plate armour"
    ; tier = Run_defining
    ; weight = 80
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "fire dragon scales"
    ; tier = Run_defining
    ; weight = 50
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "ice dragon scales"
    ; tier = Run_defining
    ; weight = 50
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "troll leather armour"
    ; tier = Strong
    ; weight = 45
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "swamp dragon scales"
    ; tier = Strong
    ; weight = 30
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "acid dragon scales"
    ; tier = Strong
    ; weight = 30
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "steam dragon scales"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "plate armour"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "chain mail"
    ; tier = Strong
    ; weight = 15
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "scale mail"
    ; tier = Bulk
    ; weight = 8
    ; note = None
    }
  ; { base_type = "armour"; sub_type = "ring mail"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "armour"
    ; sub_type = "leather armour"
    ; tier = Bulk
    ; weight = 5
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "animal skin"
    ; tier = Bulk
    ; weight = 0
    ; note = None
    }
  ; { base_type = "armour"; sub_type = "robe"; tier = Bulk; weight = 3; note = None }
  ; { base_type = "armour"
    ; sub_type = "tower shield"
    ; tier = Strong
    ; weight = 50
    ; note = None
    }
  ; { base_type = "armour"
    ; sub_type = "kite shield"
    ; tier = Strong
    ; weight = 40
    ; note = None
    }
  ; { base_type = "armour"; sub_type = "buckler"; tier = Bulk; weight = 20; note = None }
  ; { base_type = "armour"; sub_type = "orb"; tier = Strong; weight = 15; note = None }
  ; { base_type = "armour"; sub_type = "scarf"; tier = Strong; weight = 15; note = None }
  ; { base_type = "armour"; sub_type = "cloak"; tier = Strong; weight = 15; note = None }
  ; { base_type = "armour"; sub_type = "helmet"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "armour"; sub_type = "hat"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "armour"; sub_type = "gloves"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "armour"; sub_type = "boots"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "armour"; sub_type = "*"; tier = Bulk; weight = 3; note = None }
  ; { base_type = "jewellery"
    ; sub_type = "amulet of faith"
    ; tier = Strong
    ; weight = 20
    ; note = Some "transformative with a god, dead weight without"
    }
  ; { base_type = "jewellery"
    ; sub_type = "amulet of regeneration"
    ; tier = Strong
    ; weight = 30
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "amulet of guardian spirit"
    ; tier = Strong
    ; weight = 15
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "amulet of reflection"
    ; tier = Strong
    ; weight = 40
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "amulet of the acrobat"
    ; tier = Bulk
    ; weight = 8
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "amulet of chemistry"
    ; tier = Bulk
    ; weight = 8
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "amulet of wildshape"
    ; tier = Strong
    ; weight = 15
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "amulet of dissipation"
    ; tier = Bulk
    ; weight = 5
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "amulet of magic regeneration"
    ; tier = Bulk
    ; weight = 15
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "amulet of nothing"
    ; tier = Worthless
    ; weight = 0
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of slaying"
    ; tier = Strong
    ; weight = 30
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of protection"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of evasion"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of willpower"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of protection from fire"
    ; tier = Bulk
    ; weight = 10
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of protection from cold"
    ; tier = Bulk
    ; weight = 10
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of resist corrosion"
    ; tier = Bulk
    ; weight = 8
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of poison resistance"
    ; tier = Bulk
    ; weight = 5
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of see invisible"
    ; tier = Bulk
    ; weight = 5
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of positive energy"
    ; tier = Bulk
    ; weight = 5
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of flight"
    ; tier = Bulk
    ; weight = 8
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of magical power"
    ; tier = Bulk
    ; weight = 12
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of wizardry"
    ; tier = Strong
    ; weight = 12
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of intelligence"
    ; tier = Bulk
    ; weight = 10
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of strength"
    ; tier = Bulk
    ; weight = 8
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of dexterity"
    ; tier = Bulk
    ; weight = 8
    ; note = None
    }
  ; { base_type = "jewellery"
    ; sub_type = "ring of stealth"
    ; tier = Bulk
    ; weight = 8
    ; note = None
    }
  ; { base_type = "jewellery"; sub_type = "*"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "talisman"
    ; sub_type = "talisman of death"
    ; tier = Run_defining
    ; weight = 60
    ; note = Some "powerful"
    }
  ; { base_type = "talisman"
    ; sub_type = "protean talisman"
    ; tier = Strong
    ; weight = 30
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "storm talisman"
    ; tier = Run_defining
    ; weight = 60
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "fortress talisman"
    ; tier = Strong
    ; weight = 30
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "dragon-coil talisman"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "serpent talisman"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "blade talisman"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "granite talisman"
    ; tier = Run_defining
    ; weight = 50
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "sanguine talisman"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "riddle talisman"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "wellspring talisman"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "hive talisman"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "eel talisman"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "spider talisman"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "lupine talisman"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "medusa talisman"
    ; tier = Strong
    ; weight = 15
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "maw talisman"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "rimehorn talisman"
    ; tier = Strong
    ; weight = 15
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "scarab talisman"
    ; tier = Bulk
    ; weight = 8
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "spore talisman"
    ; tier = Bulk
    ; weight = 8
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "inkwell talisman"
    ; tier = Bulk
    ; weight = 5
    ; note = None
    }
  ; { base_type = "talisman"
    ; sub_type = "quill talisman"
    ; tier = Bulk
    ; weight = 5
    ; note = None
    }
  ; { base_type = "talisman"; sub_type = "*"; tier = Bulk; weight = 5; note = None }
  ; { base_type = "staff"
    ; sub_type = "*"
    ; tier = Strong
    ; weight = 20
    ; note = Some "elemental staves are strong for a caster of that school"
    }
  ; { base_type = "miscellaneous"
    ; sub_type = "lightning rod"
    ; tier = Strong
    ; weight = 20
    ; note = None
    }
  ; { base_type = "miscellaneous"
    ; sub_type = "phantom mirror"
    ; tier = Strong
    ; weight = 40
    ; note = None
    }
  ; { base_type = "miscellaneous"
    ; sub_type = "box of beasts"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "miscellaneous"
    ; sub_type = "tin of tremorstones"
    ; tier = Bulk
    ; weight = 15
    ; note = None
    }
  ; { base_type = "miscellaneous"
    ; sub_type = "phial of floods"
    ; tier = Bulk
    ; weight = 15
    ; note = None
    }
  ; { base_type = "miscellaneous"
    ; sub_type = "Gell's gravitambourine"
    ; tier = Bulk
    ; weight = 15
    ; note = None
    }
  ; { base_type = "miscellaneous"
    ; sub_type = "condenser vane"
    ; tier = Bulk
    ; weight = 20
    ; note = None
    }
  ; { base_type = "miscellaneous"
    ; sub_type = "sack of spiders"
    ; tier = Strong
    ; weight = 25
    ; note = None
    }
  ; { base_type = "miscellaneous"; sub_type = "*"; tier = Bulk; weight = 8; note = None }
  ; { base_type = "bauble"; sub_type = "*"; tier = Worthless; weight = 0; note = None }
  ; { base_type = "¤"; sub_type = "*"; tier = Bulk; weight = 0; note = Some "gold" }
  ]
;;

let exact : (string * string, t) Hashtbl.Poly.t = Hashtbl.Poly.create ()
let wild : (string, t) Hashtbl.t = Hashtbl.create (module String)

let () =
  List.iter table ~f:(fun { base_type; sub_type; tier; weight; note = _ } ->
    let w = { tier; weight } in
    if String.equal sub_type "*"
    then Hashtbl.set wild ~key:base_type ~data:w
    else Hashtbl.set exact ~key:(base_type, sub_type) ~data:w)
;;

let find ~base_type ~sub_type =
  match Hashtbl.find exact (base_type, sub_type) with
  | Some w -> Some w
  | None -> Hashtbl.find wild base_type
;;

let row_count = List.length table
let keys = List.map table ~f:(fun { base_type; sub_type; _ } -> base_type, sub_type)
