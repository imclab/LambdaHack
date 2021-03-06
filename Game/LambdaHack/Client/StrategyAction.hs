-- | AI strategy operations implemented with the 'Action' monad.
module Game.LambdaHack.Client.StrategyAction
  ( targetStrategy, actionStrategy
  ) where

import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Function
import Data.List
import Data.Maybe
import Data.Ord
import qualified Data.Traversable as Traversable

import Game.LambdaHack.Client.Action
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.Strategy
import Game.LambdaHack.Common.Ability (Ability)
import qualified Game.LambdaHack.Common.Ability as Ability
import Game.LambdaHack.Common.Action
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Feature as F
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import qualified Game.LambdaHack.Common.Random as Random
import Game.LambdaHack.Common.ServerCmd
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.FactionKind
import Game.LambdaHack.Content.ItemKind
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Content.TileKind as TileKind
import Game.LambdaHack.Utils.Frequency

-- | AI proposes possible targets for the actor. Never empty.
targetStrategy :: forall m. MonadClient m
               => ActorId -> ActorId -> m (Strategy (Target, PathEtc))
targetStrategy oldLeader aid = do
  Kind.COps{ cotile=cotile@Kind.Ops{ouniqGroup}
           , coactor=Kind.Ops{okind}
           , cofaction=Kind.Ops{okind=fokind} } <- getsState scops
  modifyClient $ \cli -> cli {sbfsD = EM.delete aid (sbfsD cli)}
  b <- getsState $ getActorBody aid
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  oldTgtUpdatedPath <- case mtgtMPath of
    Just (tgt, Just path) -> do
      mvalidPos <- aidTgtToPos aid (blid b) (Just tgt)
      if isNothing mvalidPos then return Nothing  -- wrong level
      else return $! case path of
        (p : q : rest, (goal, len)) ->
          if bpos b == p
          then Just (tgt, path)  -- no move last turn
          else if bpos b == q
               then Just (tgt, (q : rest, (goal, len - 1)))  -- step along path
               else Nothing  -- veered off the path
        ([p], (goal, _)) -> do
          assert (p == goal `blame` (aid, b, mtgtMPath)) skip
          if bpos b == p then
            Just (tgt, path)  -- goal reached; stay there picking up items
          else
            Nothing  -- somebody pushed us off the goal; let's target again
        ([], _) -> assert `failure` (aid, b, mtgtMPath)
    Just (_, Nothing) -> return Nothing  -- path invalidated, e.g. SpotActorA
    Nothing -> return Nothing  -- no target assigned yet
  lvl <- getLevel $ blid b
  assert (not $ bproj b) skip  -- would work, but is probably a bug
  fact <- getsState $ \s -> sfactionD s EM.! bfid b
  allFoes <- getsState $ actorNotProjAssocs (isAtWar fact) (blid b)
  dungeon <- getsState sdungeon
  -- TODO: we assume the actor eventually becomes a leader (or has the same
  -- set of abilities as the leader, anyway) and set his target accordingly.
  actorAbs <- actorAbilities aid (Just aid)
  let nearby = 10
      nearbyFoes = filter (\(_, body) ->
                             chessDist (bpos body) (bpos b) < nearby) allFoes
      unknownId = ouniqGroup "unknown space"
      -- TODO: make more common when weak ranged foes preferred, etc.
      focused = bspeed b < speedNormal
      canSmell = asmell $ okind $ bkind b
      setPath :: Target -> m (Strategy (Target, PathEtc))
      setPath tgt = do
        mpos <- aidTgtToPos aid (blid b) (Just tgt)
        let p = fromMaybe (assert `failure` (b, tgt)) mpos
        (bfs, mpath) <- getCacheBfsAndPath aid p
        case mpath of
          Nothing -> assert `failure` "new target unreachable" `twith` (b, tgt)
          Just path ->
            return $! returN "pickNewTarget"
              (tgt, ( bpos b : path
                    , (p, fromMaybe (assert `failure` mpath)
                          $ accessBfs bfs p) ))
      pickNewTarget :: m (Strategy (Target, PathEtc))
      pickNewTarget = do
        -- TODO: for foes, items, etc. consider a few nearby, not just one
        cfoes <- closestFoes aid
        case cfoes of
          (_, (a, _)) : _ -> setPath $ TEnemy a False
          [] -> do
            -- Tracking enemies is more important than exploring,
            -- and smelling actors are usually blind, so bad at exploring.
            -- TODO: prefer closer items to older smells
            smpos <- if canSmell
                     then closestSmell aid
                     else return []
            case smpos of
              [] -> do
                citems <- if Ability.Pickup `elem` actorAbs
                          then closestItems aid
                          else return []
                case citems of
                  [] -> do
                    upos <- closestUnknown aid
                    case upos of
                      Nothing -> do
                        ctriggers <- if Ability.Trigger `elem` actorAbs
                                     then closestTriggers Nothing False aid
                                     else return []
                        case ctriggers of
                          [] -> do
                            getDistant <-
                              rndToAction $ oneOf
                              $ [fmap maybeToList . furthestKnown]
                                ++ [ closestTriggers Nothing True
                                   | EM.size dungeon > 1 ]
                            kpos <- getDistant aid
                            case kpos of
                              [] -> return reject
                              p : _ -> setPath $ TPoint (blid b) p
                          p : _ -> setPath $ TPoint (blid b) p
                      Just p -> setPath $ TPoint (blid b) p
                  (_, (p, _)) : _ -> setPath $ TPoint (blid b) p
              (_, (p, _)) : _ -> setPath $ TPoint (blid b) p
      tellOthersNothingHere pos = do
        let f (tgt, _) = case tgt of
              TEnemyPos _ lid p _ -> p /= pos || lid /= blid b
              _ -> True
        modifyClient $ \cli -> cli {stargetD = EM.filter f (stargetD cli)}
        pickNewTarget
      updateTgt :: Target -> PathEtc
                -> m (Strategy (Target, PathEtc))
      updateTgt oldTgt updatedPath = case oldTgt of
        TEnemy a _ -> do
          body <- getsState $ getActorBody a
          if not focused  -- prefers closer foes
             && not (null nearbyFoes)  -- foes nearby
             && a `notElem` map fst nearbyFoes  -- old one not close enough
             || blid body /= blid b  -- wrong level
          then pickNewTarget
          else if bpos body == fst (snd updatedPath)
               then return $! returN "TEnemy" (oldTgt, updatedPath)
                      -- The enemy didn't move since the target acquired.
                      -- If any walls were added that make the enemy
                      -- unreachable, AI learns that the hard way,
                      -- as soon as it bumps into them.
               else do
                 let p = bpos body
                 (bfs, mpath) <- getCacheBfsAndPath aid p
                 case mpath of
                   Nothing -> pickNewTarget  -- enemy became unreachable
                   Just path ->
                      return $! returN "TEnemy"
                        (oldTgt, ( bpos b : path
                                 , (p, fromMaybe (assert `failure` mpath)
                                       $ accessBfs bfs p) ))
        _ | not $ null nearbyFoes ->
          pickNewTarget  -- prefer close foes to anything
        TPoint lid pos -> do
          explored <- getsClient sexplored
          let allExplored = ES.size explored == EM.size dungeon
              abilityLeader = fAbilityLeader $ fokind $ gkind fact
              abilityOther = fAbilityOther $ fokind $ gkind fact
          if lid /= blid b  -- wrong level
             -- Below we check the target could not be picked again in
             -- pickNewTarget, and only in this case it is invalidated.
             -- This ensures targets are eventually reached (unless a foe
             -- shows up) and not changed all the time mid-route
             -- to equally interesting, but perhaps a bit closer targets,
             -- most probably already targeted by other actors.
             || (Ability.Pickup `notElem` actorAbs  -- closestItems
                 || EM.null (lvl `atI` pos))
                && (not canSmell  -- closestSmell
                    || pos == bpos b  -- in case server resends deleted smell
                    || let sml =
                             EM.findWithDefault timeZero pos (lsmell lvl)
                       in sml `timeAdd` timeNegate (ltime lvl) <= timeZero)
                && let t = lvl `at` pos
                   in if ES.notMember lid explored
                      then  -- closestUnknown
                        t /= unknownId
                        && not (Tile.isSuspect cotile t)
                      else  -- closestTriggers
                        -- Try to kill that very last enemy for his loot before
                        -- leaving the level or dungeon.
                        not (null allFoes)
                        || -- If all explored, escape/block escapes.
                           (Ability.Trigger `notElem` actorAbs
                            || not (Tile.isEscape cotile t && allExplored))
                           -- The next case is stairs in closestTriggers.
                           -- We don't determine if the stairs are interesting
                           -- (this changes with time), but allow the actor
                           -- to reach them and then retarget.
                           && not (pos /= bpos b && Tile.isStair cotile t)
                           -- The remaining case is furthestKnown. This is
                           -- always an unimportant target, so we forget it
                           -- if the actor is stuck (could move, but waits).
                           && let isStuck =
                                    waitedLastTurn b
                                    && (oldLeader == aid
                                        || abilityLeader == abilityOther)
                              in not (pos /= bpos b
                                      && not isStuck
                                      && allExplored)
          then pickNewTarget
          else return $! returN "TPoint" (oldTgt, updatedPath)
        _ | not $ null allFoes ->
          pickNewTarget  -- new likely foes location spotted, forget the old
        TEnemyPos _ lid p _ ->
          -- Chase last position even if foe hides or dies,
          -- to find his companions, loot, etc.
          if lid /= blid b  -- wrong level
          then pickNewTarget
          else if p == bpos b
               then tellOthersNothingHere p
               else return $! returN "TEnemyPos" (oldTgt, updatedPath)
        TVector{} -> pickNewTarget
  case oldTgtUpdatedPath of
    Just (oldTgt, updatedPath) -> updateTgt oldTgt updatedPath
    Nothing -> pickNewTarget

