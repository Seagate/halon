{-# LANGUAGE OverloadedStrings #-}
module Helper.SSPL
  ( emptySensorMessage
  , emptyActuatorMessage
  , emptyHPIMessage
  , emptyHostUpdate
  , mkSensorResponse
  , mkActuatorResponse
  , mkResponseDriveManager
  , mkResponseHPI
  , mkHpiMessage
  , mkResponseRaidData
  ) where

import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified SSPL.Bindings as SSPL

emptySensorMessage :: SSPL.SensorResponseMessageSensor_response_type
emptySensorMessage = SSPL.SensorResponseMessageSensor_response_type
  { SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpi = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeIf_data = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeHost_update = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanager = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeService_watchdog = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeLocal_mount_data = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeCpu_data = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeRaid_data = Nothing
  , SSPL.sensorResponseMessageSensor_response_typeSnmp_trap = Nothing
  }

emptyActuatorMessage :: SSPL.ActuatorResponseMessageActuator_response_type
emptyActuatorMessage = SSPL.ActuatorResponseMessageActuator_response_type
  { SSPL.actuatorResponseMessageActuator_response_typeAck = Nothing
  , SSPL.actuatorResponseMessageActuator_response_typeThread_controller = Nothing
  , SSPL.actuatorResponseMessageActuator_response_typeService_controller = Nothing
  }

-- | Create stub sensor response
mkSensorResponse :: SSPL.SensorResponseMessageSensor_response_type -> SSPL.SensorResponse
mkSensorResponse rsp = SSPL.SensorResponse
  { SSPL.sensorResponseSignature = "not-yet-implemented"
  , SSPL.sensorResponseTime      = "YYYY-MM-DD HH:mm"
  , SSPL.sensorResponseExpires   = Nothing
  , SSPL.sensorResponseUsername  = "sspl"
  , SSPL.sensorResponseMessage   = SSPL.SensorResponseMessage Nothing rsp
  }

-- | Create stub actuator response.
mkActuatorResponse :: SSPL.ActuatorResponseMessageActuator_response_type -> SSPL.ActuatorResponse
mkActuatorResponse rsp = SSPL.ActuatorResponse
  { SSPL.actuatorResponseSignature = "not-yet-implemented"
  , SSPL.actuatorResponseTime      = "YYYY-MM-DD HH:mm"
  , SSPL.actuatorResponseExpires   = Nothing
  , SSPL.actuatorResponseUsername  = "sspl"
  , SSPL.actuatorResponseMessage   = SSPL.ActuatorResponseMessage rsp Aeson.Null
  }

-- | Create default HPI message.
emptyHPIMessage :: SSPL.SensorResponseMessageSensor_response_typeDisk_status_hpi
emptyHPIMessage = SSPL.SensorResponseMessageSensor_response_typeDisk_status_hpi
  { SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiProductName = "seagate-dh"
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiDrawer = 42
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiManufacturer = "seagate"
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiHostId = "SOMEHOST"
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiDiskNum = 0
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiLocation = 0
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiDeviceId = "deviceId"
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiSerialNumber = "serial"
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiWwn = "wwn"
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiProductVersion = "0.0.1"
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiEnclosureSN = "ENCLOSURE"
  }

emptyHostUpdate :: Text -> SSPL.SensorResponseMessageSensor_response_typeHost_update
emptyHostUpdate hostid =
  SSPL.SensorResponseMessageSensor_response_typeHost_update
    { SSPL.sensorResponseMessageSensor_response_typeHost_updateRunningProcessCount = Nothing
    , SSPL.sensorResponseMessageSensor_response_typeHost_updateUname               = Nothing
    , SSPL.sensorResponseMessageSensor_response_typeHost_updateHostId              = hostid
    , SSPL.sensorResponseMessageSensor_response_typeHost_updateLocaltime           = ""
    , SSPL.sensorResponseMessageSensor_response_typeHost_updateUpTime              = Nothing
    , SSPL.sensorResponseMessageSensor_response_typeHost_updateFreeMem             = Nothing
    , SSPL.sensorResponseMessageSensor_response_typeHost_updateLoggedInUsers       = Nothing
    , SSPL.sensorResponseMessageSensor_response_typeHost_updateTotalMem            = Nothing
    , SSPL.sensorResponseMessageSensor_response_typeHost_updateProcessCount        = Nothing
    , SSPL.sensorResponseMessageSensor_response_typeHost_updateBootTime            = Nothing
    }

-- | Create drive manager message
mkResponseDriveManager :: Text -- ^ Enclosure SN
                       -> Text -- ^ Serial number
                       -> Int  -- ^ Disk Num
                       -> Text -- ^ Status
                       -> Text -- ^ Reason
                       -> Text -- ^ Path
                       -> SSPL.SensorResponseMessageSensor_response_typeDisk_status_drivemanager
mkResponseDriveManager enclosure serial idx status reason path =
  SSPL.SensorResponseMessageSensor_response_typeDisk_status_drivemanager
    { SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerEnclosureSN = enclosure
    , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskNum     = fromIntegral idx
    , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskStatus  = status
    , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerSerialNumber = serial
    , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerPathID      = path
    , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskReason  = reason
    }

mkResponseHPI :: Text -- ^ Host ID of node
              -> Text -- ^ Enclosure name
              -> Text -- ^ Serial number
              -> Integer -- ^ Location number of drive
              -> Text -- ^ Drive identifier (UUID)
              -> Text -- ^ wwn of the drive
              -> SSPL.SensorResponseMessageSensor_response_type
mkResponseHPI hostid enclosure serial location uuid wwn =
   emptySensorMessage
     { SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpi =
         Just $ emptyHPIMessage
           { SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiHostId = hostid
           , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiDiskNum = fromIntegral location
           , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiDeviceId = uuid
           , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiWwn = wwn
           , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiEnclosureSN = enclosure
           , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiSerialNumber = serial
           }
     }

mkHpiMessage :: Text -- ^ Host ID of node
             -> Text -- ^ Enclosure name
             -> Text -- ^ Serial
             -> Integer -- ^ Location number of drive
             -> Text -- ^ Drive identifier (UUID)
             -> Text -- ^ wwn of the drive
             -> SSPL.SensorResponseMessageSensor_response_typeDisk_status_hpi
mkHpiMessage hostid enclosure serial location uuid wwn = emptyHPIMessage
  { SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiHostId = hostid
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiDiskNum = fromIntegral location
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiDeviceId = uuid
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiSerialNumber = serial
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiWwn = wwn
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiEnclosureSN = enclosure
  }

mkResponseRaidData :: Text -- ^ Host ID of node
                   -> Text -- ^ RAID device name
                   -> [((Text, Text), Bool)] -- ^ Device path, sn, device good?
                   -> SSPL.SensorResponseMessageSensor_response_typeRaid_data
mkResponseRaidData host raidDev devStates = SSPL.SensorResponseMessageSensor_response_typeRaid_data {
      SSPL.sensorResponseMessageSensor_response_typeRaid_dataHostId = host
    , SSPL.sensorResponseMessageSensor_response_typeRaid_dataDevice = raidDev
    , SSPL.sensorResponseMessageSensor_response_typeRaid_dataDrives = (\ds ->
        SSPL.SensorResponseMessageSensor_response_typeRaid_dataDrivesItem {
            SSPL.sensorResponseMessageSensor_response_typeRaid_dataDrivesItemStatus = status $ snd ds
          , SSPL.sensorResponseMessageSensor_response_typeRaid_dataDrivesItemIdentity = Just $
              SSPL.SensorResponseMessageSensor_response_typeRaid_dataDrivesItemIdentity {
                  SSPL.sensorResponseMessageSensor_response_typeRaid_dataDrivesItemIdentityPath = fst . fst $ ds
                , SSPL.sensorResponseMessageSensor_response_typeRaid_dataDrivesItemIdentitySerialNumber = snd . fst $ ds
              }
        }) <$> devStates
    }
  where
    status x = if x then "U" else "_"
