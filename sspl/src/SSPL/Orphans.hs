{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- |
-- Module    : SSPL.Orphans
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Orphan instances for generated bindings.
module SSPL.Orphans where

import Data.SafeCopy
import SSPL.Bindings.ActuatorResponse
import SSPL.Bindings.CommandRequest
import SSPL.Bindings.SensorResponse

deriveSafeCopy 0 'base ''ActuatorResponseMessageActuator_response_typeThread_controller

deriveSafeCopy 0 'base ''CommandRequest
deriveSafeCopy 0 'base ''CommandRequestMessage
deriveSafeCopy 0 'base ''CommandRequestMessageNodeStatusChangeRequest
deriveSafeCopy 0 'base ''CommandRequestMessageServiceRequest
deriveSafeCopy 0 'base ''CommandRequestMessageStatusRequest

deriveSafeCopy 0 'base ''SensorResponseMessageSensor_response_typeDisk_status_drivemanager
deriveSafeCopy 0 'base ''SensorResponseMessageSensor_response_typeDisk_status_hpi
deriveSafeCopy 0 'base ''SensorResponseMessageSensor_response_typeRaid_data
deriveSafeCopy 0 'base ''SensorResponseMessageSensor_response_typeRaid_dataDrivesItem
deriveSafeCopy 0 'base ''SensorResponseMessageSensor_response_typeRaid_dataDrivesItemIdentity
deriveSafeCopy 0 'base ''SensorResponseMessageSensor_response_typeService_watchdog
