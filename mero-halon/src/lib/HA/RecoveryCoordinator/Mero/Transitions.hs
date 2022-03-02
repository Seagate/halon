{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase     #-}
-- |
-- Module    : HA.RecoveryCoordinator.Mero.Transitions
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Collection of all 'Transition's.
--
-- [toConfObjState]: various transitions use 'toConfObjState' on the
-- provided, old state. This is to reflect any existing code which
-- does things based on 'ConfObjectState' and not object-specific
-- state. Further, multiple object-specific states can map to a single
-- 'ConfObjectState' so using 'toConfObjState' is the most sane
-- solution.
--
-- TODO: Nicer naming.
module HA.RecoveryCoordinator.Mero.Transitions
  ( module HA.RecoveryCoordinator.Mero.Transitions
  , HA.RecoveryCoordinator.Mero.Transitions.Internal.Transition
  ) where

import           GHC.Stack
import           Text.Printf
import           HA.RecoveryCoordinator.Mero.Transitions.Internal
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note

-- | A 'CascadeTransition' is a 'Transition' that depends on a state
-- of some other object to decide what to do.
type CascadeTransition a b = StateCarrier a -> Transition b

-- * 'M0.Process'

-- | Keepalive timeout for a process.
processKeepaliveTimeout :: (?loc :: CallStack)
                        => M0.TimeSpec -- ^ Elapsed time
                        -> Transition M0.Process
processKeepaliveTimeout ts = Transition $ \case
  M0.PSOnline    -> toPSFailed
  M0.PSStarting  -> toPSFailed
  M0.PSQuiescing -> toPSFailed
  M0.PSStopping  -> toPSFailed
  st -> transitionErr ?loc st
  where
    (s, ms) = divMod (M0.timeSpecToNanoSecs ts `quot` 10^(6 :: Int)) 1000
    toPSFailed = TransitionTo . M0.PSFailed $ printf
                 "Keepalive timed out after %d.%d seconds" s ms

-- | Fail a process with the given reason.
processFailed :: (?loc :: CallStack) => String -> Transition M0.Process
processFailed m = Transition $ \case
  st@M0.PSOffline -> transitionErr ?loc st
  (M0.PSFailed _) -> NoTransition
  _ -> TransitionTo $ M0.PSFailed m

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
processHAStopping = Transition $ \case
  M0.PSOnline -> TransitionTo M0.PSStopping
  st -> transitionErr ?loc st

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

-- | We do not know the state of this process.
processUnknown :: Transition M0.Process
processUnknown = constTransition M0.PSUnknown

-- | Node has failed so inhibit the processes. See also
-- 'nodeUnfailsProcess'.
nodeFailsProcess :: CascadeTransition M0.Node M0.Process
nodeFailsProcess _ = Transition $ \case
  M0.PSFailed{} -> NoTransition
  M0.PSInhibited{} -> NoTransition
  x -> TransitionTo $ M0.PSInhibited x

-- | Node is no longer failed. Uninhibit processes. See also
-- 'nodeFailsProcess'.
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
  M0.SSUnknown -> TransitionTo M0.SSOnline
  M0.SSStarting -> TransitionTo M0.SSOnline
  st -> transitionErr ?loc st

-- | Unconditionally transition the service 'M0.SSOffline'.
serviceOffline :: Transition M0.Service
serviceOffline = constTransition M0.SSOffline

-- | Process state changed, adjust service states accordingly.
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
processCascadeService M0.PSUnknown = constTransition M0.SSUnknown

-- * 'M0.Node'

-- | Unconditionally transition 'M0.Node' to 'M0.NSUnknown'.
nodeUnknown :: Transition M0.Node
nodeUnknown = constTransition M0.NSUnknown

-- | Unconditionally transition 'M0.Node' to 'M0.NSOnline'.
nodeOnline :: Transition M0.Node
nodeOnline = constTransition M0.NSOnline

-- | Unconditionally transition 'M0.Node' to 'M0.NSFailed'.
nodeFailed :: Transition M0.Node
nodeFailed = constTransition M0.NSFailed

nodeRebalance :: (?loc :: CallStack) => Transition M0.Node
nodeRebalance = constTransition M0.NSRebalance

-- * 'M0.Enclosure'

-- | Unconditionally transition 'M0.Enclosure' to 'M0_NC_TRANSIENT'.
enclosureTransient :: Transition M0.Enclosure
enclosureTransient = constTransition M0_NC_TRANSIENT

-- | Unconditionally transition 'M0.Enclosure' to 'M0_NC_ONLINE'.
enclosureOnline :: Transition M0.Enclosure
enclosureOnline = constTransition M0_NC_ONLINE

-- | Unconditionally transition 'M0.Enclosure' to 'M0_NC_TRANSIENT'
-- due to 'M0.Rack' state change.
rackCascadeEnclosure :: CascadeTransition M0.Rack M0.Enclosure
rackCascadeEnclosure _ = constTransition M0_NC_TRANSIENT

-- | Unconditionally transition 'M0.Rack' to 'M0_NC_TRANSIENT'
-- due to 'M0.Site' state change.
siteCascadeRack :: CascadeTransition M0.Site M0.Rack
siteCascadeRack _ = constTransition M0_NC_TRANSIENT

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

-- | Unconditionally transition 'M0.Disk' to 'M0.SDSOnline'.
diskOnline :: Transition M0.Disk
diskOnline = constTransition M0.SDSOnline

-- | Transition 'M0.Disk's to a rebalancing state, after repair has
-- finished.
diskRebalance :: (?loc :: CallStack) => Transition M0.Disk
diskRebalance = Transition $ \case
  st | toConfObjState (undefined :: M0.SDev) st == M0_NC_REPAIRED ->
         TransitionTo M0.SDSRebalancing
     | otherwise -> transitionErr ?loc st

-- | Transition 'M0.Disk's directly to a rebalancing state, after repair has
-- finished.
diskDiReb :: (?loc :: CallStack) => Transition M0.Disk
diskDiReb = Transition $ \case
  st | toConfObjState (undefined :: M0.SDev) st == M0_NC_ONLINE ->
         TransitionTo M0.SDSRebalancing
     | otherwise -> transitionErr ?loc st

-- | Unconditionally transiniot 'M0.Disk' to 'M0.SDSFailed'.
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

-- | Perform 'M0.sdsFailTransient' on the 'M0.SDev'.
sdevFailTransient :: Transition M0.SDev
sdevFailTransient = Transition $ TransitionTo . M0.sdsFailTransient

-- | Recover an 'M0.SDev' from a transient failure.
sdevRecoverTransient :: (?loc :: CallStack) => Transition M0.SDev
sdevRecoverTransient = Transition $ \case
  -- Make sure we start with transient on the outside.
  M0.SDSTransient st -> TransitionTo $ recover st
  st -> transitionErr ?loc st
  where
    -- Unwrap any layers of transient/inhibited we may have inside.
    recover (M0.SDSTransient st) = recover st
    recover (M0.SDSInhibited st) = M0.SDSInhibited $! recover st
    recover st = st

-- | Fail an 'M0.SDev'. Most of the time this will switch a device to
-- 'M0.SDSFailed', unless it is already on-going SNS. In cases where SNS
-- fails the state should be set back to 'M0.SDSFailed' through a direct
-- transition to rather than using this one.
sdevFailFailed :: Transition M0.SDev
sdevFailFailed = Transition $ TransitionTo . \case
  M0.SDSRepairing -> M0.SDSRepairing
  M0.SDSRepaired -> M0.SDSRepaired
  M0.SDSRebalancing -> M0.SDSRepaired
  _ -> M0.SDSFailed

-- | 'M0.Service' has changed state: if there are any 'M0.SDev's
-- associated with it, adjust accordingly.
--
-- Currently this only applies to IOS.
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

-- | 'M0.Node' state change so adjust 'M0.Controller' accordingly.
nodeCascadeController' :: CascadeTransition M0.Node M0.Controller
nodeCascadeController' M0.NSUnknown = Transition $ \_ -> NoTransition
nodeCascadeController' M0.NSOnline = constTransition M0.CSOnline
nodeCascadeController' _ = constTransition M0.CSTransient

-- | Set 'M0.Controller' to 'M0.CSTransient' as a result of a
-- 'M0.Service' state change.
iosFailsControllerTransient :: CascadeTransition M0.Service M0.Controller
iosFailsControllerTransient _ = constTransition M0.CSTransient

-- | Set 'M0.Controller' to 'M0.CSOnline' as a result of a
-- 'M0.Service' state change.
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

-- | Set 'M0.Controller' to 'M0.CSTransient' as a result of a
-- 'M0.Enclosure' state change.
enclosureCascadeControllerTransient :: CascadeTransition M0.Enclosure M0.Controller
enclosureCascadeControllerTransient _ = constTransition M0.CSTransient

-- | Set 'M0.Controller' to 'M0.CSOnline' as a result of a
-- 'M0.Enclosure' state change.
enclosureCascadeControllerOnline :: CascadeTransition M0.Enclosure M0.Controller
enclosureCascadeControllerOnline _ = constTransition M0.CSOnline
