-- | Weapons and treasure for LambdaHack.
module Content.ItemKind ( cdefs ) where

import Game.LambdaHack.Common.Color
import Game.LambdaHack.Common.ContentDef
import Game.LambdaHack.Common.Dice
import Game.LambdaHack.Common.Effect
import Game.LambdaHack.Common.Flavour
import Game.LambdaHack.Common.ItemFeature
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Content.ItemKind

cdefs :: ContentDef ItemKind
cdefs = ContentDef
  { getSymbol = isymbol
  , getName = iname
  , getFreq = ifreq
  , validate = validateItemKind
  , content =
      [amulet, bolas, brassLantern, dart, dart100, gem1, gem2, gem3, currency, harpoon, jumpingPole, net, oilLamp, potion1, potion2, potion3, potion4, ring, scroll1, scroll2, scroll3, scroll4, scroll5, scroll6, scroll7, shield, sword, wand1, wand2, woodenTorch, fist, foot, tentacle, lash, noseTip, lip, claw, smallClaw, snout, venomTooth, venomFang, largeTail, jaw, largeJaw, fragrance, mist_healing, mist_wounding, burningOil2, burningOil3, burningOil4, explosionBlast10, glass_piece, smoke]
  }
amulet,        bolas, brassLantern, dart, dart100, gem1, gem2, gem3, currency, harpoon, jumpingPole, net, oilLamp, potion1, potion2, potion3, potion4, ring, scroll1, scroll2, scroll3, scroll4, scroll5, scroll6, scroll7, shield, sword, wand1, wand2, woodenTorch, fist, foot, tentacle, lash, noseTip, lip, claw, smallClaw, snout, venomTooth, venomFang, largeTail, jaw, largeJaw, fragrance, mist_healing, mist_wounding, burningOil2, burningOil3, burningOil4, explosionBlast10, glass_piece, smoke :: ItemKind

gem, potion, scroll, wand :: ItemKind  -- generic templates

amulet = ItemKind
  { isymbol  = '"'
  , iname    = "amulet"
  , ifreq    = [("useful", 6)]
  , iflavour = zipFancy [BrGreen]
  , icount   = 1
  , iverbApply   = "tear down"
  , iverbProject = "cast"
  , iweight  = 30
  , iaspects = [Regeneration (2 * d 3 + dl 10)]
  , ieffects = []  -- TODO: DropAllEqp? change text if so
  , ifeature = [ToThrow (-50)]  -- not dense enough
  , idesc    = "A necklace of dried herbs and healing berries."
  }
bolas = ItemKind
  { isymbol  = '|'
  , iname    = "a set of bolas"
  , ifreq    = [("useful", 5)]
  , iflavour = zipPlain [BrYellow]
  , icount   = 1 + dl 3
  , iverbApply   = "tie"
  , iverbProject = "swirl"
  , iweight  = 500
  , iaspects = []
  , ieffects = [Hurt (d 2) 0, Paralyze (5 + d 5), ActivateEqp '!']
  , ifeature = []
  , idesc    = "Wood balls tied with hemp rope for tripping, entangling and bringing down crashing."
  }
brassLantern = ItemKind
  { isymbol  = '('
  , iname    = "brass lantern"
  , ifreq    = [("useful", 2)]
  , iflavour = zipPlain [BrWhite]
  , icount   = 1
  , iverbApply   = "douse"
  , iverbProject = "heave"
  , iweight  = 2400
  , iaspects = [Explode "burning oil 4"]
  , ieffects = [Burn 4]
  , ifeature = [ ToThrow (-30)  -- hard to throw so that it opens and burns
               , Light 4, Fragile ]
  , idesc    = "Very bright and quite heavy brass lantern."
  }
dart = ItemKind
  { isymbol  = '|'
  , iname    = "dart"
  , ifreq    = [("useful", 20), ("fallback item", 1)]
  , iflavour = zipPlain [Cyan]
  , icount   = 3 * d 3
  , iverbApply   = "snap"
  , iverbProject = "hurl"
  , iweight  = 50
  , iaspects = []
  , ieffects = [Hurt (d 2) (d 3 + dl 3)]
  , ifeature = []
  , idesc    = "Little, but sharp and sturdy."
  }
