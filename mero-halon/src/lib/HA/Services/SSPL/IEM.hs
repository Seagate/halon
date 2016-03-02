{-# LANGUAGE OverloadedStrings #-}
-- | 
-- Module for generation log events in Telemetry message format.
--
-- For full specificaiton refer to <http:\/\/goo.gl\/uM0J24>.
--
module HA.Services.SSPL.IEM
  ( IEMLog(..)
  , IEM
  , iemToText
  , LogLevel
  , logLevelToText
    -- * Registered messages.
  , mkGenericMessage
    -- * Disk
  , mkDiskMessage
  , mkDiskStatusMessage
    -- * SSPL
  , mkSSPLMessage
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.Monoid

data IEMLog = IEMLog IEM LogLevel deriving (Eq, Show)

data IEM = IEM
  { iemEventCode :: Text -- ^ IEM Event code
  , iemEventText :: Text -- ^ Event code String
  , iemObject    :: Text -- ^ JSON formatted data containing metadata of
                         --   the event in the format of JSON encoded text
  } deriving (Eq, Show)

data LogLevel = LOG_EMERG -- ^ A panic condition was reported to all processes.
                          -- Examples: Something that will cause the node to immediately go down
              | LOG_ALERT -- ^ A condition that should be corrected immediately
              | LOG_CRIT  -- ^ A critical condition
              | LOG_ERR   -- ^ An error condition has occurred. Examples:
                          --     * A component has failed, but the system continues work slightly degraded.
                          --     * A SSU has failed to add correctly
              | LOG_NOTICE -- ^ A previous error condition has been resolved. Examples:
                           --     A previously failed component is back online
              | LOG_INFO -- ^ A general information message:
                         --    * A component has failed, but does not affect the day to day running of the custer
                         --    * The cluster has been put into daily mode
                         --    * A connection to a service has failed
                         --    * A new SSU Has been added
              | LOG_DEBUG -- ^ A messages useful for debugging programs
                         -- Examples:
                         --   * The user changes some configuration on the system
                         --   * The system has begun to evaluate a failed FRU
              deriving (Eq, Show)

logLevelToText :: LogLevel -> Text
logLevelToText LOG_EMERG = "LOG_EMERG"
logLevelToText LOG_ALERT = "LOG_ALERT"
logLevelToText LOG_CRIT  = "LOG_CRIT"
logLevelToText LOG_ERR   = "LOG_ERR"
logLevelToText LOG_NOTICE = "LOG_NOTICE"
logLevelToText LOG_INFO   = "LOG_INFO"
logLevelToText LOG_DEBUG  = "LOG_DEBUG"

-- | Convert IEM to text representation.
iemToText :: IEM -> Text
iemToText iem = Text.concat 
  ["IEM: ", iemEventCode iem , " : ", iemEventText iem , " : ", iemObject iem]

halonId :: Text
halonId = "038"

-- | Subsystem that logs a problem.
data Subsystem = Disks 
               | SSPL
               deriving (Eq, Show)

subsystemToId :: Subsystem -> Text
subsystemToId Disks = "001"
subsystemToID SSPL  = "002"


mkGenericMessage :: Subsystem -- ^ subsytem ID
                 -> Text      -- ^ Event ID
                 -> Text      -- ^ Event description
                 -> Text      -- ^ Metadata object
                 -> IEM
mkGenericMessage s i t m = IEM (halonId <> subsystemToId s <> i) t m


mkDiskMessage :: Text -- ^ Event ID
              -> Text -- ^ Event description
              -> Text -- ^ Metadata object
mkDiskMessage = mkGenericMessage Disks

mkDiskStatusMessage :: T.Text -- ^ Serial number
                    -> T.Text -- ^ Status
                    -> T.Text -- ^ Reason
                    -> IEM
mkDiskStatusMessage = mkDiskMessage "001" "HALON DISK STATUS" msg where
   msg = "{'status': '" <> st <> "', 'reason': '" <> reason <> "', 'serial_number': '" <> serial <> "'}"

mkSSPLMessage :: Text -- ^ Event ID
              -> Text -- ^ Event description
              -> Text -- ^ Metadata object
mkSSPLMessage = mkGenericMessage SSPL


type HALON = Subsystem "038"
type Disk
