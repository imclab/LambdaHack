{-# LANGUAGE DeriveGeneric, GeneralizedNewtypeDeriving #-}
-- | Screen frames and animations.
module Game.LambdaHack.Client.UI.Animation
  ( SingleFrame(..), decodeLine, encodeLine
  , overlayOverlay
  , Animation, Frames, renderAnim, restrictAnim
  , twirlSplash, blockHit, blockMiss, deathBody, swapPlaces, fadeout
  ) where

import Control.Exception.Assert.Sugar
import Data.Binary
import Data.Bits
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Int (Int32)
import Data.List
import Data.Maybe
import Data.Monoid
import qualified Data.Text as T
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Unboxed as U
import GHC.Generics (Generic)

import Game.LambdaHack.Common.Color
import qualified Game.LambdaHack.Common.Color as Color
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random

type ScreenLine = U.Vector Int32

decodeLine :: ScreenLine -> [AttrChar]
decodeLine v = map (toEnum . fromIntegral) $ G.toList v

encodeLine :: [AttrChar] -> ScreenLine
encodeLine l = G.fromList $ map (fromIntegral . fromEnum) l

-- | The data sufficent to draw a single game screen frame.
data SingleFrame = SingleFrame
  { sfLevel  :: ![ScreenLine]  -- ^ screen, from top to bottom, line by line
  , sfTop    :: !Overlay       -- ^ some extra lines to show over the top
  , sfBottom :: ![ScreenLine]  -- ^ some extra lines to show at the bottom
  , sfBlank  :: !Bool          -- ^ display only @sfTop@, on blank screen
  }
  deriving (Eq, Show, Generic)

instance Binary SingleFrame

-- | Overlays the @sfTop@ and @sfBottom@ fields onto the @sfLevel@ field.
-- The resulting frame has empty @sfTop@ and @sfBottom@.
-- To be used by simple frontends that don't display overlays
-- in separate windows/panes/scrolled views.
overlayOverlay :: SingleFrame -> SingleFrame
overlayOverlay SingleFrame{..} =
  let lxsize = fst normalLevelBound + 1  -- TODO
      lysize = snd normalLevelBound + 1
      emptyLine = encodeLine
                  $ replicate lxsize (Color.AttrChar Color.defAttr ' ')
      canvasLength = if sfBlank then lysize + 3 else lysize + 1
      canvas | sfBlank = replicate canvasLength emptyLine
             | otherwise = emptyLine : sfLevel
      topTrunc = map (truncateMsg lxsize) $ overlay sfTop
      topLayer = if length topTrunc <= canvasLength
                 then topTrunc
                 else take (canvasLength - 1) topTrunc
                      ++ ["--a portion of the text trimmed--"]
      addAttr t = map (Color.AttrChar Color.defAttr) (T.unpack t)
      f layerLine canvasLine = encodeLine
        $ addAttr layerLine
          ++ drop (T.length layerLine) (decodeLine canvasLine)
      picture = zipWith f topLayer canvas
      bottomLines = if sfBlank then [] else sfBottom
      newLevel = picture ++ drop (length picture) canvas ++ bottomLines
  in SingleFrame { sfLevel = newLevel
                 , sfTop = emptyOverlay
                 , sfBottom = []
                 , sfBlank }

-- | Animation is a list of frame modifications to play one by one,
-- where each modification if a map from positions to level map symbols.
newtype Animation = Animation [EM.EnumMap Point AttrChar]
  deriving (Eq, Show, Monoid)

-- | Sequences of screen frames, including delays.
type Frames = [Maybe SingleFrame]

-- | Render animations on top of a screen frame.
renderAnim :: X -> Y -> SingleFrame -> Animation -> Frames
renderAnim lxsize lysize basicFrame (Animation anim) =
  let modifyFrame SingleFrame{sfLevel = []} _ =
        assert `failure` (lxsize, lysize, basicFrame, anim)
      modifyFrame SingleFrame{sfLevel = levelOld, ..} am =
        let fLine y lineOld =
              let f l (x, acOld) =
                    let pos = Point x y
                        !ac = fromMaybe acOld $ EM.lookup pos am
                    in ac : l
              in foldl' f [] (zip [lxsize-1,lxsize-2..0] (reverse lineOld))
            sfLevel =  -- fully evaluated inside
              let f l (y, lineOld) = let !line = fLine y lineOld in line : l
              in map encodeLine
                 $ foldl' f [] (zip [lysize-1,lysize-2..0]
                                $ reverse $ map decodeLine levelOld)
        in Just SingleFrame{..}  -- a thunk within Just
  in Nothing : map (modifyFrame basicFrame) anim ++ [Nothing]

blank :: Maybe AttrChar
blank = Nothing

coloredSymbol :: Color -> Char -> Maybe AttrChar
coloredSymbol color symbol = Just $ AttrChar (Attr color defBG) symbol

mzipPairs :: (Point, Point) -> (Maybe AttrChar, Maybe AttrChar)
          -> [(Point, AttrChar)]
mzipPairs (p1, p2) (mattr1, mattr2) =
  let mzip (pos, mattr) = fmap (\x -> (pos, x)) mattr
  in catMaybes $ if p1 /= p2
                 then [mzip (p1, mattr1), mzip (p2, mattr2)]
                 else -- If actor affects himself, show only the effect,
                      -- not the action.
                      [mzip (p1, mattr1)]

