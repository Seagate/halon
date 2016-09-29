-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module handling SMART testing of drives.
--

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns   #-}
module HA.RecoveryCoordinator.Castor.Drive.Rules.Smart
  ( rules
  , runSmartTest
  ) where

import HA.EventQueue.Types
  ( HAEvent(..)
  , UUID
  )
import HA.RecoveryCoordinator.Actions.Core
  ( LoopState
  , fldUUID
  , messageProcessed
  , unlessM
  , whenM
  )

import HA.RecoveryCoordinator.Actions.Hardware
  ( isStorageDriveRemoved
  , isStorageDevicePowered
  , lookupStorageDeviceSerial
  )
import HA.RecoveryCoordinator.Job.Actions
import HA.RecoveryCoordinator.Castor.Drive.Events
  ( SMARTRequest(..)
  , SMARTResponse(..)
  , SMARTResponseStatus(..)
  )
import HA.Resources (Node(..))
import HA.Resources.Castor (StorageDevice)
import HA.Services.SSPL.CEP
  ( sendNodeCmd )
import HA.Services.SSPL.LL.Resources
  ( AckReply(..)
  , CommandAck(..)
  , NodeCmd(..)
  , commandAck
  )

import Control.Distributed.Process (Process)
import Control.Lens

import Data.Foldable (for_)
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
runSmartTest :: Definitions LoopState ()
runSmartTest = mkJobRule jobRunSmartTest args $ \finish -> do
    smart         <- phaseHandle "smart"
    smartSuccess  <- phaseHandle "smart-success"
    smartFailure  <- phaseHandle "smart-failure"
    smartTimeout  <- phaseHandle "smart-timeout"

    directly smart $ do
      Just (node@(Node nid)) <- gets Local (^. rlens fldNode . rfield)
      Just (DeviceInfo sdev serial) <-
        gets Local (^. rlens fldDeviceInfo . rfield)

      logInfo

      whenM (isStorageDriveRemoved sdev) $ do
        phaseLog "info" $ "Drive is removed."
        modify Local $ rlens fldRep . rfield .~
          (Just $ SMARTResponse sdev SRSNotPossible)
        continue finish
      unlessM (isStorageDevicePowered sdev) $ do
        phaseLog "info" $ "Drive is not powered."
        modify Local $ rlens fldRep . rfield .~
          (Just $ SMARTResponse sdev SRSNotPossible)
        continue finish

      sent <- sendNodeCmd nid Nothing (SmartTest serial)
      if sent
      then do
        phaseLog "info" $ "Running SMART test."
        switch [ smartSuccess, smartFailure
               , timeout smartTestTimeout smartTimeout ]
      else do
        phaseLog "warning" $ "Cannot send message to SSPL."
        modify Local $ rlens fldRep . rfield .~
          (Just $ SMARTResponse sdev SRSNotAvailable)
        continue finish

    setPhaseIf smartSuccess onSmartSuccess $ \eid -> do
      Just (DeviceInfo sdev _) <-
        gets Local (^. rlens fldDeviceInfo . rfield)
      logInfo
      phaseLog "info" $ "SMART test success"
      modify Local $ rlens fldRep . rfield .~
        (Just $ SMARTResponse sdev SRSSuccess)
      messageProcessed eid
      continue finish

    setPhaseIf smartFailure onSmartFailure $ \eid -> do
      Just (DeviceInfo sdev _) <-
        gets Local (^. rlens fldDeviceInfo . rfield)
      logInfo
      phaseLog "warning" $ "SMART test failed"
      modify Local $ rlens fldRep . rfield .~
        (Just $ SMARTResponse sdev SRSFailed)
      messageProcessed eid
      continue finish

    directly smartTimeout $ do
      Just (DeviceInfo sdev _) <-
        gets Local (^. rlens fldDeviceInfo . rfield)
      logInfo
      phaseLog "warning" $ "SMART test timeout"
      modify Local $ rlens fldRep . rfield .~
        (Just $ SMARTResponse sdev SRSTimeout)
      continue finish

    return $ \(SMARTRequest node sdev) -> do
      serial <- lookupStorageDeviceSerial sdev
      case serial of
        (T.pack -> serial):_ -> do
          modify Local $ rlens fldNode . rfield .~ (Just node)
          modify Local $ rlens fldDeviceInfo . rfield .~
            (Just $ DeviceInfo sdev serial)
          return $ Just [smart]
        [] -> do
          phaseLog "device.id" $ show sdev
          phaseLog "warning" $ "Cannot find serial number for sdev."
          return Nothing
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
    logInfo = do
      node <- gets Local (^. rlens fldNode . rfield)
      mdinfo <- gets Local (^. rlens fldDeviceInfo . rfield)
      phaseLog "node" $ show node
      for_ mdinfo $ \dinfo -> do
        phaseLog "device.id" $ show (dinfo ^. diSDev)
        phaseLog "device.serial" $ show (dinfo ^. diSerial)

onSmartSuccess :: forall g l. (FldDeviceInfo ∈ l)
               => HAEvent CommandAck
               -> g
               -> FieldRec l
               -> Process (Maybe UUID)
onSmartSuccess (HAEvent eid cmd _) _
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
               => HAEvent CommandAck
               -> g
               -> FieldRec l
               -> Process (Maybe UUID)
onSmartFailure (HAEvent eid cmd _) _
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
rules :: Definitions LoopState ()
rules = sequence_
  [ runSmartTest ]
