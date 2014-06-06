{-# LANGUAGE DataKinds #-}
-- | Semantics of abilities in terms of actions and the AI procedure
-- for picking the best action for an actor.
module Game.LambdaHack.Client.AI.HandleAbilityClient
  ( actionStrategy
  ) where

import Control.Applicative
import Control.Arrow (second)
import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Function
import Data.List
import Data.Maybe
import Data.Ord
import Data.Ratio
import qualified Data.Traversable as Traversable

import Game.LambdaHack.Client.AI.ConditionClient
import Game.LambdaHack.Client.AI.Preferences
import Game.LambdaHack.Client.AI.Strategy
import Game.LambdaHack.Client.BfsClient
import Game.LambdaHack.Client.CommonClient
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Common.Ability
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Feature as F
import Game.LambdaHack.Common.Frequency
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.ItemStrongest
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Content.TileKind as TileKind

type ToAny a = Strategy (RequestTimed a) -> Strategy RequestAnyAbility

toAny :: ToAny a
toAny strat = RequestAnyAbility <$> strat

-- | AI strategy based on actor's sight, smell, intelligence, etc.
-- Never empty.
actionStrategy :: forall m. MonadClient m
               => ActorId -> m (Strategy RequestAnyAbility)
actionStrategy aid = do
  body <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid body) . sfactionD
  condTgtEnemyPresent <- condTgtEnemyPresentM aid
  condTgtEnemyRemembered <- condTgtEnemyRememberedM aid
  condAnyFoeAdj <- condAnyFoeAdjM aid
  threatDistL <- threatDistList aid
  condHpTooLow <- condHpTooLowM aid
  condOnTriggerable <- condOnTriggerableM aid
  condBlocksFriends <- condBlocksFriendsM aid
  condNoWeapon <- condNoWeaponM aid
  condFloorWeapon <- condFloorWeaponM aid
  condCanProject <- condCanProjectM aid
  condNotCalmEnough <- condNotCalmEnoughM aid
  condDesirableFloorItem <- condDesirableFloorItemM aid
  condMeleeBad <- condMeleeBadM aid
  condLightBetrays <- condLightBetraysM aid
  fleeL <- fleeList aid
  let condThreatAdj = not $ null $ takeWhile ((== 1) . fst) threatDistL
      condThreatAtHand = not $ null $ takeWhile ((<= 2) . fst) threatDistL
      condThreatNearby = not $ null $ takeWhile ((<= nearby) . fst) threatDistL
      speed1_5 = speedScale (3%2) (bspeed body)
      condFastThreatAdj = any (\(_, (_, b)) -> bspeed b > speed1_5)
                          $ takeWhile ((== 1) . fst) threatDistL
      condCanFlee = not (null fleeL || condFastThreatAdj)
  mleader <- getsClient _sleader
  actorAbs <- actorAbilities aid mleader
  let stratToFreq :: MonadStateRead m
                  => Int -> m (Strategy RequestAnyAbility)
                  -> m (Frequency RequestAnyAbility)
      stratToFreq scale mstrat = do
        st <- mstrat
        return $! scaleFreq scale $ bestVariant st  -- TODO: flatten instead?
      prefix, suffix :: [([Ability], m (Strategy RequestAnyAbility), Bool)]
      prefix =
        [ ( [AbApply], (toAny :: ToAny AbApply)
            <$> applyItem aid ApplyFirstAid
          , condHpTooLow && not condAnyFoeAdj
            && not condOnTriggerable )  -- don't block stairs, perhaps ascend
        , ( [AbTrigger], (toAny :: ToAny AbTrigger)
            <$> trigger aid True
              -- flee via stairs, even if to wrong level
              -- may return via different stairs
          , condOnTriggerable
            && ((condNotCalmEnough || condHpTooLow)
                && condThreatNearby && not condTgtEnemyPresent
                || condMeleeBad && condThreatAdj) )
        , ( [AbMove]
          , flee aid fleeL
          , condMeleeBad && condThreatAdj && condCanFlee )
        , ( [AbDisplace]
          , displaceFoe aid  -- only swap with an enemy to expose him
          , condBlocksFriends && condAnyFoeAdj
            && not condOnTriggerable && not condDesirableFloorItem )
        , ( [AbMoveItem], (toAny :: ToAny AbMoveItem)
            <$> pickup aid True
          , condNoWeapon && condFloorWeapon && not condHpTooLow )
        , ( [AbMelee], (toAny :: ToAny AbMelee)
            <$> meleeBlocker aid  -- only melee target or blocker
          , condAnyFoeAdj
            || AbDisplace `notElem` actorAbs  -- melee friends, not displace
               && not (playerLeader $ gplayer fact)  -- not restrained
               && (condTgtEnemyPresent || condTgtEnemyRemembered) )  -- excited
        , ( [AbTrigger], (toAny :: ToAny AbTrigger)
            <$> trigger aid False
          , condOnTriggerable && not condDesirableFloorItem )
        , ( [AbDisplace]  -- prevents some looping movement
          , displaceBlocker aid  -- fires up only when path blocked
          , not condDesirableFloorItem )
        , ( [AbMoveItem], (toAny :: ToAny AbMoveItem)
            <$> manageEqp aid  -- doesn't take long, very useful if safe
                               -- only if calm enough, so high priority
          , not condAnyFoeAdj && not condDesirableFloorItem ) ]
      distant :: [([Ability], m (Frequency RequestAnyAbility), Bool)]
      distant =
        [ ( [AbProject]  -- for high-value target, shoot even in melee
          , stratToFreq 2 $ (toAny :: ToAny AbProject)
            <$> ranged aid
          , condTgtEnemyPresent && condCanProject && not condOnTriggerable )
        , ( [AbApply]
          , stratToFreq 2 $ (toAny :: ToAny AbApply)
            <$> applyItem aid ApplyAll  -- use any option or scroll
          , (condTgtEnemyPresent || condThreatNearby)  -- can affect enemies
            && not condOnTriggerable )
        , ( [AbMove]
          , stratToFreq (if not condTgtEnemyPresent || condMeleeBad
                         then 1
                         else 100)
            $ chase aid True
          , (condTgtEnemyPresent || condTgtEnemyRemembered)
            && not condDesirableFloorItem ) ]
      suffix =
        [ ( [AbMoveItem], (toAny :: ToAny AbMoveItem)
            <$> pickup aid False
          , True )  -- unconditionally, e.g., to give to other party members
        , ( [AbMove]
          , flee aid fleeL
          , condMeleeBad && (condNotCalmEnough && condThreatNearby
                             || condThreatAtHand)
            && condCanFlee )
        , ( [AbMelee], (toAny :: ToAny AbMelee)
            <$> meleeAny aid  -- avoid getting damaged for naught
          , condAnyFoeAdj )
        , ( [AbApply], (toAny :: ToAny AbApply)  -- better to throw than quench
            <$> applyItem aid QuenchLight
          , condLightBetrays && bcalmDelta body < -1 )  -- hit by a projectile
        , ( [AbMove]
          , chase aid False
          , True )
        , ( [AbWait], (toAny :: ToAny AbWait)
            <$> waitBlockNow
            -- Wait until friends sidestep; ensures strategy is never empty.
            -- TODO: try to switch leader away before that (we already
            -- switch him afterwards)
          , True ) ]
      -- TODO: don't msum not to evaluate until needed
      checkAction :: ([Ability], m a, Bool) -> Bool
      checkAction (abts, _, cond) = cond && all (`elem` actorAbs) abts
      sumS abAction = do
        let as = filter checkAction abAction
        strats <- sequence $ map (\(_, m, _) -> m) as
        return $! msum strats
      sumF abFreq = do
        let as = filter checkAction abFreq
        strats <- sequence $ map (\(_, m, _) -> m) as
        return $! msum strats
      combineDistant as = fmap liftFrequency $ sumF as
  sumPrefix <- sumS prefix
  comDistant <- combineDistant distant
  sumSuffix <- sumS suffix
  return $! sumPrefix .| comDistant .| sumSuffix

