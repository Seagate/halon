{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.DecisionLog.Types where

import           Prelude hiding ((<$>))
import           Control.Applicative ((<|>))
import qualified Data.ByteString      as Strict
import qualified Data.ByteString.Lazy as Lazy
import           Data.Functor ((<$>))
import           Data.Monoid ((<>))
import           Data.Typeable
import           GHC.Generics

import Control.Distributed.Process (ProcessId, Process)
import Data.Binary
import Data.Hashable
import Options.Schema
import Options.Schema.Builder
import Network.CEP

import HA.Service.TH

data DecisionLogOutput
    = FileOutput FilePath
      -- ^ File path of a file.
    | ProcessOutput ProcessId
      -- ^ Sends any log to the specified 'Process'.
    | StandardOutput
      -- ^ Writes to stdout.
    deriving (Eq, Show, Generic)

instance Binary DecisionLogOutput
instance Hashable DecisionLogOutput

-- | Writes any log to a file. It will append the content from the end of the
--   file.
fileOutput :: FilePath -> DecisionLogOutput
fileOutput = FileOutput

-- | Sends any log to that 'Process'.
processOutput :: ProcessId -> DecisionLogOutput
processOutput = ProcessOutput


-- | Writes any log to stdout.
standardOutput :: DecisionLogOutput
standardOutput = StandardOutput

newtype DecisionLogConf = DecisionLogConf  DecisionLogOutput
    deriving (Eq, Generic, Show, Typeable)

instance Binary DecisionLogConf
instance Hashable DecisionLogConf

decisionLogSchema :: Schema DecisionLogConf
decisionLogSchema =
    let filepath = strOption
                   $  long "file"
                   <> short 'f'
                   <> metavar "DECISION_LOG_FILE" in
     DecisionLogConf <$> ((FileOutput <$> filepath) <|> pure StandardOutput)

$(generateDicts ''DecisionLogConf)
$(deriveService ''DecisionLogConf 'decisionLogSchema [])

data EntriesLogged =
    EntriesLogged
    { elRuleId  :: !Strict.ByteString
    , elInputs  :: !Lazy.ByteString
    , elEntries :: !Lazy.ByteString
    } deriving (Generic, Typeable)

instance Binary EntriesLogged

newtype WriteLogs = WriteLogs (Logs -> Process ())

writeLogs :: WriteLogs -> Logs -> Process ()
writeLogs (WriteLogs k) logs = k logs