-- | AI strategy based on actor's sight, smell, intelligence, etc.
-- Never empty.
actionStrategy :: forall m. MonadClient m
               => ActorId -> m (Strategy CmdTakeTimeSer)
actionStrategy aid = do
  cops <- getsState scops
  disco <- getsClient sdisco
  btarget <- getsClient $ getTarget aid
  Actor{bpos, blid} <- getsState $ getActorBody aid
  bitems <- getsState $ getActorItem aid
  lootItems <- getsState $ getFloorItem blid bpos
  lvl <- getLevel blid
  mleader <- getsClient _sleader
  actorAbs <- actorAbilities aid mleader
  let mfAid =
        case btarget of
          Just (TEnemy foeAid _) -> Just foeAid
          _ -> Nothing
      foeVisible = isJust mfAid
      lootHere x = not $ EM.null $ lvl `atI` x
      lootIsWeapon = isJust $ strongestSword cops lootItems
      hasNoWeapon = isNothing $ strongestSword cops bitems
      isDistant = (`elem` [ Ability.Trigger
                          , Ability.Ranged
                          , Ability.Tools
                          , Ability.Chase ])
      -- TODO: this is too fragile --- depends on order of abilities
      (prefix, rest)    = break isDistant actorAbs
      (distant, suffix) = partition isDistant rest
      aFrequency :: Ability -> m (Frequency CmdTakeTimeSer)
      aFrequency Ability.Trigger = if foeVisible then return mzero
                                   else triggerFreq aid
      aFrequency Ability.Ranged  = rangedFreq aid
      aFrequency Ability.Tools   = if not foeVisible then return mzero
                                   else toolsFreq disco aid
      aFrequency Ability.Chase   = if not foeVisible then return mzero
                                   else chaseFreq
      aFrequency ab              = assert `failure` "unexpected ability"
                                          `twith` (ab, distant, actorAbs)
      chaseFreq :: MonadActionRO m => m (Frequency CmdTakeTimeSer)
      chaseFreq = do
        st <- chase aid True
        return $! scaleFreq 30 $ bestVariant st
      aStrategy :: Ability -> m (Strategy CmdTakeTimeSer)
      aStrategy Ability.Track  = track aid
      aStrategy Ability.Heal   = return reject  -- TODO
      aStrategy Ability.Flee   = return reject  -- TODO
      aStrategy Ability.Melee | foeVisible = melee aid
      aStrategy Ability.Melee  = return reject
      aStrategy Ability.Displace = displace aid
      aStrategy Ability.Pickup | not foeVisible && lootHere bpos
                                 || hasNoWeapon && lootIsWeapon = pickup aid
      aStrategy Ability.Pickup = return reject
      aStrategy Ability.Wander = chase aid False
      aStrategy ab             = assert `failure` "unexpected ability"
                                        `twith`(ab, actorAbs)
      sumS abis = do
        fs <- mapM aStrategy abis
        return $! msum fs
      sumF abis = do
        fs <- mapM aFrequency abis
        return $! msum fs
      combineDistant as = fmap liftFrequency $ sumF as
  sumPrefix <- sumS prefix
  comDistant <- combineDistant distant
  sumSuffix <- sumS suffix
  return $! sumPrefix .| comDistant .| sumSuffix
            -- Wait until friends sidestep; ensures strategy is never empty.
            -- TODO: try to switch leader away before that (we already
            -- switch him afterwards)
            .| waitBlockNow aid

