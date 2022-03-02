{-# LANGUAGE LambdaCase #-}
-- |
-- Copyright : (C) 2013,2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- * Recovery coordinator
--
-- LEGEND: RC - recovery coordinator, R - replicator, RG - resource graph.
--
-- Behaviour of RC is determined by the state of RG and incoming HA events that
-- are posted by R from the event queue maintained by R. After recovering an HA
-- event, RC instructs R to drop the event, using a globally unique identifier.
module HA.RecoveryCoordinator.Mero
       ( module HA.RecoveryCoordinator.RC.Actions
       , module HA.RecoveryCoordinator.Actions.Hardware
       , module HA.RecoveryCoordinator.Actions.Test
       , IgnitionArguments(..)
       , ack
       , makeRecoveryCoordinator
       , buildRCState
       , timeoutHost
       , HostDisconnected(..)
       , labelRecoveryCoordinator
       ) where

import           Control.Distributed.Process
import           Data.Binary (Binary)
import           Data.Dynamic
import           Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import           GHC.Generics (Generic)
import           HA.Migrations
import           HA.Multimap
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Test
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.RecoveryCoordinator.RC.Internal.Storage as Storage
import qualified HA.RecoverySupervisor as RS
import qualified HA.ResourceGraph as G
import           HA.Resources
import qualified HA.Resources.Castor as M0
import           Network.CEP

-- | Initial configuration data.
data IgnitionArguments = IgnitionArguments
  { -- | The names of all event queue nodes.
    eqNodes :: [NodeId]
  } deriving (Generic,Typeable)

instance Binary IgnitionArguments

-- | Used in 'timeoutHost'
newtype HostDisconnected = HostDisconnected M0.Host
  deriving (Show, Eq, Generic, Typeable)

instance Binary HostDisconnected

-- | Notify mero about the node being considered down and set the
-- appropriate host attributes.
timeoutHost :: M0.Host -> PhaseM RC g ()
timeoutHost h = hasHostAttr M0.HA_TRANSIENT h >>= \case
  False -> return ()
  True -> do
    Log.rcLog' Log.DEBUG $ "Disconnecting " ++ show h ++ " due to timeout"
    unsetHostAttr h M0.HA_TRANSIENT
    setHostAttr h M0.HA_DOWN
    publish $ HostDisconnected h

-- | Send '()' to the given 'ProcessId' as a form of acknowledgement.
ack :: ProcessId -> PhaseM RC l ()
ack pid = liftProcess $ usend pid ()

initialize :: StoreChan -> Process G.Graph
initialize mm = do
   -- Migrate replicated state before doing anything else if necessary.
    rg <- migrateOrQuit mm
    -- Empty graph means cluster initialization.
    if G.null rg
    then do
      say "Starting from empty graph."
      return $! G.addRootNode Cluster rg
    else do
      say "Found existing graph."
      return rg

----------------------------------------------------------
-- Recovery Co-ordinator                                --
----------------------------------------------------------

-- | Create a 'LoopState'. Multimap 'StoreChan' and EQ 'ProcessId'
-- have to be specified.
buildRCState :: StoreChan -> ProcessId -> Process LoopState
buildRCState mm eq = do
    rg      <- HA.RecoveryCoordinator.Mero.initialize mm
    startRG <- G.sync rg $ writeCurrentVersionFile
    return $ LoopState startRG mm eq Map.empty Storage.empty

msgProcessedGap :: Int
msgProcessedGap = 10

-- | Process label used by the recovery coordinator.
labelRecoveryCoordinator :: String
labelRecoveryCoordinator = "mero-halon.RC"

-- | The entry point for the RC.
--
-- Before evaluating 'recoveryCoordinator', the global network variable needs
-- to be initialized with 'HA.Network.Address.writeNetworkGlobalIVar'. This is
-- done automatically if 'HA.Network.Address.startNetwork' is used to create
-- the transport.
makeRecoveryCoordinator :: StoreChan -- ^ channel to the replicated multimap
                        -> ProcessId -- ^ pid of the EQ
                        -> Definitions RC ()
                        -> Process ()
makeRecoveryCoordinator mm eq rm = do
   init_st <- buildRCState mm eq
   self <- getSelfPid
   maybe (register labelRecoveryCoordinator self)
         (const $ reregister labelRecoveryCoordinator self)
         =<< whereis labelRecoveryCoordinator
   execute init_st $ do
     rm
     defineSimple "rs:keepalive-reply" $ liftProcess . RS.keepaliveReply
     setRuleFinalizer $ \ls -> do
       newGraph <- G.sync (lsGraph ls) (return ())
       -- We don't accept message as soon as ref count is zero, but
       -- instead give 'msgProcessedGap' number of rounds, this way
       -- we a trying to solve a case when more than one rule is interested
       -- in particular message.
       let refCnt = Map.map update (lsRefCount ls)
           update i
             | i <= 0 = i-1
             | otherwise = i
           (removed, !newRefCnt) = Map.partition (<(-msgProcessedGap)) refCnt
       for_ (Map.keys removed) $ usend (lsEQPid ls)

       return ls { lsGraph = newGraph, lsRefCount = newRefCnt }
