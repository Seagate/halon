{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DoAndIfThenElse       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules specific to mero server Castor install of Mero.

module HA.RecoveryCoordinator.Rules.Castor.Server
  ( ruleNewMeroServer
  , HA.RecoveryCoordinator.Rules.Castor.Server.__remoteTable
  , bootstrapMeroServerExtra__tdict
  ) where

import           Control.Category ((>>>))
import           Control.Distributed.Process
import           Control.Distributed.Process.Closure (mkClosure)
import           Control.Distributed.Process.Closure (remotable)
import           Control.Monad
import           Data.Binary (Binary)
import qualified Data.ByteString as BS
import           Data.Foldable
import           Data.List (partition)
import           Data.Maybe (listToMaybe, isJust)
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           HA.EventQueue.Producer
import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Events.Mero
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import           HA.Resources.Castor.Initial (Network(Data))
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero hiding (Node, Process, Enclosure, Rack, fid)
import           HA.Services.Mero
import           Mero.ConfC (ServiceType(..), Fid, fidToStr)
import           Network.CEP
import           Prelude
import           System.Directory
import           System.IO
import           System.SystemD.API (startService, sysctlFile)

-- | Mero server bootstrapping has finished all together.
newtype ServerBootstrapFinished = ServerBootstrapFinished NodeId
  deriving (Typeable, Generic)

instance Binary ServerBootstrapFinished

newtype MeroServerStartRemainingServices = MeroServerStartRemainingServices NodeId
  deriving (Typeable, Generic)

instance Binary MeroServerStartRemainingServices

-- | Start processes using the @m0d\@@ systemd service. These are the
-- services that aren't part of the core bootstrap, i.e. not confd or RM.
--
-- Takes a list of fids (one per service), m0d endpoint address, halon
-- endpoint address and the 'M0.Profile' 'Fid'.
bootstrapMeroServerExtra :: ([Fid], String, String, Fid)
                            -- ^ Process fids of the services
                         -> Process ()
bootstrapMeroServerExtra (fids, m0addr, haAddr, profileFid) = do
  say "Bootstrapping extra services"
  _ <- liftIO . forM_ (fidToStr <$> fids) $ \fid -> do
    _ <- sysctlFile ("m0d-" ++ fid)
      [ ("MERO_M0D_EP", m0addr)
      , ("MERO_HA_EP", haAddr)
      , ("MERO_PROFILE_FID", fidToStr profileFid)
      ]
    startService $ "m0d@" ++ fid
  getSelfNode >>= promulgateWait . ServerBootstrapFinished

remotable [ 'bootstrapMeroServerExtra ]

-- | Retrieve the conf file contents so they can be sent to the nodes
-- and stored there before confd and RM are brought up.
syncConfToBS :: PhaseM LoopState l BS.ByteString
syncConfToBS = do
  fp <- liftIO $ do
    tmpdir <- getTemporaryDirectory
    (fp, h) <- openTempFile tmpdir "conf.xc"
    hClose h >> return fp
  syncAction Nothing $ SyncDumpToFile fp
  conf <- liftIO $ BS.readFile fp
  liftIO $ BS.length conf `seq` removeFile fp
  return conf

-- | Bootstrap a new mero server.
--
-- Procedure:
--
-- * Receive 'NewMeroServer'. Mark the node as being bootstrapped.
-- Start the mero service and wait for the reply from it in the next
-- phase.
--
-- * Receive 'MeroServerCoreBootstrapped' from the mero service. Wait
-- until we have received this message for every node we have been
-- bootstrapping so far. Once we do, send a message to each node
-- telling it to start non-core services.
--
-- * Receive the non-core service message. Tell each node to start the
-- services it's in charge of.
--
-- * Wait for 'MeroServerBootstrapped' from the non-core service
-- starter. Wait until every node gets this message. Remove the RG
-- bootstrap flag from the nodes in the RG. The rule ends.
ruleNewMeroServer :: Definitions LoopState ()
ruleNewMeroServer = define "new-mero-server" $ do
  new_server <- phaseHandle "initial"
  core_bootstrapped <- phaseHandle "core-bootstrapped"
  start_remaining_services <- phaseHandle "start-remaining-services"
  finish_extra_bootstrap <- phaseHandle "finish-extra-bootstrap"
  finish <- phaseHandle "finish"

  let alreadyBootstrapping n g = G.isConnected Cluster Runs (ServerBootstrapCoreProcess n False) g
                                || G.isConnected Cluster Runs (ServerBootstrapProcess n False) g

      startMeroService :: Node -> PhaseM LoopState l ()
      startMeroService node = findNodeHost node >>= \case
        Nothing -> continue finish
        Just host -> do
          svs <- getServices node
          case null [ () | M0.Service{ M0.s_type = CST_MGS }
                            <- concat . fmap snd $ svs ] of
            True -> do
              phaseLog "info" $ "No confd service on " ++ show host
              startMeroServerService host node Nothing
            False -> do
              conf <- syncConfToBS
              startMeroServerService host node $ Just conf
          continue core_bootstrapped

      ackingLast handle newMsgEid newNid phase = do
        Just (Node nid, eid) <- get Local
        if (nid /= newNid)
        then continue handle
        else do messageProcessed eid
                put Local $ Just (Node nid, newMsgEid)
                phase

      failureHandler e nid = case e of
        Nothing -> Nothing
        Just ex -> Just $ do
          phaseLog "warn" $ "Core bootstrapping failed on " ++ show nid
          findNodeHost (Node nid) >>= \case
            Nothing -> return ()
            Just host -> setHostAttr host (HA_BOOTSTRAP_FAILED ex)


  setPhase new_server $ \(HAEvent eid (NewMeroServer node@(Node nid)) _) -> do
    put Local $ Just (node, eid)
    findNodeHost node >>= \case
      Just host -> alreadyBootstrapping nid <$> getLocalGraph >>= \case
        True -> continue finish
        False -> getFilesystem >>= \case
          Just fs -> do
            let pcore = ServerBootstrapCoreProcess nid False
            phaseLog "info" "Starting core bootstrap"
            modifyLocalGraph $
              return . G.connect Cluster Runs pcore . G.newResource pcore
            hatrs <- findHostAttrs host
            g <- getLocalGraph
            let lnid = listToMaybe $ [ ip | Interface { if_network = Data, if_ipAddrs = ip:_ }
                                              <- G.connectedTo host Has g ]
                memsize = listToMaybe $ [ fromIntegral m | HA_MEMSIZE_MB m <- hatrs ]
                cpucnt = listToMaybe $ [ cnt | HA_CPU_COUNT cnt <- hatrs ]
            case HostHardwareInfo <$> memsize <*> cpucnt <*> lnid of
              Nothing -> do
                phaseLog "warn" $ "HostHardwareInfo couldn't be constructed: "
                               ++ show (lnid, memsize, cpucnt)
                continue finish
              Just info -> do
                storeMeroNodeInfo fs host info HA_M0SERVER
                startMeroService node
                continue core_bootstrapped
          Nothing -> do
            phaseLog "warn" "Couldn't getFilesystem"
            continue finish
      Nothing -> do
        phaseLog "error" $ "Can't find host for node " ++ show node
        continue finish


  -- Wait until every process comes back as finished bootstrapping
  setPhase core_bootstrapped $ \(HAEvent eid (MeroServerCoreBootstrapped e nid) _) -> do
    ackingLast core_bootstrapped eid nid $
      barrier
        Cluster Runs
        (ServerBootstrapCoreProcess nid)
        (\(ServerBootstrapCoreProcess _ b) -> b)
        start_remaining_services finish (failureHandler e nid)
        (\(ServerBootstrapCoreProcess nid' _) ->
          liftProcess . promulgateWait $ MeroServerStartRemainingServices nid')


  setPhase start_remaining_services $ \(HAEvent eid (MeroServerStartRemainingServices nid) _) -> do
    Just (Node nid', eid') <- get Local
    g <- getLocalGraph
    case () of
      _ | (nid /= nid') -> continue start_remaining_services
        | G.isConnected Cluster Runs (ServerBootstrapProcess nid False) g -> do
            phaseLog "info" $ "Already bootstrapping: " ++ show nid
            continue finish_extra_bootstrap
        | otherwise -> do
           messageProcessed eid'
           put Local $ Just (Node nid', eid)
           modifyLocalGraph $
             return . G.connect Cluster Runs (ServerBootstrapProcess nid False)
           syncGraphBlocking
           svs <- getServices (Node nid)
           phaseLog "debug" $ "Processes/services: " ++ show svs
           let extraFids :: [Fid]
               extraFids = [ M0.r_fid p | (p, c) <- svs
                                        , notElem CST_MGS $ s_type <$> c
                                        ]
           phaseLog "debug" $ "Non MGS process fids: " ++ show extraFids
           mhost <- findNodeHost (Node nid)
           maybe (return Nothing) getMeroServiceInfo mhost >>= \case
             Nothing -> liftProcess $ getSelfNode >>= promulgateWait . ServerBootstrapFinished
             Just (haAddr, profile, process) -> do
               liftProcess . void . spawnLocal . void . spawnAsync nid $
                 $(mkClosure 'bootstrapMeroServerExtra)
                   (extraFids, M0.r_endpoint process, haAddr, M0.fid profile)
           continue finish_extra_bootstrap

  setPhase finish_extra_bootstrap $ \(HAEvent eid (ServerBootstrapFinished nid) _) -> do
    ackingLast finish_extra_bootstrap eid nid $
      barrier
        Cluster Runs
        (ServerBootstrapProcess nid)
        (\(ServerBootstrapProcess _ b) -> b)
        finish finish Nothing
        (\_ -> return ())

  directly finish $ do
    Just (n, eid) <- get Local
    phaseLog "server-bootstrap" $ "Finished bootstrapping mero server at "
                               ++ show n
    messageProcessed eid

  start new_server Nothing

-- |
-- @
-- 'barrier' hookPoint hookRel setState viewState phandle failHandle
-- failure release
-- @
--
-- A helper for creating barriers across multiple workers. Providied
-- some user-defined tracking state for each of the workers and some
-- information on how to query it, we can synchronise by having each
-- of the workers check if it's the last one to finish its work. All
-- workers continue to @phandle@ regardless but the last one also runs
-- @release@. It should be easy to see that if @phandle@ blocks until
-- certain condition happens and @release@ satisfies that condition,
-- we have a barrier. Note there is no internal blocking mechanism:
-- this helper relies on @phandle@ to block and @release@ to unblock.
--
-- In case that @failure@ is not 'Nothing', something has gone wrong
-- with this worker so we shouldn't advance it to @phandle@ nor
-- consider it in @release@. Instead, run @failure@ which should be
-- used to mark failure for the rest of the system if necessary and
-- then advance the worker to @failHandle@. If the failed worker is
-- the last one in the pool, it will still run @release@ before
-- continuing to @failHandle@.
--
-- @viewState . setState == id@
barrier :: forall r a st l. G.Relation r a st
        => a -- ^ Resource to which tracking states are attached to
        -> r -- ^ Relation by which the tracking states are attached through
        -> (Bool -> st) -- ^ Tracker state constructor
        -> (st -> Bool) -- ^ Tracker state destructor
        -> Jump PhaseHandle -- ^ Next phase
        -> Jump PhaseHandle -- ^ Bail out phase
        -> Maybe (PhaseM LoopState l ())
        -- ^ Exception handler bootstrap process
        -> (st -> PhaseM LoopState l ())
        -- ^ Callback to execute by the last worker in the pool: this
        -- should allow the other workers to progress onto the given
        -- phase handle, effectively releasing the barrier. The
        -- release callback is applied to each of the tracking states
        -- to give it a chance to make a smart release.
        -> PhaseM LoopState l ()
barrier hookPoint hookRel setState viewState phandle failHandle failure release = do
  modifyLocalGraph $ return . G.disconnect hookPoint hookRel (setState False)
  reconnectStatus
  g <- getLocalGraph
  let finished, unfinished :: [st]
      (finished, unfinished) = partition viewState $ G.connectedTo hookPoint hookRel g
  when (null unfinished) $ do
    modifyLocalGraph $ \g0 -> do
      -- Disconect all the state trackers from the RG, we no longer
      -- need them.
      return $ foldl' (\g' sp -> G.disconnect hookPoint hookRel sp g') g0 finished
    mapM_ release finished
  continue $ if isJust failure then failHandle else phandle
  where
    -- When we have a failure handler available, use it. If not then
    -- there was no failure so insert tracking state back into RG as
    -- successful so the barrier release can catch it.
    reconnectStatus = case failure of
      Nothing -> modifyLocalGraph
                $ G.newResource (setState True)
             >>> return . G.connect hookPoint hookRel (setState True)
      Just h -> h

getServices :: Node -> PhaseM LoopState l [(M0.Process, [M0.Service])]
getServices node = do
  Just host <- findNodeHost node
  g <- getLocalGraph
  return [ (p, G.connectedTo p IsParentOf g)
         | ctl :: M0.Controller <- G.connectedFrom M0.At host g
         , m0node :: M0.Node <- G.connectedFrom M0.IsOnHardware ctl g
         , p :: M0.Process <- G.connectedTo m0node IsParentOf g
         ]