-- | A strategy to always just wait.
waitBlockNow :: ActorId -> Strategy CmdTakeTimeSer
waitBlockNow aid = returN "wait" $ WaitSer aid

-- | Strategy for a dumb missile or a strongly hurled actor.
track :: MonadActionRO m => ActorId -> m (Strategy CmdTakeTimeSer)
track aid = do
  btrajectory <- getsState $ btrajectory . getActorBody aid
  return $! if isNothing btrajectory
            then reject
            else returN "SetTrajectorySer" $ SetTrajectorySer aid

-- TODO: (most?) animals don't pick up. Everybody else does.
-- TODO: pick up best weapons first
pickup :: MonadActionRO m => ActorId -> m (Strategy CmdTakeTimeSer)
pickup aid = do
  body@Actor{bpos, blid} <- getsState $ getActorBody aid
  lvl <- getLevel blid
  actionPickup <- case EM.minViewWithKey $ lvl `atI` bpos of
    Nothing -> assert `failure` "pickup of empty pile" `twith` (aid, bpos, lvl)
    Just ((iid, k), _) -> do  -- pick up first item
      item <- getsState $ getItemBody iid
      let l = if jsymbol item == '$' then Just $ InvChar '$' else Nothing
      return $! case assignLetter iid l body of
        Just _ -> returN "pickup" $ PickupSer aid iid k
        Nothing -> returN "pickup" $ WaitSer aid  -- TODO
  return $! actionPickup

