{-# LANGUAGE DeriveGeneric         #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
-- Logging functionality for CEP.
module Network.CEP.Log where

import Data.Aeson (ToJSON, FromJSON)
import Data.Binary (Binary)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

-- | Used to document jumps. This is a restricted version of
--   'Network.CEP.Types.Jump PhaseHandle'
--   which can be easily displayed.
data Jump =
    NormalJump String
  | TimeoutJump Int String
  deriving (Show, Generic, Typeable)

instance Binary Jump
instance ToJSON Jump
instance FromJSON Jump

-- | Identifies the location of a logging statement.
data Location = Location {
    loc_rule_name :: String
  , loc_sm_id :: Int64
  , loc_phase_name :: String
} deriving (Eq, Show, Generic, Typeable)

instance Binary Location
instance ToJSON Location
instance FromJSON Location

-- | Used to document forks. We define this type here as we don't want to
--   expose CEP internal types to the logging framework (and, more prosaically,
--   it avoids a circular import problem with Network.CEP.Types).
data ForkType = NoBuffer | CopyBuffer | CopyNewerBuffer
  deriving (Show, Generic, Typeable)

instance Binary ForkType
instance ToJSON ForkType
instance FromJSON ForkType

-- | Emitted when a call to 'fork' is made.
data ForkInfo = ForkInfo {
    f_buffer_type :: ForkType -- ^ How much of the buffer
                              --   should be copied to the child rule?
  , f_sm_child_id :: Int64 -- ^ ID of the child SM
} deriving (Generic, Typeable)

instance Binary ForkInfo
instance ToJSON ForkInfo
instance FromJSON ForkInfo

data ContinueInfo = ContinueInfo {
    c_continue_phase :: Jump -- ^ Phase to continue to.
} deriving (Generic, Typeable)

instance Binary ContinueInfo
instance ToJSON ContinueInfo
instance FromJSON ContinueInfo

data SwitchInfo = SwitchInfo {
    s_switch_phases :: [Jump] -- ^ Phases to switch on.
} deriving (Generic, Typeable)

instance Binary SwitchInfo
instance ToJSON SwitchInfo
instance FromJSON SwitchInfo

-- | Currently, whenever a rule "normally" terminates, it restarts at its
--   beginning phase. This event documents that.
data RestartInfo = RestartInfo {
    r_restarting_from_phase :: String -- ^ Phase to restart from.
} deriving (Generic, Typeable)

instance Binary RestartInfo
instance ToJSON RestartInfo
instance FromJSON RestartInfo

-- | Emitted whenever a legacy call to 'phaseLog' is made.
data PhaseLogInfo = PhaseLogInfo {
    pl_key :: String
  , pl_value :: String
} deriving (Generic, Typeable)

instance Binary PhaseLogInfo
instance ToJSON PhaseLogInfo
instance FromJSON PhaseLogInfo

-- | Emitted whenever an application log is made from the underlying
--   application.
data ApplicationLogInfo a = ApplicationLogInfo {
    al_value :: a
} deriving (Generic, Typeable)

instance Binary a => Binary (ApplicationLogInfo a)
instance ToJSON a => ToJSON (ApplicationLogInfo a)
instance FromJSON a => FromJSON (ApplicationLogInfo a)

-- | Environment used to capture local state.
type Environment = Map.Map String String

data StateLogInfo = StateLogInfo {
    sl_state :: Environment
} deriving (Generic, Typeable)

instance Binary StateLogInfo
instance ToJSON StateLogInfo
instance FromJSON StateLogInfo

-- | Full set of log events which may be emitted from CEP, with an underlying
--   application emitting log events of type 'a'.
data CEPLog a =
    Fork ForkInfo
    -- ^ Emitted when a call to 'fork' is made.
  | Continue ContinueInfo
    -- ^ Emitted when a call to 'continue' is made.
  | Switch SwitchInfo
    -- ^ Emitted when a call to 'switch' is made.
  | Stop
    -- ^ Emitted whenever a direct call to 'stop' is made, terminating the SM.
  | Suspend
    -- ^ Emitted when the SM suspends (outside of switch mode).
  | Restart RestartInfo
  | PhaseEntry
    -- ^ Emitted whenever the body of a phase begins processing.
  | PhaseLog PhaseLogInfo
  | StateLog StateLogInfo
  | ApplicationLog (ApplicationLogInfo a)
  deriving (Generic, Typeable)

instance (Binary a) => Binary (CEPLog a)
instance ToJSON a => ToJSON (CEPLog a)
instance FromJSON a => FromJSON (CEPLog a)

-- | An event is a log message plus a location where it occurred.
data Event a = Event {
    evt_loc :: Location
  , evt_log :: CEPLog a
} deriving (Generic, Typeable)

instance (Binary a) => Binary (Event a)
instance ToJSON a => ToJSON (Event a)
instance FromJSON a => FromJSON (Event a)
