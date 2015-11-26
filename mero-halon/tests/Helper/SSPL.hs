{-# LANGUAGE OverloadedStrings #-}
module Helper.SSPL 
  ( emptySensorMessage
  , emptyHPIMessage
  , emptyHostUpdate
  , mkSensorResponse
  , mkResponseDriveManager
  , mkResponseHPI
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
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiLocation = 0 
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiDeviceId = "deviceId"
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiSerialNumber = "serial"
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiWwn = "wwn"
  , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiProductVersion = "0.0.1"
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
                       -> Int  -- ^ Disk Num
                       -> Text -- ^ Status
                       -> SSPL.SensorResponseMessageSensor_response_typeDisk_status_drivemanager
mkResponseDriveManager enclosure idx status =
  SSPL.SensorResponseMessageSensor_response_typeDisk_status_drivemanager
    { SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerEnclosureSN = enclosure
    , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskNum     = fromIntegral idx
    , SSPL.sensorResponseMessageSensor_response_typeDisk_status_drivemanagerDiskStatus  = status
    }

mkResponseHPI :: Text -- ^ Host ID of node
              -> Integer -- ^ Location number of drive
              -> Text -- ^ Drive identifier (UUID)
              -> Text -- ^ wwn of the drive
              -> SSPL.SensorResponseMessageSensor_response_type
mkResponseHPI hostid location uuid wwn =
   emptySensorMessage
     { SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpi =
         Just $ emptyHPIMessage
           { SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiHostId = hostid
           , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiLocation = location
           , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiDeviceId = uuid
           , SSPL.sensorResponseMessageSensor_response_typeDisk_status_hpiWwn = wwn
           }
     }
