{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE StrictData             #-}
-- |
-- Module    : HA.Migrations.Teacake
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Teacake migration
module HA.Migrations.Teacake
  ( teacakeUpdate
  , teacakeMapRes
  , teacakeMapRel
  ) where

import           Control.Applicative ((<|>), Alternative(..))
import           Control.Distributed.Static
import           Data.Foldable (foldl')
import qualified Data.HashMap.Strict as M
import           Data.Maybe (listToMaybe)
import           Data.Proxy
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.UUID (UUID)
import           GHC.TypeLits
import qualified HA.ResourceGraph as G
import qualified HA.ResourceGraph.UGraph as U
import qualified HA.Resources as R
import qualified HA.Resources.Castor as Castor
import qualified HA.Resources.Castor.Initial as CastorInitial
import qualified HA.Resources.Castor.Old as CastorOld
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as Note
import qualified HA.Resources.RC as RC
import qualified HA.Service as S
import qualified HA.Services.DecisionLog.Types as DLog
import qualified HA.Services.Mero.RC.Resources as M0
import qualified HA.Services.Mero.Types as M0
import qualified HA.Services.SSPL.LL.Resources as SSPL

teacakeUpdate :: U.UGraph -> U.UGraph
teacakeUpdate rg =
  let storeDevs :: Set.Set (Maybe Castor.Enclosure, CastorOld.StorageDevice)
      storeDevs = Set.fromList $
        [ (Nothing, s) | h :: Castor.Host <- U.connectedTo R.Cluster R.Has rg
                       , s <- U.connectedTo h R.Has rg ]
        ++
        [ (Just enc, s) | r :: Castor.Rack <- U.connectedTo R.Cluster R.Has rg
                        , enc :: Castor.Enclosure <- U.connectedTo r R.Has rg
                        , s <- U.connectedTo enc R.Has rg ]
      stIds :: Set.Set OldStorageDevice
      stIds = Set.map (\(e, s) -> OldStorageDevice e s (ids s) (attrs s)) storeDevs
        where
          attrs s = Set.fromList $ U.connectedTo s R.Has rg
          ids s = Set.fromList $ U.connectedTo s R.Has rg ++ U.connectedTo s Castor.Is rg

      -- Apply updates resulting from old storage devs
      throughStoreDevs :: OldStorageDevice -> U.UGraph -> U.UGraph
      throughStoreDevs osd =

        let exInfo (CastorOld.DIPath v) = \x ->
              x { _nsd_ids = Set.insert (Castor.DIPath $ T.pack v) (_nsd_ids x) }
            exInfo (CastorOld.DIIndexInEnclosure v) = \x ->
              x { _nsd_slot = _nsd_slot x <|> maybe Nothing (\e -> Just $! Castor.Slot e v) (_osd_enclosure osd) }
            exInfo (CastorOld.DIWWN v) = \x ->
              x { _nsd_ids = Set.insert (Castor.DIWWN $ T.pack v) (_nsd_ids x) }
            exInfo (CastorOld.DIUUID v) = \x ->
              x { _nsd_ids = Set.insert (Castor.DIUUID $ T.pack v) (_nsd_ids x) }
            exInfo (CastorOld.DISerialNumber v) = \x ->
              x { _nsd_dev = _nsd_dev x <|> pure (Castor.StorageDevice $ T.pack v) }
            exInfo (CastorOld.DIRaidIdx v) = \x ->
              x { _nsd_ids = Set.insert (Castor.DIRaidIdx v) (_nsd_ids x) }
            exInfo (CastorOld.DIRaidDevice v) = \x ->
              x { _nsd_ids = Set.insert (Castor.DIRaidDevice $ T.pack v) (_nsd_ids x) }

            exAttr (CastorOld.SDResetAttempts v) = \x ->
              x { _nsd_attrs = Set.insert (Castor.SDResetAttempts v) (_nsd_attrs x) }
            exAttr (CastorOld.SDPowered v) = \x ->
              x { _nsd_attrs = Set.insert (Castor.SDPowered v) (_nsd_attrs x) }
            exAttr CastorOld.SDOnGoingReset = \x ->
              x { _nsd_attrs = Set.insert Castor.SDOnGoingReset (_nsd_attrs x) }
            exAttr CastorOld.SDRemovedAt = \x -> x { _nsd_removed = True }
            exAttr CastorOld.SDReplaced = \x -> x { _nsd_replaced = True }
            exAttr CastorOld.SDRemovedFromRAID = \x ->
              x { _nsd_attrs = Set.insert Castor.SDRemovedFromRAID (_nsd_attrs x) }

            extractedState :: NewStorageDevice (Maybe Castor.StorageDevice)
            extractedState =
                 (\acc -> foldl' (flip exAttr) acc (_osd_attrs osd))
               $ foldl' (flip exInfo) (defaultNewStorageDevice (_osd_sdev osd)) (_osd_ids osd)
        in case _nsd_dev extractedState of
          Just sdev -> writeNewStorageDevice (extractedState { _nsd_dev = sdev })
          Nothing -> id
  in foldl' (flip throughStoreDevs) rg stIds

data OldStorageDevice = OldStorageDevice
  { _osd_enclosure :: !(Maybe Castor.Enclosure)
  , _osd_sdev :: !CastorOld.StorageDevice
  , _osd_ids :: !(Set.Set CastorOld.DeviceIdentifier)
  , _osd_attrs :: !(Set.Set CastorOld.StorageDeviceAttr)
  } deriving (Show, Eq, Ord)

data NewStorageDevice dev = NewStorageDevice
  { -- | If the device is in a 'Castor.Slot', which one? If none, it's
    -- attached to 'R.Cluster' only.
    _nsd_slot :: !(Maybe Castor.Slot)
  , _nsd_dev :: !dev
  , _nsd_ids :: !(Set.Set Castor.DeviceIdentifier)
  , _nsd_oldDev :: !CastorOld.StorageDevice
  , _nsd_disk :: !(Maybe M0.Disk)
  , _nsd_replaced :: !Bool
  , _nsd_attrs :: !(Set.Set Castor.StorageDeviceAttr)
  , _nsd_removed :: !Bool
  } deriving (Show, Eq, Ord)

defaultNewStorageDevice :: Alternative m
                        => CastorOld.StorageDevice
                        -> NewStorageDevice (m Castor.StorageDevice)
defaultNewStorageDevice oldDev = NewStorageDevice
  { _nsd_slot = Nothing
  , _nsd_dev = empty
  , _nsd_ids = mempty
  , _nsd_oldDev = oldDev
  , _nsd_disk = Nothing
  , _nsd_replaced = False
  , _nsd_attrs = mempty
  , _nsd_removed = False
  }

writeNewStorageDevice :: NewStorageDevice Castor.StorageDevice
                      -> U.UGraph -> U.UGraph
writeNewStorageDevice NewStorageDevice{..} =
    connectCluster
  . connectSlot
  . connectIdentifiers
  . connectAttributes
  . collapseStorageDeviceStatus
  where
    -- All StorageDevices should be connected to Cluster element so
    -- even if we're temporarily removing them in hardware, we still
    -- can keep information about them.
    connectCluster = U.connect R.Cluster R.Has _nsd_dev

    -- Connect Slot out of inferred information. If the Disk is marked
    -- as replaced, give it the Replaced marker and do nothing else.
    -- If not, it must be in a Slot. Make the connection between the
    -- Slot and Enclosure, SDev, StorageDevice and LedControlState.
    connectSlot rg = maybe rg withSlot _nsd_slot
      where
        withSlot slot =
            U.connect (Castor.slotEnclosure slot) R.Has slot
          . connectStorageDevice
          . connectDisk
          . connectLed
          $ rg
          where
            -- Connect StorageDevice to slot unless it was marked as removed.
            connectStorageDevice rg'
              | not _nsd_removed = U.connect _nsd_dev R.Has slot rg'
              | otherwise = rg'

            -- If the StorageDevice has been marked as replaced
            -- through an identifier in the past, mark relevant Disk
            -- as Replaced.
            maybeMarkReplaced disk rg'
              | _nsd_replaced = U.connect disk Castor.Is M0.Replaced rg'
              | otherwise = rg'

            -- Connect SDev to Slot and mark associated Disk as
            -- Replaced if needed.
            connectDisk :: U.UGraph -> U.UGraph
            connectDisk rg' = maybe rg'
              (\disk -> let msdev :: Maybe M0.SDev
                            msdev = listToMaybe $ U.connectedFrom M0.IsOnHardware disk rg'
                        in maybeMarkReplaced disk
                           . U.connect disk M0.At _nsd_dev
                           $ maybe rg' (\sdev -> U.connect sdev M0.At slot rg') msdev
              ) _nsd_disk

            -- Led states are now connected to the slots directly
            -- rather that to drives.
            connectLed rg' = maybe rg' (\(led :: SSPL.LedControlState) -> U.connect slot R.Has led rg')
                                       (listToMaybe $ U.connectedTo _nsd_oldDev R.Has rg')

    -- Connect every device identifier to the new StorageDevice
    connectIdentifiers rg =
      foldl' (\g0 i -> U.connect _nsd_dev R.Has i g0) rg _nsd_ids

    -- Attach the update device to all the new attributes.
    connectAttributes rg =
      foldl' (\g0 attr -> U.connect _nsd_dev R.Has attr g0) rg _nsd_attrs

    -- Find all StorageDeviceStatus that exists in the old graph for
    -- the device and pick the first one as the authoritative one.
    collapseStorageDeviceStatus :: U.UGraph -> U.UGraph
    collapseStorageDeviceStatus rg =
      let oldStatus :: Maybe Castor.StorageDeviceStatus
          oldStatus = listToMaybe $ U.connectedTo _nsd_oldDev R.Has rg
                                 ++ U.connectedTo _nsd_oldDev Castor.Is rg
      in maybe rg (\st -> U.connect _nsd_dev Castor.Is st rg) oldStatus

teacakeMapRes :: G.UpgradeMap UUID
teacakeMapRes = M.fromList
  [ mkEntry (Proxy :: Proxy "HA.Resources.Castor.Initial.resourceDict_FailureSetScheme")
  , mkEntry (Proxy :: Proxy "HA.Resources.Castor.resourceDict_BMC")
  , mkEntry (Proxy :: Proxy "HA.Resources.Castor.resourceDict_DeviceIdentifier")
  , mkEntry (Proxy :: Proxy "HA.Resources.Castor.resourceDict_Enclosure")
  , mkEntry (Proxy :: Proxy "HA.Resources.Castor.resourceDict_HalonVars")
  , mkEntry (Proxy :: Proxy "HA.Resources.Castor.resourceDict_Host")
  , mkEntry (Proxy :: Proxy "HA.Resources.Castor.resourceDict_HostAttr")
  , mkEntry (Proxy :: Proxy "HA.Resources.Castor.resourceDict_Rack")
  , mkEntry (Proxy :: Proxy "HA.Resources.Castor.resourceDict_ReassemblingRaid")
  , mkEntry (Proxy :: Proxy "HA.Resources.Castor.resourceDict_StorageDevice")
  , mkEntry (Proxy :: Proxy "HA.Resources.Castor.resourceDict_StorageDeviceAttr")
  , mkEntry (Proxy :: Proxy "HA.Resources.Castor.resourceDict_StorageDeviceStatus")
  , mkEntry (Proxy :: Proxy "HA.Resources.Castor.resourceDict_UUID")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.Note.resourceDict_ConfObjectState")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.Note.resourceDict_PrincipalRM")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_BootLevel")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_ConfUpdateVersion")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_Controller")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_ControllerState")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_ControllerV")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_Disk")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_DiskFailureVector")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_DiskV")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_Disposition")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_Enclosure")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_EnclosureV")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_FidSeq")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_Filesystem")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_FilesystemStats")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_LNid")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_M0Globals")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_Node")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_NodeState")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_PID")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_PVer")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_PVerCounter")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_Pool")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_PoolRepairStatus")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_Process")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_ProcessBootstrapped")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_ProcessEnv")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_ProcessLabel")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_ProcessState")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_Profile")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_Rack")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_RackV")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_Root")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_RunLevel")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_SDev")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_SDevState")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_Service")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_ServiceState")
  , mkEntry (Proxy :: Proxy "HA.Resources.Mero.resourceDict_StopLevel")
  , mkEntry (Proxy :: Proxy "HA.Resources.RC.resourceDict_Active")
  , mkEntry (Proxy :: Proxy "HA.Resources.RC.resourceDict_IsSubscriber")
  , mkEntry (Proxy :: Proxy "HA.Resources.RC.resourceDict_RC")
  , mkEntry (Proxy :: Proxy "HA.Resources.RC.resourceDict_Stopping")
  , mkEntry (Proxy :: Proxy "HA.Resources.RC.resourceDict_SubProcessId ")
  , mkEntry (Proxy :: Proxy "HA.Resources.RC.resourceDict_SubscribedTo")
  , mkEntry (Proxy :: Proxy "HA.Resources.RC.resourceDict_Subscriber")
  , mkEntry (Proxy :: Proxy "HA.Resources.resourceDict_Cluster")
  , mkEntry (Proxy :: Proxy "HA.Resources.resourceDict_EpochId")
  , mkEntry (Proxy :: Proxy "HA.Resources.resourceDict_Node")
  , mkEntry (Proxy :: Proxy "HA.Service.Internal.resourceDict_ServiceInfoMsg")
  , mkEntry (Proxy :: Proxy "HA.Services.DecisionLog.Types.resourceDictService")
  , mkEntry (Proxy :: Proxy "HA.Services.Mero.RC.Resources.resourceDict_DeliveredTo")
  , mkEntry (Proxy :: Proxy "HA.Services.Mero.RC.Resources.resourceDict_DeliveryFailedTo")
  , mkEntry (Proxy :: Proxy "HA.Services.Mero.RC.Resources.resourceDict_ShouldDeliverTo")
  , mkEntry (Proxy :: Proxy "HA.Services.Mero.RC.Resources.resourceDict_StateDiff")
  , mkEntry (Proxy :: Proxy "HA.Services.Mero.RC.Resources.resourceDict_StateDiffIndex")
  , mkEntry (Proxy :: Proxy "HA.Services.Mero.Types.resourceDictService")
  , mkEntry (Proxy :: Proxy "HA.Services.SSPL.LL.Resources.resourceDictService")
  ]