dart100 = ItemKind
  { isymbol  = '|'
  , iname    = "fine dart"
  , ifreq    = [("useful", 20)]
  , iflavour = zipPlain [BrRed]
  , icount   = 3 * d 3
  , iverbApply   = "snap"
  , iverbProject = "hurl"
  , iweight  = 50
  , iaspects = []
  , ieffects = [Hurt (d 1) (d 2 + dl 2)]
  , ifeature = [ToThrow 100]
  , idesc    = "Finely balanced for throws of great speed."
  }
gem = ItemKind
  { isymbol  = '*'
  , iname    = "gem"
  , ifreq    = [("treasure", 20)]  -- x3, but rare on shallow levels
  , iflavour = zipPlain brightCol  -- natural, so not fancy
  , icount   = 0
  , iverbApply   = "crush"
  , iverbProject = "toss"
  , iweight  = 50
  , iaspects = []
  , ieffects = []
  , ifeature = [Light 0]  -- just reflects strongly
  , idesc    = "Precious, though useless. Worth around 100 gold."
  }
gem1 = gem
  { icount   = dl 1  -- appears on max depth
  }
gem2 = gem
  { icount   = dl 2  -- appears halfway
  }
gem3 = gem
  { icount   = dl 3  -- appears early
  }
currency = ItemKind
  { isymbol  = '$'
  , iname    = "gold piece"
  , ifreq    = [("treasure", 20), ("currency", 1)]
  , iflavour = zipPlain [BrYellow]
  , icount   = 10 * dl 10  -- appears on lvl 2
  , iverbApply   = "grind"
  , iverbProject = "toss"
  , iweight  = 31
  , iaspects = []
  , ieffects = []
  , ifeature = []
  , idesc    = "Reliably valuable in every civilized place."
  }
harpoon = ItemKind
  { isymbol  = '|'
  , iname    = "harpoon"
  , ifreq    = [("useful", 15)]
  , iflavour = zipPlain [Brown]
  , icount   = 1 + dl 3
  , iverbApply   = "break up"
  , iverbProject = "hurl"
  , iweight  = 4000
  , iaspects = []
  , ieffects = [Hurt (3 * d 1) (d 2 + 2 * dl 2), PullActor 100 50]
  , ifeature = []
  , idesc    = "The cruel, barbed head lodges in its victim so painfully that the weakest tug of the thin line sends the victim flying."
  }
jumpingPole = ItemKind
  { isymbol  = '|'
  , iname    = "jumping pole"
  , ifreq    = [("useful", 3)]
  , iflavour = zipPlain [White]
  , icount   = 1
  , iverbApply   = "break up"
  , iverbProject = "extend"
  , iweight  = 10000
  , iaspects = []
  , ieffects = [InsertMove 2]  -- TODO: implement with timed speed instead
  , ifeature = [Consumable]
  , idesc    = "Makes you vulnerable at take-off, but then you are free like a bird."
  }
net = ItemKind
  { isymbol  = '|'
  , iname    = "net"
  , ifreq    = [("useful", 5)]
  , iflavour = zipPlain [White]
  , icount   = 1 + dl 2
  , iverbApply   = "entangle"
  , iverbProject = "spread"
  , iweight  = 1000
  , iaspects = []
  , ieffects = [ Hurt (d 1) 0, Paralyze (5 + d 5)
               , DropBestWeapon, DropEqp ']' False ]
  , ifeature = []
  , idesc    = "A wide net with weights along the edges. Entangles weapon and armor alike."  -- shield instead of armor if a separate symbol for shields
  }
oilLamp = ItemKind
  { isymbol  = '('
  , iname    = "oil lamp"
  , ifreq    = [("useful", 5)]
  , iflavour = zipPlain [BrYellow]
  , icount   = 1
  , iverbApply   = "douse"
  , iverbProject = "lob"
  , iweight  = 1000
  , iaspects = [Explode "burning oil 3"]
  , ieffects = [Burn 3]
  , ifeature = [ ToThrow (-30)  -- hard not to spill the oil while throwing
               , Light 3, Fragile ]
  , idesc    = "A clay lamp full of plant oil feeding a thick wick."
  }
potion = ItemKind
  { isymbol  = '!'
  , iname    = "potion"
  , ifreq    = [("useful", 10)]
  , iflavour = zipFancy stdCol
  , icount   = 1
  , iverbApply   = "gulp down"
  , iverbProject = "lob"
  , iweight  = 200
  , iaspects = []
  , ieffects = []
  , ifeature = [ ToThrow (-50)  -- oily, bad grip
               , Consumable, Fragile ]
  , idesc    = "A flask of bubbly, slightly oily liquid of a suspect color."
  }
