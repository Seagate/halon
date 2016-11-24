{-# LANGUAGE LambdaCase #-}
-- |
-- Module    : HA.RecoveryCoordinator.Mero.Transitions
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Collection of all 'Transition's.
--
-- TODO: Nicer naming. More specific entry states (depending on
-- use-sites) and erroring (with loc?).
module HA.RecoveryCoordinator.Mero.Transitions
  ( module HA.RecoveryCoordinator.Mero.Transitions
  , HA.RecoveryCoordinator.Mero.Transitions.Internal.Transition
  ) where

import           HA.RecoveryCoordinator.Mero.Transitions.Internal
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note

-- * 'M0.Process'

-- | Fail a process with the given reason.
processFailed :: String -> Transition M0.Process
processFailed = constTransition . M0.PSFailed

processOnline :: Transition M0.Process
processOnline = constTransition M0.PSOnline

processStopping :: Transition M0.Process
processStopping = constTransition M0.PSStopping

processStarting :: Transition M0.Process
processStarting = constTransition M0.PSStarting

processOffline :: Transition M0.Process
processOffline = constTransition M0.PSOffline

processQuiescing :: Transition M0.Process
processQuiescing = constTransition M0.PSQuiescing

nodeFailsProcess :: StateCarrier M0.Node -> Transition M0.Process
nodeFailsProcess _ = Transition $ \case
  M0.PSFailed{} -> NoTransition
  M0.PSInhibited{} -> NoTransition
  x -> TransitionTo $ M0.PSInhibited x

nodeUnfailsProcess :: StateCarrier M0.Node -> Transition M0.Process
nodeUnfailsProcess _ = Transition uninhibit
  where
    uninhibit = \case
      M0.PSInhibited M0.PSOffline -> TransitionTo M0.PSOffline
      M0.PSInhibited M0.PSUnknown -> TransitionTo M0.PSUnknown
      M0.PSInhibited x@M0.PSInhibited{} -> uninhibit x
      M0.PSInhibited _ -> TransitionTo $ M0.PSFailed "node failure"
      _ -> NoTransition

-- * 'M0.Service'

serviceOnline :: Transition M0.Service
serviceOnline = constTransition M0.SSOnline

serviceOffline :: Transition M0.Service
serviceOffline = constTransition M0.SSOffline

processCascadeService :: StateCarrier M0.Process -> Transition M0.Service
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

rackCascadeEnclosure :: StateCarrier M0.Rack -> Transition M0.Enclosure
rackCascadeEnclosure _ = constTransition M0_NC_TRANSIENT

-- * 'M0.Pool'

poolRebalance :: Transition M0.Pool
poolRebalance = constTransition M0_NC_REBALANCE

poolRepairing :: Transition M0.Pool
poolRepairing = constTransition M0_NC_REPAIR

poolRepaired :: Transition M0.Pool
poolRepaired = constTransition M0_NC_REPAIRED

poolOnline :: Transition M0.Pool
poolOnline = constTransition M0_NC_ONLINE

-- * 'M0.Disk'

diskOnline :: Transition M0.Disk
diskOnline = constTransition M0.SDSOnline

diskRepaired :: Transition M0.Disk
diskRepaired = constTransition M0.SDSRepaired

diskRebalance :: Transition M0.Disk
diskRebalance = constTransition M0.SDSRebalancing

diskFailed :: Transition M0.Disk
diskFailed = constTransition M0.SDSFailed

sdevCascadeDisk' :: StateCarrier M0.SDev -> Transition M0.Disk
sdevCascadeDisk' _ = Transition $ \_ -> NoTransition

-- * 'M0.SDev'

sdevRepaired :: Transition M0.SDev
sdevRepaired = constTransition M0.SDSRepaired

sdevRepairing :: Transition M0.SDev
sdevRepairing = constTransition M0.SDSRepairing

sdevOnline :: Transition M0.SDev
sdevOnline = constTransition M0.SDSOnline

sdevFailed :: Transition M0.SDev
sdevFailed = constTransition M0.SDSFailed

sdevFailTransient :: Transition M0.SDev
sdevFailTransient = Transition $ TransitionTo . M0.sdsFailTransient

sdevRecoverTransient :: Transition M0.SDev
sdevRecoverTransient = Transition $ TransitionTo . M0.sdsRecoverTransient

sdevFailFailed :: Transition M0.SDev
sdevFailFailed = Transition $ TransitionTo . M0.sdsFailFailed

serviceCascadeDisk :: StateCarrier M0.Service -> Transition M0.SDev
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

diskCascadeSDev' :: StateCarrier M0.Disk -> Transition M0.SDev
diskCascadeSDev' _ = Transition $ \_ -> NoTransition

-- * 'M0.Controller'

nodeCascadeController' :: StateCarrier M0.Node -> Transition M0.Controller
nodeCascadeController' M0.NSUnknown = Transition $ \_ -> NoTransition
nodeCascadeController' M0.NSOnline = constTransition M0.CSOnline
nodeCascadeController' _ = constTransition M0.CSTransient

iosFailsControllerTransient :: StateCarrier M0.Service -> Transition M0.Controller
iosFailsControllerTransient _ = constTransition M0.CSTransient

iosFailsControllerOnline :: StateCarrier M0.Service -> Transition M0.Controller
iosFailsControllerOnline _ = constTransition M0.CSOnline

diskChangesPVer :: StateCarrier M0.Disk -> Transition M0.PVer
diskChangesPVer a = Transition $ \_ ->
  TransitionTo (toConfObjState (undefined :: M0.Disk) a)

enclosureCascadeControllerTransient :: StateCarrier M0.Enclosure
                                    -> Transition M0.Controller
enclosureCascadeControllerTransient _ = constTransition M0.CSTransient

enclosureCascadeControllerOnline :: StateCarrier M0.Enclosure
                                 -> Transition M0.Controller
enclosureCascadeControllerOnline _ = constTransition M0.CSOnline
