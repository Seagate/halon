-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module HA.Services.SSPL.LL.Resources where

import Control.Distributed.Process (NodeId)

import HA.SafeCopy.OrphanInstances()
import HA.Service.TH
import HA.Services.SSPL.IEM
import qualified HA.Services.SSPL.Rabbit as Rabbit
import qualified HA.Resources as R
import HA.ResourceGraph

import Prelude

import SSPL.Bindings
  ( ActuatorRequestMessageActuator_request_type (..)
  , ActuatorRequestMessageActuator_request_typeService_controller (..)
  , ActuatorRequestMessageActuator_request_typeNode_controller (..)
  , ActuatorRequestMessageActuator_request_typeLogging (..)
  )

import Control.Distributed.Process
  ( ProcessId
  , SendPort
  )
import Control.Distributed.Process.Closure

import Data.Aeson hiding (encode, decode)
import Data.Binary (Binary, encode, decode)
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Time
import qualified Data.Text as T
import Data.SafeCopy
import Data.Serialize hiding (encode, decode)
import Data.Typeable (Typeable)
import Data.UUID (UUID)

import GHC.Generics (Generic)

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

import System.IO.Unsafe (unsafePerformIO)
import System.Process (readProcess)

--------------------------------------------------------------------------------
-- SSPL Control messages                                                      --
--------------------------------------------------------------------------------

-- | Interesting Event Message.
--   TODO Make this more interesting.
newtype InterestingEventMessage = InterestingEventMessage IEM
  deriving (Binary, Hashable, Typeable)

data ServiceOp = SERVICE_START | SERVICE_STOP | SERVICE_RESTART | SERVICE_STATUS
  deriving (Eq, Show, Generic, Typeable)

instance Binary ServiceOp
instance Hashable ServiceOp

serviceOpString :: ServiceOp -> T.Text
serviceOpString SERVICE_START = "start"
serviceOpString SERVICE_STOP = "stop"
serviceOpString SERVICE_RESTART = "restart"
serviceOpString SERVICE_STATUS = "status"

data SystemdCmd = SystemdCmd T.Text ServiceOp
  deriving (Eq, Show, Generic, Typeable)

instance Binary SystemdCmd
instance Hashable SystemdCmd

data IPMIOp = IPMI_ON | IPMI_OFF | IPMI_CYCLE | IPMI_STATUS
  deriving (Eq, Show, Generic, Typeable)

instance Binary IPMIOp
instance Hashable IPMIOp

ipmiOpString :: IPMIOp -> T.Text
ipmiOpString IPMI_ON = "on"
ipmiOpString IPMI_OFF = "off"
ipmiOpString IPMI_CYCLE = "cycle"
ipmiOpString IPMI_STATUS = "status"

parseIPMIOp :: T.Text -> Maybe IPMIOp
parseIPMIOp t = case (T.toLower t) of
  "on"     -> Just IPMI_ON
  "off"    -> Just IPMI_OFF
  "cycle"  -> Just IPMI_CYCLE
  "status" -> Just IPMI_STATUS
  _        -> Nothing

-- | RAID related commands.
data RaidCmd =
    RaidFail T.Text
  | RaidRemove T.Text
  | RaidAdd T.Text
  | RaidAssemble [T.Text]
  | RaidRun
  | RaidDetail
  | RaidStop
  deriving (Eq, Show, Generic, Typeable)

instance Binary RaidCmd
instance Hashable RaidCmd

raidCmdToText :: T.Text -> RaidCmd -> T.Text
raidCmdToText dev (RaidFail x) = T.intercalate " " ["fail", dev, x]
raidCmdToText dev (RaidRemove x) = T.intercalate " " ["remove", dev, x]
raidCmdToText dev (RaidAdd x) = T.intercalate " " ["add", dev, x]
raidCmdToText dev (RaidAssemble xs) = T.intercalate " " $ ["assemble", dev] ++ xs
raidCmdToText dev RaidRun = T.intercalate " " ["run", dev]
raidCmdToText dev RaidDetail = T.intercalate " " ["detail", dev]
raidCmdToText dev RaidStop = T.intercalate " " ["stop", dev]