potion1 = potion
  { iaspects = [Explode "fragrance"]
  , ieffects = [ApplyPerfume, Impress]
  }
potion2 = potion
  { iaspects = [Explode "healing mist"]
  , ieffects = [Heal 5]
  }
potion3 = potion  -- TODO: a bit boring
  { ifreq    = [("useful", 5)]
  , iaspects = [Explode "wounding mist"]
  , ieffects = [Heal (-5)]
  }
potion4 = potion
  { iaspects = [Explode "explosion blast 10"]
  , ieffects = [Blast 10, PushActor 100 75]
  }
ring = ItemKind
  { isymbol  = '='
  , iname    = "ring"
  , ifreq    = [("useful", 6)]
  , iflavour = zipPlain [White]
  , icount   = 1
  , iverbApply   = "squeeze down"
  , iverbProject = "toss"
  , iweight  = 15
  , iaspects = [Steadfastness (d 2 + 2 * dl 2)]
  , ieffects = []  -- TODO: add something
  , ifeature = []
  , idesc    = "Cold, solid to the touch, perfectly round, engraved with letters that meant a lot to somebody."
  }
scroll = ItemKind
  { isymbol  = '?'
  , iname    = "scroll"
  , ifreq    = [("useful", 4)]
  , iflavour = zipFancy darkCol ++ zipPlain darkCol  -- arcane and old
  , icount   = 1
  , iverbApply   = "decipher"
  , iverbProject = "lob"
  , iweight  = 50
  , iaspects = []
  , ieffects = []
  , ifeature = [ ToThrow (-75)  -- bad shape, even rolled up
               , Consumable ]
  , idesc    = "A haphazardly scribbled piece of parchment. May contain directions or a secret call sign."
  }
scroll1 = scroll
  { ifreq    = [("useful", 2)]
  , ieffects = [CallFriend 1]
  }
scroll2 = scroll
  { ieffects = [Summon 1]
  }
scroll3 = scroll
  { ieffects = [Ascend (-1)]
  }
scroll4 = scroll
  { ifreq    = [("useful", 1)]
  , ieffects = [Dominate]
  }
scroll5 = scroll
  { ifreq    = [("useful", 5)]
  , ieffects = [Teleport 5]
  }
scroll6 = scroll
  { ifreq    = [("useful", 2)]
  , ieffects = [Teleport 15]
  }
scroll7 = scroll
  { ifreq    = [("useful", 1)]
  , ieffects = [InsertMove (1 + d 2)]
  }
shield = ItemKind
  { isymbol  = ']'
  , iname    = "shield"
  , ifreq    = [("useful", 5)]
  , iflavour = zipPlain [Brown]
  , icount   = 1
  , iverbApply   = "bash"
  , iverbProject = "push"
  , iweight  = 3000
  , iaspects = [ArmorMelee 50]
  , ieffects = [PushActor 0 50]
  , ifeature = [ToThrow (-80)]  -- unwieldy to throw and blunt
  , idesc    = "Large and unwieldy. Absorbs the precentage of melee damage, both dealt and sustained."
  }
sword = ItemKind
  { isymbol  = ')'
  , iname    = "sword"
  , ifreq    = [("useful", 40)]
  , iflavour = zipPlain [BrCyan]
  , icount   = 1
  , iverbApply   = "hit"
  , iverbProject = "heave"
  , iweight  = 2000
  , iaspects = []
  , ieffects = [Hurt (5 * d 1) (d 2 + 4 * dl 2)]
  , ifeature = [ToThrow (-60)]  -- ensuring it hits with the tip costs speed
  , idesc    = "A standard heavy weapon. Does not penetrate very effectively, but hard to block."
  }
wand = ItemKind
  { isymbol  = '/'
  , iname    = "wand"
  , ifreq    = []  -- TODO: add charges, etc.  -- [("useful", 2)]
  , iflavour = zipFancy brightCol
  , icount   = 1
  , iverbApply   = "snap"
  , iverbProject = "zap"
  , iweight  = 300
  , iaspects = []
  , ieffects = []
  , ifeature = [ ToThrow 25  -- magic
               , Light 1
               , Fragile ]
  , idesc    = "Buzzing with dazzling light that shines even through appendages that handle it."
  }
