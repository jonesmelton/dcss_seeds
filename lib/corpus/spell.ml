open! Core

module Tier = struct
  type t =
    | Low
    | Mid
    | High
  [@@deriving compare, equal, sexp_of]

  let to_string = function
    | Low -> "low"
    | Mid -> "mid"
    | High -> "high"
  ;;

  let of_level l = if l >= 8 then High else if l >= 5 then Mid else Low
end

let levels =
  [ "Airstrike", 4
  ; "Alistair's Intoxication", 5
  ; "Alistair's Walking Alembic", 5
  ; "Anguish", 4
  ; "Animate Dead", 4
  ; "Apportation", 1
  ; "Arcjolt", 5
  ; "Awaken Armour", 4
  ; "Blink", 2
  ; "Bombard", 6
  ; "Borgnjor's Revivification", 8
  ; "Borgnjor's Vile Clutch", 5
  ; "Brom's Barrelling Boulder", 4
  ; "Call Canine Familiar", 3
  ; "Call Imp", 2
  ; "Cause Fear", 4
  ; "Chain Lightning", 9
  ; "Cigotuvi's Putrefaction", 4
  ; "Confusing Touch", 3
  ; "Conjure Ball Lightning", 6
  ; "Construct Spike Launcher", 2
  ; "Curse of Agony", 5
  ; "Death Channel", 6
  ; "Death's Door", 9
  ; "Detonation Catalyst", 5
  ; "Diamond Sawblades", 7
  ; "Dimensional Bullseye", 4
  ; "Discord", 8
  ; "Disjunction", 8
  ; "Dispel Undead", 4
  ; "Dispersal", 6
  ; "Dragon's Call", 9
  ; "Enfeeble", 7
  ; "Ensorcelled Hibernation", 2
  ; "Eringya's Noxious Bog", 6
  ; "Eringya's Surprising Crocodile", 4
  ; "Fire Storm", 9
  ; "Fireball", 5
  ; "Flame Wave", 4
  ; "Forge Blazeheart Golem", 4
  ; "Forge Lightning Spire", 4
  ; "Forge Monarch Bomb", 6
  ; "Forge Phalanx Beetle", 6
  ; "Fortress Blast", 6
  ; "Foxfire", 1
  ; "Freeze", 1
  ; "Freezing Cloud", 5
  ; "Frozen Ramparts", 3
  ; "Fugue of the Fallen", 3
  ; "Fulminant Prism", 4
  ; "Fulsome Fusillade", 8
  ; "Gell's Gavotte", 6
  ; "Gloom", 3
  ; "Grave Claw", 2
  ; "Hailstorm", 3
  ; "Haunt", 7
  ; "Hellfire Mortar", 7
  ; "Hoarfrost Cannonade", 5
  ; "Ignite Poison", 4
  ; "Ignition", 8
  ; "Infestation", 8
  ; "Inner Flame", 3
  ; "Irradiate", 5
  ; "Iskenderun's Battlesphere", 4
  ; "Iskenderun's Mystic Blast", 4
  ; "Jinxbite", 2
  ; "Kinetic Grapnel", 1
  ; "Kiss of Death", 1
  ; "Launch Clockwork Bee", 3
  ; "Leda's Liquefaction", 4
  ; "Lee's Rapid Deconstruction", 5
  ; "Lehudib's Crystal Spear", 8
  ; "Lesser Beckoning", 2
  ; "Magic Dart", 1
  ; "Magnavolt", 7
  ; "Malign Gateway", 7
  ; "Manifold Assault", 7
  ; "Martyr's Knell", 4
  ; "Maxwell's Capacitive Coupling", 8
  ; "Maxwell's Portable Piledriver", 3
  ; "Mephitic Cloud", 3
  ; "Mercury Arrow", 2
  ; "Metabolic Englaciation", 5
  ; "Momentum Strike", 2
  ; "Nazja's Percussive Tempering", 5
  ; "Olgreb's Toxic Radiance", 4
  ; "Orb of Destruction", 7
  ; "Ozocubu's Armour", 3
  ; "Ozocubu's Refrigeration", 7
  ; "Passage of Golubria", 4
  ; "Passwall", 3
  ; "Permafrost Eruption", 6
  ; "Petrify", 4
  ; "Plasma Beam", 6
  ; "Platinum Paragon", 9
  ; "Poisonous Vapours", 1
  ; "Polar Vortex", 9
  ; "Rending Blade", 4
  ; "Rimeblight", 7
  ; "Sandblast", 1
  ; "Scorch", 2
  ; "Sculpt Simulacrum", 6
  ; "Searing Ray", 2
  ; "Shatter", 9
  ; "Shock", 1
  ; "Sigil of Binding", 3
  ; "Silence", 5
  ; "Slow", 1
  ; "Soul Splinter", 1
  ; "Spellspark Servitor", 7
  ; "Sphinx Sisters", 7
  ; "Splinterfrost Shell", 7
  ; "Starburst", 6
  ; "Static Discharge", 2
  ; "Sticky Flame", 4
  ; "Stone Arrow", 3
  ; "Sublimation of Blood", 2
  ; "Summon Cactus Giant", 6
  ; "Summon Forest", 5
  ; "Summon Horrible Things", 8
  ; "Summon Hydra", 7
  ; "Summon Ice Beast", 3
  ; "Summon Mana Viper", 5
  ; "Summon Seismosaurus Egg", 4
  ; "Summon Small Mammal", 1
  ; "Swiftness", 3
  ; "Teleport Other", 3
  ; "Tukima's Dance", 3
  ; "Vampiric Draining", 3
  ; "Vhi's Electric Charge", 4
  ; "Volatile Blastmotes", 3
  ; "Yara's Violent Unravelling", 5
  ]
  |> Map.of_alist_exn (module String)
;;

let level = Map.find levels
let tier name = Option.map (level name) ~f:Tier.of_level
let known = Map.keys levels

let of_parchment sub_type =
  Option.bind (String.chop_prefix sub_type ~prefix:"parchment of ") ~f:tier
;;