data NodeCmd
  = IPMICmd IPMIOp T.Text -- ^ IP address
  | DriveReset T.Text     -- ^ Reset drive
  | DrivePowerdown T.Text -- ^ Powerdown drive
  | DrivePoweron T.Text   -- ^ Poweron drive
  | SmartTest  T.Text     -- ^ SMART drive test
  | DriveLed T.Text LedControlState -- ^ Set led style
  | DriveLedColor T.Text (Int, Int, Int) -- ^ Set led color
  | NodeRaidCmd T.Text RaidCmd -- ^ RAID device, command
  | SwapEnable Bool -- ^ Enable/disable swap on the node
  | Mount T.Text -- ^ Mount the mountpoint
  | Unmount T.Text -- ^ Unmount
  deriving (Eq, Show, Generic, Typeable)

instance Binary NodeCmd
instance Hashable NodeCmd

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

instance Binary LedControlState
instance Hashable LedControlState

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

-- | LED color priority.
halonPriority :: Int
halonPriority = 7

-- | Convert @NodeCmd@ to text represetnation.
nodeCmdString :: NodeCmd -> T.Text
nodeCmdString (IPMICmd op ip) = T.intercalate " "
  [ "IPMI:", ip, ipmiOpString op ]
nodeCmdString (DriveReset drive) = T.intercalate " "
  [ "RESET_DRIVE:", drive ]
nodeCmdString (DrivePowerdown drive) = T.intercalate " "
  [ "STOP_DRIVE:", drive ]
nodeCmdString (DrivePoweron drive) = T.intercalate " "
  [ "DONT_START_DRIVE:", drive ]
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
parseNodeCmd t =
    case cmd of
      "IPMI:"        -> do [ip, opt] <- return rest
                           op <- parseIPMIOp opt
                           return $ IPMICmd op ip
      "RESET_DRIVE:" -> return $ DriveReset (head rest)
      "DRIVE_POWERDOWN:" -> return $ DrivePowerdown (head rest)
      "DRIVE_POWERON:" -> return $ DrivePoweron (head rest)
      "SMART_TEST:"  -> return $ SmartTest (head rest)
      "LED:" -> case rest of
         ("set":drive:st:_) ->
            either (const Nothing) (Just . DriveLed drive) (parseControlState st)
         _ -> Nothing
      _ -> Nothing
  where
    (cmd:rest) = T.words t

data LoggerCmd = LoggerCmd
       { lcMsg :: T.Text
       , lcLevel :: T.Text
       , lcType  :: T.Text
       } deriving (Eq, Show, Generic, Typeable)

-- | Actuator reply.
data AckReply = AckReplyPassed       -- ^ Request succesfully processed.
              | AckReplyFailed       -- ^ Request failed.
              | AckReplyError T.Text -- ^ Error while processing request.
              deriving (Eq, Show, Generic, Typeable)

instance Binary AckReply

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
  , commandAck     :: AckReply      -- ^ Command result.
  } deriving (Eq, Show, Generic, Typeable)

instance Binary CommandAck

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
-- Events
--------------------------------------------------------------------------------

-- | Event that sspl service didn't receive any messages in time.
newtype SSPLServiceTimeout = SSPLServiceTimeout NodeId
  deriving (Eq, Show, Binary, Typeable)

-- | Request hard SSPL service restart.
data ResetSSPLService = ResetSSPLService
  deriving (Eq, Show, Generic, Typeable)

instance Binary ResetSSPLService

data RequestChannels = RequestChannels
  deriving (Eq, Show, Generic, Typeable)

instance Binary RequestChannels

-- | Event happens when SSPL can't connect to Rabbit-MQ broker
newtype SSPLConnectFailure = SSPLConnectFailure NodeId
   deriving (Eq, Show, Binary, Typeable)