wand1 = wand
  { ieffects = [NoEffect]  -- TODO: emit a cone of sound shrapnel that makes enemy cover his ears and so drop '|' and '{'
  }
wand2 = wand
  { ieffects = [NoEffect]
  }
woodenTorch = ItemKind
  { isymbol  = '('
  , iname    = "wooden torch"
  , ifreq    = [("useful", 10)]
  , iflavour = zipPlain [Brown]
  , icount   = d 3
  , iverbApply   = "douse"
  , iverbProject = "fling"
  , iweight  = 1200
  , iaspects = []
  , ieffects = [Burn 2]
  , ifeature = [Light 2]
  , idesc    = "A heavy wooden torch, burning with a weak fire."
  }
fist = sword
  { isymbol  = '%'
  , iname    = "fist"
  , ifreq    = [("fist", 100)]
  , icount   = 2
  , iverbApply   = "punch"
  , iverbProject = "ERROR, please report: iverbProject"
  , ieffects = [Hurt (5 * d 1) 0]
  , idesc    = ""
  }
foot = fist
  { isymbol  = '%'
  , iname    = "foot"
  , ifreq    = [("foot", 50)]
  , icount   = 2
  , iverbApply   = "kick"
  , ieffects = [Hurt (5 * d 1) 0]
  , idesc    = ""
  }
tentacle = fist
  { isymbol  = '%'
  , iname    = "tentacle"
  , ifreq    = [("tentacle", 50)]
  , icount   = 4
  , iverbApply   = "slap"
  , ieffects = [Hurt (5 * d 1) 0]
  , idesc    = ""
  }
lash = fist
  { isymbol  = '%'
  , iname    = "lash"
  , ifreq    = [("lash", 100)]
  , icount   = 1
  , iverbApply   = "lash"
  , ieffects = [Hurt (5 * d 1) 0]
  , idesc    = ""
  }
noseTip = fist
  { isymbol  = '%'
  , iname    = "nose tip"
  , ifreq    = [("nose tip", 50)]
  , icount   = 1
  , iverbApply   = "poke"
  , ieffects = [Hurt (2 * d 1) 0]
  , idesc    = ""
  }
lip = fist
  { isymbol  = '%'
  , iname    = "lip"
  , ifreq    = [("lip", 10)]
  , icount   = 2
  , iverbApply   = "lap"
  , ieffects = [Hurt (1 * d 1) 0]
  , idesc    = ""
  }
claw = fist
  { isymbol  = '%'
  , iname    = "claw"
  , ifreq    = [("claw", 50)]
  , icount   = 2  -- even if more, only the fore claws used for fighting
  , iverbApply   = "slash"
  , ieffects = [Hurt (5 * d 1) 0]
  , idesc    = ""
  }
smallClaw = fist
  { isymbol  = '%'
  , iname    = "small claw"
  , ifreq    = [("small claw", 50)]
  , icount   = 2
  , iverbApply   = "slash"
  , ieffects = [Hurt (3 * d 1) 0]
  , idesc    = ""
  }
snout = fist
  { isymbol  = '%'
  , iname    = "snout"
  , ifreq    = [("snout", 10)]
  , iverbApply   = "bite"
  , ieffects = [Hurt (2 * d 1) 0]
  , idesc    = ""
  }
venomTooth = fist
  { isymbol  = '%'
  , iname    = "venom tooth"
  , ifreq    = [("venom tooth", 100)]
  , icount   = 2
  , iverbApply   = "bite"
  , ieffects = [Hurt (3 * d 1) 0, Paralyze 3]
  , idesc    = ""
  }
venomFang = fist
  { isymbol  = '%'
  , iname    = "venom fang"
  , ifreq    = [("venom fang", 100)]
  , icount   = 2
  , iverbApply   = "bite"
  , ieffects = [Hurt (3 * d 1) 12]
  , idesc    = ""
  }
largeTail = fist
  { isymbol  = '%'
  , iname    = "large tail"
  , ifreq    = [("large tail", 50)]
  , icount   = 1
  , iverbApply   = "knock"
  , ieffects = [Hurt (5 * d 1) 0, PushActor 300 25]
  , idesc    = ""
  }
jaw = fist
  { isymbol  = '%'
  , iname    = "jaw"
  , ifreq    = [("jaw", 20)]
  , icount   = 1
  , iverbApply   = "rip"
  , ieffects = [Hurt (5 * d 1) 0]
  , idesc    = ""
  }
