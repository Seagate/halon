{-# LANGUAGE LambdaCase #-}
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
import           HA.RecoveryCoordinator.RC.Events.Debug as D
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources.Castor as Cas
import qualified HA.Resources.Mero as M0
import           Network.CEP (Definitions, PhaseM, liftProcess)

debugRules :: Definitions RC ()
debugRules = sequence_
  [ ruleDebugModify
  , ruleDebugQuery
  ]

----------------------------------------------------------------------
-- Query requests

-- | Dispatches `hctl debug print` requests.
ruleDebugQuery :: Definitions RC ()
ruleDebugQuery = defineSimpleTask "debug-query" $ \case
    D.QueryDriveState req -> queryDriveState req

-- | Handles `hctl debug print drive` requests.
queryDriveState :: D.QueryDriveStateReq -> PhaseM RC l ()
queryDriveState (D.QueryDriveStateReq (D.SelectDrive driveId) sp) = do
    Log.rcLog' Log.DEBUG (show driveId)
    rg <- getGraph
    let resp = either D.QDriveStateNoStorageDeviceError
                      (driveStateResp rg)
                      (findStorageDevice rg driveId)
    liftProcess (sendChan sp resp)

----------------------------------------------------------------------
-- Modification requests

-- | Dispatches `hctl debug set` requests.
ruleDebugModify :: Definitions RC ()
ruleDebugModify = defineSimpleTask "debug-modify" $ \case
    D.ModifyDriveState req -> modifyDriveState req

-- | Handles `hctl debug set drive` requests.
modifyDriveState :: D.ModifyDriveStateReq -> PhaseM RC l ()
modifyDriveState (D.ModifyDriveStateReq (D.SelectDrive driveId) newState sp) =
  do
    Log.rcLog' Log.DEBUG $ show driveId ++ " -> " ++ show newState
    let resp = D.MDriveStateNoStorageDeviceError "XXX IMPLEMENTME"
    liftProcess (sendChan sp resp)

----------------------------------------------------------------------
-- Misc.

-- XXX Compare with HA.RecoveryCoordinator.Mero.Actions.Initial.dereference.
findStorageDevice :: G.Graph -> D.DriveId -> Either String Cas.StorageDevice
findStorageDevice rg (D.DriveSerial serial) =
    let sd = Cas.StorageDevice (T.unpack serial)
    in if G.isConnected Cluster Has sd rg
       then Right sd
       else Left $ printf "No StorageDevice with serial number %s found" serial
findStorageDevice rg (D.DriveWwn wwn) =
    case [ sd
         | sd :: Cas.StorageDevice <- G.connectedTo Cluster Has rg
         , let ids = G.connectedTo sd Has rg :: [Cas.DeviceIdentifier]
         , Cas.DIWWN (T.unpack wwn) `elem` ids
         ] of
        [sd] -> Right sd
        _    -> Left $ printf "No StorageDevice with WWN %s found" wwn
findStorageDevice rg (D.DriveEnclSlot enclId slotIdx) =
    case [ encl
         | site :: Cas.Site <- G.connectedTo Cluster Has rg
         , rack :: Cas.Rack <- G.connectedTo site Has rg
         , encl@(Cas.Enclosure eid) <- G.connectedTo rack Has rg
         , eid == T.unpack enclId
         ] of
        [encl] -> let slot = Cas.Slot encl slotIdx
                  in if G.isConnected encl Has slot rg
                     then case G.connectedFrom Has slot rg of
                        Just sd -> Right sd
                        Nothing -> Left "Slot is not linked to a StorageDevice"
                     else Left $ printf "Enclosure %s doesn't have slot %d"
                                 enclId slotIdx
        [] -> Left $ T.unpack enclId ++ ": No such enclosure"
        _  -> Left $ "Impossible happened! Several enclosures have id "
                  ++ show enclId

driveStateResp :: G.Graph -> Cas.StorageDevice -> D.QueryDriveStateResp
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
    in D.QDriveState . T.pack $
        printf "XXX sd=(%s) ids=%s mstatus=(%s) attrs=%s mslot=(%s) mdr=(%s)"
            (show sd) (show ids) (show mstatus) (show attrs) (show mslot) (show mdr)
