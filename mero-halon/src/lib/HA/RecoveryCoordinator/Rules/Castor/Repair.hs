{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module dealing with pool repair.
module HA.RecoveryCoordinator.Rules.Castor.Repair
  ( handleRepair
  , noteToSDev
  , querySpiel
  , querySpielHourly
  ) where

import           Control.Applicative
import           Control.Arrow (second)
import           Control.Distributed.Process
import           Control.Exception (SomeException)
import           Control.Monad
import qualified Data.Binary as B
import           Data.Foldable
import qualified Data.HashSet as S
import qualified Data.Map as M
import           Data.Maybe (catMaybes, fromMaybe)
import           Data.Monoid ((<>))
import           Data.Typeable (Typeable)
import           Data.UUID (nil)
import           GHC.Generics (Generic)
import           HA.EventQueue.Producer
import           HA.EventQueue.Types
import qualified HA.ResourceGraph as G
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Mero
import qualified HA.RecoveryCoordinator.Rules.Castor.Repair.Internal as R
import           HA.Resources
import           HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero hiding (Enclosure, Process, Rack, Process)
import           HA.Resources.Mero.Note
import           HA.Services.Mero
import           Mero.Notification hiding (notifyMero)
import           Mero.Notification.HAState (Note(..))
import qualified Mero.Spiel as Spiel
import           Network.CEP
import           Prelude hiding (id)

--------------------------------------------------------------------------------
-- Queries                                                               --
--------------------------------------------------------------------------------

-- | Event sent when we want a 5 minute spiel query rule to fire
data SpielQuery = SpielQuery Pool M0.PoolRepairType UUID
  deriving (Eq, Show, Generic, Typeable)

instance B.Binary SpielQuery

-- | Event sent when we want a 60 minute repeated query rule to fire
data SpielQueryHourly = SpielQueryHourly Pool M0.PoolRepairType UUID
  deriving (Eq, Show, Generic, Typeable)

instance B.Binary SpielQueryHourly

-- | Handler for @M0_NC_ONLINE@ 'Pool' messages. Its main role is to
-- check whether we need to wait for more messages and if yes,
-- dispatch queries to SSPL after a period of time through
-- 'querySpiel'. As we do not receive information as to what type of
-- message this is about, we use previously stored 'M0.PoolRepairType'
-- to help us out.
queryStartHandling :: M0.Pool -> PhaseM LoopState l ()
queryStartHandling pool = do
  possiblyInitialisePRI pool
  incrementOnlinePRSResponse pool
  M0.PoolRepairStatus prt ruuid (Just pri) <- getPoolRepairStatus pool >>= \case
    Nothing -> do
      let err = "In queryStartHandling for " ++ show pool ++ " without PRS set."
      phaseLog "error" err
      return $ error err
    Just prs -> return prs

  iosvs <- length <$> R.getIOServices pool

  -- Ask for status always.
  onlines <- R.repairStatus prt pool >>= \case
    Left e -> do
      phaseLog "warn" $ "repairStatus " ++ show prt ++ " failed: " ++ show e
      -- we use priOnlineNotifications as a fallback here and we may
      -- want to do something better in case R.repairStatus fails but
      -- priOnlineNotifications has one more use, see [Note multipleIOS]
      return $ priOnlineNotifications pri
    Right sts -> return . length $ R.filterCompletedRepairs sts
  if -- Everything is repaired. Running timeouts keep running but
     -- 'completeRepair' will remove the repair information with given
     -- UUID they expect so they will simply die when it's their time
     -- to fire.
     | onlines == iosvs -> completeRepair pool prt Nothing
     -- This is the first of many notifications, start query in 5
     -- minutes.
     --
     -- [Note multipleIOS]
     -- We don't use ‘onlines’ here: consider the case where we
     -- receive our first notification and enter queryStartHandling
     -- for the first time but in the meantime, more than one IOS has
     -- finished repair. In this case ’onlines > 1’ and we can't
     -- decide whether we have dispatched SpielQuery. The obvious
     -- solution is to record in RG whether we have already started
     -- the query and use that to decide. But we already do except not
     -- explicitly: if we check ‘priOnlineNotifications’, we
     -- effectively find out how many times we entered
     -- queryStartHandling so we can determine when we have entered it
     -- for the first time and therefore can decide if we should
     -- dispatch a query.
     | priOnlineNotifications pri == 1 && iosvs > 1 ->
         promulgateRC $ SpielQuery pool prt ruuid

     -- This is not the first notification and also we haven't yet
     -- finished repair so do nothing and let the running queries or
     -- future notifications deal with it.
     | otherwise -> return ()

-- | This function does basic checking of whether we're done
-- repairing/rebalancing as well as handling time related matters.
--
-- Check if have received all online messages we were expecting.
--
-- If yes, notify about success and finish repair/rebalance.
--
-- If not, calculate the amount of time we have to wait until the next
-- query. Currently it's 5 minutes since the last query. Note that
-- when we enter this rule, the time since last query is the same as
-- the time that we received the first online notification, set by
-- 'incrementOnlinePRSResponse'. This ensure that we don't query
-- immediately after we receive the first status message. 'timeout'
-- for constant amount of time here is not good enough in case RC dies
-- in the middle of the wait.
--
-- When time to query comes, check the pool repair information again
-- to make sure the repair hasn't finished while we were waiting. If
-- it has, do nothing except mark message as processed.
--
-- This query is only ran once. If we're not finished repairing by
-- time we query spiel, we dispatch 'querySpielHourly' and finish the
-- rule.
querySpiel :: Specification LoopState ()
querySpiel = define "query-spiel" $ do
  dispatchQuery <- phaseHandle "dispatch-query"
  runQuery <- phaseHandle "run-query"

  setPhase dispatchQuery $ \(HAEvent uid (SpielQuery pool prt ruuid) _) -> do
    startProcessingMsg uid
    put Local $ Just (uid, pool, prt, ruuid)
    getPoolRepairInformation pool >>= \case
      Nothing -> do
        unsetPoolRepairStatusWithUUID pool ruuid
        messageProcessed uid
      Just pri -> do
        timeNow <- liftIO getTime
        let elapsed = timeNow - priTimeOfFirstCompletion pri
            untilTimeout = M0.mkTimeSpec 300 - elapsed
        iosvs <- length <$> R.getIOServices pool
        if priOnlineNotifications pri < iosvs
        then switch [timeout (timeSpecToSeconds untilTimeout) runQuery]
        else completeRepair pool prt $ Just uid

  directly runQuery $ do
    Just (uid, pool, prt, ruuid) <- get Local
    keepRunning <- getPoolRepairStatus pool >>= return . \case
      Nothing -> False
      Just prs -> prsRepairUUID prs == ruuid

    when keepRunning $ do
      iosvs <- length <$> R.getIOServices pool
      withRepairStatus prt pool uid $ \sts -> do
        let onlines = length $ R.filterCompletedRepairs sts
        modifyPoolRepairInformation pool $ \pri ->
          pri { priOnlineNotifications = onlines }
        updatePoolRepairStatusTime pool
        if onlines < iosvs
        then liftProcess . promulgateWait $ SpielQueryHourly pool prt ruuid
        else completeRepair pool prt $ Just uid
    phaseLog "repair" $ "First query for pool " ++ show pool ++ " terminating."

  start dispatchQuery Nothing

-- | This rule works in similar fashion to 'querySpiel' with the main difference
-- that:
--
-- * it runs hourly
-- * it runs until repairs complete
querySpielHourly :: Specification LoopState ()
querySpielHourly = define "query-spiel-hourly" $ do
  dispatchQueryHourly <- phaseHandle "dispatch-query-hourly"
  runQueryHourly <- phaseHandle "run-query-hourly"

  setPhase dispatchQueryHourly $ \(HAEvent uid (SpielQueryHourly pool prt ruuid) _) -> do
    t <- getTimeUntilQueryHourlyPRI pool
    put Local $ Just (uid, pool, prt, ruuid)
    phaseLog "repair" $ "Running hourly query in " ++ show t ++ " seconds."
    switch [timeout t runQueryHourly]

  directly runQueryHourly $ do
    Just (uid, pool, prt, ruuid) <- get Local
    keepRunning <- getPoolRepairStatus pool >>= return . \case
      Nothing -> False
      Just prs -> prsRepairUUID prs == ruuid
    when keepRunning $ do
      iosvs <- length <$> R.getIOServices pool
      Just pri <- getPoolRepairInformation pool
      case priOnlineNotifications pri < iosvs of
        False -> completeRepair pool prt (Just uid)
        True -> withRepairStatus prt pool uid $ \sts -> do
          -- is 'filterCompletedRepairs' relevant for rebalancing too?
          -- If not, how do we handle this query?
          let onlines = length $ R.filterCompletedRepairs sts
          modifyPoolRepairInformation pool $ \pri' ->
            pri' { priOnlineNotifications = onlines }
          updatePoolRepairStatusTime pool
          if onlines < iosvs
          then do t <- getTimeUntilQueryHourlyPRI pool
                  switch [timeout t runQueryHourly]
          else completeRepair pool prt (Just uid)
    phaseLog "repair" $ "Hourly query for pool " ++ show pool ++ " terminating."
    messageProcessed uid

  start dispatchQueryHourly Nothing

-- | Try to fetch 'Spiel.SnsStatus' for the given 'Pool' and if that
-- fails, unset the @PRS@ and ack the message. Otherwise run the
-- user-supplied handler.
withRepairStatus :: PoolRepairType -> Pool -> UUID
                 -> ([Spiel.SnsStatus] -> PhaseM LoopState l ())
                 -> PhaseM LoopState l ()
withRepairStatus prt pool uid f = R.repairStatus prt pool >>= \case
  Left e -> do
    liftProcess . sayRC $ "repairStatus " ++ show prt ++ " failed: " ++ show e
    updatePoolRepairStatusTime pool
    messageProcessed uid
  Right sts -> f sts

--------------------------------------------------------------------------------
-- Actions                                                                    --
--------------------------------------------------------------------------------

-- | Continue a previously-quiesced repair.
continueRepair :: M0.Pool
                  -- ^ Pool under repair
               -> M0.PoolRepairType
               -> PhaseM LoopState l ()
continueRepair pool prt = repairHasQuiesced pool prt >>= \case
  Left e -> phaseLog "repair" $ "queryContinueRepair: failed repair status: "
                             ++ show e
  Right True -> do
    R.continueRepair prt pool >>= \case
      Nothing -> return ()
      Just e -> phaseLog "repair" $ "Repair continue failed with " ++ show e
  Right False ->
    phaseLog "repair" $ "queryContinueRepair: repair not quiesced, not contunuing"

-- | Quiesce the repair on the given pool if the repair is on-going.
--
-- Tell spiel to quiesce and mark the given set of 'M0.SDev's
-- 'M0_NC_TRANSIENT' internally so we can track drives as they come
-- back up online and know when to continue repair. We don't have to
-- do much else, the regular spiel queries can run as usual because
-- the repair states will come back as 'M0_SNS_CM_STATUS_PAUSED' so
-- the repair won't finish and they'll just keep running until either
-- we 'queryContinueRepair' and everything completes fine or something
-- fails and we kill them during halt.
quiesceRepair :: M0.Pool
              -- ^ Pool under repair
              -> M0.PoolRepairType
              -- ^ Rebalance/repair?
              -> PhaseM LoopState l ()
quiesceRepair pool prt = repairHasQuiesced pool prt >>= \case
  -- We may have quiesced before. We could check the stored disk map
  -- here but in case of RC death we might have quiesced but lost the
  -- graph update. Therefore we ask for repair status explicitly and
  -- check if any status comes back as PAUSED, in which case we know
  -- quiesce has happened.
  Right False -> do
    phaseLog "repair" $ "Quescing repair operation on " ++ show pool
    R.quiesceRepair prt pool >>= \case
      Nothing -> return ()
      Just e -> phaseLog "repair" $ "Repair quiesce failed with " ++ show e
  Right True -> do
    phaseLog "repair" $ "queryQuiesceRepair: "
                     ++ show pool ++ " already quiesced."
  Left e -> phaseLog "repair" $ "queryQuiesceRepair: failed repair status: "
                               ++ show e

-- | Abort repair on the given pool.
abortRepair :: M0.Pool
            -> PhaseM LoopState l ()
abortRepair pool = getPoolRepairStatus pool >>= \case
  Nothing -> phaseLog "repair" $ "Abort requested on " ++ show pool
                              ++ "but no repair seems to be happening."
  Just (M0.PoolRepairStatus prt uuid _) -> R.abortRepair prt pool >>= \case
    -- Without the PRS on this pool, the queries will die. Even if new
    -- repair starts, the new PRS will have a fresh UUID so the
    -- queries for old repair will die anyway.
    Nothing -> unsetPoolRepairStatusWithUUID pool uuid
    Just e -> phaseLog "repair" $ "Failed to abort repair on "
                               ++ show pool ++ ": " ++ show e


-- | Complete the given pool repair by notifying mero about all the
-- devices being repaired and marking the message as processed.
--
-- If the repair/rebalance has not finished on every device in the
-- pool, will send information about devices that did complete and
-- continue with the process.
--
-- Starts rebalance if we were repairing and have fully completed.
completeRepair :: Pool -> PoolRepairType -> Maybe UUID -> PhaseM LoopState l ()
completeRepair pool prt muid = do
  -- if no status is found for SDev, assume M0_NC_ONLINE
  let getSDevState :: M0.SDev -> PhaseM LoopState l' ConfObjectState
      getSDevState d = fromMaybe M0_NC_ONLINE <$> queryObjectStatus d

  sdevs <- getPoolSDevs pool
  sts <- mapM (\d -> (,d) <$> getSDevState d) sdevs

  -- states that are considered as ‘OK, we can finish
  -- repair/rebalance’ states for the drives
  let okMessages = [R.repairedNotificationMsg prt, M0_NC_ONLINE]

   -- list of devices in OK state
      repairedSDevs = snd <$> filter (\(typ, _) -> typ == R.repairedNotificationMsg prt) sts
      okObjects =  snd <$> filter (\(typ, _) -> typ `elem` okMessages) sts
  -- Always set pool type to the type of the repair we're [partially]
  -- reporting
  setObjectStatus pool $ R.repairedNotificationMsg prt
  repairedObjs <- fmap AnyConfObj <$> mapMaybeM lookupSDevDisk repairedSDevs
  if length sdevs == length okObjects
    -- everything completed, if we were reparing, start rebalance and continue
    then do phaseLog "info" $ "Full repair on " ++ show pool
            notifyMero (AnyConfObj pool : repairedObjs) $ R.repairedNotificationMsg prt
            unsetPoolRepairStatus pool
            -- If we have just finished repair, start rebalance and
            -- start queries.
            when (prt == M0.Failure) $ do
              phaseLog "info" $ "Repair on " ++ show pool
                             ++ " complete, proceeding to rebalance [DISABLED]"

              -- TODO XXX Duo to MERO-1569, we don't start rebalance.
              when False $ do
                -- Update pool and drive states, startRebalanceOperation
                -- will notify mero
                rg <- getLocalGraph
                mapM_ (flip updateDriveState M0_NC_REBALANCE)
                   $ filter (isReplaced rg) sdevs
                startRebalanceOperation pool
                queryStartHandling pool
    -- only notifying about partial repair, don't finish repairing
    else do phaseLog "info" $ "Partial repair, notifying about " ++ show repairedSDevs
            notifyMero repairedObjs $ R.repairedNotificationMsg prt

  traverse_ messageProcessed muid
  where
    isReplaced :: G.Graph -> M0.SDev -> Bool
    isReplaced rg s = not . null $
      [ () | (disk :: M0.Disk) <- G.connectedTo s M0.IsOnHardware rg
           , (sd :: StorageDevice) <- G.connectedTo disk At rg
           , G.isConnected sd Has SDReplaced rg]

--------------------------------------------------------------------------------
-- Main handler                                                               --
--------------------------------------------------------------------------------

-- | Dispatch appropriate repair procedures based on the set of
-- notifications we have received.
--
-- * Process the set of notifications into a format that we can work
-- with and only with information we care about.
--
-- * Start by processing any devices that went into a failed state.
-- Unfortunately we have to include some drive reset logic in here.
--
-- * Handle messages that only include information about devices and
-- not pools.
--
-- * If pool information was included in the message set, use
-- 'processPoolInfo' instead.
--
-- TODO: Currently we don't handle a case where we have pool
-- information in the message set but also some disks which belong to
-- a different pool.
handleRepair :: Set -> PhaseM LoopState l ()
handleRepair noteSet = processSet noteSet >>= \case
  -- Handle information from messages that didn't include pool
  -- information. That is, DevicesOnly is a list of all devices and
  -- their states that were reported in the given 'Set' message. Most
  -- commonly we'll enter here when some device changes state and
  -- RC is notified about the change.
  DevicesOnly devices -> do
    phaseLog "repair" $ "Processed as " ++ show (DevicesOnly devices)
    for_ devices $ \(pool, diskMap) -> do

      tr <- getPoolSDevsWithState pool M0_NC_TRANSIENT
      fa <- getPoolSDevsWithState pool M0_NC_FAILED

      -- If no devices are transient and something is failed, begin
      -- repair. It's up to caller to ensure any previous repair has
      -- been aborted/completed.
      let maybeBeginRepair = when (null tr && not (null fa)) $ do
            phaseLog "repair" $ "Starting repair operation on " ++ show pool
            startRepairOperation pool
            queryStartHandling pool

      getPoolRepairStatus pool >>= \case
        Just (M0.PoolRepairStatus prt _ _)
          -- Repair happening, device failed, restart repair
          | fa' <- getSDevs diskMap M0_NC_FAILED
          , not (S.null fa') -> abortRepair pool >> maybeBeginRepair
          -- Repair happening, some devices are transient
          | tr' <- getSDevs diskMap M0_NC_TRANSIENT
          , not (S.null tr') -> do
              phaseLog "repair" $ "Got M0_NC_TRANSIENT for " ++ show (pool, tr)
                               ++ ", quescing repair."
              quiesceRepair pool prt
          -- Repair happening, something came online, check if
          -- nothing is left transient and continue repair if possible
          | Just ds <- allWithState diskMap M0_NC_ONLINE
          , ds' <- S.toList ds -> do
              sdevs <- filter (`notElem` ds') <$> getPoolSDevs pool
              sts <- mapMaybeM queryObjectStatus sdevs
              if null $ filter (== M0_NC_TRANSIENT) sts
              then continueRepair pool prt
              else phaseLog "repair" $ "Still some drives transient: " ++ show sts
          | otherwise -> phaseLog "repair" $
              "Repair on-going but don't know what to do with " ++ show diskMap
        -- No repair, devices have failed, no TRANSIENT devices; start repair
        Nothing -> maybeBeginRepair

  PoolInfo pool st m -> do
    phaseLog "repair" $ "Processed as PoolInfo " ++ show (pool, st, m)
    setObjectStatus pool st
    processPoolInfo pool st m
  UnknownSet st -> phaseLog "warn" $ "Could not classify " ++ show st


-- | We have received information about a pool state change (as well
-- as some devices) so handle this here. Such a notification is likely
-- to have come from IOS indicating thigns like finished
-- repair/rebalance.
processPoolInfo :: M0.Pool
                -- ^ Pool to work on
                -> ConfObjectState
                -- ^ Status of the pool
                -> SDevStateMap
                -- ^ Status of the disks in the pool as received in a
                -- notification. Note this may not be the full set of
                -- disks belonging to the pool.
                -> PhaseM LoopState l ()

-- We are rebalancing and have received ONLINE for the pool and all
-- the devices: rebalance is finished so simply fall back to query
-- handler which will query the repair status and complete the
-- procedure.
processPoolInfo pool M0_NC_ONLINE m
  | Just _ <- allWithState m M0_NC_ONLINE = getPoolRepairStatus pool >>= \case
      Nothing -> phaseLog "warning" $ "Got M0_NC_ONLINE for a pool but "
                                   ++ "no pool repair status was found."
      Just (M0.PoolRepairStatus M0.Rebalance _ _) -> do
        phaseLog "repair" $ "Got M0_NC_ONLINE for a pool that is rebalancing."
        -- Will query spiel for repair status and complete the repair
        queryStartHandling pool
      _ -> phaseLog "repair" $ "Got M0_NC_ONLINE but pool is repairing now."

-- We got a REPAIRED for a pool that was repairing before. Currently
-- we simply fall back to queryStartHandling which should conclude the
-- repair.
processPoolInfo pool M0_NC_REPAIRED _ = getPoolRepairStatus pool >>= \case
  Nothing -> phaseLog "warning" $ "Got M0_NC_REPAIRED for a pool but "
                               ++ "no pool repair status was found."
  Just pri@(M0.PoolRepairStatus prt _ _)
    | prt == M0.Failure -> do
    phaseLog "repair" $ "Got M0_NC_REPAIRED for a pool that is repairing, "
                     ++ "checking if other IOS completed."
    iosvs <- length <$> R.getIOServices pool
    Just pri <- getPoolRepairInformation pool
    unless (priOnlineNotifications pri < iosvs) $
      withRepairStatus prt pool nil $ \sts -> do
        -- is 'filterCompletedRepairs' relevant for rebalancing too?
        -- If not, how do we handle this query?
        let onlines = length $ R.filterCompletedRepairs sts
        modifyPoolRepairInformation pool $ \pri' ->
            pri' { priOnlineNotifications = onlines }
        updatePoolRepairStatusTime pool
        unless (onlines < iosvs) $ do
          phaseLog "repair" $ "All IOS have finished repair, moving to complete"
          completeRepair pool prt Nothing
  _ -> phaseLog "repair" $ "Got M0_NC_REPAIRED but pool is rebalancing now."

-- We got some pool state info but we don't care about what it is as
-- it seems some devices belonging to the pool failed, abort repair.
processPoolInfo pool _ m
  | fa <- getSDevs m M0_NC_FAILED
  , not (S.null fa) = abortRepair pool
-- All the devices we were notified in the pool came up as ONLINE. In
-- this case we may want to continue repair if no other devices in the
-- pool are transient.
  | Just ds <- allWithState m M0_NC_ONLINE
  , ds' <- S.toList ds = getPoolRepairStatus pool >>= \case
      Just (M0.PoolRepairStatus prt _ _) -> do
        sdevs <- filter (`notElem` ds') <$> getPoolSDevs pool
        sts <- mapMaybeM queryObjectStatus sdevs
        if null $ filter (== M0_NC_TRANSIENT) sts
        then continueRepair pool prt
        else phaseLog "repair" $ "Still some drives transient: " ++ show sts
      _ -> phaseLog "repair" $ "Got some transient drives but repair not on-going on " ++ show pool
-- Some devices came up as transient, quiesce repair if it's on-going.
  | tr <- getSDevs m M0_NC_TRANSIENT
  , _:_ <- S.toList tr = getPoolRepairStatus pool >>= \case
      Nothing -> do
        phaseLog "repair" $ "Got M0_NC_TRANSIENT for " ++ show (pool, tr)
                         ++ " but no repair is on-going, doing nothing."
      Just (M0.PoolRepairStatus prt _ _) -> do
        phaseLog "repair" $ "Got M0_NC_TRANSIENT for " ++ show (pool, tr)
                         ++ ", quescing repair."
        quiesceRepair pool prt

processPoolInfo pool st m = phaseLog "warning" $ unwords
  [ "Got", show st, "for a pool", show pool
  , "but don't know how to handle it: ", show m ]

--------------------------------------------------------------------------------
-- Helpers                                                                    --
--------------------------------------------------------------------------------

-- | Like 'mapMaybe' but lifted to 'Monad'.
mapMaybeM :: Monad m => (a -> m (Maybe b)) -> [a] -> m [b]
mapMaybeM f xs = catMaybes <$> mapM f xs

-- | Helper used by 'processSet'
data ProcessedSet = DevicesOnly [(M0.Pool, SDevStateMap)]
                    -- ^ We got a set of sdevs but no pool info
                  | PoolInfo M0.Pool ConfObjectState SDevStateMap
                    -- ^ Some info came back about done repairs
                  | UnknownSet Set
                    -- ^ Can't classify
                  deriving (Show, Eq)

-- | Given a 'Set', figure out what type of information we're getting
-- so we can act accordingly: for example, we want to act differently
-- if it's s a vector of failed drives from when it's a vector of
-- repaired pool and drives.
--
-- TODO: Currently we don't handle a case where we have pool
-- information in the message set but also some disks which belong to
-- a different pool. We should always check which SDevs belong to what
-- pool instead of making an assumption that all sdevs in notification
-- belong to the only pool in notification.
processSet :: Set -> PhaseM LoopState l ProcessedSet
processSet st@(Set ns) = do
  -- Is it a set of failed drives so we should start repair?
  getDevicesOnly >>= \case
    Just devs -> return $ DevicesOnly devs
    Nothing -> getPoolInfo >>= \case
      Just pinfo -> return pinfo
      _ -> return $ UnknownSet st
  where
    getDevicesOnly = mapMaybeM (\(Note fid' _) -> lookupConfObjByFid fid') ns >>= \case
      ([] :: [M0.Pool]) -> do
        disks <- mapMaybeM noteToSDev ns
        pdisks <- mapMaybeM (\(stType, sdev) -> getSDevPool sdev
                               >>= return . fmap (,(stType, sdev)))
                            disks

        return . Just . M.toList
                      . M.map (SDevStateMap . M.fromListWith (<>))
                      . M.fromListWith (<>)
                      . map (\(pool, (st', sdev)) -> (pool, [(st', S.singleton sdev)]))
                      $ pdisks

      _ -> return Nothing

    getPoolInfo = do
      mapMaybeM (\(Note fid' typ) -> fmap (typ,) <$> lookupConfObjByFid fid') ns >>= \case
        [(typ, pool)] -> do
          disks <- M.fromListWith (<>) . map (second S.singleton) <$> mapMaybeM noteToSDev ns
          return . Just . PoolInfo pool typ $ SDevStateMap disks
        _ -> return Nothing

-- | A mapping of 'ConfObjectState's to 'M0.SDev's.
newtype SDevStateMap = SDevStateMap (M.Map ConfObjectState (S.HashSet SDev))
  deriving (Show, Eq, Generic, Typeable)

-- | Queries the 'SDevStateMap'.
getSDevs :: SDevStateMap -> ConfObjectState -> S.HashSet SDev
getSDevs (SDevStateMap m) st = fromMaybe mempty $ M.lookup st m

-- | Check that all 'SDev's have the given 'ConfObjectState' and if
-- they do, return them.
allWithState :: SDevStateMap -> ConfObjectState -> Maybe (S.HashSet SDev)
allWithState sm@(SDevStateMap m) st =
  if M.member st m && M.size m == 1 then Just $ getSDevs sm st else Nothing


-- | Check if the repair is quiesced. Note that this function just
-- checks if any SNS status comes back as
-- 'Spiel.M0_SNS_CM_STATUS_PAUSED': if we get no statuses back, it
-- will report as no quiesce happening.
repairHasQuiesced :: Pool -> PoolRepairType
                  -> PhaseM LoopState l (Either SomeException Bool)
repairHasQuiesced pool prt = R.repairStatus prt pool >>= \case
  Left e -> return $ Left e
  Right sts -> do
    let p (Spiel.SnsStatus _ Spiel.M0_SNS_CM_STATUS_PAUSED _) = True
        p _                                                   = False
    return . Right . not . null $ filter p sts