-- Everybody melees in a pinch, even though some prefer ranged attacks.
melee :: MonadClient m => ActorId -> m (Strategy CmdTakeTimeSer)
melee aid = do
  b <- getsState $ getActorBody aid
  fact <- getsState $ \s -> sfactionD s EM.! bfid b
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  str1 <- case mtgtMPath of
    Just (_, Just (_ : q : _, (goal, _))) -> do
      -- We prefer the goal (e.g., when no accessible, but adjacent),
      -- but accept @q@ even if it's only a blocking enemy position.
      let maim = if adjacent (bpos b) goal then Just goal
                 else if adjacent (bpos b) q then Just q
                 else Nothing  -- MeleeDistant
      mBlocker <- case maim of
        Nothing -> return Nothing
        Just aim -> getsState $ posToActor aim (blid b)
      case mBlocker of
        Just ((aid2, _), _) -> do
          -- No problem if there are many projectiles at the spot. We just
          -- attack the first one.
          body2 <- getsState $ getActorBody aid2
          if isAtWar fact (bfid body2) then
            return $! returN "melee in the way" (MeleeSer aid aid2)
          else return reject
        Nothing -> return reject
    _ -> return reject  -- probably no path to the foe, if any
  -- TODO: depending on actor kind, sometimes move this in strategy
  -- to a place after movement
  if not $ nullStrategy str1 then return str1 else do
    Level{lxsize, lysize} <- getLevel $ blid b
    allFoes <- getsState $ actorNotProjAssocs (isAtWar fact) (blid b)
    let vic = vicinity lxsize lysize $ bpos b
        adjFoes = filter ((`elem` vic) . bpos . snd) allFoes
        -- TODO: prioritize somehow
        freq = uniformFreq "melee adjacent" $ map (MeleeSer aid . fst) adjFoes
    return $ liftFrequency freq