largeJaw = fist
  { isymbol  = '%'
  , iname    = "large jaw"
  , ifreq    = [("large jaw", 100)]
  , icount   = 1
  , iverbApply   = "crush"
  , ieffects = [Hurt (10 * d 1) 0]
  , idesc    = ""
  }
fragrance = ItemKind
  { isymbol  = '\''
  , iname    = "fragrance"
  , ifreq    = [("fragrance", 1)]
  , iflavour = zipFancy [BrMagenta]
  , icount   = 15
  , iverbApply   = "smell"
  , iverbProject = "exude"
  , iweight  = 1
  , iaspects = []
  , ieffects = [Impress]
  , ifeature = [ ToThrow (-87)  -- the slowest that travels at least 2 steps
               , Fragile ]
  , idesc    = ""
  }
mist_healing = ItemKind
  { isymbol  = '\''
  , iname    = "mist"
  , ifreq    = [("healing mist", 1)]
  , iflavour = zipFancy [White]
  , icount   = 11
  , iverbApply   = "inhale"
  , iverbProject = "blow"
  , iweight  = 1
  , iaspects = []
  , ieffects = [Heal 2]
  , ifeature = [ ToThrow (-93)  -- the slowest that gets anywhere (1 step only)
               , Light 0
               , Fragile ]
  , idesc    = ""
  }
mist_wounding = ItemKind
  { isymbol  = '\''
  , iname    = "mist"
  , ifreq    = [("wounding mist", 1)]
  , iflavour = zipFancy [White]
  , icount   = 13
  , iverbApply   = "inhale"
  , iverbProject = "blow"
  , iweight  = 1
  , iaspects = []
  , ieffects = [Heal (-2)]
  , ifeature = [ ToThrow (-93)  -- the slowest that gets anywhere (1 step only)
               , Fragile ]
  , idesc    = ""
  }
burningOil2 = burningOil 2
burningOil3 = burningOil 3
burningOil4 = burningOil 4
explosionBlast10 = explosionBlast 10
glass_piece = ItemKind  -- when blowing up windows
  { isymbol  = '\''
  , iname    = "glass piece"
  , ifreq    = [("glass piece", 1)]
  , iflavour = zipPlain [BrBlue]
  , icount   = 17
  , iverbApply   = "grate"
  , iverbProject = "toss"
  , iweight  = 10
  , iaspects = []
  , ieffects = [Hurt (d 1) 0]
  , ifeature = [Fragile, Linger 20]
  , idesc    = ""
  }
smoke = ItemKind  -- when stuff burns out
  { isymbol  = '\''
  , iname    = "smoke"
  , ifreq    = [("smoke", 1)]
  , iflavour = zipPlain [BrBlack]
  , icount   = 19
  , iverbApply   = "inhale"
  , iverbProject = "blow"
  , iweight  = 1
  , iaspects = []
  , ieffects = []
  , ifeature = [ ToThrow (-70)
               , Fragile ]
  , idesc    = ""
  }

burningOil :: Int -> ItemKind
burningOil n = ItemKind
  { isymbol  = '\''
  , iname    = "burning oil"
  , ifreq    = [("burning oil" <+> tshow n, 1)]
  , iflavour = zipFancy [BrYellow]
  , icount   = intToDice (n * 6)
  , iverbApply   = "smear"
  , iverbProject = "spit"
  , iweight  = 1
  , iaspects = []
  , ieffects = [ Burn 1
               , Paralyze (intToDice n) ]  -- actors strain not to trip on oil
  , ifeature = [ ToThrow (min 0 $ n * 7 - 100)
               , Light 1
               , Fragile ]
  , idesc    = "Sticky oil, burning brightly."
  }

explosionBlast :: Int -> ItemKind
explosionBlast n = ItemKind
  { isymbol  = '\''
  , iname    = "explosion blast"
  , ifreq    = [("explosion blast" <+> tshow n, 1)]
  , iflavour = zipPlain [BrWhite]
  , icount   = 12  -- strong, but few, so not always hits target
  , iverbApply   = "blast"
  , iverbProject = "give off"
  , iweight  = 1
  , iaspects = []
  , ieffects = [Burn (n `div` 2), DropBestWeapon]
  , ifeature = [Light n, Fragile, Linger 10]
  , idesc    = ""
  }
