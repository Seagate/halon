{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase     #-}
-- |
-- Module    : HA.RecoveryCoordinator.Mero.Transitions
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Collection of all 'Transition's.
--
-- TODO: Nicer naming.
module HA.RecoveryCoordinator.Mero.Transitions
  ( module HA.RecoveryCoordinator.Mero.Transitions
  , HA.RecoveryCoordinator.Mero.Transitions.Internal.Transition
  ) where

import           GHC.Stack
import           HA.RecoveryCoordinator.Mero.Transitions.Internal
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note

-- | A 'CascadeTransition' is a 'Transition' that depends on a state
-- of some other object to decide what to do.
type CascadeTransition a b = StateCarrier a -> Transition b

-- * 'M0.Process'

-- | Fail a process with the given reason.
processFailed :: String -> Transition M0.Process
processFailed = constTransition . M0.PSFailed

-- | HA 'M0.Process' online.
processHAOnline :: Transition M0.Process
processHAOnline = constTransition M0.PSOnline

-- | 'M0.Process' started.
processOnline :: (?loc :: CallStack) => Transition M0.Process
processOnline = Transition $ \case
  M0.PSStarting -> TransitionTo M0.PSOnline
  st -> transitionErr ?loc st

-- | 'M0.Process' stop initiated.
--
-- TODO: 'stopNodeProcesses' uses direct graph update, make it use
-- this transition instead
processStopping :: (?loc :: CallStack) => Transition M0.Process
processStopping = Transition $ \case
  M0.PSQuiescing -> TransitionTo M0.PSStopping
  st -> transitionErr ?loc st

-- | HA 'M0.Process' stopping.
--
-- TODO: Make HA process go through quiescing like other processes
-- do and use 'processStopping'.
processHAStopping :: Transition M0.Process
processHAStopping = constTransition M0.PSStopping

-- | 'M0.Process' is starting.
processStarting :: Transition M0.Process
processStarting = constTransition M0.PSStarting

-- | 'M0.Process' was stopping and is now 'M0.PSOffline'.
processOffline :: (?loc :: CallStack) => Transition M0.Process
processOffline = Transition $ \case
  M0.PSStopping -> TransitionTo M0.PSOffline
  st -> transitionErr ?loc st

-- | 'M0.Process' will soon initiate stop.
processQuiescing :: Transition M0.Process
processQuiescing = constTransition M0.PSQuiescing

nodeFailsProcess :: CascadeTransition M0.Node M0.Process
nodeFailsProcess _ = Transition $ \case
  M0.PSFailed{} -> NoTransition
  M0.PSInhibited{} -> NoTransition
  x -> TransitionTo $ M0.PSInhibited x

nodeUnfailsProcess :: CascadeTransition M0.Node M0.Process
nodeUnfailsProcess _ = Transition uninhibit
  where
    uninhibit = \case
      M0.PSInhibited M0.PSOffline -> TransitionTo M0.PSOffline
      M0.PSInhibited M0.PSUnknown -> TransitionTo M0.PSUnknown
      M0.PSInhibited x@M0.PSInhibited{} -> uninhibit x
      M0.PSInhibited _ -> TransitionTo $ M0.PSFailed "node failure"
      _ -> NoTransition

-- * 'M0.Service'

-- | 'M0.Service' came online.
serviceOnline :: (?loc :: CallStack) => Transition M0.Service
serviceOnline = Transition $ \case
  M0.SSStarting -> TransitionTo M0.SSOnline
  st -> transitionErr ?loc st

serviceOffline :: Transition M0.Service
serviceOffline = constTransition M0.SSOffline

processCascadeService :: CascadeTransition M0.Process M0.Service
processCascadeService M0.PSStarting = constTransition M0.SSStarting
processCascadeService M0.PSOnline = constTransition M0.SSOnline
processCascadeService M0.PSOffline = Transition $ \case
  M0.SSFailed -> NoTransition
  _ -> TransitionTo M0.SSOffline
processCascadeService M0.PSFailed{} = constTransition M0.SSFailed
processCascadeService M0.PSQuiescing = Transition $ \case
  M0.SSFailed -> NoTransition
  M0.SSOffline -> NoTransition
  M0.SSInhibited{} -> NoTransition
  o -> TransitionTo $ M0.SSInhibited o
processCascadeService M0.PSStopping = Transition $ \case
  M0.SSFailed -> NoTransition
  _ -> TransitionTo $ M0.SSStopping
processCascadeService M0.PSInhibited{} = Transition $ \case
  M0.SSFailed -> NoTransition
  M0.SSInhibited{} -> NoTransition
  o -> TransitionTo $ M0.SSInhibited o
processCascadeService M0.PSUnknown = Transition $ \_ -> NoTransition

-- * 'M0.Node'

nodeUnknown :: Transition M0.Node
nodeUnknown = constTransition M0.NSUnknown

nodeOnline :: Transition M0.Node
nodeOnline = constTransition M0.NSOnline

nodeFailed :: Transition M0.Node
nodeFailed = constTransition M0.NSFailed

-- * 'M0.Enclosure'

enclosureTransient :: Transition M0.Enclosure
enclosureTransient = constTransition M0_NC_TRANSIENT

enclosureOnline :: Transition M0.Enclosure
enclosureOnline = constTransition M0_NC_ONLINE

rackCascadeEnclosure :: CascadeTransition M0.Rack M0.Enclosure
rackCascadeEnclosure _ = constTransition M0_NC_TRANSIENT

-- * 'M0.Pool'

-- | Transition a 'M0.Pool' to a rebalancing state, after repair has
-- finished.
poolRebalance :: (?loc :: CallStack) => Transition M0.Pool
poolRebalance = Transition $ \case
  M0_NC_REPAIRED -> TransitionTo M0_NC_REBALANCE
  st -> transitionErr ?loc st

-- | TODO: Fill my states in!
poolRepairing :: Transition M0.Pool
poolRepairing = constTransition M0_NC_REPAIR

-- | 'M0.Pool' has managed to repair.
poolRepairComplete :: (?loc :: CallStack) => Transition M0.Pool
poolRepairComplete = Transition $ \case
  M0_NC_REPAIR -> TransitionTo M0_NC_REPAIRED
  st -> transitionErr ?loc st

-- | 'M0.Pool' has managed to rebalance.
poolRebalanceComplete :: (?loc :: CallStack) => Transition M0.Pool
poolRebalanceComplete = Transition $ \case
  M0_NC_REBALANCE -> TransitionTo M0_NC_ONLINE
  st -> transitionErr ?loc st

-- * 'M0.Disk'

diskOnline :: Transition M0.Disk
diskOnline = constTransition M0.SDSOnline

-- | Transition 'M0.Disk's to a rebalancing state, after repair has
-- finished.
diskRebalance :: (?loc :: CallStack) => Transition M0.Disk
diskRebalance = Transition $ \case
  st | toConfObjState (undefined :: M0.SDev) st == M0_NC_REPAIRED ->
         TransitionTo M0.SDSRebalancing
     | otherwise -> transitionErr ?loc st

diskFailed :: Transition M0.Disk
diskFailed = constTransition M0.SDSFailed

-- | 'M0.Disk' inherits any change made to 'M0.SDev'.
sdevCascadeDisk' :: CascadeTransition M0.SDev M0.Disk
sdevCascadeDisk' st = Transition $ \_ -> TransitionTo st

-- * 'M0.SDev'

-- | We're starting repair on 'M0.SDev'.
sdevRepairStart :: (?loc :: CallStack) => Transition M0.SDev
sdevRepairStart = Transition $ \case
  st | toConfObjState (undefined :: M0.SDev) st == M0_NC_FAILED ->
         TransitionTo M0.SDSRepairing
     | otherwise -> transitionErr ?loc st

-- | 'M0.SDev' has managed to repair.
sdevRepairComplete :: (?loc :: CallStack) => Transition M0.SDev
sdevRepairComplete = Transition $ \case
  M0.SDSRepairing -> TransitionTo M0.SDSRepaired
  st -> transitionErr ?loc st

-- | Abort repair on the 'M0.SDev'
sdevRepairAbort :: (?loc :: CallStack) => Transition M0.SDev
sdevRepairAbort = Transition $ \case
  st | toConfObjState (undefined :: M0.SDev) st == M0_NC_REPAIR ->
         TransitionTo M0.SDSFailed
     | otherwise -> transitionErr ?loc st

-- | 'M0.SDev' completed rebalance
sdevRebalanceComplete :: (?loc :: CallStack) => Transition M0.SDev
sdevRebalanceComplete = Transition $ \case
  M0.SDSRebalancing -> TransitionTo M0.SDSOnline
  st -> transitionErr ?loc st

-- | Abort rebalance on the 'M0.SDev'
sdevRebalanceAbort :: (?loc :: CallStack) => Transition M0.SDev
sdevRebalanceAbort = Transition $ \case
  st | toConfObjState (undefined :: M0.SDev) st == M0_NC_REBALANCE ->
         TransitionTo M0.SDSRepaired
     | otherwise -> transitionErr ?loc st

-- | 'M0.SDev' became ready: it may have been attached and had a
-- successful SMART.
sdevReady :: (?loc :: CallStack) => Transition M0.SDev
sdevReady = Transition $ \case
  M0.SDSUnknown -> TransitionTo M0.SDSOnline
  M0.SDSTransient{} -> TransitionTo M0.SDSOnline
  st -> transitionErr ?loc st

sdevFailTransient :: Transition M0.SDev
sdevFailTransient = Transition $ TransitionTo . M0.sdsFailTransient

-- | 'M0.SDev' is no longer transient, recover.
sdevRecoverTransient :: (?loc :: CallStack) => Transition M0.SDev
sdevRecoverTransient = Transition $ \case
  st@M0.SDSTransient{} -> TransitionTo $ M0.sdsRecoverTransient st
  st -> transitionErr ?loc st

sdevFailFailed :: Transition M0.SDev
sdevFailFailed = Transition $ TransitionTo . M0.sdsFailFailed

serviceCascadeDisk :: CascadeTransition M0.Service M0.SDev
serviceCascadeDisk = \case
  M0.SSUnknown -> Transition $ \_ -> NoTransition
  M0.SSOffline -> inhibitSDev
  M0.SSFailed   -> inhibitSDev
  M0.SSStarting -> uninhibitSDev
  M0.SSOnline   -> uninhibitSDev
  M0.SSStopping -> inhibitSDev
  M0.SSInhibited _ -> inhibitSDev
  where
    inhibitSDev = Transition $ \case
      M0.SDSFailed -> NoTransition
      M0.SDSInhibited{} -> NoTransition
      x -> TransitionTo $ M0.SDSInhibited x
    uninhibitSDev = Transition $ \case
      M0.SDSInhibited x -> TransitionTo x
      _ -> NoTransition

-- | 'M0.SDev' inherits any change made to 'M0.Disk'.
diskCascadeSDev' :: CascadeTransition M0.Disk M0.SDev
diskCascadeSDev' st = Transition $ \_ -> TransitionTo st

-- * 'M0.Controller'

nodeCascadeController' :: CascadeTransition M0.Node M0.Controller
nodeCascadeController' M0.NSUnknown = Transition $ \_ -> NoTransition
nodeCascadeController' M0.NSOnline = constTransition M0.CSOnline
nodeCascadeController' _ = constTransition M0.CSTransient

iosFailsControllerTransient :: CascadeTransition M0.Service M0.Controller
iosFailsControllerTransient _ = constTransition M0.CSTransient

iosFailsControllerOnline :: CascadeTransition M0.Service M0.Controller
iosFailsControllerOnline _ = constTransition M0.CSOnline

-- | A 'M0.Disk' has failed, fail the corresponding 'M0.PVer'. The
-- check for limits is performed elsewhere (cascade).
diskFailsPVer :: (?loc :: CallStack) => CascadeTransition M0.Disk M0.PVer
diskFailsPVer a = Transition $ \case
  st@M0_NC_FAILED -> transitionErr ?loc st
  _ -> TransitionTo (toConfObjState (undefined :: M0.Disk) a)

-- | A 'M0.Disk' has come back online, fail the corresponding
-- 'M0.PVer'. The check for whether restoration should happen at all
-- is performed elsewhere (cascade).
diskFixesPVer :: (?loc :: CallStack) => CascadeTransition M0.Disk M0.PVer
diskFixesPVer a = Transition $ \case
  st@M0_NC_ONLINE -> transitionErr ?loc st
  _ -> TransitionTo (toConfObjState (undefined :: M0.Disk) a)

enclosureCascadeControllerTransient :: CascadeTransition M0.Enclosure M0.Controller
enclosureCascadeControllerTransient _ = constTransition M0.CSTransient

enclosureCascadeControllerOnline :: CascadeTransition M0.Enclosure M0.Controller
enclosureCascadeControllerOnline _ = constTransition M0.CSOnline