-- Fast monsters don't pay enough attention to features.
triggerFreq :: MonadClient m => ActorId -> m (Frequency CmdTakeTimeSer)
triggerFreq aid = do
  cops@Kind.COps{cotile=Kind.Ops{okind}} <- getsState scops
  dungeon <- getsState sdungeon
  explored <- getsClient sexplored
  b <- getsState $ getActorBody aid
  fact <- getsState $ \s -> sfactionD s EM.! bfid b
  lvl <- getLevel $ blid b
  unexploredD <- unexploredDepth
  s <- getState
  let unexploredCurrent = ES.notMember (blid b) explored
      allExplored = ES.size explored == EM.size dungeon
      isHero = isHeroFact cops fact
      t = lvl `at` bpos b
      feats = TileKind.tfeature $ okind t
      ben feat = case feat of
        F.Cause (Effect.Ascend k) ->  -- change levels sensibly, in teams
          let expBenefit =
                if unexploredCurrent
                then 0  -- don't leave the level until explored
                else if unexploredD (signum k) (blid b)
                then 1000
                else if unexploredD (- signum k) (blid b)
                then 0  -- wait for stairs in the opposite direciton
                else if lescape lvl
                then 0  -- all explored, stay on the escape level
                else 2  -- no escape anywhere, switch levels occasionally
              (lid2, pos2) = whereTo (blid b) (bpos b) k dungeon
              actorsThere = posToActors pos2 lid2 s
          in if boldpos b == bpos b   -- probably used stairs last turn
                && boldlid b == lid2  -- in the opposite direction
             then 0  -- avoid trivial loops (pushing, being pushed, etc.)
             else case actorsThere of
               [] -> expBenefit
               [((_, body), _)] | not (bproj body)
                                  && isAtWar fact (bfid body) ->
                 min 1 expBenefit  -- push the enemy if no better option
               _ -> 0  -- projectiles or non-enemies
        F.Cause ef@Effect.Escape{} ->
          -- Only heroes escape but they first explore all for high score.
          if not (isHero && allExplored) then 0 else effectToBenefit cops b ef
        F.Cause ef -> effectToBenefit cops b ef
        _ -> 0
      benFeat = zip (map ben feats) feats
  return $! toFreq "triggerFreq" $ [ (benefit, TriggerSer aid (Just feat))
                                   | (benefit, feat) <- benFeat
                                   , benefit > 0 ]

-- Actors require sight to use ranged combat and intelligence to throw
-- or zap anything else than obvious physical missiles.
rangedFreq :: MonadClient m
           => ActorId -> m (Frequency CmdTakeTimeSer)