teacakeMapRel :: G.UpgradeMap (UUID, UUID, UUID)
teacakeMapRel = M.fromList
  [ mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictCluster_Has_HalonVars")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictCluster_Has_Host")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictCluster_Has_Rack")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictEnclosure_Has_BMC")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictEnclosure_Has_Host")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictEnclosure_Has_StorageDevice")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictHost_Has_HostAttr")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictHost_Has_StorageDevice")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictHost_Has_UUID")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictHost_Is_ReassemblingRaid")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictHost_Runs_Node")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictRack_Has_Enclosure")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictStorageDevice_Has_DeviceIdentifier")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictStorageDevice_Has_StorageDeviceAttr")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictStorageDevice_Has_StorageDeviceStatus")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictStorageDevice_Is_StorageDeviceStatus")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Castor.relationDictStorageDevice_ReplacedBy_StorageDevice")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.Note.relationDictCluster_Has_PrincipalRM")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.Note.relationDictController_Is_ConfObjectState")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.Note.relationDictEnclosure_Is_ConfObjectState")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.Note.relationDictPVer_Is_ConfObjectState")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.Note.relationDictPool_Is_ConfObjectState")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.Note.relationDictRack_Is_ConfObjectState")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.Note.relationDictService_Is_PrincipalRM")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictCluster_Has_ConfUpdateVersion")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictCluster_Has_Disposition")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictCluster_Has_FidSeq")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictCluster_Has_M0Globals")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictCluster_Has_PVerCounter")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictCluster_Has_Profile")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictCluster_Has_Root")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictCluster_RunLevel_BootLevel")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictCluster_StopLevel_BootLevel")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictControllerV_IsParentOf_DiskV")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictController_At_Host")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictController_IsParentOf_Disk")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictController_IsRealOf_ControllerV")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictController_Is_ControllerState")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictDisk_At_StorageDevice")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictDisk_IsRealOf_DiskV")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictEnclosureV_IsParentOf_ControllerV")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictEnclosure_At_Enclosure")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictEnclosure_IsParentOf_Controller")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictEnclosure_IsRealOf_EnclosureV")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictFilesystem_Has_FilesystemStats")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictFilesystem_IsParentOf_Node")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictFilesystem_IsParentOf_Pool")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictFilesystem_IsParentOf_Rack")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictHost_Has_LNid")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictHost_Runs_Node")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictNode_IsOnHardware_Controller")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictNode_IsParentOf_Process")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictNode_Is_NodeState")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictPVer_IsParentOf_RackV")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictPool_Has_DiskFailureVector")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictPool_Has_PoolRepairStatus")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictPool_IsRealOf_PVer")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictProcess_Has_PID")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictProcess_Has_ProcessLabel")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictProcess_IsParentOf_Service")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictProcess_Is_ProcessBootstrapped")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictProcess_Is_ProcessState")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictProfile_IsParentOf_Filesystem")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictRackV_IsParentOf_EnclosureV")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictRack_At_Rack")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictRack_IsParentOf_Enclosure")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictRack_IsRealOf_RackV")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictRoot_IsParentOf_Profile")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictSDev_IsOnHardware_Disk")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictSDev_Is_SDevState")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictService_IsParentOf_SDev")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.Mero.relationDictService_Is_ServiceState")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.RC.relationDictCluster_Has_RC")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.RC.relationDictNode_Stopping_ServiceInfoMsg")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.RC.relationDictRC_Is_Active")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.RC.relationDictSubProcessId_IsSubscriber_Subscriber")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.RC.relationDictSubscriber_SubscribedTo_RC")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.relationDictCluster_Has_EpochId")
  , mkEntryRel (Proxy :: Proxy "HA.Resources.relationDictCluster_Has_Node")
  , mkEntryRel (Proxy :: Proxy "HA.Service.Internal.relationDictNode_Has_ServiceInfoMsg")
  , mkEntryRel (Proxy :: Proxy "HA.Services.DecisionLog.Types.relationDictSupportsClusterService")
  , mkEntryRel (Proxy :: Proxy "HA.Services.Mero.RC.Resources.relationDictRC_Has_StateDiff")
  , mkEntryRel (Proxy :: Proxy "HA.Services.Mero.RC.Resources.relationDictStateDiffIndex_Is_StateDiff")
  , mkEntryRel (Proxy :: Proxy "HA.Services.Mero.RC.Resources.relationDictStateDiff_DeliveredTo_Process")
  , mkEntryRel (Proxy :: Proxy "HA.Services.Mero.RC.Resources.relationDictStateDiff_DeliveryFailedTo_Process")
  , mkEntryRel (Proxy :: Proxy "HA.Services.Mero.RC.Resources.relationDictStateDiff_ShouldDeliverTo_Process")
  , mkEntryRel (Proxy :: Proxy "HA.Services.Mero.Types.relationDictSupportsClusterService")
  , mkEntryRel (Proxy :: Proxy "HA.Services.SSPL.LL.Resources.relationDictSupportsClusterService")
  ]


