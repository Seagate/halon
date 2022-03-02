-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Module handling SMART testing of drives.
--

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns   #-}
module HA.RecoveryCoordinator.Castor.Drive.Rules.Smart
  ( rules
  , runSmartTest
  ) where

import Data.UUID (UUID)
import HA.EventQueue
  ( HAEvent(..)
  )
import HA.RecoveryCoordinator.RC.Actions
  ( RC
  , fldUUID
  , messageProcessed
  , unlessM
  , whenM
  )

import HA.RecoveryCoordinator.Actions.Hardware
  ( isStorageDriveRemoved
  )
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import HA.RecoveryCoordinator.Job.Actions
import HA.RecoveryCoordinator.Castor.Drive.Events
  ( SMARTRequest(..)
  , SMARTResponse(..)
  , SMARTResponseStatus(..)
  )
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import HA.Resources (Node(..))
import HA.Resources.HalonVars
import HA.Resources.Castor (StorageDevice(..))
import HA.Services.SSPL.LL.CEP
  ( sendNodeCmd )
import HA.Services.SSPL.LL.Resources
  ( AckReply(..)
  , NodeCmd(..)
  , commandAck
  , commandAckType
  , SsplLlFromSvc(..)
  )

import Control.Distributed.Process (Process)
import Control.Lens

import qualified Data.Map.Strict as Map
import Data.Proxy
import qualified Data.Text as T
import Data.Vinyl

import Network.CEP

-- | Time to allow for SSPL reply on a smart test request.
smartTestTimeout :: Int
smartTestTimeout = 15*60

data DeviceInfo = DeviceInfo {
    _diSDev :: StorageDevice
  , _diSerial :: T.Text
}
makeLenses ''DeviceInfo

fldNode :: Proxy '("node", Maybe Node)
fldNode = Proxy

type FldDeviceInfo = '("deviceInfo", Maybe DeviceInfo)
-- | Device info used in SMART rule
fldDeviceInfo :: Proxy FldDeviceInfo
fldDeviceInfo = Proxy

jobRunSmartTest :: Job SMARTRequest SMARTResponse
jobRunSmartTest = Job "castor::drive::smart::run"