-- | Event representing an expander reset, which is otherwise
--   an empty message.
data ExpanderResetInternal = ExpanderResetInternal
  deriving (Eq, Show, Generic, Typeable)

instance Binary ExpanderResetInternal

--------------------------------------------------------------------------------
-- Channels                                                                   --
--------------------------------------------------------------------------------

-- | Actuator channel list
data ActuatorChannels = ActuatorChannels
    { iemPort :: SendPort InterestingEventMessage
    , systemdPort :: SendPort (Maybe UUID, ActuatorRequestMessageActuator_request_type)
    }
  deriving (Generic, Typeable)

instance Binary ActuatorChannels
instance Hashable ActuatorChannels

-- | Message to the RC advertising which channels to talk on.
data DeclareChannels = DeclareChannels
    ProcessId -- Identity of reporting process
    ActuatorChannels -- Relevant channels
  deriving (Generic, Typeable)

instance Binary DeclareChannels
instance Hashable DeclareChannels

-- | Resource graph representation of a channel
newtype Channel a = Channel (SendPort a)
  deriving (Eq, Show, Typeable, Binary, Hashable)

instance (Typeable a, Binary a) => SafeCopy (Channel a) where
  putCopy (Channel sp) = contain $ put (encode sp)
  getCopy = contain $ Channel . decode <$> get

-- | Relation connecting the SSPL service process to its IEM channel.
data IEMChannel = IEMChannel
  deriving (Eq, Show, Typeable, Generic)

deriveSafeCopy 0 'base ''IEMChannel
instance Binary IEMChannel
instance Hashable IEMChannel

data CommandChannel = CommandChannel
  deriving (Eq, Show, Typeable, Generic)

deriveSafeCopy 0 'base ''CommandChannel
instance Binary CommandChannel
instance Hashable CommandChannel

--------------------------------------------------------------------------------
-- Configuration                                                              --
--------------------------------------------------------------------------------

iemSchema :: Schema Rabbit.BindConf
iemSchema = genericBindConf ("sspl_iem", "iem_exchange")
                            ("sspl_ll",  "iem_routingKey")
                            ("sspl_iem", "dcs_queue")

commandSchema :: Schema Rabbit.BindConf
commandSchema = genericBindConf ("sspl_halon","systemd_exchange")
                                ("sspl_ll", "systemd_routingKey")
                                ("sspl_halon", "systemd_queue")

commandAckSchema :: Schema Rabbit.BindConf
commandAckSchema = genericBindConf ("sspl_command_ack", "command_ack_exchange")
                                   ("sspl_ll",      "command_ack_routing_key")
                                   ("sspl_command_ack", "command_ack_queue")

