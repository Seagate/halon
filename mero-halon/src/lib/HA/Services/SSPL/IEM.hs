{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DefaultSignatures   #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
-- |
-- Module    : HA.Services.SSPL.IEM
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Module for generation log events in Telemetry message format.
--
-- For full specificaiton refer to <http://goo.gl/uM0J24>.
--
module HA.Services.SSPL.IEM
  ( IEMLog(..)
  , IEM
  , iemToText
  , iemToBytes
  , dumpCSV
  , LogLevel
  , logLevelToText
  -- * Commands
  -- ** Disks
  , logHalonDiskStatus
  , logRaidArrayFailure
  , logFailureOverK
  -- ** SSPL
  , logSSPLUnknownMessage
  -- ** Mero
  , logMeroRepairStart
  , logMeroRepairFinish
  , logMeroRepairQuiesce
  , logMeroRepairContinue
  , logMeroRepairAbort
  , logMeroRebalanceStart
  , logMeroRebalanceFinish
  , logMeroRebalanceQuiesce
  , logMeroRebalanceContinue
  , logMeroRebalanceAbort
  , logMeroClientFailed
  , logMeroBEError
  ) where

import           Data.ByteString (ByteString)
import           Data.Hashable
import           Data.List (intercalate)
import           Data.Monoid
import           Data.Proxy
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL
import           Data.Typeable
import           GHC.Generics
import           GHC.TypeLits
import qualified HA.Aeson as JSON
import           HA.SafeCopy


-- | Encoded interesting event message.
data IEM = IEM
  { iemEventCode :: Text -- ^ IEM Event code
  , iemEventText :: Text -- ^ Event code String
  , iemObject    :: Text -- ^ JSON formatted data containing metadata of
                         --   the event in the format of JSON encoded text
  } deriving (Eq, Show, Generic, Typeable, Ord)

instance Hashable IEM
deriveSafeCopy 0 'base ''IEM

-- | Interestng event message log.
data IEMLog = IEMLog IEM LogLevel deriving (Eq, Show)

-- | Severity of the event the log describes
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

-- | Convert LogLevel to text.
logLevelToText :: LogLevel -> Text
logLevelToText LOG_EMERG = "LOG_EMERG"
logLevelToText LOG_ALERT = "LOG_ALERT"
logLevelToText LOG_CRIT  = "LOG_CRIT"
logLevelToText LOG_ERR   = "LOG_ERR"
logLevelToText LOG_NOTICE = "LOG_NOTICE"
logLevelToText LOG_INFO   = "LOG_INFO"
logLevelToText LOG_DEBUG  = "LOG_DEBUG"

-- | Convert 'IEM' to 'Text' representation.
iemToText :: IEM -> Text
iemToText iem = Text.concat
  ["IEC: ", iemEventCode iem , " : ", iemEventText iem , " : ", iemObject iem]

-- | Convert an 'IEM' to 'ByteString'.
iemToBytes :: IEM -> ByteString
iemToBytes = Text.encodeUtf8  . iemToText

-- | IEM ID assigned to halon.
halonId :: Text
halonId = "038"

class ToMetadata a where
  toMetadata :: a -> Text
  default toMetadata :: JSON.ToJSON a => a -> Text
  toMetadata = TL.toStrict . TL.decodeUtf8 . JSON.encode

instance ToMetadata () where toMetadata _ = "{}"
instance ToMetadata Text where toMetadata = id

data Log (subsystem :: (Symbol,Symbol)) (code :: Symbol) (msg :: Symbol) a

type family Generator l where Generator (Log a b c d) = d -> IEM

type family Generators l where
  Generators '[]           = ()
  Generators (l ': ls) = (Generator l, Generators ls)

class Eta (a :: [*]) where mkCommands :: Proxy a -> (Generators a)
instance Eta '[] where mkCommands _ = ()
instance forall z s c m a as . (KnownSymbol s, KnownSymbol c, KnownSymbol m, ToMetadata a, Eta as) => Eta (Log '(z,s) c m a ': as) where
  mkCommands _ = ((IEM (halonId <> subsystemId <> messageId) shortMessage . toMetadata), mkCommands (Proxy :: Proxy as)) where
    subsystemId  = Text.pack $ symbolVal (Proxy :: Proxy s)
    messageId    = Text.pack $ symbolVal (Proxy :: Proxy c)
    shortMessage = Text.pack $ symbolVal (Proxy :: Proxy m)

class Kappa (a :: [*]) where mkCSV :: Proxy a -> String
instance Kappa '[] where mkCSV _ = ""
instance forall z s c m a as . (KnownSymbol s, KnownSymbol z, KnownSymbol c, KnownSymbol m, Kappa as) => Kappa (Log '(s,z) c m a ': as) where
   mkCSV _ = intercalate "," [halonName, Text.unpack halonId, subsystemName, subsystemId, shortMessage, messageId]
         ++ "\n"
         ++ mkCSV (Proxy :: Proxy as) where
     halonName = "Halon"
     subsystemName = symbolVal (Proxy :: Proxy s)
     subsystemId   = symbolVal (Proxy :: Proxy z)
     shortMessage  = symbolVal (Proxy :: Proxy m)
     messageId     = symbolVal (Proxy :: Proxy c)

-- | Output all interesting event messages halon can emit.
dumpCSV :: String
dumpCSV =
  "#Application name, Application id, Subsystem name, Subsystem id, Event description, Event id\n"
  ++ mkCSV (Proxy :: Proxy IECList)

---------------------------------------------------------------------------------
--  Boilerplate
---------------------------------------------------------------------------------
type Disks = '("Halon Disk Subsystem", "001")
type HalonDiskStatus       = Log Disks "001" "HALON DISK STATUS" Text
type RaidArrayFailure      = Log Disks "026" "Raid Array Failed" Text
type FailureOverK          = Log Disks "027" "Disk failure over tolerance" Text

type SSPL  = '("Halon SSPL Subsystem", "002")
type SSPLUnknownMessage    = Log SSPL  "042" "UNKNOWN MESSAGE"   Text

type Mero  = '("Halon Mero Subsystem", "003")
type MeroRepairStart       = Log Mero  "010" "Repair start" ()
type MeroRepairFinish      = Log Mero  "011" "Repair finish"     ()
type MeroRepairQuiesce     = Log Mero  "012" "Repair quiesce"    ()
type MeroRepairContinue    = Log Mero  "013" "Repair continue"   ()
type MeroRepairAbort       = Log Mero  "014" "Repair abort"      ()
type MeroRebalanceStart    = Log Mero  "020" "Rebalance start"      ()
type MeroRebalanceFinish   = Log Mero  "021" "Rebalance finish"     ()
type MeroRebalanceQuiesce  = Log Mero  "022" "Rebalance quiesce"    ()
type MeroRebalanceContinue = Log Mero  "023" "Rebalance continue"   ()
type MeroRebalanceAbort    = Log Mero  "024" "Rebalance abort"      ()
type MeroClientFailed      = Log Mero  "025" "Mero client failed" Text
type MeroBEError           = Log Mero  "026" "Mero BE error" Text

type IECList =
  '[ HalonDiskStatus
   , RaidArrayFailure
   , FailureOverK
   , SSPLUnknownMessage
   , MeroRepairStart
   , MeroRepairFinish
   , MeroRepairQuiesce
   , MeroRepairContinue
   , MeroRepairAbort
   , MeroRebalanceStart
   , MeroRebalanceFinish
   , MeroRebalanceQuiesce
   , MeroRebalanceContinue
   , MeroRebalanceAbort
   , MeroClientFailed
   , MeroBEError
   ]

-- | Used to create 'IEM's about halon disk status.
logHalonDiskStatus       :: Generator HalonDiskStatus

-- | Used to create 'IEM's about raid array failures.
logRaidArrayFailure      :: Generator RaidArrayFailure

-- | Used to create 'IEM's about disk failures occuring over failure
-- tolerance threshold.
logFailureOverK          :: Generator FailureOverK

-- | Used to create 'IEM's about receiving unknown SSPL messages.
logSSPLUnknownMessage    :: Generator SSPLUnknownMessage

-- | Used to create 'IEM's about SNS repair start.
logMeroRepairStart       :: Generator MeroRepairStart

-- | Used to create 'IEM's about SNS repair finish.
logMeroRepairFinish      :: Generator MeroRepairFinish

-- | Used to create 'IEM's about SNS repair quiesce.
logMeroRepairQuiesce     :: Generator MeroRepairQuiesce

-- | Used to create 'IEM's about SNS repair resuming.
logMeroRepairContinue    :: Generator MeroRepairContinue

-- | Used to create 'IEM's about SNS repair abort.
logMeroRepairAbort       :: Generator MeroRepairAbort

-- | Used to create 'IEM's about SNS rebalance start.
logMeroRebalanceStart    :: Generator MeroRebalanceStart

-- | Used to create 'IEM's about SNS rebalance finish.
logMeroRebalanceFinish   :: Generator MeroRebalanceFinish

-- | Used to create 'IEM's about SNS rebalance quiesce.
logMeroRebalanceQuiesce  :: Generator MeroRebalanceQuiesce

-- | Used to create 'IEM's about SNS rebalance resuming.
logMeroRebalanceContinue :: Generator MeroRebalanceContinue

-- | Used to create 'IEM's about SNS rebalance abort.
logMeroRebalanceAbort    :: Generator MeroRebalanceAbort

-- | Used to create 'IEM's about a mero client failing.
logMeroClientFailed      :: Generator MeroClientFailed

-- | Used to create 'IEM's about metadata backend errors.
logMeroBEError           :: Generator MeroBEError

(logHalonDiskStatus
 ,(logRaidArrayFailure
 ,(logFailureOverK
 ,(logSSPLUnknownMessage
 ,(logMeroRepairStart
 ,(logMeroRepairFinish
 ,(logMeroRepairQuiesce
 ,(logMeroRepairContinue
 ,(logMeroRepairAbort
 ,(logMeroRebalanceStart
 ,(logMeroRebalanceFinish
 ,(logMeroRebalanceQuiesce
 ,(logMeroRebalanceContinue
 ,(logMeroRebalanceAbort
 ,(logMeroClientFailed
 ,(logMeroBEError
 ,())))))))))))))))) = mkCommands (Proxy :: Proxy IECList)
