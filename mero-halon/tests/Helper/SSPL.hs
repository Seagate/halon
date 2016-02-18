{-# LANGUAGE OverloadedStrings #-}
module Helper.SSPL
  ( emptySensorMessage
  , emptyHPIMessage
  , emptyHostUpdate
  , mkSensorResponse
  , mkResponseDriveManager
  , mkResponseHPI
  , mkHpiMessage
  , mkResponseRaidData
  ) where

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
                       -> SSPL.SensorResponseMessageSensor_response_typeDisk_status_drivemanager
mkResponseDriveManager enclosure serial idx status reason =
  SSPL.SensorResponseMessageSensor_response_typeDisk_status_drivemanager
    { SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerEnclosure_serial_number = enclosure
    , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDisk     = fromIntegral idx
    , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerStatus  = status
    , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerReason  = reason
    , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerSerial_number = serial
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
           , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiDiskNum = location
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
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiDiskNum = location
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiDeviceId = uuid
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiSerialNumber = serial
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiWwn = wwn
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiEnclosureSN = enclosure
  }

mkResponseRaidData :: Text -- ^ Host ID of node
                   -> Text -- ^ Contents of /proc/mdstat
                   -> SSPL.SensorResponseMessageSensor_response_typeRaid_data
mkResponseRaidData host mdstat = SSPL.SensorResponseMessageSensor_response_typeRaid_data {
    SSPL.sensorResponseMessageSensor_response_typeRaid_dataHostId = host
  , SSPL.sensorResponseMessageSensor_response_typeRaid_dataMdstat = Just mdstat
}
