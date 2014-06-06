{-# LANGUAGE FlexibleContexts #-}
-- | Semantics of responses that are sent to clients.
--
-- See
-- <https://github.com/kosmikus/LambdaHack/wiki/Client-server-architecture>.
module Game.LambdaHack.Client
  ( exeFrontend
  ) where

import Game.LambdaHack.Atomic
import Game.LambdaHack.Client.LoopClient
import Game.LambdaHack.Client.ProtocolClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI
import Game.LambdaHack.Common.ClientOptions
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.Response
import Game.LambdaHack.Common.State

-- | Wire together game content, the main loop of game clients,
-- the main game loop assigned to this frontend (possibly containing
-- the server loop, if the whole game runs in one process),
-- UI config and the definitions of game commands.
exeFrontend :: ( MonadAtomic m, MonadClientUI m
               , MonadClientReadResponse ResponseUI m
               , MonadClientWriteRequest RequestUI m
               , MonadAtomic n
               , MonadClientReadResponse ResponseAI n
               , MonadClientWriteRequest RequestAI n )
            => (m () -> SessionUI -> State -> StateClient
                -> chanServerUI
                -> IO ())
            -> (n () -> SessionUI -> State -> StateClient
                -> chanServerAI
                -> IO ())
            -> KeyKind -> Kind.COps -> DebugModeCli
            -> ((FactionId -> chanServerUI -> IO ())
               -> (FactionId -> chanServerAI -> IO ())
               -> IO ())
            -> IO ()
exeFrontend executorUI executorAI copsClient cops sdebugCli exeServer =
  srtFrontend (executorUI . loopUI)
              (executorAI . loopAI)
              copsClient cops sdebugCli exeServer