-- | Teacake-exclusive migration helper. The problem is that in
-- teacake, resources do not carry all the required information that's
-- necessary to resolve them into 'StorageResource'. We do however
-- have these instances for all modern-day resources. To obtain these
-- instances from 'RemoteTable', we need the 'StorageIndex' of the
-- resource. With this typeclass, we create a mapping from the name of
-- teacake resources to the UUID which we can then in turn use to find
-- the instances we need. There are a few cases to think about:
--
-- * For teacake types we do not want to read in, we simply do not
--   provide a mapping. We'll get a warning and resource will be discarded.
--
-- * For types that we want to read in but don't have equivalent in
--   modern-day resources (i.e. types which don't automatically
--   migrate through SafeCopy and need extra work) we create versions
--   of those types in some @.Old@ modules, assign 'StorageIndex' to
--   them and read them in that way for the duration of the migration.
--
-- After teacake migration is complete and no longer necessary, remove
-- this typeclass.
class (KnownSymbol s, G.StorageIndex r) => FromTeacake s r | s -> r where
  mkEntry :: proxy s -> (G.SomeStatic, UUID)
  mkEntry p = (G.SomeStatic st, G.typeKey (Proxy :: Proxy r))
    where
     st :: Static r
     st = staticApply (staticLabel "HA.ResourceGraph.someResourceDict")
                      (staticLabel $ symbolVal p)

