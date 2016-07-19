{-# LANGUAGE TypeOperators #-}
-- |
-- Copyright : (C) 2013,2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- * Recovery coordinator
--
-- LEGEND: RC - recovery coordinator, R - replicator, RG - resource graph.
--
-- Behaviour of RC is determined by the state of RG and incoming HA events that
-- are posted by R from the event queue maintained by R. After recovering an HA
-- event, RC instructs R to drop the event, using a globally unique identifier.

{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}

module HA.RecoveryCoordinator.Mero
       ( module HA.RecoveryCoordinator.Actions.Core
       , module HA.RecoveryCoordinator.Actions.Hardware
       , module HA.RecoveryCoordinator.Actions.Service
       , module HA.RecoveryCoordinator.Actions.Test
       , IgnitionArguments(..)
       , GetMultimapProcessId(..)
       , ack
       , makeRecoveryCoordinator
       , sendToMonitor
       , sendToMasterMonitor
       , loadNodeMonitorConf
       , buildRCState
       , timeoutHost
       , HostDisconnected(..)
       , labelRecoveryCoordinator
       ) where

import Prelude hiding ((.), id, mapM_)
import HA.Resources
import HA.Multimap

import HA.RecoveryCoordinator.Actions.Core
import qualified HA.RecoveryCoordinator.Actions.Storage as Storage
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Actions.Service
import HA.RecoveryCoordinator.Actions.Monitor
import HA.RecoveryCoordinator.Actions.Test
import qualified HA.Resources.Castor as M0
#ifdef USE_MERO
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note (ConfObjectState(..))
import HA.Services.Mero (createSet, notifyMero)
import HA.RecoveryCoordinator.Actions.Mero.Core
#endif
import qualified HA.ResourceGraph as G

import Control.Distributed.Process
import qualified Control.Monad.Catch as Catch

import Control.Wire hiding (when)

import Data.Binary (Binary)
import Data.Dynamic
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map

import GHC.Generics (Generic)

import Network.CEP

-- | Initial configuration data.
data IgnitionArguments = IgnitionArguments
  { -- | The names of all event queue nodes.
    eqNodes :: [NodeId]
  } deriving (Generic,Typeable)

instance Binary IgnitionArguments

-- | An internal message type.
data NodeAgentContacted = NodeAgentContacted ProcessId
         deriving (Typeable, Generic)

instance Binary NodeAgentContacted

data GetMultimapProcessId =
    GetMultimapProcessId ProcessId deriving (Typeable, Generic)

instance Binary GetMultimapProcessId

-- | Used in 'timeoutHost'
newtype HostDisconnected = HostDisconnected M0.Host
  deriving (Show, Eq, Generic, Typeable)

instance Binary HostDisconnected

-- | Notify mero about the node being considered down and set the
-- appropriate host attributes.
timeoutHost :: M0.Host -> PhaseM LoopState g ()
timeoutHost h = hasHostAttr M0.HA_TRANSIENT h >>= \case
  False -> return ()
  True -> do
    phaseLog "info" $ "Disconnecting " ++ show h ++ " due to timeout"
    unsetHostAttr h M0.HA_TRANSIENT
    setHostAttr h M0.HA_DOWN
    publish $ HostDisconnected h

ack :: ProcessId -> PhaseM LoopState l ()
ack pid = liftProcess $ usend pid ()

initialize :: StoreChan -> Process G.Graph
initialize mm = do
    rg <- G.getGraph mm
    if G.null rg then say "Starting from empty graph."
                 else say "Found existing graph."
    -- Empty graph means cluster initialization.
    let rg' | G.null rg =
            G.newResource Cluster >>>
            G.addRootNode Cluster
            $ rg
            | otherwise = rg
    return rg'

----------------------------------------------------------
-- Recovery Co-ordinator                                --
----------------------------------------------------------

buildRCState :: StoreChan -> ProcessId -> Process LoopState
buildRCState mm eq = do
    rg      <- HA.RecoveryCoordinator.Mero.initialize mm
    startRG <- G.sync rg (return ())
    return $ LoopState startRG Map.empty mm eq Map.empty Storage.empty

msgProcessedGap :: Int
msgProcessedGap = 10

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
                        -> Definitions LoopState ()
                        -> Process ()
makeRecoveryCoordinator mm eq rm = do
   init_st <- buildRCState mm eq
   self <- getSelfPid
   maybe (register labelRecoveryCoordinator self)
         (const $ reregister labelRecoveryCoordinator self)
         =<< whereis labelRecoveryCoordinator
#ifdef USE_MERO
   flip Catch.finally tryCloseMeroWorker $ execute init_st $ do
#else
   execute init_st $ do
#endif
     rm
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