-- | A strategy to always just wait.
waitBlockNow :: MonadClient m => m (Strategy (RequestTimed AbWait))
waitBlockNow = return $! returN "wait" ReqWait

pickup :: MonadClient m
       => ActorId -> Bool -> m (Strategy (RequestTimed AbMoveItem))
pickup aid onlyWeapon = do
  Kind.COps{corule} <- getsState scops
  let RuleKind{ritemMelee} = Kind.stdRuleset corule
  benItemL <- benGroundItems aid
  let isWeapon (_, (_, item)) = jsymbol item `elem` ritemMelee
      filterWeapon | onlyWeapon = filter isWeapon
                   | otherwise = id
  case filterWeapon benItemL of
    ((_, k), (iid, _)) : _ -> do  -- pick up the best desirable item, if any
      updateItemSlot (Just aid) iid
      return $! returN "pickup" $ ReqMoveItem iid k CGround CEqp
    [] -> return reject

manageEqp :: MonadClient m => ActorId -> m (Strategy (RequestTimed AbMoveItem))
manageEqp aid = do
  cops@Kind.COps{coactor=Kind.Ops{okind}, corule} <- getsState scops
  let RuleKind{ritemEqp, rsharedInventory} = Kind.stdRuleset corule
  body <- getsState $ getActorBody aid
  invAssocs <- fullAssocsClient aid [CInv]
  eqpAssocs <- fullAssocsClient aid [CEqp]
  let kind = okind $ bkind body
  if calmEnough body kind then do
    let improve symbol =
          -- We don't take OFF into account, because AI can toggle it at will.
          let bestInv = strongestItem False invAssocs
                        $ strengthSymbol cops symbol
              bestEqp = strongestItem False eqpAssocs
                        $ strengthSymbol cops symbol
          in case (bestInv, bestEqp) of
            (_, (_, (iidEqp, itemEqp)) : _) | harmful body itemEqp ->
              -- This item is harmful to this actor, take it off.
              returN "yield harmful"
              $ ReqMoveItem iidEqp (getK bestEqp) CEqp CInv
            ((_, (iidInv, itemInv)) : _, []) | not $ harmful body itemInv ->
              returN "wield any"
              $ ReqMoveItem iidInv 1 CInv CEqp
            ((vInv, (iidInv, _)) : _, (vEqp, _) : _) | vInv > vEqp ->
              returN "wield better"
              $ ReqMoveItem iidInv 1 CInv CEqp
            (_, (_, (iidEqp, _)) : _) | getK bestEqp > 1
                                        && rsharedInventory ->
              -- To share the best items with others.
              returN "yield rest"
              $ ReqMoveItem iidEqp (getK bestEqp - 1) CEqp CInv
            (_, _ : (_, (iidEqp, _)) : _) ->
              -- To make room in limited equipment store or to share.
              returN "yield worse"
              $ ReqMoveItem iidEqp (getK bestEqp) CEqp CInv
            _ -> reject
        getK [] = 0
        getK ((_, (_, itemFull)) : _) = itemK itemFull
    return $ msum $ map improve ritemEqp
  else return reject