rangedFreq aid = do
  cops@Kind.COps{ coactor=Kind.Ops{okind}
                , coitem=coitem@Kind.Ops{okind=iokind}
                , corule
                } <- getsState scops
  btarget <- getsClient $ getTarget aid
  b@Actor{bkind, bpos, bfid, blid, bbag, binv} <- getsState $ getActorBody aid
  mfpos <- aidTgtToPos aid blid btarget
  case (btarget, mfpos) of
    (Just TEnemy{}, Just fpos) -> do
      disco <- getsClient sdisco
      itemD <- getsState sitemD
      lvl@Level{lxsize, lysize} <- getLevel blid
      let mk = okind bkind
          tis = lvl `atI` bpos
      fact <- getsState $ \s -> sfactionD s EM.! bfid
      foes <- getsState $ actorNotProjList (isAtWar fact) blid
      let foesAdj = foesAdjacent lxsize lysize bpos foes
      (steps, eps) <- makePath b fpos
      let permitted = (if aiq mk >= 10 then ritemProject else ritemRanged)
                      $ Kind.stdRuleset corule
          itemReaches item =
            let lingerPercent = isLingering coitem disco item
                toThrow = maybe 0 (itoThrow . iokind) $ jkind disco item
                speed = speedFromWeight (jweight item) toThrow
                range = rangeFromSpeed speed
                totalRange = lingerPercent * range `div` 100
            in steps <= totalRange  -- probably enough range
                 -- TODO: make sure itoThrow identified after a single throw
          getItemB iid =
            fromMaybe (assert `failure` "item body not found"
                              `twith` (iid, itemD)) $ EM.lookup iid itemD
          throwFreq bag multi container =
            [ (- benefit * multi,
              ProjectSer aid fpos eps iid (container iid))
            | (iid, i) <- map (\iid -> (iid, getItemB iid))
                          $ EM.keys bag
            , let benefit =
                    case jkind disco i of
                      Nothing -> -- TODO: (undefined, 0)  --- for now, cheating
                        effectToBenefit cops b (jeffect i)
                      Just _ki ->
                        let _kik = iokind _ki
                            _unneeded = isymbol _kik
                        in effectToBenefit cops b (jeffect i)
            , benefit < 0
            , jsymbol i `elem` permitted
            , itemReaches i ]
          freq =
            if asight mk  -- ProjectBlind
               && not foesAdj  -- ProjectBlockFoes
               -- ProjectAimOnself, ProjectBlockActor, ProjectBlockTerrain
               -- and no actors or obstracles along the path
               && steps == chessDist bpos fpos
            then toFreq "throwFreq"
                 $ throwFreq bbag 4 (actorContainer aid binv)
                   ++ throwFreq tis 8 (const $ CFloor blid bpos)
            else toFreq "throwFreq: not possible" []
      return $! freq
    _ -> return $! toFreq "throwFreq: no enemy target" []

-- TODO: finetune eps
-- | Counts the number of steps until the projectile would hit
-- an actor or obstacle.
makePath :: MonadClient m => Actor -> Point -> m (Int, Int)
makePath body fpos = do
  cops <- getsState scops
  lvl@Level{lxsize, lysize} <- getLevel (blid body)
  bs <- getsState $ actorNotProjList (const True) (blid body)
  let eps = 0
      mbl = bla lxsize lysize eps (bpos body) fpos
  case mbl of
    Just bl@(pos1:_) -> do
      let noActor p = any ((== p) . bpos) bs
      case break noActor bl of
        (flies, hits : _) -> do
          let blRest = flies ++ [hits]
              blZip = zip (bpos body : blRest) blRest
              blAccess = takeWhile (uncurry $ accessible cops lvl) blZip
          mab <- getsState $ posToActor pos1 (blid body)
          if maybe True (bproj . snd . fst) mab then
            return $ (length blAccess, eps)
          else return (0, eps)  -- ProjectBlockActor
        _ -> assert `failure` (body, fpos, bl)
    Just [] -> assert `failure` (body, fpos)
    Nothing -> return (0, eps)  -- ProjectAimOnself

-- Tools use requires significant intelligence and sometimes literacy.
toolsFreq :: MonadActionRO m
          => Discovery -> ActorId -> m (Frequency CmdTakeTimeSer)