class (KnownSymbol s, G.StorageIndex r, G.StorageIndex a, G.StorageIndex b) =>
    FromTeacakeRel s a r b | s -> r, s -> a, s -> b where
  mkEntryRel :: proxy s -> (G.SomeStatic, (UUID, UUID, UUID))
  mkEntryRel p = (G.SomeStatic st,
                  (G.typeKey (Proxy :: Proxy r), G.typeKey (Proxy :: Proxy a), G.typeKey (Proxy :: Proxy b)))
    where
     st :: Static r
     st = staticApply (staticLabel "HA.ResourceGraph.someRelationDict")
                      (staticLabel $ symbolVal p)

instance FromTeacake "HA.Resources.Castor.Initial.resourceDict_FailureSetScheme" CastorInitial.FailureSetScheme
instance FromTeacake "HA.Resources.Castor.resourceDict_BMC" CastorInitial.BMC
instance FromTeacake "HA.Resources.Castor.resourceDict_DeviceIdentifier" CastorOld.DeviceIdentifier
instance FromTeacake "HA.Resources.Castor.resourceDict_Enclosure" Castor.Enclosure
instance FromTeacake "HA.Resources.Castor.resourceDict_HalonVars" Castor.HalonVars
instance FromTeacake "HA.Resources.Castor.resourceDict_Host" Castor.Host
instance FromTeacake "HA.Resources.Castor.resourceDict_HostAttr" Castor.HostAttr
instance FromTeacake "HA.Resources.Castor.resourceDict_Rack" Castor.Rack
instance FromTeacake "HA.Resources.Castor.resourceDict_ReassemblingRaid" Castor.ReassemblingRaid
instance FromTeacake "HA.Resources.Castor.resourceDict_StorageDevice" CastorOld.StorageDevice
instance FromTeacake "HA.Resources.Castor.resourceDict_StorageDeviceAttr" CastorOld.StorageDeviceAttr
instance FromTeacake "HA.Resources.Castor.resourceDict_StorageDeviceStatus" Castor.StorageDeviceStatus
instance FromTeacake "HA.Resources.Castor.resourceDict_UUID" UUID
instance FromTeacake "HA.Resources.Mero.Note.resourceDict_ConfObjectState" Note.ConfObjectState
instance FromTeacake "HA.Resources.Mero.Note.resourceDict_PrincipalRM" Note.PrincipalRM
instance FromTeacake "HA.Resources.Mero.resourceDict_BootLevel" M0.BootLevel
instance FromTeacake "HA.Resources.Mero.resourceDict_ConfUpdateVersion" M0.ConfUpdateVersion
instance FromTeacake "HA.Resources.Mero.resourceDict_Controller" M0.Controller
instance FromTeacake "HA.Resources.Mero.resourceDict_ControllerState" M0.ControllerState
instance FromTeacake "HA.Resources.Mero.resourceDict_ControllerV" M0.ControllerV
instance FromTeacake "HA.Resources.Mero.resourceDict_Disk" M0.Disk
instance FromTeacake "HA.Resources.Mero.resourceDict_DiskFailureVector" M0.DiskFailureVector
instance FromTeacake "HA.Resources.Mero.resourceDict_DiskV" M0.DiskV
instance FromTeacake "HA.Resources.Mero.resourceDict_Disposition" M0.Disposition
instance FromTeacake "HA.Resources.Mero.resourceDict_Enclosure" M0.Enclosure
instance FromTeacake "HA.Resources.Mero.resourceDict_EnclosureV" M0.EnclosureV
instance FromTeacake "HA.Resources.Mero.resourceDict_FidSeq" M0.FidSeq
instance FromTeacake "HA.Resources.Mero.resourceDict_Filesystem" M0.Filesystem
instance FromTeacake "HA.Resources.Mero.resourceDict_FilesystemStats" M0.FilesystemStats
instance FromTeacake "HA.Resources.Mero.resourceDict_LNid" M0.LNid
instance FromTeacake "HA.Resources.Mero.resourceDict_M0Globals" CastorInitial.M0Globals
instance FromTeacake "HA.Resources.Mero.resourceDict_Node" M0.Node
instance FromTeacake "HA.Resources.Mero.resourceDict_NodeState" M0.NodeState
instance FromTeacake "HA.Resources.Mero.resourceDict_PID" M0.PID
instance FromTeacake "HA.Resources.Mero.resourceDict_PVer" M0.PVer
instance FromTeacake "HA.Resources.Mero.resourceDict_PVerCounter" M0.PVerCounter
instance FromTeacake "HA.Resources.Mero.resourceDict_Pool" M0.Pool
instance FromTeacake "HA.Resources.Mero.resourceDict_PoolRepairStatus" M0.PoolRepairStatus
instance FromTeacake "HA.Resources.Mero.resourceDict_Process" M0.Process
instance FromTeacake "HA.Resources.Mero.resourceDict_ProcessBootstrapped" M0.ProcessBootstrapped
instance FromTeacake "HA.Resources.Mero.resourceDict_ProcessEnv" M0.ProcessEnv
instance FromTeacake "HA.Resources.Mero.resourceDict_ProcessLabel" M0.ProcessLabel
instance FromTeacake "HA.Resources.Mero.resourceDict_ProcessState" M0.ProcessState
instance FromTeacake "HA.Resources.Mero.resourceDict_Profile" M0.Profile
instance FromTeacake "HA.Resources.Mero.resourceDict_Rack" M0.Rack
instance FromTeacake "HA.Resources.Mero.resourceDict_RackV" M0.RackV
instance FromTeacake "HA.Resources.Mero.resourceDict_Root" M0.Root
instance FromTeacake "HA.Resources.Mero.resourceDict_RunLevel" M0.RunLevel
instance FromTeacake "HA.Resources.Mero.resourceDict_SDev" M0.SDev
instance FromTeacake "HA.Resources.Mero.resourceDict_SDevState" M0.SDevState
instance FromTeacake "HA.Resources.Mero.resourceDict_Service" M0.Service
instance FromTeacake "HA.Resources.Mero.resourceDict_ServiceState" M0.ServiceState
instance FromTeacake "HA.Resources.Mero.resourceDict_StopLevel" M0.StopLevel
instance FromTeacake "HA.Resources.RC.resourceDict_Active" RC.Active
instance FromTeacake "HA.Resources.RC.resourceDict_IsSubscriber" RC.IsSubscriber
instance FromTeacake "HA.Resources.RC.resourceDict_RC" RC.RC
instance FromTeacake "HA.Resources.RC.resourceDict_Stopping" RC.Stopping
instance FromTeacake "HA.Resources.RC.resourceDict_SubProcessId " RC.SubProcessId
instance FromTeacake "HA.Resources.RC.resourceDict_SubscribedTo" RC.SubscribedTo
instance FromTeacake "HA.Resources.RC.resourceDict_Subscriber" RC.Subscriber
instance FromTeacake "HA.Resources.resourceDict_Cluster" R.Cluster
instance FromTeacake "HA.Resources.resourceDict_EpochId" R.EpochId
instance FromTeacake "HA.Resources.resourceDict_Node" R.Node
instance FromTeacake "HA.Service.Internal.resourceDict_ServiceInfoMsg" S.ServiceInfoMsg
instance FromTeacake "HA.Services.DecisionLog.Types.resourceDictService" (S.Service DLog.DecisionLogConf)
instance FromTeacake "HA.Services.Mero.RC.Resources.resourceDict_DeliveredTo" M0.DeliveredTo
instance FromTeacake "HA.Services.Mero.RC.Resources.resourceDict_DeliveryFailedTo" M0.DeliveryFailedTo
instance FromTeacake "HA.Services.Mero.RC.Resources.resourceDict_ShouldDeliverTo" M0.ShouldDeliverTo
instance FromTeacake "HA.Services.Mero.RC.Resources.resourceDict_StateDiff" M0.StateDiff
instance FromTeacake "HA.Services.Mero.RC.Resources.resourceDict_StateDiffIndex" M0.StateDiffIndex
instance FromTeacake "HA.Services.Mero.Types.resourceDictService" (S.Service M0.MeroConf)
instance FromTeacake "HA.Services.SSPL.LL.Resources.resourceDictService" (S.Service SSPL.SSPLConf)

