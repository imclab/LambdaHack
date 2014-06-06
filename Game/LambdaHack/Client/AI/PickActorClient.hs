-- | Semantics of most 'ResponseAI' client commands.
module Game.LambdaHack.Client.AI.PickActorClient
  ( pickActorToMove
  ) where

import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import Data.List
import Data.Maybe
import Data.Ord

import Game.LambdaHack.Client.AI.ConditionClient
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Frequency
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Vector

pickActorToMove :: MonadClient m
                => (ActorId -> (ActorId, Actor)
                    -> m (Maybe ((ActorId, Actor), (Target, PathEtc))))
                -> ActorId
                -> m (ActorId, Actor)
pickActorToMove refreshTarget oldAid = do
  cops@Kind.COps{cotile} <- getsState scops
  oldBody <- getsState $ getActorBody oldAid
  let side = bfid oldBody
      arena = blid oldBody
  fact <- getsState $ (EM.! side) . sfactionD
  lvl <- getLevel arena
  let leaderStuck = waitedLastTurn oldBody
      t = lvl `at` bpos oldBody
  mleader <- getsClient _sleader
  ours <- getsState $ actorRegularAssocs (== side) arena
  let pickOld = do
        void $ refreshTarget oldAid (oldAid, oldBody)
        return (oldAid, oldBody)
  case ours of
    _ | -- Keep the leader: only a leader is allowed to pick another leader.
        mleader /= Just oldAid
        -- Keep the leader: all can move. TODO: check not accurate,
        -- instead define 'movesThisTurn' and use elsehwere.
        || isAllMoveFact cops fact
        -- Keep the leader: he is on stairs and not stuck
        -- and we don't want to clog stairs or get pushed to another level.
        || not leaderStuck && Tile.isStair cotile t
      -> pickOld
    [] -> assert `failure` (oldAid, oldBody)
    [_] -> pickOld  -- Keep the leader: he is alone on the level.
    (captain, captainBody) : (sergeant, sergeantBody) : _ -> do
      -- At this point we almost forget who the old leader was
      -- and treat all party actors the same, eliminating candidates
      -- until we can't distinguish them any more, at which point we prefer
      -- the old leader, if he is among the best candidates
      -- (to make the AI appear more human-like and easier to observe).
      -- TODO: this also takes melee into account, but not shooting.
      oursTgt <- fmap catMaybes $ mapM (refreshTarget oldAid) ours
      let actorWeak ((aid, body), _) = do
            condMeleeBad <- condMeleeBadM aid
            threatDistL <- threatDistList aid
            fleeL <- fleeList aid
            let condThreatAdj =
                  not $ null $ takeWhile ((== 1) . fst) threatDistL
                condFastThreatAdj =
                  any (\(_, (_, b)) -> bspeed b > bspeed body)
                  $ takeWhile ((== 1) . fst) threatDistL
                condCanFlee = not (null fleeL || condFastThreatAdj)
            return $! if condThreatAdj
                      then condMeleeBad && condCanFlee
                      else bcalmDelta body < -1  -- hit by a projectile
                        -- TODO: modify when reaction fire is possible
          actorHearning (_, (TEnemyPos{}, (_, (_, d)))) | d <= 2 =
            return False  -- noise probably due to fleeing target
          actorHearning ((_aid, b), _) = do
            allFoes <- getsState $ actorRegularList (isAtWar fact) (blid b)
            let closeFoes = filter ((<= 3) . chessDist (bpos b) . bpos) allFoes
            return $! bcalmDelta b == -1  -- hears an enemy
                      && null closeFoes  -- the enemy not visible; a trap!
          -- AI has to be prudent and not lightly waste leader for meleeing,
          -- even if his target is distant
          actorMeleeing ((aid, _), _) = condAnyFoeAdjM aid
      oursWeak <- filterM actorWeak oursTgt
      oursStrong <- filterM (fmap not . actorWeak) oursTgt  -- TODO: partitionM
      oursMeleeing <- filterM actorMeleeing oursStrong
      oursNotMeleeing <- filterM (fmap not . actorMeleeing) oursStrong
      oursHearing <- filterM actorHearning oursNotMeleeing
      oursNotHearing <- filterM (fmap not . actorHearning) oursNotMeleeing
      let targetTEnemy (_, (TEnemy{}, _)) = True
          targetTEnemy (_, (TEnemyPos{}, _)) = True
          targetTEnemy _ = False
          (oursTEnemy, oursOther) = partition targetTEnemy oursNotHearing
          -- These are not necessarily stuck (perhaps can go around),
          -- but their current path is blocked by friends.
          targetBlocked our@((_aid, _b), (_tgt, (path, _etc))) =
            let next = case path of
                  [] -> assert `failure` our
                  [_goal] -> Nothing
                  _ : q : _ -> Just q
            in any ((== next) . Just . bpos . snd) ours
