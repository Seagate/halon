{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- |
-- Module    : HA.Services.SSPL.LL.Resources
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Resources used by @halon:sspl-ll@ service.
module HA.Services.SSPL.LL.Resources
  ( AckReply(..)
  , ActuatorChannels(..)
  , ActuatorConf(..)
  , Channel(..)
  , CommandAck(..)
  , HA.Services.SSPL.LL.Resources.__remoteTable
  , IPMIOp(..)
  , InterestingEventMessage(..)
  , LedControlState(..)
  , LoggerCmd(..)
  , NodeCmd(..)
  , RaidCmd(..)
  , SSPLConf(..)
  , SensorConf(..)
  , SsplLlFromSvc(..)
  , SsplLlToSvc(..)
  , SystemdCmd(..)
  , configDictSSPLConf
  , configDictSSPLConf__static
  , formatTimeSSPL
  , interface
  , makeLoggerMsg
  , makeNodeMsg
  , makeSystemdMsg
  , myResourcesTable
  , nodeCmdString
  , parseNodeCmd
  , parseTimeSSPL
  , tryParseAckReply
  ) where

import           Control.Concurrent.STM (TChan)
import           Control.Distributed.Process (NodeId, ProcessId, SendPort)
import           Control.Distributed.Process.Closure
import           Control.Distributed.Static (RemoteTable)
import           Data.Binary (Binary, encode, decode)
import           Data.Defaultable
import           Data.Hashable (Hashable)
import           Data.Monoid ((<>))
import           Data.Serialize hiding (encode, decode)
import qualified Data.Text as T
import           Data.Time
import           Data.Typeable (Typeable)
import           Data.UUID (UUID)
import           GHC.Generics (Generic)
import           HA.Aeson hiding (encode, decode)
import           HA.ResourceGraph
import           HA.Resources (Has)
import           HA.Resources.Castor (Slot)
import           HA.SafeCopy
import qualified HA.Service
import           HA.Service.Interface
import           HA.Service.TH
import           HA.Services.SSPL.IEM (IEM)
import qualified HA.Services.SSPL.Rabbit as Rabbit
import           Language.Haskell.TH (mkName)
import           Options.Schema (Schema)
import           Options.Schema.Builder hiding (name, desc)
import           SSPL.Bindings
  ( ActuatorRequestMessageActuator_request_type (..)
  , ActuatorRequestMessageActuator_request_typeLogging (..)
  , ActuatorRequestMessageActuator_request_typeNode_controller (..)
  , ActuatorRequestMessageActuator_request_typeService_controller (..)
  , ActuatorResponseMessageActuator_response_typeThread_controller
  , SensorResponseMessageSensor_response_typeDisk_status_drivemanager
  , SensorResponseMessageSensor_response_typeDisk_status_hpi
  , SensorResponseMessageSensor_response_typeRaid_data
  , SensorResponseMessageSensor_response_typeService_watchdog
  )

--------------------------------------------------------------------------------
-- SSPL Control messages                                                      --
--------------------------------------------------------------------------------

-- | Interesting Event Message.
--   TODO Make this more interesting.
newtype InterestingEventMessage = InterestingEventMessage IEM
  deriving (Hashable, Typeable, Show, Eq)

-- | Possible operations to run on a service.
data ServiceOp = SERVICE_START | SERVICE_STOP | SERVICE_RESTART | SERVICE_STATUS
  deriving (Eq, Show, Generic, Typeable)

instance Binary ServiceOp
instance Hashable ServiceOp

-- | Convert 'ServiceOp' to an operation systemd understands.
serviceOpString :: ServiceOp -> T.Text
serviceOpString SERVICE_START = "start"
serviceOpString SERVICE_STOP = "stop"
serviceOpString SERVICE_RESTART = "restart"
serviceOpString SERVICE_STATUS = "status"

-- | systemd command: serivce name and operation to execute.
data SystemdCmd = SystemdCmd T.Text ServiceOp
  deriving (Eq, Show, Generic, Typeable)

instance Binary SystemdCmd
instance Hashable SystemdCmd

-- | IPMI operations.
data IPMIOp = IPMI_ON | IPMI_OFF | IPMI_CYCLE | IPMI_STATUS
  deriving (Eq, Show, Generic, Typeable)

instance Hashable IPMIOp

-- | Convert 'IPMIOp' to a string IPMI system can understand.
ipmiOpString :: IPMIOp -> T.Text
ipmiOpString IPMI_ON = "on"
ipmiOpString IPMI_OFF = "off"
ipmiOpString IPMI_CYCLE = "cycle"
ipmiOpString IPMI_STATUS = "status"

-- | Parse IPMI operation from upstream into 'IPMIOp'.
parseIPMIOp :: T.Text -> Maybe IPMIOp
parseIPMIOp t = case T.toLower t of
  "on"     -> Just IPMI_ON
  "off"    -> Just IPMI_OFF
  "cycle"  -> Just IPMI_CYCLE
  "status" -> Just IPMI_STATUS
  _        -> Nothing

-- | RAID related commands.
data RaidCmd =
    RaidFail !T.Text
  | RaidRemove !T.Text
  | RaidAdd !T.Text
  | RaidAssemble [T.Text]
  | RaidRun
  | RaidDetail
  | RaidStop
  deriving (Eq, Show, Generic, Typeable)

instance Hashable RaidCmd

-- | Convert raid command into format system can understand.
raidCmdToText :: T.Text -> RaidCmd -> T.Text
raidCmdToText dev (RaidFail x) = T.intercalate " " ["fail", dev, x]
raidCmdToText dev (RaidRemove x) = T.intercalate " " ["remove", dev, x]
raidCmdToText dev (RaidAdd x) = T.intercalate " " ["add", dev, x]
raidCmdToText dev (RaidAssemble xs) = T.intercalate " " $ ["assemble", dev] ++ xs
raidCmdToText dev RaidRun = T.intercalate " " ["run", dev]
raidCmdToText dev RaidDetail = T.intercalate " " ["detail", dev]
raidCmdToText dev RaidStop = T.intercalate " " ["stop", dev]

-- | Possible LED states we can set.
data LedControlState
      = FaultOn
      | FaultOff
      | IdentifyOn
      | IdentifyOff
      | PulseSlowOn
      | PulseSlowOff
      | PulseFastOn
      | PulseFastOff
      deriving (Eq, Show, Generic, Typeable)

instance Hashable LedControlState
storageIndex ''LedControlState "4689d3b3-1597-4a79-a68a-8a20a06f4fe0"
instance ToJSON LedControlState

-- | Node commands we can request.
data NodeCmd
  = IPMICmd !IPMIOp !T.Text -- ^ IP address
  | DriveReset !T.Text     -- ^ Reset drive
  | DrivePowerdown !T.Text -- ^ Powerdown drive
  | DrivePoweron !T.Text   -- ^ Poweron drive
  | SmartTest  !T.Text     -- ^ SMART drive test
  | DriveLed !T.Text !LedControlState -- ^ Set led style
  | DriveLedColor !T.Text !(Int, Int, Int) -- ^ Set led color
  | NodeRaidCmd !T.Text !RaidCmd -- ^ RAID device, command
  | SwapEnable !Bool -- ^ Enable/disable swap on the node
  | Mount !T.Text -- ^ Mount the mountpoint
  | Unmount !T.Text -- ^ Unmount
  deriving (Eq, Show, Generic, Typeable)
instance Hashable NodeCmd

-- | Convert control state to text.
controlStateToText :: LedControlState -> T.Text
controlStateToText FaultOn      = "FAULT_ON"
controlStateToText FaultOff     = "FAULT_OFF"
controlStateToText IdentifyOn   = "IDENTIFY_ON"
controlStateToText IdentifyOff  = "IDENTIFY_ON"
controlStateToText PulseSlowOn  = "PULSE_SLOW_ON"
controlStateToText PulseSlowOff = "PULSE_SLOW_OFF"
controlStateToText PulseFastOn  = "PULSE_FAST_ON"
controlStateToText PulseFastOff = "PULSE_FAST_OFF"

-- | Parse control state back.
parseControlState :: T.Text -> Either T.Text LedControlState
parseControlState t
  | t == controlStateToText FaultOn      = Right FaultOn
  | t == controlStateToText FaultOff     = Right FaultOff
  | t == controlStateToText IdentifyOn   = Right IdentifyOn
  | t == controlStateToText IdentifyOff  = Right IdentifyOff
  | t == controlStateToText PulseSlowOn  = Right PulseSlowOn
  | t == controlStateToText PulseSlowOff = Right PulseSlowOff
  | t == controlStateToText PulseFastOn  = Right PulseFastOn
  | t == controlStateToText PulseFastOff = Right PulseFastOff
  | otherwise                            = Left "Unknown state"

-- | Convert @NodeCmd@ to text representation.
nodeCmdString :: NodeCmd -> T.Text
nodeCmdString (IPMICmd op ip) = T.intercalate " "
  [ "IPMI:", ip, ipmiOpString op ]
nodeCmdString (DriveReset drive) = T.intercalate " "
  [ "RESET_DRIVE:", drive ]
nodeCmdString (DrivePowerdown drive) = T.intercalate " "
  [ "STOP_DRIVE:", drive ]
nodeCmdString (DrivePoweron drive) = T.intercalate " "
  [ "START_DRIVE:", drive ]
nodeCmdString (SmartTest drive) = T.intercalate " "
  [ "SMART_TEST:", drive ]
nodeCmdString (DriveLed drive state) = T.intercalate " "
  ["LED: set", drive,  controlStateToText state]
nodeCmdString (DriveLedColor _ _) =
  "BEZEL: [{default},7]" -- XXX: not yet supported
nodeCmdString (NodeRaidCmd dev cmd) = T.intercalate " "
  ["RAID:", raidCmdToText dev cmd]
nodeCmdString (SwapEnable x) = T.intercalate " "
  ["SSPL:", "SWAP", case x of True -> "ON"; False -> "OFF"]
nodeCmdString (Mount x) = T.intercalate " "
  ["SSPL:", "MOUNT", x]
nodeCmdString (Unmount x) = T.intercalate " "
  ["SSPL:", "UMOUNT", x]


-- | Convert @NodeCmd@ back from a text representation.
parseNodeCmd :: T.Text -> Maybe NodeCmd
parseNodeCmd t = case T.words t of
  ["IPMI:", ip, opt] -> do
    op <- parseIPMIOp opt
    return $ IPMICmd op ip
  "RESET_DRIVE:" : opt : _ -> return $ DriveReset opt
  "DRIVE_POWERDOWN:" : opt : _ -> return $ DrivePowerdown opt
  "DRIVE_POWERON:" : opt : _ -> return $ DrivePoweron opt
  "SMART_TEST:" : opt : _  -> return $ SmartTest opt
  "LED:" : "set" : drive : st : _ -> do
    either (const Nothing) (Just . DriveLed drive) (parseControlState st)
  _ -> Nothing

-- | Logger actuator command
data LoggerCmd = LoggerCmd
       { lcMsg :: !T.Text
       , lcLevel :: !T.Text
       , lcType  :: !T.Text
       } deriving (Eq, Show, Generic, Typeable)
instance Binary LoggerCmd

-- | Actuator reply.
data AckReply = AckReplyPassed        -- ^ Request succesfully processed.
              | AckReplyFailed        -- ^ Request failed.
              | AckReplyError !T.Text -- ^ Error while processing request.
              deriving (Eq, Show, Generic, Typeable)

-- | Parse text representation of the @AckReply@
tryParseAckReply :: T.Text -> Either String AckReply
tryParseAckReply "Passed" = Right AckReplyPassed
tryParseAckReply "Failed" = Right AckReplyFailed
tryParseAckReply t
  | errmsg `T.isPrefixOf` t = Right $ AckReplyError $ T.drop (T.length errmsg) t
  | success `T.isPrefixOf` t = Right AckReplyPassed
  | otherwise               = Left $ "parseAckReply: unknown reply (" ++ T.unpack t ++ ")"
  where errmsg = "Error: "
        success = "Success"

-- | Reply over 'CommandAck' channel.
data CommandAck = CommandAck
  { commandAckUUID :: Maybe UUID    -- ^ Unique identifier.
  , commandAckType :: Maybe NodeCmd -- ^ Command text message.
  , commandAck     :: !AckReply     -- ^ Command result.
  } deriving (Eq, Show, Generic, Typeable)

emptyActuatorMsg :: ActuatorRequestMessageActuator_request_type
emptyActuatorMsg = ActuatorRequestMessageActuator_request_type
  { actuatorRequestMessageActuator_request_typeThread_controller = Nothing
  , actuatorRequestMessageActuator_request_typeLogin_controller = Nothing
  , actuatorRequestMessageActuator_request_typeNode_controller = Nothing
  , actuatorRequestMessageActuator_request_typeLogging = Nothing
  , actuatorRequestMessageActuator_request_typeService_controller = Nothing
  }

makeSystemdMsg :: SystemdCmd -> ActuatorRequestMessageActuator_request_type
makeSystemdMsg (SystemdCmd svcName op) = emptyActuatorMsg {
  actuatorRequestMessageActuator_request_typeService_controller = Just $
    ActuatorRequestMessageActuator_request_typeService_controller
      svcName (serviceOpString op)
}

makeNodeMsg :: NodeCmd -> ActuatorRequestMessageActuator_request_type
makeNodeMsg nc = emptyActuatorMsg {
  actuatorRequestMessageActuator_request_typeNode_controller = Just $
    ActuatorRequestMessageActuator_request_typeNode_controller
      (nodeCmdString nc)
}

makeLoggerMsg :: LoggerCmd -> ActuatorRequestMessageActuator_request_type
makeLoggerMsg lc = emptyActuatorMsg {
  actuatorRequestMessageActuator_request_typeLogging = Just $
    ActuatorRequestMessageActuator_request_typeLogging
      { actuatorRequestMessageActuator_request_typeLoggingLog_msg = lcMsg lc
      , actuatorRequestMessageActuator_request_typeLoggingLog_level = Just (lcLevel lc)
      , actuatorRequestMessageActuator_request_typeLoggingLog_type = lcType lc
      }
  }

--------------------------------------------------------------------------------
-- Channels                                                                   --
--------------------------------------------------------------------------------

-- | Actuator channel list
data ActuatorChannels = ActuatorChannels
    { iemPort :: TChan InterestingEventMessage
    , systemdPort :: TChan (Maybe UUID, ActuatorRequestMessageActuator_request_type)
    }
  deriving (Generic, Typeable)

-- | Resource graph representation of a channel
newtype Channel a = Channel (SendPort a)
  deriving (Eq, Show, Typeable, Binary, Hashable)

instance (Typeable a, Binary a) => SafeCopy (Channel a) where
  putCopy (Channel sp) = contain $ put (encode sp)
  getCopy = contain $ Channel . decode <$> get

--------------------------------------------------------------------------------
-- Configuration                                                              --
--------------------------------------------------------------------------------

-- | 'Schema' for IEM bind configuration.
iemSchema :: Schema Rabbit.BindConf
iemSchema = genericBindConf ("sspl-in",   "iem-exchange")
                            ("iem-key",   "iem-routing-key")
                            ("iem-queue", "iem-queue")

-- | 'Schema' for command bind configuration.
commandSchema :: Schema Rabbit.BindConf
commandSchema = genericBindConf ("sspl-in",            "actuator-exchange")
                                ("actuator-req-key",   "actuator-routing-key")
                                ("actuator-req-queue", "actuator-queue")

-- | 'Schema' for command ack bind configuration.
commandAckSchema :: Schema Rabbit.BindConf
commandAckSchema = genericBindConf ("sspl-out",            "actuator-resp-exchange")
                                   ("actuator-resp-key",   "actuator-resp-routing-key")
                                   ("actuator-resp-queue", "actuator-resp-queue")

-- | 'Schema' for sensor bind configuration. See also 'sensorSchema'.
dcsSchema :: Schema Rabbit.BindConf
dcsSchema = genericBindConf ("sspl-out",     "sensor-exchange")
                            ("sensor-key",   "sensor-routing-key")
                            ("sensor-queue", "sensor-queue")

-- | Generic 'Schema' creating 'Rabbit.BindConf' on the given
-- @genericBindConf exchange route queue@.
genericBindConf :: (String, String) -> (String, String) -> (String, String)
                -> Schema Rabbit.BindConf
{-# INLINE genericBindConf #-}
genericBindConf (exchange, exchangeLong)
                (routingKey, routingKeyLong)
                (queue, queueLong) = Rabbit.BindConf <$> en <*> rk <*> qn
  where
    en = defaultable exchange . strOption
       $ long exchangeLong
       <> metavar "EXCHANGE-NAME"
    rk = defaultable routingKey . strOption
       $ long routingKeyLong
       <> metavar "ROUTING-KEY"
    qn = defaultable queue . strOption
       $ long queueLong
       <> metavar "QUEUE-NAME"

data ActuatorConf = ActuatorConf {
    acIEM :: Rabbit.BindConf
  , acSystemd :: Rabbit.BindConf
  , acCommandAck :: Rabbit.BindConf
  , acDeclareChanTimeout :: Defaultable Int
} deriving (Eq, Generic, Show, Typeable)

instance Hashable ActuatorConf
instance ToJSON ActuatorConf where
  toJSON (ActuatorConf iem systemd command timeout) =
    object [ "iem" .= iem
           , "systemd" .= systemd
           , "commands" .= command
           , "timeout"  .= fromDefault timeout
           ]

-- | 'Schema' for actuator.
actuatorSchema :: Schema ActuatorConf
actuatorSchema = compositeOption subOpts
                  $ long "actuator"
                  <> summary "Actuator configuration."
  where
    subOpts = ActuatorConf <$> iemSchema <*> commandSchema <*> commandAckSchema <*> timeout
    timeout = defaultable 5000000 . intOption
                $ long "declareChannelsTimeout"
                <> summary "Timeout to use when declaring channels to the RC."
                <> metavar "MICROSECONDS"

-- | Sensor configuration
data SensorConf = SensorConf {
    scDCS :: Rabbit.BindConf
    -- ^ Binds to DCS; see 'dcsSchema'.
} deriving (Eq, Generic, Show, Typeable)

instance Hashable SensorConf
instance ToJSON SensorConf

-- | 'Schema' for 'SensorConf'.
sensorSchema :: Schema SensorConf
sensorSchema = compositeOption subOpts
                  $ long "sensor"
                  <> summary "Sensor configuration."
  where
    subOpts = SensorConf <$> dcsSchema

-- | Values that can be sent from RC to the SSPL-HL service.
data SsplLlToSvc
  = SsplIem !InterestingEventMessage
  | SystemdMessage !(Maybe UUID) !ActuatorRequestMessageActuator_request_type
  | ResetSSPLService
  deriving (Show, Eq)

-- | Values that can be sent from RC to the SSPL-HL service.
data SsplLlFromSvc
  = CAck CommandAck
  | SSPLServiceTimeout !NodeId
  | SSPLConnectFailure !NodeId
  | DiskHpi !NodeId !SensorResponseMessageSensor_response_typeDisk_status_hpi
  | DiskStatusDm !NodeId !SensorResponseMessageSensor_response_typeDisk_status_drivemanager
  | ServiceWatchdog !SensorResponseMessageSensor_response_typeService_watchdog
  | RaidData !NodeId !SensorResponseMessageSensor_response_typeRaid_data
  | ThreadController !NodeId !ActuatorResponseMessageActuator_response_typeThread_controller
  | ExpanderResetInternal !NodeId
  deriving (Show, Eq)

-- | SSPL service configuration.
data SSPLConf = SSPLConf
  { scConnectionConf :: Rabbit.ConnectionConf
  -- ^ Connection configuration.
  , scSensorConf :: SensorConf
  -- ^ Sensor configuration.
  , scActuatorConf :: ActuatorConf
  -- ^ Actuator configuration.
  } deriving (Eq, Generic, Show, Typeable)

type instance HA.Service.ServiceState SSPLConf = ProcessId

instance Hashable SSPLConf
instance ToJSON SSPLConf
storageIndex ''SSPLConf "2f3e5559-c3f2-4e02-9ce5-3e5d2d231ea6"
serviceStorageIndex ''SSPLConf "d54e9eaf-c1a5-4ea7-96d6-7fbdb29bd277"

instance HA.Service.HasInterface SSPLConf where
  type ToSvc SSPLConf = SsplLlToSvc
  type FromSvc SSPLConf = SsplLlFromSvc
  getInterface _ = interface

-- | SSPL-LL 'Interface
interface :: Interface SsplLlToSvc SsplLlFromSvc
interface = Interface
  { ifVersion = 0
  , ifServiceName = "sspl"
  , ifEncodeToSvc = \_v -> Just . safeEncode interface
  , ifDecodeToSvc = safeDecode
  , ifEncodeFromSvc = \_v -> Just . safeEncode interface
  , ifDecodeFromSvc = safeDecode
  }

-- | SSPL configuration 'Schema'.
ssplSchema :: Schema SSPLConf
ssplSchema = SSPLConf
            <$> Rabbit.connectionSchema
            <*> sensorSchema
            <*> actuatorSchema

ssplTimeFormatString :: String
ssplTimeFormatString = "%Y-%m-%d %H:%M:%S%Q"

-- | Format 'UTCTime' into SSPL-friendly string.
formatTimeSSPL :: UTCTime -> T.Text
formatTimeSSPL = T.pack . formatTime defaultTimeLocale ssplTimeFormatString

-- | Parse time from SSPL into a more usable 'UTCTime'.
parseTimeSSPL :: Monad m => T.Text -> m UTCTime
parseTimeSSPL = parseTimeM True defaultTimeLocale ssplTimeFormatString . T.unpack

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

mkDictsQ
  [ (mkName "resourceDictLedControlState", [t| LedControlState |])
  ]
  [ (mkName "relationDictLedControlStateSlot"
    ,  ([t| Slot|], [t| Has |], [t| LedControlState |]))
  ]
mkStorageDictsQ
  [ (mkName "storageDictLedControlState", [t| LedControlState |])
  ]
  [ (mkName "storageDictLedControlStateSlot"
    ,  ([t| Slot|], [t| Has |], [t| LedControlState |]))
  ]
generateDicts ''SSPLConf
deriveService ''SSPLConf 'ssplSchema
  [ 'resourceDictLedControlState
  , 'relationDictLedControlStateSlot
  , 'storageDictLedControlState
  , 'storageDictLedControlStateSlot
  ]
mkStorageResRelQ
  [ (mkName "storageDictLedControlState", [t| LedControlState |])
  ]
  [ (mkName "storageDictLedControlStateSlot"
    ,  ([t| Slot|], [t| Has |], [t| LedControlState |]))
  ]

instance Resource LedControlState where
  resourceDict = $(mkStatic 'resourceDictLedControlState)

instance Relation Has Slot LedControlState where
  type CardinalityFrom Has Slot LedControlState = 'Unbounded
  type CardinalityTo Has Slot LedControlState = 'AtMostOne
  relationDict = $(mkStatic 'relationDictLedControlStateSlot)

myResourcesTable :: RemoteTable -> RemoteTable
myResourcesTable
  = $(makeResource [t| LedControlState |])
  . $(makeRelation [t| Slot |] [t| Has |] [t| LedControlState |])
  . HA.Services.SSPL.LL.Resources.__resourcesTable

--------------------------------------------------------------------------------
-- End Dictionaries                                                           --
--------------------------------------------------------------------------------

deriveSafeCopy 0 'base ''AckReply
deriveSafeCopy 0 'base ''ActuatorConf
deriveSafeCopy 0 'base ''CommandAck
deriveSafeCopy 0 'base ''IPMIOp
deriveSafeCopy 0 'base ''InterestingEventMessage
deriveSafeCopy 0 'base ''LedControlState
deriveSafeCopy 0 'base ''NodeCmd
deriveSafeCopy 0 'base ''RaidCmd
deriveSafeCopy 0 'base ''SSPLConf
deriveSafeCopy 0 'base ''SensorConf
deriveSafeCopy 0 'base ''SsplLlFromSvc
deriveSafeCopy 0 'base ''SsplLlToSvc