instance FromTeacakeRel "HA.Resources.Castor.relationDictCluster_Has_HalonVars" R.Cluster R.Has Castor.HalonVars
instance FromTeacakeRel "HA.Resources.Castor.relationDictCluster_Has_Host" R.Cluster R.Has Castor.Host
instance FromTeacakeRel "HA.Resources.Castor.relationDictCluster_Has_Rack" R.Cluster R.Has Castor.Rack
instance FromTeacakeRel "HA.Resources.Castor.relationDictEnclosure_Has_BMC" Castor.Enclosure R.Has CastorInitial.BMC
instance FromTeacakeRel "HA.Resources.Castor.relationDictEnclosure_Has_Host" Castor.Enclosure R.Has Castor.Host
instance FromTeacakeRel "HA.Resources.Castor.relationDictEnclosure_Has_StorageDevice" Castor.Enclosure R.Has CastorOld.StorageDevice
instance FromTeacakeRel "HA.Resources.Castor.relationDictHost_Has_HostAttr" Castor.Host R.Has Castor.HostAttr
instance FromTeacakeRel "HA.Resources.Castor.relationDictHost_Has_StorageDevice" Castor.Host R.Has CastorOld.StorageDevice
instance FromTeacakeRel "HA.Resources.Castor.relationDictHost_Has_UUID" Castor.Host R.Has UUID
instance FromTeacakeRel "HA.Resources.Castor.relationDictHost_Is_ReassemblingRaid" Castor.Host Castor.Is Castor.ReassemblingRaid
instance FromTeacakeRel "HA.Resources.Castor.relationDictHost_Runs_Node" Castor.Host R.Runs R.Node
instance FromTeacakeRel "HA.Resources.Castor.relationDictRack_Has_Enclosure" Castor.Rack R.Has Castor.Enclosure
instance FromTeacakeRel "HA.Resources.Castor.relationDictStorageDevice_Has_DeviceIdentifier" CastorOld.StorageDevice R.Has CastorOld.DeviceIdentifier
instance FromTeacakeRel "HA.Resources.Castor.relationDictStorageDevice_Has_StorageDeviceAttr" CastorOld.StorageDevice R.Has CastorOld.StorageDeviceAttr
instance FromTeacakeRel "HA.Resources.Castor.relationDictStorageDevice_Has_StorageDeviceStatus" CastorOld.StorageDevice R.Has Castor.StorageDeviceStatus
instance FromTeacakeRel "HA.Resources.Castor.relationDictStorageDevice_Is_StorageDeviceStatus" CastorOld.StorageDevice Castor.Is Castor.StorageDeviceStatus
instance FromTeacakeRel "HA.Resources.Castor.relationDictStorageDevice_ReplacedBy_StorageDevice" CastorOld.StorageDevice Castor.ReplacedBy CastorOld.StorageDevice
instance FromTeacakeRel "HA.Resources.Mero.Note.relationDictCluster_Has_PrincipalRM" R.Cluster R.Has Note.PrincipalRM
instance FromTeacakeRel "HA.Resources.Mero.Note.relationDictController_Is_ConfObjectState" M0.Controller Castor.Is Note.ConfObjectState
instance FromTeacakeRel "HA.Resources.Mero.Note.relationDictEnclosure_Is_ConfObjectState" M0.Enclosure Castor.Is Note.ConfObjectState
instance FromTeacakeRel "HA.Resources.Mero.Note.relationDictPVer_Is_ConfObjectState" M0.PVer Castor.Is Note.ConfObjectState
instance FromTeacakeRel "HA.Resources.Mero.Note.relationDictPool_Is_ConfObjectState" M0.Pool Castor.Is Note.ConfObjectState
instance FromTeacakeRel "HA.Resources.Mero.Note.relationDictRack_Is_ConfObjectState" M0.Rack Castor.Is Note.ConfObjectState
instance FromTeacakeRel "HA.Resources.Mero.Note.relationDictService_Is_PrincipalRM" M0.Service Castor.Is Note.PrincipalRM
instance FromTeacakeRel "HA.Resources.Mero.relationDictCluster_Has_ConfUpdateVersion" R.Cluster R.Has M0.ConfUpdateVersion
instance FromTeacakeRel "HA.Resources.Mero.relationDictCluster_Has_Disposition" R.Cluster R.Has M0.Disposition
instance FromTeacakeRel "HA.Resources.Mero.relationDictCluster_Has_FidSeq" R.Cluster R.Has M0.FidSeq
instance FromTeacakeRel "HA.Resources.Mero.relationDictCluster_Has_M0Globals" R.Cluster R.Has CastorInitial.M0Globals
instance FromTeacakeRel "HA.Resources.Mero.relationDictCluster_Has_PVerCounter" R.Cluster R.Has M0.PVerCounter
instance FromTeacakeRel "HA.Resources.Mero.relationDictCluster_Has_Profile" R.Cluster R.Has M0.Profile
instance FromTeacakeRel "HA.Resources.Mero.relationDictCluster_Has_Root" R.Cluster R.Has M0.Root
instance FromTeacakeRel "HA.Resources.Mero.relationDictCluster_RunLevel_BootLevel" R.Cluster M0.RunLevel M0.BootLevel
instance FromTeacakeRel "HA.Resources.Mero.relationDictCluster_StopLevel_BootLevel" R.Cluster M0.StopLevel M0.BootLevel
instance FromTeacakeRel "HA.Resources.Mero.relationDictControllerV_IsParentOf_DiskV" M0.ControllerV M0.IsParentOf M0.DiskV
instance FromTeacakeRel "HA.Resources.Mero.relationDictController_At_Host" M0.Controller M0.At Castor.Host
instance FromTeacakeRel "HA.Resources.Mero.relationDictController_IsParentOf_Disk" M0.Controller M0.IsParentOf M0.Disk
instance FromTeacakeRel "HA.Resources.Mero.relationDictController_IsRealOf_ControllerV" M0.Controller M0.IsRealOf M0.ControllerV
instance FromTeacakeRel "HA.Resources.Mero.relationDictController_Is_ControllerState" M0.Controller Castor.Is M0.ControllerState
instance FromTeacakeRel "HA.Resources.Mero.relationDictDisk_At_StorageDevice" M0.Disk M0.At CastorOld.StorageDevice
instance FromTeacakeRel "HA.Resources.Mero.relationDictDisk_IsRealOf_DiskV" M0.Disk M0.IsRealOf M0.DiskV
instance FromTeacakeRel "HA.Resources.Mero.relationDictEnclosureV_IsParentOf_ControllerV" M0.EnclosureV M0.IsParentOf M0.ControllerV
instance FromTeacakeRel "HA.Resources.Mero.relationDictEnclosure_At_Enclosure" M0.Enclosure M0.At Castor.Enclosure
instance FromTeacakeRel "HA.Resources.Mero.relationDictEnclosure_IsParentOf_Controller" M0.Enclosure M0.IsParentOf M0.Controller
instance FromTeacakeRel "HA.Resources.Mero.relationDictEnclosure_IsRealOf_EnclosureV" M0.Enclosure M0.IsRealOf M0.EnclosureV
instance FromTeacakeRel "HA.Resources.Mero.relationDictFilesystem_Has_FilesystemStats" M0.Filesystem R.Has M0.FilesystemStats
instance FromTeacakeRel "HA.Resources.Mero.relationDictFilesystem_IsParentOf_Node" M0.Filesystem M0.IsParentOf M0.Node
instance FromTeacakeRel "HA.Resources.Mero.relationDictFilesystem_IsParentOf_Pool" M0.Filesystem M0.IsParentOf M0.Pool
instance FromTeacakeRel "HA.Resources.Mero.relationDictFilesystem_IsParentOf_Rack" M0.Filesystem M0.IsParentOf M0.Rack
instance FromTeacakeRel "HA.Resources.Mero.relationDictHost_Has_LNid" Castor.Host R.Has M0.LNid
instance FromTeacakeRel "HA.Resources.Mero.relationDictHost_Runs_Node" Castor.Host R.Runs M0.Node
instance FromTeacakeRel "HA.Resources.Mero.relationDictNode_IsOnHardware_Controller" M0.Node M0.IsOnHardware M0.Controller
instance FromTeacakeRel "HA.Resources.Mero.relationDictNode_IsParentOf_Process" M0.Node M0.IsParentOf M0.Process
instance FromTeacakeRel "HA.Resources.Mero.relationDictNode_Is_NodeState" M0.Node Castor.Is M0.NodeState
instance FromTeacakeRel "HA.Resources.Mero.relationDictPVer_IsParentOf_RackV" M0.PVer M0.IsParentOf M0.RackV
instance FromTeacakeRel "HA.Resources.Mero.relationDictPool_Has_DiskFailureVector" M0.Pool R.Has M0.DiskFailureVector
instance FromTeacakeRel "HA.Resources.Mero.relationDictPool_Has_PoolRepairStatus" M0.Pool R.Has M0.PoolRepairStatus
instance FromTeacakeRel "HA.Resources.Mero.relationDictPool_IsRealOf_PVer" M0.Pool M0.IsRealOf M0.PVer
instance FromTeacakeRel "HA.Resources.Mero.relationDictProcess_Has_PID" M0.Process R.Has M0.PID
instance FromTeacakeRel "HA.Resources.Mero.relationDictProcess_Has_ProcessLabel" M0.Process R.Has M0.ProcessLabel
instance FromTeacakeRel "HA.Resources.Mero.relationDictProcess_IsParentOf_Service" M0.Process M0.IsParentOf M0.Service
instance FromTeacakeRel "HA.Resources.Mero.relationDictProcess_Is_ProcessBootstrapped" M0.Process Castor.Is M0.ProcessBootstrapped
instance FromTeacakeRel "HA.Resources.Mero.relationDictProcess_Is_ProcessState" M0.Process Castor.Is M0.ProcessState
instance FromTeacakeRel "HA.Resources.Mero.relationDictProfile_IsParentOf_Filesystem" M0.Profile M0.IsParentOf M0.Filesystem
instance FromTeacakeRel "HA.Resources.Mero.relationDictRackV_IsParentOf_EnclosureV" M0.RackV M0.IsParentOf M0.EnclosureV
instance FromTeacakeRel "HA.Resources.Mero.relationDictRack_At_Rack" M0.Rack M0.At Castor.Rack
instance FromTeacakeRel "HA.Resources.Mero.relationDictRack_IsParentOf_Enclosure" M0.Rack M0.IsParentOf M0.Enclosure
instance FromTeacakeRel "HA.Resources.Mero.relationDictRack_IsRealOf_RackV" M0.Rack M0.IsRealOf M0.RackV
instance FromTeacakeRel "HA.Resources.Mero.relationDictRoot_IsParentOf_Profile" M0.Root M0.IsParentOf M0.Profile
instance FromTeacakeRel "HA.Resources.Mero.relationDictSDev_IsOnHardware_Disk" M0.SDev M0.IsOnHardware M0.Disk
instance FromTeacakeRel "HA.Resources.Mero.relationDictSDev_Is_SDevState" M0.SDev Castor.Is M0.SDevState
instance FromTeacakeRel "HA.Resources.Mero.relationDictService_IsParentOf_SDev" M0.Service M0.IsParentOf M0.SDev
instance FromTeacakeRel "HA.Resources.Mero.relationDictService_Is_ServiceState" M0.Service Castor.Is M0.ServiceState
instance FromTeacakeRel "HA.Resources.RC.relationDictCluster_Has_RC" R.Cluster R.Has RC.RC
instance FromTeacakeRel "HA.Resources.RC.relationDictNode_Stopping_ServiceInfoMsg" R.Node RC.Stopping S.ServiceInfoMsg
instance FromTeacakeRel "HA.Resources.RC.relationDictRC_Is_Active" RC.RC Castor.Is RC.Active
instance FromTeacakeRel "HA.Resources.RC.relationDictSubProcessId_IsSubscriber_Subscriber" RC.SubProcessId RC.IsSubscriber RC.Subscriber
instance FromTeacakeRel "HA.Resources.RC.relationDictSubscriber_SubscribedTo_RC" RC.Subscriber RC.SubscribedTo RC.RC
instance FromTeacakeRel "HA.Resources.relationDictCluster_Has_EpochId" R.Cluster R.Has R.EpochId
instance FromTeacakeRel "HA.Resources.relationDictCluster_Has_Node" R.Cluster R.Has R.Node
instance FromTeacakeRel "HA.Service.Internal.relationDictNode_Has_ServiceInfoMsg" R.Node R.Has S.ServiceInfoMsg
instance FromTeacakeRel "HA.Services.DecisionLog.Types.relationDictSupportsClusterService" R.Cluster S.Supports (S.Service DLog.DecisionLogConf)
instance FromTeacakeRel "HA.Services.Mero.RC.Resources.relationDictRC_Has_StateDiff" RC.RC R.Has M0.StateDiff
instance FromTeacakeRel "HA.Services.Mero.RC.Resources.relationDictStateDiffIndex_Is_StateDiff" M0.StateDiffIndex Castor.Is M0.StateDiff
instance FromTeacakeRel "HA.Services.Mero.RC.Resources.relationDictStateDiff_DeliveredTo_Process" M0.StateDiff M0.DeliveredTo M0.Process
instance FromTeacakeRel "HA.Services.Mero.RC.Resources.relationDictStateDiff_DeliveryFailedTo_Process" M0.StateDiff M0.DeliveryFailedTo M0.Process
instance FromTeacakeRel "HA.Services.Mero.RC.Resources.relationDictStateDiff_ShouldDeliverTo_Process" M0.StateDiff M0.ShouldDeliverTo M0.Process
instance FromTeacakeRel "HA.Services.Mero.Types.relationDictSupportsClusterService" R.Cluster S.Supports (S.Service M0.MeroConf)
instance FromTeacakeRel "HA.Services.SSPL.LL.Resources.relationDictSupportsClusterService" R.Cluster S.Supports (S.Service SSPL.SSPLConf)