genericBindConf :: (String, String) -> (String,String) -> (String,String)
                -> Schema Rabbit.BindConf
{-# INLINE genericBindConf #-}
genericBindConf (exchange,exchangeLong)
                (routingKey,routingKeyLong)
                (queue, queueLong) = Rabbit.BindConf <$> en <*> rk <*> qn
  where
    en = defaultable exchange . strOption
       $ long exchangeLong
       <> metavar "EXCHANGE_NAME"
    rk = defaultable routingKey . strOption
       $ long routingKeyLong
       <> metavar "ROUTING_KEY"
    qn = defaultable queue . strOption
       $ long queueLong
       <> metavar "QUEUE_NAME"

data ActuatorConf = ActuatorConf {
    acIEM :: Rabbit.BindConf
  , acSystemd :: Rabbit.BindConf
  , acCommandAck :: Rabbit.BindConf
  , acDeclareChanTimeout :: Defaultable Int
} deriving (Eq, Generic, Show, Typeable)

instance Binary ActuatorConf
instance Hashable ActuatorConf
instance ToJSON ActuatorConf where
  toJSON (ActuatorConf iem systemd command timeout) =
    object [ "iem" .= iem
           , "systemd" .= systemd
           , "commands" .= command
           , "timeout"  .= fromDefault timeout
           ]
deriveSafeCopy 0 'base ''ActuatorConf

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

dcsSchema :: Schema Rabbit.BindConf
dcsSchema = let
    en = defaultable "sspl_halon" . strOption
        $ long "dcs_exchange"
        <> metavar "EXCHANGE_NAME"
    rk = defaultable "sspl_ll" . strOption
          $ long "dcs_routingKey"
          <> metavar "ROUTING_KEY"
    qn = defaultable shortHostName . strOption
          $ long "dcs_queue"
          <> metavar "QUEUE_NAME"
          where
            shortHostName = unsafePerformIO $ readProcess "hostname" ["-s"] ""
  in Rabbit.BindConf <$> en <*> rk <*> qn

data SensorConf = SensorConf {
    scDCS :: Rabbit.BindConf
} deriving (Eq, Generic, Show, Typeable)
deriveSafeCopy 0 'base ''SensorConf

instance Binary SensorConf
instance Hashable SensorConf
instance ToJSON SensorConf

sensorSchema :: Schema SensorConf
sensorSchema = compositeOption subOpts
                  $ long "sensor"
                  <> summary "Sensor configuration."
  where
    subOpts = SensorConf <$> dcsSchema

data SSPLConf = SSPLConf {
    scConnectionConf :: Rabbit.ConnectionConf
  , scSensorConf :: SensorConf
  , scActuatorConf :: ActuatorConf
} deriving (Eq, Generic, Show, Typeable)

instance Binary SSPLConf
instance Hashable SSPLConf
instance ToJSON SSPLConf
deriveSafeCopy 0 'base ''SSPLConf

ssplSchema :: Schema SSPLConf
ssplSchema = SSPLConf
            <$> Rabbit.connectionSchema
            <*> sensorSchema
            <*> actuatorSchema

ssplTimeFormatString :: String
ssplTimeFormatString = "%Y-%m-%d %H:%M:%S%Q"

formatTimeSSPL :: UTCTime -> T.Text
formatTimeSSPL = T.pack . formatTime defaultTimeLocale ssplTimeFormatString

parseTimeSSPL :: Monad m => T.Text -> m UTCTime
parseTimeSSPL = parseTimeM True defaultTimeLocale ssplTimeFormatString . T.unpack

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------
resourceDictChannelIEM :: Dict (Resource (Channel InterestingEventMessage))
resourceDictChannelIEM = Dict

resourceDictChannelSystemd :: Dict (Resource (Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type)))
resourceDictChannelSystemd = Dict

relationDictIEMChannelServiceProcessChannel :: Dict (
    Relation IEMChannel R.Node (Channel InterestingEventMessage)
  )
relationDictIEMChannelServiceProcessChannel = Dict

relationDictCommandChannelServiceProcessChannel :: Dict (
    Relation CommandChannel R.Node (Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type))
  )
relationDictCommandChannelServiceProcessChannel = Dict

$(generateDicts ''SSPLConf)
$(deriveService ''SSPLConf 'ssplSchema [ 'resourceDictChannelIEM
                                       , 'relationDictIEMChannelServiceProcessChannel
                                       , 'resourceDictChannelSystemd
                                       , 'relationDictCommandChannelServiceProcessChannel
                                       ])

instance Resource (Channel InterestingEventMessage) where
  resourceDict = $(mkStatic 'resourceDictChannelIEM)

instance Resource (Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type)) where
  resourceDict = $(mkStatic 'resourceDictChannelSystemd)

instance Relation IEMChannel
                  R.Node
                  (Channel InterestingEventMessage) where
  relationDict = $(mkStatic 'relationDictIEMChannelServiceProcessChannel)

instance Relation CommandChannel
                  R.Node
                  (Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type)) where
  relationDict = $(mkStatic 'relationDictCommandChannelServiceProcessChannel)
--------------------------------------------------------------------------------
-- End Dictionaries                                                           --
--------------------------------------------------------------------------------