harmful :: Actor -> ItemFull -> Bool
harmful body itemFull =
  -- Fast actors want to hide in darkness to ambush opponents and want
  -- to hit hard for the short span they get to survive melee.
  not (null (strengthLight (itemBase itemFull) ++ strengthArmor itemFull))
  && bspeed body > speedNormal
  -- TODO:
  -- teach AI to turn shields OFF (or stash) when ganging up on an enemy
  -- (friends close, only one enemy close)
  -- and turning on afterwards (AI plays for time, especially spawners
  -- so shields are preferable by default;
  -- also, turning on when no friends and enemies close is too late,
  -- AI should flee or fire at such times, not muck around with eqp)

-- Everybody melees in a pinch, even though some prefer ranged attacks.
meleeBlocker :: MonadClient m => ActorId -> m (Strategy (RequestTimed AbMelee))
meleeBlocker aid = do
  b <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  mleader <- getsClient _sleader
  actorAbs <- actorAbilities aid mleader
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  case mtgtMPath of
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
          if not (actorDying body2)  -- already dying
             && (not (bproj body2)  -- displacing saves a move
                 && isAtWar fact (bfid body2)  -- they at war with us
                 || AbDisplace `notElem` actorAbs  -- melee, not displace
                    && not (playerLeader $ gplayer fact)  -- not restrained
                    && AbMove `elem` actorAbs  -- blocked move
                    && bhp body2 < bhp b) then do -- respect power
            mel <- pickWeaponClient aid aid2
            return $! returN "melee in the way" mel
          else return reject
        Nothing -> return reject
    _ -> return reject  -- probably no path to the enemy, if any

-- Everybody melees in a pinch, even though some prefer ranged attacks.
meleeAny :: MonadClient m => ActorId -> m (Strategy (RequestTimed AbMelee))
meleeAny aid = do
  b <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  allFoes <- getsState $ actorRegularAssocs (isAtWar fact) (blid b)
  let adjFoes = filter (adjacent (bpos b) . bpos . snd) allFoes
  mels <- mapM (pickWeaponClient aid . fst) adjFoes
      -- TODO: prioritize somehow
  let freq = uniformFreq "melee adjacent" mels
  return $ liftFrequency freq

