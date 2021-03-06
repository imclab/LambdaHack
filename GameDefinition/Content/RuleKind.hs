{-# LANGUAGE TemplateHaskell #-}
-- | Game rules and assorted game setup data for LambdaHack.
module Content.RuleKind ( cdefs ) where

import Control.Arrow (first)
import Language.Haskell.TH.Syntax
import System.FilePath

-- Cabal
import qualified Paths_LambdaHack as Self (getDataFileName, version)

import Game.LambdaHack.Common.ContentDef
import qualified Game.LambdaHack.Common.Effect as Effect
import qualified Game.LambdaHack.Common.Feature as F
import Game.LambdaHack.Common.HumanCmd
import qualified Game.LambdaHack.Common.Key as K
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.RuleKind

cdefs :: ContentDef RuleKind
cdefs = ContentDef
  { getSymbol = rsymbol
  , getName = rname
  , getFreq = rfreq
  , validate = validateRuleKind
  , content =
      [standard]
  }

standard :: RuleKind
standard = RuleKind
  { rsymbol        = 's'
  , rname          = "standard LambdaHack ruleset"
  , rfreq          = [("standard", 100)]
  -- Check whether one position is accessible from another.
  -- Precondition: the two positions are next to each other.
  -- Apart of checking the target tile, we forbid diagonal movement
  -- to and from doors.
  , raccessible    = Nothing
  , raccessibleDoor = Just $ \spos tpos ->
                                not $ isDiagonal $ displacement spos tpos
  , rtitle         = "LambdaHack"
  , rpathsDataFile = Self.getDataFileName
  , rpathsVersion  = Self.version
  , ritemMelee     = ")"
  , ritemRanged    = "|"
  -- Wasting weapons and armour would be too cruel to the player.
  , ritemProject   = "!?|/"
  -- The strings containing the default configuration file
  -- included from config.ui.default.
  , rcfgUIName = "config.ui"
  , rcfgUIDefault = $(do
      let path = "GameDefinition" </> "config.ui" <.> "default"
      qAddDependentFile path
      x <- qRunIO (readFile path)
      lift x)
  -- ASCII art for the Main Menu. Only pure 7-bit ASCII characters are
  -- allowed. The picture should be exactly 24 rows by 80 columns,
  -- plus an extra frame (of any characters) that is ignored.
  -- For a different screen size, the picture is centered and the outermost
  -- rows and columns cloned. When displayed in the Main Menu screen,
  -- it's overwritten with the game version string and keybinding strings.
  -- The game version string begins and ends with a space and is placed
  -- in the very bottom right corner. The keybindings overwrite places
  -- marked with 25 left curly brace signs '{' in a row. The sign is forbidden
  -- everywhere else. A specific number of such places with 25 left braces
  -- are required, at most one per row, and all are overwritten
  -- with text that is flushed left and padded with spaces.
  -- The Main Menu is displayed dull white on black.
  -- TODO: Show highlighted keybinding in inverse video or bright white on grey
  -- background. The spaces that pad keybindings are not highlighted.
  , rmainMenuArt = $(do
      let path = "GameDefinition/MainMenu.ascii"
      qAddDependentFile path
      x <- qRunIO (readFile path)
      lift x)
  , rhumanCommands = map (first K.mkKM)
      -- All commands are defined here, except some movement and leader picking
      -- commands. All commands are shown on help screens except debug commands
      -- and macros with empty descriptions.
      -- The order below determines the order on the help screens.
      -- Remember to put commands that show information (e.g., enter targeting
      -- mode) first.

      -- Main Menu, which apart of these includes a few extra commands
      [ ("CTRL-x", (CmdMenu, GameExit))
      , ("CTRL-r", (CmdMenu, GameRestart "campaign"))
      , ("CTRL-k", (CmdMenu, GameRestart "skirmish"))
      , ("CTRL-v", (CmdMenu, GameRestart "PvP"))
      , ("CTRL-o", (CmdMenu, GameRestart "Coop"))
      , ("CTRL-e", (CmdMenu, GameRestart "defense"))
      , ("CTRL-d", (CmdMenu, GameDifficultyCycle))

      -- Movement and terrain alteration
      , ("less", (CmdMove, TriggerTile
           [ TriggerFeature { verb = "ascend"
                            , object = "a level"
                            , feature = F.Cause (Effect.Ascend 1) }
           , TriggerFeature { verb = "escape"
                            , object = "dungeon"
                            , feature = F.Cause (Effect.Escape 1) } ]))
      , ("CTRL-less", (CmdMove, TriggerTile
           [ TriggerFeature { verb = "ascend"
                            , object = "10 levels"
                            , feature = F.Cause (Effect.Ascend 10) } ]))
      , ("greater", (CmdMove, TriggerTile
           [ TriggerFeature { verb = "descend"
                            , object = "a level"
                            , feature = F.Cause (Effect.Ascend (-1)) }
           , TriggerFeature { verb = "escape"
                            , object = "dungeon"
                            , feature = F.Cause (Effect.Escape (-1)) } ]))
      , ("CTRL-greater", (CmdMove, TriggerTile
           [ TriggerFeature { verb = "descend"
                            , object = "10 levels"
                            , feature = F.Cause (Effect.Ascend (-10)) } ]))
      , ("CTRL-semicolon", (CmdMove, StepToTarget))
      , ("semicolon", (CmdMove, Macro "go to target for 100 steps"
                                      ["CTRL-semicolon", "P"]))
      , ("x", (CmdMove, Macro "explore the closest unknown spot"
                              [ "BackSpace"
                              , "CTRL-question", "CTRL-semicolon", "P" ]))
      , ("X", (CmdMove, Macro "autoexplore 100 times"
                              [ "BackSpace"
                              , "'", "CTRL-question", "CTRL-semicolon", "'"
                              , "P" ]))
      , ("R", (CmdMove, Macro "rest (wait 100 times)" ["KP_Begin", "P"]))
      , ("c", (CmdMove, AlterDir
           [ AlterFeature { verb = "close"
                          , object = "door"
                          , feature = F.CloseTo "vertical closed door Lit" }
           , AlterFeature { verb = "close"
                          , object = "door"
                          , feature = F.CloseTo "horizontal closed door Lit" }
           , AlterFeature { verb = "close"
                          , object = "door"
                          , feature = F.CloseTo "vertical closed door Dark" }
           , AlterFeature { verb = "close"
                          , object = "door"
                          , feature = F.CloseTo "horizontal closed door Dark" }
           ]))
      , ("o", (CmdMove, AlterDir
           [ AlterFeature { verb = "open"
                          , object = "door"
                          , feature = F.OpenTo "vertical open door Lit" }
           , AlterFeature { verb = "open"
                          , object = "door"
                          , feature = F.OpenTo "horizontal open door Lit" }
           , AlterFeature { verb = "open"
                          , object = "door"
                          , feature = F.OpenTo "vertical open door Dark" }
           , AlterFeature { verb = "open"
                          , object = "door"
                          , feature = F.OpenTo "horizontal open door Dark" }
           ]))

      -- Inventory and items
      , ("I", (CmdItem, Inventory))
      , ("g", (CmdItem, Pickup))
      , ("d", (CmdItem, Drop))
      , ("q", (CmdItem, Apply [ApplyItem { verb = "quaff"
                                         , object = "potion"
                                         , symbol = '!' }]))
      , ("r", (CmdItem, Apply [ApplyItem { verb = "read"
                                         , object = "scroll"
                                         , symbol = '?' }]))
      , ("t", (CmdItem, Project [ApplyItem { verb = "throw"
                                           , object = "missile"
                                           , symbol = '|' }]))
      , ("z", (CmdItem, Project [ApplyItem { verb = "zap"
                                           , object = "wand"
                                           , symbol = '/' }]))

      -- Targeting
      , ("asterisk", (CmdTgt, TgtEnemy))
      , ("slash", (CmdTgt, TgtFloor))
      , ("plus", (CmdTgt, EpsIncr True))
      , ("minus", (CmdTgt, EpsIncr False))
      , ("BackSpace", (CmdTgt, TgtClear))
      , ("CTRL-question", (CmdTgt, TgtUnknown))
      , ("CTRL-I", (CmdTgt, TgtItem))
      , ("CTRL-braceleft", (CmdTgt, TgtStair True))
      , ("CTRL-braceright", (CmdTgt, TgtStair False))

      -- Assorted
      , ("question", (CmdMeta, Help))
      , ("D", (CmdMeta, History))
      , ("T", (CmdMeta, MarkSuspect))
      , ("V", (CmdMeta, MarkVision))
      , ("S", (CmdMeta, MarkSmell))
      , ("Tab", (CmdMeta, MemberCycle))
      , ("ISO_Left_Tab", (CmdMeta, MemberBack))
      , ("equal", (CmdMeta, SelectActor))
      , ("underscore", (CmdMeta, SelectNone))
      , ("p", (CmdMeta, Repeat 1))
      , ("P", (CmdMeta, Repeat 100))
      , ("CTRL-p", (CmdMeta, Repeat 1000))
      , ("apostrophe", (CmdMeta, Record))
      , ("space", (CmdMeta, Clear))
      , ("Escape", (CmdMeta, Cancel))
      , ("Return", (CmdMeta, Accept))

      -- Debug and others not to display in help screens
      , ("CTRL-s", (CmdDebug, GameSave))
      , ("CTRL-y", (CmdDebug, Resend))
      ]
  , rfirstDeathEnds = False
  , rfovMode = Digital 12
  , rsaveBkpClips = 500
  , rleadLevelClips = 100
  , rscoresFile = "scores"
  , rsavePrefix = "save"
  }
