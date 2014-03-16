-- | Atomic monads.
module Game.LambdaHack.Atomic
  ( -- * MonadAtomic
    MonadAtomic(..)
  , broadcastUpdAtomic,  broadcastSfxAtomic
    -- * CmdAtomic
  , CmdAtomic(..), UpdAtomic(..), SfxAtomic(..), HitAtomic(..)
    -- * PosCmdAtomicRead
  , PosAtomic(..), posUpdAtomic, posSfxAtomic, seenAtomicCli, lidOfPosAtomic
  ) where

import Game.LambdaHack.Atomic.CmdAtomic
import Game.LambdaHack.Atomic.MonadAtomic
import Game.LambdaHack.Atomic.PosCmdAtomicRead
