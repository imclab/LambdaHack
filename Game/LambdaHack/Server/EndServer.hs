-- | The main loop of the server, processing human and computer player
-- moves turn by turn.
module Game.LambdaHack.Server.EndServer
  ( endOrLoop, dieSer, dropEqpItem, dropEqpItems
  ) where

import Control.Exception.Assert.Sugar
import Control.Monad
import Data.Bits (xor)
import qualified Data.EnumMap.Strict as EM
import Data.Maybe
import Data.Text (Text)

import Game.LambdaHack.Atomic
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Frequency
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.State
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Server.CommonServer
import Game.LambdaHack.Server.ItemRev
import Game.LambdaHack.Server.ItemServer
import Game.LambdaHack.Server.MonadServer
import Game.LambdaHack.Server.State

-- | Continue or exit or restart the game.
endOrLoop :: (MonadAtomic m, MonadServer m)
          => m () -> m () -> m () -> m () -> m ()
endOrLoop loop restart gameExit gameSave = do
  factionD <- getsState sfactionD
  let inGame fact = case gquit fact of
        Nothing -> True
        Just Status{stOutcome=Camping} -> True
        _ -> False
      gameOver = not $ any inGame $ EM.elems factionD
  let getQuitter fact = case gquit fact of
        Just Status{stOutcome=Restart, stInfo} -> Just stInfo
        _ -> Nothing
      quitters = mapMaybe getQuitter $ EM.elems factionD
  let isCamper fact = case gquit fact of
        Just Status{stOutcome=Camping} -> True
        _ -> False
      campers = filter (isCamper . snd) $ EM.assocs factionD
  -- Wipe out the quit flag for the savegame files.
  mapM_ (\(fid, fact) ->
            execUpdAtomic
            $ UpdQuitFaction fid Nothing (gquit fact) Nothing) campers
  bkpSave <- getsServer sbkpSave
  when bkpSave $ do
    modifyServer $ \ser -> ser {sbkpSave = False}
    gameSave
  case (quitters, campers) of
    (sgameMode : _, _) -> do
      modifyServer $ \ser -> ser {sdebugNxt = (sdebugNxt ser) {sgameMode}}
      restart
    _ | gameOver -> restart
    ([], []) -> loop  -- continue current game
    ([], _ : _) -> gameExit  -- don't call @loop@, that is, quit the game loop

dieSer :: (MonadAtomic m, MonadServer m) => ActorId -> Actor -> Bool -> m ()
dieSer aid b hit = do
  -- TODO: clients don't see the death of their last standing actor;
  --       modify Draw.hs and Client.hs to handle that
  if bproj b then do
    dropAllItems aid b hit
    b2 <- getsState $ getActorBody aid
    execUpdAtomic $ UpdDestroyActor aid b2 []
  else do
    execUpdAtomic $ UpdRecordKill aid 1
    electLeader (bfid b) (blid b) aid
    dropAllItems aid b False
    b2 <- getsState $ getActorBody aid
    execUpdAtomic $ UpdDestroyActor aid b2 []
    deduceKilled b

-- | Drop all actor's items. If the actor hits another actor and this
-- collision results in all item being dropped, all items are destroyed.
-- If the actor does not hit, but dies, only fragile items are destroyed
-- and only if the actor was a projectile (and so died by dropping
-- to the ground due to exceeded range or bumping off an obstacle).
dropAllItems :: (MonadAtomic m, MonadServer m)
             => ActorId -> Actor -> Bool -> m ()
dropAllItems aid b hit = do
  stashAllItems aid b
  dropEqpItems aid b hit

stashAllItems :: (MonadAtomic m, MonadServer m)
              => ActorId -> Actor -> m ()
stashAllItems aid b = do
  Kind.COps{corule} <- getsState scops
  let RuleKind{rsharedInventory} = Kind.stdRuleset corule
      loseInv = do
        let g iid (k, _) = do
              mvCmd <- generalMoveItem iid k (CActor aid CInv) (CActor aid CEqp)
              mapM_ execUpdAtomic mvCmd
        mapActorInv_ g b
  if not rsharedInventory then loseInv
  else do
    fact <- getsState $ (EM.! bfid b) . sfactionD
    case gleader fact of
      Nothing -> loseInv
      Just leader -> do
        let g iid (k, _) = do
              upds <- generalMoveItem iid k (CActor aid CInv)
                                            (CActor leader CInv)
              mapM_ execUpdAtomic upds
        mapActorInv_ g b

