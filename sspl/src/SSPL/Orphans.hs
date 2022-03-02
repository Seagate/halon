{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- |
-- Module    : SSPL.Orphans
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Orphan instances for generated bindings.
module SSPL.Orphans where

import Data.SafeCopy
import SSPL.Bindings.ActuatorRequest
import SSPL.Bindings.ActuatorResponse
import SSPL.Bindings.CommandRequest
import SSPL.Bindings.CommandResponse
import SSPL.Bindings.SensorResponse

deriveSafeCopy 0 'base ''ActuatorRequestMessageActuator_request_type
deriveSafeCopy 0 'base ''ActuatorRequestMessageActuator_request_typeLogin_controller
deriveSafeCopy 0 'base ''ActuatorRequestMessageActuator_request_typeNode_controller
deriveSafeCopy 0 'base ''ActuatorRequestMessageActuator_request_typeThread_controller
deriveSafeCopy 0 'base ''ActuatorRequestMessageActuator_request_typeLogging
deriveSafeCopy 0 'base ''ActuatorRequestMessageActuator_request_typeService_controller

deriveSafeCopy 0 'base ''ActuatorResponseMessageActuator_response_typeThread_controller

deriveSafeCopy 0 'base ''CommandRequest
deriveSafeCopy 0 'base ''CommandRequestMessage
deriveSafeCopy 0 'base ''CommandRequestMessageNodeStatusChangeRequest
deriveSafeCopy 0 'base ''CommandRequestMessageServiceRequest
deriveSafeCopy 0 'base ''CommandRequestMessageStatusRequest

deriveSafeCopy 0 'base ''CommandResponseMessage
deriveSafeCopy 0 'base ''CommandResponseMessageStatusResponseItem

deriveSafeCopy 0 'base ''SensorResponseMessageSensor_response_typeDisk_status_drivemanager
deriveSafeCopy 0 'base ''SensorResponseMessageSensor_response_typeDisk_status_hpi
deriveSafeCopy 0 'base ''SensorResponseMessageSensor_response_typeRaid_data
deriveSafeCopy 0 'base ''SensorResponseMessageSensor_response_typeRaid_dataDrivesItem
deriveSafeCopy 0 'base ''SensorResponseMessageSensor_response_typeRaid_dataDrivesItemIdentity
deriveSafeCopy 0 'base ''SensorResponseMessageSensor_response_typeService_watchdog