restrictAnim :: ES.EnumSet Point -> Animation -> Animation
restrictAnim vis (Animation as) =
  let f imap =
        let common = EM.intersection imap $ EM.fromSet (const ()) vis
          in if EM.null common then Nothing else Just common
  in Animation $ mapMaybe f as

-- | Attack animation. A part of it also reused for self-damage and healing.
twirlSplash :: (Point, Point) -> Color -> Color -> Animation
twirlSplash poss c1 c2 = Animation $ map (EM.fromList . mzipPairs poss)
  [ (blank                    , coloredSymbol BrCyan '\'')
  , (blank                    , coloredSymbol BrYellow '^')
  , (coloredSymbol c1      '/', coloredSymbol BrCyan '^')
  , (coloredSymbol c1      '-', blank)
  , (coloredSymbol c1      '\\',blank)
  , (coloredSymbol c1      '|', blank)
  , (coloredSymbol c2      '%', blank)
  , (coloredSymbol c2      '/', blank)
  ]

-- | Attack that hits through a block.
blockHit :: (Point, Point) -> Color -> Color -> Animation
blockHit poss c1 c2 = Animation $ map (EM.fromList . mzipPairs poss)
  [ (blank                    , coloredSymbol BrCyan '\'')
  , (blank                    , coloredSymbol BrYellow '^')
  , (blank                    , coloredSymbol BrCyan '^')
  , (coloredSymbol BrBlue  '{', coloredSymbol BrYellow '\'')
  , (coloredSymbol BrBlue  '{', blank)
  , (coloredSymbol BrBlue  '}', blank)
  , (coloredSymbol BrBlue  '}', blank)
  , (coloredSymbol c1      '\\',blank)
  , (coloredSymbol c1      '|', blank)
  , (coloredSymbol c2      '%', blank)
  , (coloredSymbol c2      '/', blank)
  ]

-- | Attack that is blocked.
blockMiss :: (Point, Point) -> Animation
blockMiss poss = Animation $ map (EM.fromList . mzipPairs poss)
  [ (blank                    , coloredSymbol BrCyan '\'')
  , (coloredSymbol BrBlue  '{', coloredSymbol BrYellow '^')
  , (coloredSymbol BrBlue  '{', blank)
  , (coloredSymbol BrBlue  '}', blank)
  , (coloredSymbol Blue    '}', blank)
  ]

-- | Death animation for an organic body.
deathBody :: Point -> Animation
deathBody pos = Animation $ map (maybe EM.empty (EM.singleton pos))
  [ coloredSymbol BrRed '\\'
  , coloredSymbol BrRed '\\'
  , coloredSymbol BrRed '|'
  , coloredSymbol BrRed '|'
  , coloredSymbol BrRed '%'
  , coloredSymbol BrRed '%'
  , coloredSymbol Red   '%'
  , coloredSymbol Red   '%'
  , coloredSymbol Red   '%'
  , coloredSymbol Red   ';'
  , coloredSymbol Red   ';'
  , coloredSymbol Red   ','
  ]

-- | Swap-places animation, both hostile and friendly.
swapPlaces :: (Point, Point) -> Animation
swapPlaces poss = Animation $ map (EM.fromList . mzipPairs poss)
  [ (coloredSymbol BrMagenta 'o', coloredSymbol Magenta   'o')
  , (coloredSymbol BrMagenta 'd', coloredSymbol Magenta   'p')
  , (coloredSymbol Magenta   'p', coloredSymbol BrMagenta 'd')
  , (coloredSymbol Magenta   'o', blank)
  ]

fadeout :: Bool -> Bool -> Int -> X -> Y -> Rnd Animation
fadeout out topRight step lxsize lysize = do
  let xbound = lxsize - 1
      ybound = lysize - 1
      edge = EM.fromDistinctAscList $ zip [1..] ".%&%;:,."
      fadeChar r n x y =
        let d = x - 2 * y
            ndy = n - d - 2 * ybound
            ndx = n + d - xbound - 1  -- @-1@ for asymmetry
            mnx = if ndy > 0 && ndx > 0
                  then min ndy ndx
                  else max ndy ndx
            v3 = (r `xor` (x * y)) `mod` 3
            k | mnx < 3 || mnx > 10 = mnx
              | (min x (xbound - x - y) + n + v3) `mod` 15 < 11
                && mnx > 6 = mnx - v3
              | (x + 3 * y + v3) `mod` 30 < 19 = mnx + 1
              | otherwise = mnx
        in EM.findWithDefault ' ' k edge
      rollFrame n = do
        r <- random
        let l = [ ( Point (if topRight then x else xbound - x) y
                  , AttrChar defAttr $ fadeChar r n x y )
                | x <- [0..xbound]
                , y <- [max 0 (ybound - (n - x) `div` 2)..ybound]
                    ++ [0..min ybound ((n - xbound + x) `div` 2)]
                ]
        return $! EM.fromList l
      startN = if out then 3 else 1
      fs = [startN, startN + step .. 3 * lxsize `divUp` 4 + 2]
  as <- mapM rollFrame $ if out then fs else reverse fs
  return $! Animation as