-- Fast monsters don't pay enough attention to features.
trigger :: MonadClient m
        => ActorId -> Bool -> m (Strategy (RequestTimed AbTrigger))
trigger aid fleeViaStairs = do
  cops@Kind.COps{cotile=Kind.Ops{okind}} <- getsState scops
  dungeon <- getsState sdungeon
  explored <- getsClient sexplored
  b <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  lvl <- getLevel $ blid b
  unexploredD <- unexploredDepth
  s <- getState
  per <- getPerFid $ blid b
  let canSee = ES.member (bpos b) (totalVisible per)
      unexploredCurrent = ES.notMember (blid b) explored
      allExplored = ES.size explored == EM.size dungeon
      t = lvl `at` bpos b
      feats = TileKind.tfeature $ okind t
      ben feat = case feat of
        F.Cause (Effect.Ascend k) ->  -- change levels sensibly, in teams
          let expBenefit =
                if not (playerLeader (gplayer fact))
                then 100  -- not-exploring faction, switch at will
                else if unexploredCurrent
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
             else let eben = case actorsThere of
                        [] | canSee -> expBenefit
                        _ -> min 1 expBenefit  -- risk pushing
                  in if fleeViaStairs
                     then 1000 * eben + 1  -- strongly prefer correct direction
                     else eben
        F.Cause ef@Effect.Escape{} -> do  -- flee via this way, too
          -- Only non-spawners escape but they first explore all for high score.
          let keepArena fact1 = playerLeader (gplayer fact1)
                               && not (isSpawnFact fact1)
          if not (keepArena fact) || not allExplored
          then 0
          else effectToBenefit cops b ef
        F.Cause ef | not fleeViaStairs -> effectToBenefit cops b ef
        _ -> 0
      benFeat = zip (map ben feats) feats
  return $! liftFrequency $ toFreq "trigger"
         $ [ (benefit, ReqTrigger (Just feat))
           | (benefit, feat) <- benFeat
           , benefit > 0 ]

-- Actors require sight to use ranged combat and intelligence to throw
-- or zap anything else than obvious physical missiles.
ranged :: MonadClient m => ActorId -> m (Strategy (RequestTimed AbProject))
ranged aid = do
  Kind.COps{coactor=Kind.Ops{okind}, corule} <- getsState scops
  btarget <- getsClient $ getTarget aid
  b@Actor{bkind, bpos, blid} <- getsState $ getActorBody aid
  mfpos <- aidTgtToPos aid blid btarget
  seps <- getsClient seps
  case (btarget, mfpos) of
    (Just TEnemy{}, Just fpos) -> do
      let mk = okind bkind
      mnewEps <- makeLine b fpos seps
      case mnewEps of
        Just newEps | asight mk  -- ProjectBlind
                      && calmEnough b mk -> do  -- ProjectNotCalm
          -- ProjectAimOnself, ProjectBlockActor, ProjectBlockTerrain
          -- and no actors or obstracles along the path.
          let permitted = (if True  -- aiq mk >= 10 -- TODO; let server enforce?
                           then ritemProject
                           else ritemRanged)
                          $ Kind.stdRuleset corule
          benList <- benAvailableItems aid permitted
          let fRanged ((mben, cstore), (iid, ItemFull{itemBase})) =
                let trange = totalRange itemBase
                    bestRange = chessDist bpos fpos + 2  -- margin for fleeing
                    rangeMult =  -- penalize wasted or unsafely low range
                      10 + max 0 (10 - abs (trange - bestRange))
                    benR = (if cstore == CGround then 2 else 1)
                           * case mben of
                               Nothing -> -20  -- experimenting is fun
                               Just ben -> ben
                in if benR < 0 && trange >= chessDist bpos fpos
                   then Just ( -benR * rangeMult `div` 10
                             , ReqProject fpos newEps iid cstore )
                   else Nothing
              benRanged = mapMaybe fRanged benList
          return $! liftFrequency $ toFreq "ranged" benRanged
        _ -> return reject
    _ -> return reject

data ApplyItemGroup = ApplyAll | ApplyFirstAid | QuenchLight
  deriving Eq

-- Item application requires significant intelligence and sometimes literacy.
applyItem :: MonadClient m
          => ActorId -> ApplyItemGroup -> m (Strategy (RequestTimed AbApply))