toolsFreq disco aid = do
  cops@Kind.COps{coactor=Kind.Ops{okind}} <- getsState scops
  b@Actor{bkind, bpos, blid, bbag, binv} <- getsState $ getActorBody aid
  lvl <- getLevel blid
  s <- getState
  let tis = lvl `atI` bpos
      mk = okind bkind
      mastered | aiq mk < 5 = ""
               | aiq mk < 10 = "!"
               | otherwise = "!?"  -- literacy required
      useFreq bag multi container =
        [ (benefit * multi, ApplySer aid iid (container iid))
        | (iid, i) <- map (\iid -> (iid, getItemBody iid s))
                      $ EM.keys bag
        , let benefit =
                case jkind disco i of
                  Nothing -> 30  -- experimenting is fun
                  Just _ki -> effectToBenefit cops b $ jeffect i
        , benefit > 0
        , jsymbol i `elem` mastered ]
  return $! toFreq "useFreq" $
    useFreq bbag 1 (actorContainer aid binv)
    ++ useFreq tis 2 (const $ CFloor blid bpos)

displace :: MonadClient m => ActorId -> m (Strategy CmdTakeTimeSer)
displace aid = do
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  str <- case mtgtMPath of
    Just (_, Just (p : q : _, _)) -> displaceTowards aid p q
    _ -> return reject  -- goal reached
  Traversable.mapM (moveOrRunAid True aid) str

-- TODO: perhaps modify target when actually moving, not when
-- producing the strategy, even if it's a unique choice in this case.
displaceTowards :: MonadClient m
                => ActorId -> Point -> Point -> m (Strategy Vector)
displaceTowards aid source target = do
  cops <- getsState scops
  b <- getsState $ getActorBody aid
  assert (source == bpos b && adjacent source target) skip
  lvl <- getsState $ (EM.! blid b) . sdungeon
  if boldpos b /= target -- avoid trivial loops
     && accessible cops lvl source target then do
    mBlocker <- getsState $ posToActors target (blid b)
    case mBlocker of
      [] -> return reject
      [((aid2, _), _)] -> do
        mtgtMPath <- getsClient $ EM.lookup aid2 . stargetD
        case mtgtMPath of
          Just (tgt, Just (p : q : rest, (goal, len)))
            | q == source && p == target -> do
              let newTgt = Just (tgt, Just (q : rest, (goal, len - 1)))
              modifyClient $ \cli ->
                cli {stargetD = EM.alter (const $ newTgt) aid (stargetD cli)}
              return $! returN "displace friend" $ displacement source target
          Just _ -> return reject
          Nothing ->
            return $! returN "displace other" $ displacement source target
      _ -> return reject  -- many projectiles, can't displace
  else return reject

chase :: MonadClient m => ActorId -> Bool -> m (Strategy CmdTakeTimeSer)
chase aid foeVisible = do
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  str <- case mtgtMPath of
    Just (_, Just (p : q : _, (goal, _))) -> moveTowards aid p q goal
    _ -> return reject  -- goal reached
  if foeVisible  -- don't pick fights, but displace, if the real foe is close
    then Traversable.mapM (moveOrRunAid True aid) str
    else Traversable.mapM (moveOrRunAid False aid) str

moveTowards :: MonadClient m
            => ActorId -> Point -> Point -> Point -> m (Strategy Vector)
moveTowards aid source target goal = do
  cops@Kind.COps{coactor=Kind.Ops{okind}, cotile} <- getsState scops
  b <- getsState $ getActorBody aid
  assert (source == bpos b && adjacent source target) skip
  lvl <- getsState $ (EM.! blid b) . sdungeon
  fact <- getsState $ (EM.! bfid b) . sfactionD
  friends <- getsState $ actorList (not . isAtWar fact) $ blid b
  let _mk = okind $ bkind b
      noFriends = unoccupied friends
      -- Was:
      -- noFriends | asight mk = unoccupied friends
      --           | otherwise = const True
      -- but this should be implemented on the server or, if not,
      -- restricted to AI-only factions (e.g., animals).
      -- Otherwise human players are tempted to tweak their AI clients
      -- (as soon as we let them register their AI clients with the server).
      accessibleHere = accessible cops lvl source
      bumpableHere p =
        let t = lvl `at` p
        in Tile.isOpenable cotile t || Tile.isSuspect cotile t
      enterableHere p = accessibleHere p || bumpableHere p
  if noFriends target && enterableHere target then
    return $! returN "moveTowards adjacent" $ displacement source target
  else do
    let goesBack v = v == displacement source (boldpos b)
        nonincreasing p = chessDist source goal >= chessDist p goal
        isSensible p = nonincreasing p && noFriends p && enterableHere p
        sensible = [ ((goesBack v, chessDist p goal), v)
                   | v <- moves, let p = source `shift` v, isSensible p ]
        sorted = sortBy (comparing fst) sensible
        groups = map (map snd) $ groupBy ((==) `on` fst) sorted
        freqs = map (liftFrequency . uniformFreq "moveTowards") groups
    return $! foldr (.|) reject freqs

