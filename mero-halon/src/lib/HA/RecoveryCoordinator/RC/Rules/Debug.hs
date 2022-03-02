{-# LANGUAGE LambdaCase #-}
-- |
-- Copyright : (C) 2018 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
module HA.RecoveryCoordinator.RC.Rules.Debug
  ( debugRules
  ) where

import           Control.Distributed.Process (sendChan)
import           Control.Lens ((<&>))  -- XXX Data.Functor in lts-12.13
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
  [ ruleDebugQuery
  , ruleDebugModify
  ]

----------------------------------------------------------------------
-- Query requests

-- | Dispatches `hctl debug print` requests.
ruleDebugQuery :: Definitions RC ()
ruleDebugQuery = defineSimpleTask "hctl-debug-query" $ \case
    D.DebugQueryDriveInfo req -> queryDriveInfo req

-- | Handles `hctl debug print drive` requests.
queryDriveInfo :: D.QueryDriveInfoReq -> PhaseM RC l ()
queryDriveInfo (D.QueryDriveInfoReq (D.SelectDrive driveId) sp) = do
    Log.rcLog' Log.DEBUG (show driveId)
    rg <- getGraph
    let resp = either D.QueryDriveInfoError
                     (D.QueryDriveInfo . getDebugDriveInfo rg)
                     (findStorageDevice rg driveId)
    liftProcess (sendChan sp resp)

getDebugDriveInfo :: G.Graph -> Cas.StorageDevice -> D.DebugDriveInfo
getDebugDriveInfo rg sd =
    let h0sdev = D.DebugH0Sdev { D.dhsSdev   = sd
                               , D.dhsIds    = G.connectedTo sd Has rg
                               , D.dhsStatus = G.connectedTo sd Cas.Is rg
                               , D.dhsAttrs  = G.connectedTo sd Has rg
                               , D.dhsSlot   = G.connectedTo sd Has rg
                               , D.dhsReplacedBy =
                                     G.connectedTo sd Cas.ReplacedBy rg
                               }
        (mm0drive, mm0sdev) = case G.connectedFrom M0.At sd rg of
            Nothing -> (Nothing, Nothing)
            Just disk ->
              ( Just $ D.DebugM0Drive
                  { D.dmdDrive = disk
                  , D.dmdIsReplaced = G.isConnected disk Cas.Is M0.Replaced rg
                  }
              , G.connectedFrom M0.IsOnHardware disk rg <&> \sdev ->
                    D.DebugM0Sdev
                      { D.dmsSdev = sdev
                      , D.dmsState = G.connectedTo sdev Cas.Is rg
                      , D.dmsSlot = G.connectedTo sdev M0.At rg
                      }
              )
    in D.DebugDriveInfo { D.dsiH0Sdev = Just h0sdev
                        , D.dsiM0Drive = mm0drive
                        , D.dsiM0Sdev = mm0sdev
                        }

----------------------------------------------------------------------
-- Modification requests

-- | Dispatches `hctl debug set` requests.
ruleDebugModify :: Definitions RC ()
ruleDebugModify = defineSimpleTask "hctl-debug-modify" $ \case
    D.DebugModifyDriveState req -> modifyDriveState req
    D.DebugModifySdevState req -> modifySdevState req

-- | Handles `hctl debug set drive` requests.
modifyDriveState :: D.ModifyDriveStateReq -> PhaseM RC l ()
modifyDriveState (D.ModifyDriveStateReq (D.SelectDrive driveId) newState sp) =
  do
    Log.rcLog' Log.DEBUG $ show driveId ++ " -> " ++ show newState
    let resp = D.ModifyDriveStateError "XXX IMPLEMENTME"
    liftProcess (sendChan sp resp)

-- | Handles `hctl debug set sdev` requests.
modifySdevState :: D.ModifySdevStateReq -> PhaseM RC l ()
modifySdevState (D.ModifySdevStateReq (D.SelectSdev sdevId) newState sp) =
  do
    Log.rcLog' Log.DEBUG $ show sdevId ++ " -> " ++ show newState
    let resp = D.ModifySdevStateError "XXX IMPLEMENTME"
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
