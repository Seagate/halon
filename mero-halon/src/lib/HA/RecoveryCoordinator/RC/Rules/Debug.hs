-- |
-- Copyright : (C) 2018 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.RC.Rules.Debug
  ( debugRules
  ) where

import           Control.Distributed.Process (sendChan)
import qualified Data.Text as T
import           Text.Printf (printf)

import           HA.RecoveryCoordinator.RC.Actions.Core
  ( defineSimpleTask
  , getGraph
  )
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.RecoveryCoordinator.RC.Application (RC)
import           HA.RecoveryCoordinator.RC.Events.Debug
  ( DriveId(DriveSerial,DriveWwn)
  , ModifyDriveStateReq(..)
  , ModifyDriveStateResp(..)
  , QueryDriveStateReq(..)
  , QueryDriveStateResp(..)
  , SelectDrive(..)
  , StateOfDrive(DriveOnline)
  )
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources.Castor as Cas
import qualified HA.Resources.Mero as M0
import           Network.CEP (Definitions, liftProcess)

debugRules :: Definitions RC ()
debugRules = sequence_
  [ ruleModifyDriveState
  , ruleQueryDriveState
  ]

-- | Handles `hctl debug print drive` request.
ruleQueryDriveState :: Definitions RC ()
ruleQueryDriveState = defineSimpleTask "debug-query-drive-state" $
    \(QueryDriveStateReq (SelectDrive driveId) sp) -> do
        Log.rcLog' Log.DEBUG (show driveId)
        rg <- getGraph
        let resp = maybe QueryDriveStateNoStorageDeviceError
                         (driveStateResp rg)
                         (findStorageDevice rg driveId)
        liftProcess (sendChan sp resp)

-- | Handles `hctl debug set drive` request.
ruleModifyDriveState :: Definitions RC ()
ruleModifyDriveState = defineSimpleTask "debug-modify-drive-state" $
    \(ModifyDriveStateReq (SelectDrive driveId) newState sp) -> do
        Log.rcLog' Log.DEBUG $ show driveId ++ " -> " ++ show newState
        let resp = case newState of -- XXX IMPLEMENTME
                DriveOnline -> ModifyDriveStateOK
                _           -> ModifyDriveStateNoStorageDeviceError
        liftProcess (sendChan sp resp)

-- XXX Compare with HA.RecoveryCoordinator.Mero.Actions.Initial.dereference.
findStorageDevice :: G.Graph -> DriveId -> Maybe Cas.StorageDevice
findStorageDevice rg (DriveSerial serial) =
    let sd = Cas.StorageDevice (T.unpack serial)
    in if G.isConnected Cluster Has sd rg
       then Just sd
       else Nothing
findStorageDevice rg (DriveWwn wwn) =
    case [ sd
         | sd :: Cas.StorageDevice <- G.connectedTo Cluster Has rg
         , let ids = G.connectedTo sd Has rg :: [Cas.DeviceIdentifier]
         , Cas.DIWWN (T.unpack wwn) `elem` ids
         ] of
        [sd] -> Just sd
        _   -> Nothing

driveStateResp :: G.Graph -> Cas.StorageDevice -> QueryDriveStateResp
driveStateResp rg sd =
    let ids = G.connectedTo sd Has rg :: [Cas.DeviceIdentifier]
        attrs = G.connectedTo sd Has rg :: [Cas.StorageDeviceAttr]
        -- See also
        -- HA.RecoveryCoordinator.Hardware.StorageDevice.Actions.status
        mstatus = G.connectedTo sd Cas.Is rg :: Maybe Cas.StorageDeviceStatus
        mslot = G.connectedTo sd Has rg :: Maybe Cas.Slot
        mdr = do
            drive <- G.connectedFrom M0.At sd rg :: Maybe M0.Disk
            let mreplaced = G.connectedTo drive Cas.Is rg :: Maybe M0.Replaced
            pure (drive, mreplaced)
    in QueryDriveState . T.pack $
        printf "XXX sd=(%s) ids=%s mstatus=(%s) attrs=%s mslot=(%s) mdr=(%s)"
            (show sd) (show ids) (show mstatus) (show attrs) (show mslot) (show mdr)