-- | Rule for running a SMART test.
--   Consumes 'SMARTRequest'
--   Emits 'SMARTResponse'
runSmartTest :: Definitions RC ()
runSmartTest = mkJobRule jobRunSmartTest args $ \(JobHandle _ finish) -> do
    smart         <- phaseHandle "smart"
    smartSuccess  <- phaseHandle "smart-success"
    smartFailure  <- phaseHandle "smart-failure"
    smartTimeout  <- phaseHandle "smart-timeout"

    setLocalStateLogger $ \l -> let
        di = case (l ^. rlens fldDeviceInfo . rfield) of
          Nothing -> []
          Just dinfo -> [ ("device.id", show (dinfo ^. diSDev))
                        , ("device.serial", show (dinfo ^. diSerial))
                        ]
      in Map.fromList $ [
          ("uuid", show $ l ^. rlens fldUUID . rfield)
        , ("request", show $ l ^. rlens fldReq . rfield)
        , ("reply", show $ l ^. rlens fldRep . rfield)
        , ("node", show $ l ^. rlens fldNode . rfield)
        ] ++ di

    directly smart $ do
      Just node <- gets Local (^. rlens fldNode . rfield)
      Just (DeviceInfo sdev serial) <-
        gets Local (^. rlens fldDeviceInfo . rfield)

      whenM (isStorageDriveRemoved sdev) $ do
        Log.rcLog' Log.DEBUG "Drive is removed."
        modify Local $ rlens fldRep . rfield .~
          (Just $ SMARTResponse sdev SRSNotPossible)
        continue finish
      unlessM (StorageDevice.isPowered sdev) $ do
        Log.rcLog' Log.DEBUG "Drive is not powered."
        modify Local $ rlens fldRep . rfield .~
          (Just $ SMARTResponse sdev SRSNotPossible)
        continue finish

      sent <- sendNodeCmd [node] Nothing (SmartTest serial)
      if sent
      then do
        Log.rcLog' Log.DEBUG "Running SMART test."
        switch [ smartSuccess, smartFailure
               , timeout smartTestTimeout smartTimeout ]
      else do
        Log.rcLog' Log.WARN "Cannot send message to SSPL."
        modify Local $ rlens fldRep . rfield .~
          (Just $ SMARTResponse sdev SRSNotAvailable)
        continue finish

    setPhaseIf smartSuccess onSmartSuccess $ \eid -> do
      Just (DeviceInfo sdev _) <-
        gets Local (^. rlens fldDeviceInfo . rfield)
      Log.rcLog' Log.DEBUG "SMART test success"
      modify Local $ rlens fldRep . rfield .~
        (Just $ SMARTResponse sdev SRSSuccess)
      messageProcessed eid
      continue finish

    setPhaseIf smartFailure onSmartFailure $ \eid -> do
      Just (DeviceInfo sdev _) <-
        gets Local (^. rlens fldDeviceInfo . rfield)
      Log.rcLog' Log.WARN "SMART test failed"
      modify Local $ rlens fldRep . rfield .~
        (Just $ SMARTResponse sdev SRSFailed)
      messageProcessed eid
      continue finish

    directly smartTimeout $ do
      Just (DeviceInfo sdev _) <-
        gets Local (^. rlens fldDeviceInfo . rfield)
      Log.rcLog' Log.WARN "SMART test timeout"
      modify Local $ rlens fldRep . rfield .~
        (Just $ SMARTResponse sdev SRSTimeout)
      continue finish

    return $ \(SMARTRequest node sdev@(StorageDevice (T.pack -> serial))) -> do
      isDisabled <- getHalonVar _hv_disable_smart_checks
      Log.tagContext Log.SM node Nothing
      Log.tagContext Log.SM sdev Nothing
      modify Local $ rlens fldNode . rfield .~ (Just node)
      modify Local $ rlens fldDeviceInfo . rfield .~
        (Just $ DeviceInfo sdev serial)
      return . Right $
        if isDisabled
        then (SMARTResponse sdev SRSSuccess, [finish])
        else (SMARTResponse sdev SRSNotPossible, [smart])
  where
    fldReq :: Proxy '("request", Maybe SMARTRequest)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe SMARTResponse)
    fldRep = Proxy
    args = fldUUID          =: Nothing
       <+> fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> fldNode          =: Nothing
       <+> fldDeviceInfo    =: Nothing

onSmartSuccess :: forall g l. (FldDeviceInfo ∈ l)
               => HAEvent SsplLlFromSvc
               -> g
               -> FieldRec l
               -> Process (Maybe UUID)
onSmartSuccess (HAEvent eid (CAck cmd)) _
               ((view $ rlens fldDeviceInfo . rfield) -> Just (DeviceInfo _ serial)) =
    case commandAckType cmd of
      Just (SmartTest x)
        | serial == x ->
          case commandAck cmd of
            AckReplyPassed -> return $ Just eid
            _              -> return Nothing
        | otherwise -> return Nothing
      _ -> return Nothing
onSmartSuccess _ _ _ = return Nothing

onSmartFailure :: forall g l. (FldDeviceInfo ∈ l)
               => HAEvent SsplLlFromSvc
               -> g
               -> FieldRec l
               -> Process (Maybe UUID)
onSmartFailure (HAEvent eid (CAck cmd)) _
               ((view $ rlens fldDeviceInfo . rfield) -> Just (DeviceInfo _ serial)) =
    case commandAckType cmd of
      Just (SmartTest x)
        | serial == x ->
          case commandAck cmd of
            AckReplyFailed  -> return $ Just eid
            AckReplyError _ -> return $ Just eid
            _               -> return Nothing
        | otherwise -> return Nothing
      _ -> return Nothing
onSmartFailure _ _ _ = return Nothing

-- | All rules exported by this module.
rules :: Definitions RC ()
rules = sequence_
  [ runSmartTest ]
