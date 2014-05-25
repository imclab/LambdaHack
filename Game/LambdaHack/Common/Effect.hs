{-# LANGUAGE DeriveFunctor, DeriveGeneric #-}
-- | Effects of content on other content. No operation in this module
-- involves the 'State' or 'Action' type.
module Game.LambdaHack.Common.Effect
  ( Effect(..), Aspect(..)
  , effectTrav, aspectTrav
  , effectToSuffix, aspectToSuffix, kindEffectToSuffix, kindAspectToSuffix
  , affixPower, affixBonus
  ) where

import Control.Exception.Assert.Sugar
import qualified Control.Monad.State as St
import Data.Binary
import qualified Data.Hashable as Hashable
import Data.Text (Text)
import GHC.Generics (Generic)

import qualified Game.LambdaHack.Common.Dice as Dice
import Game.LambdaHack.Common.Msg

-- TODO: document each constructor
-- Effects of items, tiles, etc. The type argument represents power.
-- either as a random formula dependent on level, or as a final rolled value.
data Effect a =
    NoEffect
  | Heal !Int
  | Hurt !Dice.Dice !a
  | Dominate
  | Impress
  | CallFriend !Int
  | Summon !Int
  | CreateItem !Int
  | ApplyPerfume
  | Burn !Int
  | Blast !Int
  | Ascend !Int
  | Escape !Int  -- ^ the argument marks if can be placed on last level, etc.
  | Paralyze !a
  | InsertMove !a
  | DropBestWeapon
  | DropAllEqp !Bool
  | SendFlying !a !a
  | PushActor !a !a
  | PullActor !a !a
  | Teleport !a
  | ActivateAllEqp
  | TimedAspect !Int !(Aspect a)  -- enable the aspect for k clips
  deriving (Show, Read, Eq, Ord, Generic, Functor)

-- Aspects of items, tiles, etc. The type argument represents power.
-- either as a random formula dependent on level, or as a final rolled value.
data Aspect a =
    NoAspect
  | ArmorMelee !Int
  | Haste !Int  -- ^ positive or negative percent change
  | Regeneration !a
  | Steadfastness !a
  | Explode !Text  -- ^ explode, producing this group of shrapnel
  deriving (Show, Read, Eq, Ord, Generic, Functor)

instance Hashable.Hashable a => Hashable.Hashable (Effect a)

instance Hashable.Hashable a => Hashable.Hashable (Aspect a)

instance Binary a => Binary (Effect a)

instance Binary a => Binary (Aspect a)

-- TODO: Traversable?
-- | Transform an effect using a stateful function.
effectTrav :: Effect a -> (a -> St.State s b) -> St.State s (Effect b)
effectTrav NoEffect _ = return NoEffect
effectTrav (Heal p) _ = return $! Heal p
effectTrav (Hurt dice a) f = do
  b <- f a
  return $! Hurt dice b
effectTrav Dominate _ = return Dominate
effectTrav Impress _ = return Impress
effectTrav (CallFriend p) _ = return $! CallFriend p
effectTrav (Summon p) _ = return $! Summon p
effectTrav (CreateItem p) _ = return $! CreateItem p
effectTrav ApplyPerfume _ = return ApplyPerfume
effectTrav (Burn p) _ = return $! Burn p
effectTrav (Blast p) _ = return $! Blast p
effectTrav (Ascend p) _ = return $! Ascend p
effectTrav (Escape p) _ = return $! Escape p
effectTrav (Paralyze a) f = do
  b <- f a
  return $! Paralyze b
effectTrav (InsertMove a) f = do
  b <- f a
  return $! InsertMove b
effectTrav DropBestWeapon _ = return DropBestWeapon
effectTrav (DropAllEqp hit) _ = return $! DropAllEqp hit
effectTrav (SendFlying a1 a2) f = do
  b1 <- f a1
  b2 <- f a2
  return $! SendFlying b1 b2
effectTrav (PushActor a1 a2) f = do
  b1 <- f a1
  b2 <- f a2
  return $! PushActor b1 b2
effectTrav (PullActor a1 a2) f = do
  b1 <- f a1
  b2 <- f a2
  return $! PullActor b1 b2
effectTrav (Teleport a) f = do
  b <- f a
  return $! Teleport b
effectTrav ActivateAllEqp _ = return ActivateAllEqp
effectTrav (TimedAspect k asp) f = do
  asp2 <- aspectTrav asp f
  return $! TimedAspect k asp2

-- | Transform an apsect using a stateful function.
aspectTrav :: Aspect a -> (a -> St.State s b) -> St.State s (Aspect b)
aspectTrav NoAspect _ = return NoAspect
aspectTrav (ArmorMelee p) _ = return $! ArmorMelee p
aspectTrav (Haste p) _ = return $! Haste p
aspectTrav (Regeneration a) f = do
  b <- f a
  return $! Regeneration b
aspectTrav (Steadfastness a) f = do
  b <- f a
  return $! Steadfastness b
aspectTrav (Explode t) _ = return $! Explode t

-- | Suffix to append to a basic content name if the content causes the effect.
effectToSuff :: Show a => Effect a -> (a -> Text) -> Text
effectToSuff effect f =
  case St.evalState (effectTrav effect $ return . f) () of
    NoEffect -> ""
    Heal p | p > 0 -> "of healing" <+> affixBonus p
    Heal 0 -> assert `failure` effect
    Heal p -> "of wounding" <+> affixBonus p
    Hurt dice t -> "(" <> tshow dice <> ")" <+> t
    Dominate -> "of domination"
    Impress -> "of impression"
    CallFriend p -> "of aid calling" <+> affixPower p
    Summon p -> "of summoning" <+> affixPower p
    CreateItem p -> "of item creation" <+> affixPower p
    ApplyPerfume -> "of rose water"
    Burn{} -> ""  -- often accompanies Light, too verbose, too boring
    Blast p -> "of explosion" <+> affixPower p
    Ascend p | p > 0 -> "of ascending" <+> affixPower p
    Ascend 0 -> assert `failure` effect
    Ascend p -> "of descending" <+> affixPower (- p)
    Escape{} -> "of escaping"
    Paralyze t -> "of paralysis" <+> t
    InsertMove t -> "of speed burst" <+> t
    DropBestWeapon -> "of disarming"
    DropAllEqp False -> "of empty hands"
    DropAllEqp True -> "of equipment smashing"
    SendFlying t1 t2 -> "of impact" <+> t1 <+> t2
    PushActor t1 t2 -> "of pushing" <+> t1 <+> t2
    PullActor t1 t2 -> "of pulling" <+> t1 <+> t2
    Teleport t -> "of teleport" <+> t
    ActivateAllEqp -> "of mass activation"
    TimedAspect _ asp -> aspectTextToSuff asp

aspectTextToSuff :: Aspect Text -> Text
aspectTextToSuff aspect =
  case aspect of
    NoAspect -> ""
    ArmorMelee p -> "[" <> tshow p <> "]"
    Haste p | p > 0 -> "of speed" <+> affixBonus p
    Haste 0 -> assert `failure` aspect
    Haste p -> "of slowness" <+> affixBonus (- p)
    Regeneration t -> "of regeneration" <+> t
    Steadfastness t -> "of steadfastness" <+> t
    Explode{} -> ""

aspectToSuff :: Show a => Aspect a -> (a -> Text) -> Text
aspectToSuff aspect f =
  aspectTextToSuff $ St.evalState (aspectTrav aspect $ return . f) ()

effectToSuffix :: Effect Int -> Text
effectToSuffix effect = effectToSuff effect affixBonus

aspectToSuffix :: Aspect Int -> Text
aspectToSuffix aspect = aspectToSuff aspect affixBonus

affixPower :: Int -> Text
affixPower p = case compare p 1 of
  EQ -> ""
  LT -> assert `failure` "power less than 1" `twith` p
  GT -> "(+" <> tshow p <> ")"

affixBonus :: Int -> Text
affixBonus p = case compare p 0 of
  EQ -> ""
  LT -> "(" <> tshow p <> ")"
  GT -> "(+" <> tshow p <> ")"

affixDice :: Dice.Dice -> Text
affixDice d = if Dice.minDice d == Dice.maxDice d
               then affixBonus (Dice.minDice d)
               else "(?)"

kindEffectToSuffix :: Effect Dice.Dice -> Text
kindEffectToSuffix effect = effectToSuff effect affixDice

kindAspectToSuffix :: Aspect Dice.Dice -> Text
kindAspectToSuffix aspect = aspectToSuff aspect affixDice