applyItem aid applyGroup = do
  Kind.COps{coactor=Kind.Ops{okind}} <- getsState scops
  b <- getsState $ getActorBody aid
  let mk = okind $ bkind b
      permitted | applyGroup == QuenchLight = "("
                | aiq mk < 5 = ""
                | aiq mk < 10 = "!"
                | otherwise = "!?"  -- literacy required
  benList <- benAvailableItems aid permitted
  let itemLegal itemFull = case applyGroup of
        ApplyFirstAid ->
          let getP (Effect.Heal p) _ | p > 0 = True
              getP _ acc = acc
          in case itemDisco itemFull of
            Just ItemDisco{itemAE=Just ItemAspectEffect{jeffects}} ->
              foldr getP False jeffects
            _ -> False
        QuenchLight ->
          case strengthLight (itemBase itemFull) of
            _ : _ -> not $ itemIsOn itemFull
            [] -> False
        ApplyAll -> True
      coeff CBody = 3  -- never destroyed by use
      coeff CGround = 2
      coeff CEqp = 1
      coeff CInv = if applyGroup == QuenchLight then 0 else 1
      fTool ((mben, cstore), (iid, itemFull)) =
        let benR = coeff cstore
                   * case mben of
                       Nothing -> 20  -- experimenting is fun
                       Just ben -> ben
        in if itemLegal itemFull
           then if benR > 0
                then Just (benR, ReqApply iid cstore)
                else if applyGroup == QuenchLight
                     then Just (max 1 (abs benR), ReqApply iid cstore)
                     else Nothing
           else Nothing
      benTool = mapMaybe fTool benList
  return $! liftFrequency $ toFreq "applyItem" benTool

-- If low on health or alone, flee in panic, close to the path to target
-- and as far from the attackers, as possible. Usually fleeing from
-- foes will lead towards friends, but we don't insist on that.
-- We use chess distances, not pathfinding, because melee can happen
-- at path distance 2.
flee :: MonadClient m
     => ActorId -> [(Int, Point)] -> m (Strategy RequestAnyAbility)
flee aid fleeL = do
  b <- getsState $ getActorBody aid
  let vVic = map (second (`vectorToFrom` bpos b)) fleeL
      str = liftFrequency $ toFreq "flee" vVic
  Traversable.mapM (moveOrRunAid True aid) str

displaceFoe :: MonadClient m => ActorId -> m (Strategy RequestAnyAbility)
displaceFoe aid = do
  cops <- getsState scops
  b <- getsState $ getActorBody aid
  lvl <- getLevel $ blid b
  fact <- getsState $ (EM.! bfid b) . sfactionD
  let friendlyFid fid = fid == bfid b || isAllied fact fid
  friends <- getsState $ actorRegularList friendlyFid (blid b)
  allFoes <- getsState $ actorRegularList (isAtWar fact) (blid b)
  dEnemy <- getsState $ flip $ dispEnemy b
  let accessibleHere = accessible cops lvl $ bpos b  -- DisplaceAccess
      displaceable body =  -- DisplaceAccess, DisplaceDying, DisplaceSupported
        accessibleHere (bpos body)
        && adjacent (bpos body) (bpos b)
        && dEnemy body
      nFriends body = length $ filter (adjacent (bpos body) . bpos) friends
      nFrHere = nFriends b + 1
      vFoes = [ (nFr * nFr, bpos body `vectorToFrom` bpos b)
              | body <- allFoes
              , displaceable body
              , let nFr = nFriends body
              , nFr < nFrHere ]
      str = liftFrequency $ toFreq "displaceFoe" vFoes
  Traversable.mapM (moveOrRunAid True aid) str

displaceBlocker :: MonadClient m => ActorId -> m (Strategy RequestAnyAbility)
displaceBlocker aid = do
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
  lvl <- getLevel $ blid b
  if boldpos b /= target -- avoid trivial loops
     && accessible cops lvl source target then do  -- DisplaceAccess
    mBlocker <- getsState $ posToActors target (blid b)
    case mBlocker of
      [] -> return reject
      [((aid2, b2), _)] -> do
        mtgtMPath <- getsClient $ EM.lookup aid2 . stargetD
        case mtgtMPath of
          Just (tgt, Just (p : q : rest, (goal, len)))
            | q == source && p == target -> do
              let newTgt = Just (tgt, Just (q : rest, (goal, len - 1)))
              modifyClient $ \cli ->
                cli {stargetD = EM.alter (const $ newTgt) aid (stargetD cli)}
              return $! returN "displace friend" $ target `vectorToFrom` source
          Just _ -> return reject
          Nothing -> do
            tfact <- getsState $ (EM.! bfid b2) . sfactionD
            dEnemy <- getsState $ dispEnemy b b2
            if not (isAtWar tfact (bfid b)) || dEnemy then
              return $! returN "displace other" $ target `vectorToFrom` source
            else return reject  -- DisplaceDying, DisplaceSupported
      _ -> return reject  -- DisplaceProjectiles
  else return reject