-- TODO: stuck actors are picked while others close could approach an enemy;
-- we should detect stuck actors (or one-sided stuck)
-- so far we only detect blocked and only in Other mode
--             && not (aid == oldAid && waitedLastTurn b time)  -- not stuck
-- this only prevents staying stuck
          (oursBlocked, oursPos) = partition targetBlocked oursOther
          -- Lower overhead is better.
          overheadOurs :: ((ActorId, Actor), (Target, PathEtc))
                       -> (Int, Int, Bool)
          overheadOurs our@((aid, b), (_, (_, (goal, d)))) =
            if targetTEnemy our then
              -- TODO: take weapon, walk and fight speed, etc. into account
              ( d + if targetBlocked our then 2 else 0  -- possible delay, hacky
              , - 10 * (bhp b `div` 10)
              , aid /= oldAid )
            else
              -- Keep proper formation, not too dense, not to sparse.
              let
                -- TODO: vary the parameters according to the stage of game,
                -- enough equipment or not, game mode, level map, etc.
                minSpread = 7
                maxSpread = 12 * 2
                dcaptain p =
                  chessDistVector $ bpos captainBody `vectorToFrom` p
                dsergeant p =
                  chessDistVector $ bpos sergeantBody `vectorToFrom` p
                minDist | aid == captain = dsergeant (bpos b)
                        | aid == sergeant = dcaptain (bpos b)
                        | otherwise = dsergeant (bpos b)
                                      `min` dcaptain (bpos b)
                pDist p = dcaptain p + dsergeant p
                sumDist = pDist (bpos b)
                -- Positive, if the goal gets us closer to the party.
                diffDist = sumDist - pDist goal
                minCoeff | minDist < minSpread =
                  (minDist - minSpread) `div` 3
                  - if aid == oldAid then 3 else 0
                         | otherwise = 0
                explorationValue = diffDist * (sumDist `div` 4)
-- TODO: this half is not yet ready:
-- instead spread targets between actors; moving many actors
-- to a single target and stopping and starting them
-- is very wasteful; also, pick targets not closest to the actor in hand,
-- but to the sum of captain and sergant or something
                sumCoeff | sumDist > maxSpread = - explorationValue
                         | otherwise = 0
              in ( if d == 0 then d
                   else max 1 $ minCoeff + if d < 10
                                           then 3 + d `div` 4
                                           else 9 + d `div` 10
                 , sumCoeff
                 , aid /= oldAid )
          sortOurs = sortBy $ comparing overheadOurs
          goodGeneric ((aid, b), (_tgt, _pathEtc)) =
            not (aid == oldAid && waitedLastTurn b)  -- not stuck
          goodTEnemy our@((_aid, b), (TEnemy{}, (_path, (goal, _d)))) =
            not (adjacent (bpos b) goal) -- not in melee range already
            && goodGeneric our
          goodTEnemy our = goodGeneric our
          oursWeakGood = filter goodTEnemy oursWeak
          oursTEnemyGood = filter goodTEnemy oursTEnemy
          oursPosGood = filter goodGeneric oursPos
          oursMeleeingGood = filter goodGeneric oursMeleeing
          oursHearingGood = filter goodTEnemy oursHearing
          oursBlockedGood = filter goodGeneric oursBlocked
          candidates = [ sortOurs oursWeakGood
                       , sortOurs oursTEnemyGood
                       , sortOurs oursPosGood
                       , sortOurs oursMeleeingGood
                       , sortOurs oursHearingGood
                       , sortOurs oursBlockedGood
                       ]
      case filter (not . null) candidates of
        l@(c : _) : _ -> do
          let best = takeWhile ((== overheadOurs c) . overheadOurs) l
              freq = uniformFreq "candidates for AI leader" best
          ((aid, b), _) <- rndToAction $ frequency freq
          s <- getState
          modifyClient $ updateLeader aid s
          return (aid, b)
        _ -> return (oldAid, oldBody)