-- | Actor moves or searches or alters or attacks. Displaces if @run@.
moveOrRunAid :: MonadActionRO m
             => Bool -> ActorId -> Vector -> m CmdTakeTimeSer
moveOrRunAid run source dir = do
  cops@Kind.COps{cotile} <- getsState scops
  sb <- getsState $ getActorBody source
  let lid = blid sb
  lvl <- getLevel lid
  let spos = bpos sb           -- source position
      tpos = spos `shift` dir  -- target position
      t = lvl `at` tpos
  -- We start by checking actors at the the target position,
  -- which gives a partial information (actors can be invisible),
  -- as opposed to accessibility (and items) which are always accurate
  -- (tiles can't be invisible).
  tgts <- getsState $ posToActors tpos lid
  case tgts of
    [((target, _), _)] | run ->  -- can be a foe, as well as a friend
      if accessible cops lvl spos tpos then
        -- Displacing requires accessibility.
        return $! DisplaceSer source target
      else
        -- If cannot displace, hit. No DisplaceAccess.
        return $! MeleeSer source target
    ((target, _), _) : _ ->  -- can be a foe, as well as a friend (e.g., proj.)
      -- No problem if there are many projectiles at the spot. We just
      -- attack the first one.
      -- Attacking does not require full access, adjacency is enough.
      return $! MeleeSer source target
    [] -> do  -- move or search or alter
      if accessible cops lvl spos tpos then
        -- Movement requires full access.
        return $! MoveSer source dir
        -- The potential invisible actor is hit.
      else if not $ EM.null $ lvl `atI` tpos then
        -- This is, e.g., inaccessible open door with an item in it.
        assert `failure` "AI causes AlterBlockItem" `twith` (run, source, dir)
      else if not (Tile.isWalkable cotile t)  -- not implied
              && (Tile.isSuspect cotile t
                  || Tile.isOpenable cotile t
                  || Tile.isClosable cotile t
                  || Tile.isChangeable cotile t) then
        -- No access, so search and/or alter the tile.
        return $! AlterSer source tpos Nothing
      else
        -- Boring tile, no point bumping into it, do WaitSer if really idle.
        assert `failure` "AI causes MoveNothing or AlterNothing"
               `twith` (run, source, dir)

-- | How much AI benefits from applying the effect. Multipllied by item p.
-- Negative means harm to the enemy when thrown at him. Effects with zero
-- benefit won't ever be used, neither actively nor passively.
effectToBenefit :: Kind.COps -> Actor -> Effect.Effect Int -> Int
effectToBenefit Kind.COps{coactor=Kind.Ops{okind}} b eff =
  let kind = okind $ bkind b
  in case eff of
    Effect.NoEffect -> 0
    (Effect.Heal p) -> 10 * min p (Random.maxDice (ahp kind) - bhp b)
    (Effect.Hurt _ p) -> -(p * 10)     -- TODO: dice ignored, not capped
    Effect.Mindprobe{} -> 0            -- AI can't benefit yet
    Effect.Dominate -> -100
    (Effect.CallFriend p) -> p * 100
    Effect.Summon{} -> 1               -- may or may not spawn a friendly
    (Effect.CreateItem p) -> p * 20
    Effect.ApplyPerfume -> 0
    Effect.Regeneration{} -> 0         -- bigger benefit from carrying around
    Effect.Searching{} -> 0
    Effect.Ascend{} -> 0               -- change levels sensibly, in teams
    Effect.Escape{} -> 10000           -- AI wants to win; spawners to guard
