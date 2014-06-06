-- | Semantics of requests that are sent to the server.
--
-- See
-- <https://github.com/kosmikus/LambdaHack/wiki/Client-server-architecture>.
module Game.LambdaHack.Server
  ( mainSer
  ) where

import Control.Concurrent
import qualified Control.Exception as Ex hiding (handle)

import Game.LambdaHack.Atomic
import Game.LambdaHack.Common.ClientOptions
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.Response
import Game.LambdaHack.Common.Thread
import Game.LambdaHack.Server.Commandline
import Game.LambdaHack.Server.LoopServer
import Game.LambdaHack.Server.MonadServer
import Game.LambdaHack.Server.ProtocolServer
import Game.LambdaHack.Server.State

-- | Fire up the frontend with the engine fueled by content.
-- The action monad types to be used are determined by the 'exeSer'
-- and 'executorCli' calls. If other functions are used in their place
-- the types are different and so the whole pattern of computation
-- is different. Which of the frontends is run depends on the flags supplied
-- when compiling the engine library.
mainSer :: (MonadAtomic m, MonadServerReadRequest m)
        => Kind.COps
        -> (m () -> IO ())
        -> (Kind.COps -> DebugModeCli
            -> ((FactionId -> ChanServer ResponseUI RequestUI
                 -> IO ())
                -> (FactionId -> ChanServer ResponseAI RequestAI
                    -> IO ())
                -> IO ())
            -> IO ())
        -> IO ()
mainSer !copsSlow  -- evaluate fully to discover errors ASAP and free memory
        exeSer exeFront = do
  sdebugNxt <- debugArgs
  let cops = speedupCOps False copsSlow
      exeServer executorUI executorAI = do
        -- Wait for clients to exit even in case of server crash
        -- (or server and client crash), which gives them time to save.
        -- TODO: send them a message to tell users "server crashed"
        -- and then let them exit.
        Ex.finally
          (exeSer (loopSer sdebugNxt executorUI executorAI cops))
          (threadDelay 100000)  -- server crashed, show the error eventually
        waitForChildren childrenServer  -- no crash, wait indefinitely
  exeFront cops (sdebugCli sdebugNxt) exeServer