chase :: MonadClient m => ActorId -> Bool -> m (Strategy RequestAnyAbility)
chase aid doDisplace = do
  body <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid body) . sfactionD
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  str <- case mtgtMPath of
    Just (_, Just (p : q : _, (goal, _))) ->
      -- With no leader, the goal is vague, so permit arbitrary detours.
      moveTowards aid p q goal (not $ playerLeader (gplayer fact))
    _ -> return reject  -- goal reached
  -- If @doDisplace@: don't pick fights, assuming the target is more important.
  -- We'd normally melee the target earlier on via @AbMelee@, but for
  -- actors that don't have this ability (and so melee only when forced to),
  -- this is meaningul.
  Traversable.mapM (moveOrRunAid doDisplace aid) str

moveTowards :: MonadClient m
            => ActorId -> Point -> Point -> Point -> Bool -> m (Strategy Vector)
moveTowards aid source target goal relaxed = do
  cops@Kind.COps{coactor=Kind.Ops{okind}, cotile} <- getsState scops
  b <- getsState $ getActorBody aid
  assert (source == bpos b && adjacent source target) skip
  lvl <- getLevel $ blid b
  fact <- getsState $ (EM.! bfid b) . sfactionD
  friends <- getsState $ actorList (not . isAtWar fact) $ blid b
  let _mk = okind $ bkind b
      noFriends = unoccupied friends
      accessibleHere = accessible cops lvl source
      bumpableHere p =
        let t = lvl `at` p
        in Tile.isOpenable cotile t || Tile.isSuspect cotile t
      enterableHere p = accessibleHere p || bumpableHere p
  if noFriends target && enterableHere target then
    return $! returN "moveTowards adjacent" $ target `vectorToFrom` source
  else do
    let goesBack v = v == boldpos b `vectorToFrom` source
        nonincreasing p = chessDist source goal >= chessDist p goal
        isSensible p = (relaxed || nonincreasing p)
                       && noFriends p
                       && enterableHere p
        sensible = [ ((goesBack v, chessDist p goal), v)
                   | v <- moves, let p = source `shift` v, isSensible p ]
        sorted = sortBy (comparing fst) sensible
        groups = map (map snd) $ groupBy ((==) `on` fst) sorted
        freqs = map (liftFrequency . uniformFreq "moveTowards") groups
    return $! foldr (.|) reject freqs

-- | Actor moves or searches or alters or attacks. Displaces if @run@.
-- This function is very general, even though it's often used in contexts
-- when only one or two of the many cases can possibly occur.
moveOrRunAid :: MonadClient m
             => Bool -> ActorId -> Vector -> m RequestAnyAbility
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
    [((target, b2), _)] | run ->  do -- can be a foe, as well as a friend
      tfact <- getsState $ (EM.! bfid b2) . sfactionD
      dEnemy <- getsState $ dispEnemy sb b2
      if boldpos sb /= tpos -- avoid trivial Displace loops
         && accessible cops lvl spos tpos -- DisplaceAccess
         && (not (isAtWar tfact (bfid sb))
             || dEnemy)  -- DisplaceDying, DisplaceSupported
      then
        return $! RequestAnyAbility $ ReqDisplace target
      else
        -- If cannot displace, hit.
        RequestAnyAbility <$> pickWeaponClient source target
    ((target, _), _) : _ ->  -- can be a foe, as well as a friend (e.g., proj.)
      -- No problem if there are many projectiles at the spot. We just
      -- attack the first one.
      -- Attacking does not require full access, adjacency is enough.
      RequestAnyAbility <$> pickWeaponClient source target
    [] -> do  -- move or search or alter
      if accessible cops lvl spos tpos then
        -- Movement requires full access.
        return $! RequestAnyAbility $ ReqMove dir
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
        return $! RequestAnyAbility $ ReqAlter tpos Nothing
      else
        -- Boring tile, no point bumping into it, do WaitSer if really idle.
        assert `failure` "AI causes MoveNothing or AlterNothing"
               `twith` (run, source, dir)