dropEqpItems :: (MonadAtomic m, MonadServer m)
             => ActorId -> Actor -> Bool -> m ()
dropEqpItems aid b hit = mapActorEqp_ (dropEqpItem aid b hit) b

-- | Drop a single actor's item. Note that if there multiple copies,
-- at most one explodes to avoid excessive carnage and UI clutter
-- (let's say, the multiple explosions interfere with each other or perhaps
-- larger quantities of explosives tend to be packaged more safely).
dropEqpItem :: (MonadAtomic m, MonadServer m)
            => ActorId -> Actor -> Bool -> ItemId -> KisOn -> m ()
dropEqpItem aid b hit iid kIsOn = do
  item <- getsState $ getItemBody iid
  itemToF <- itemToFullServer
  let container = CActor aid CEqp
      isDestroyed = hit || bproj b && isFragile item
      itemFull = itemToF iid kIsOn
  if isDestroyed then do
    let expl = groupsExplosive itemFull
    unless (null expl) $ do
      let ik = itemKindId $ fromJust $ itemDisco itemFull
      seed <- getsServer $ (EM.! iid) . sitemSeedD
      execUpdAtomic $ UpdDiscover (blid b) (bpos b) iid ik seed
    -- Feedback from hit, or it's shrapnel, so no @UpdDestroyItem@.
    execUpdAtomic $ UpdLoseItem iid item kIsOn container
    forM_ expl $ explodeItem aid b
  else do
    mvCmd <- generalMoveItem iid (fst kIsOn) (CActor aid CEqp)
                                             (CActor aid CGround)
    mapM_ execUpdAtomic mvCmd

groupsExplosive :: ItemFull -> [Text]
groupsExplosive =
  let p (Effect.Explode cgroup) = [cgroup]
      p _ = []
  in strengthAspect p

explodeItem :: (MonadAtomic m, MonadServer m)
            => ActorId -> Actor -> Text -> m ()
explodeItem aid b cgroup = do
  Kind.COps{coitem} <- getsState scops
  flavour <- getsServer sflavour
  discoRev <- getsServer sdiscoRev
  Level{ldepth} <- getLevel $ blid b
  depth <- getsState sdepth
  let itemFreq = toFreq "shrapnel group" [(1, cgroup)]
  (itemKnown, seed, n1) <-
    rndToAction $ newItem coitem flavour discoRev itemFreq (blid b) ldepth depth
  let container = CActor aid CEqp
  iid <- registerItem itemKnown seed (n1, True) container False
  let Point x y = bpos b
      projectN k100 (n, _) = when (n > 7) $ do
        -- We pick a point at the border, not inside, to have a uniform
        -- distribution for the points the line goes through at each distance
        -- from the source. Otherwise, e.g., the points on cardinal
        -- and diagonal lines from the source would be more common.
        let fuzz = 1 + (k100 `xor` (n1 * n)) `mod` 11
        forM_ [ Point (x - 12) $ y + fuzz
              , Point (x - 12) $ y - fuzz
              , Point (x + 12) $ y + fuzz
              , Point (x + 12) $ y - fuzz
              , flip Point (y - 12) $ x + fuzz
              , flip Point (y - 12) $ x - fuzz
              , flip Point (y + 12) $ x + fuzz
              , flip Point (y + 12) $ x - fuzz
              ] $ \tpxy -> do
          let req = ReqProject tpxy k100 iid CEqp
          mfail <- projectFail aid tpxy k100 iid CEqp True
          case mfail of
            Nothing -> return ()
            Just ProjectBlockTerrain -> return ()
            Just failMsg -> execFailure aid req failMsg
  -- All shrapnels bounce off obstacles many times before they destruct.
  forM_ [101..201] $ \k100 -> do
    bag2 <- getsState $ beqp . getActorBody aid
    let mn2 = EM.lookup iid bag2
    maybe skip (projectN k100) mn2
  bag3 <- getsState $ beqp . getActorBody aid
  let mn3 = EM.lookup iid bag3
  maybe skip (\kIsOn -> execUpdAtomic
             $ UpdLoseItem iid (fst itemKnown) kIsOn container) mn3
