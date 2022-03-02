{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- |
-- Module    : HA.Services.DecisionLog
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Types used throughout the decision log service.
module HA.Services.DecisionLog.Types where

import           Control.Distributed.Process hiding (bracket)
import           Data.Foldable (asum)
import           Data.Hashable
import           Data.Monoid ((<>))
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Typeable
import           GHC.Generics
import           HA.Aeson
import qualified HA.RecoveryCoordinator.Log as RC
import           HA.SafeCopy
import qualified HA.Service
import           HA.Service.Interface
import           HA.Service.TH
import qualified Network.CEP.Log as CEP
import           Options.Schema
import           Options.Schema.Builder


-- | Old version on 'DecisionLog'
data DecisionLogOutput_v0
    = FileOutput_v0 FilePath
      -- ^ File path of a file.
    | ProcessOutput_v0 ProcessId
      -- ^ Sends any log to the specified 'Process'.
    | StandardOutput_v0
      -- ^ Writes to stdout.
    | StandardError_v0
      -- ^ Writes to stderr.
    | DPLogger_v0
      -- ^ Sends logs to the logger of d-p in the local node.
    deriving (Eq, Show, Generic)

-- | Specify ouput for decision log.
data DecisionLogOutput
  = LogTextFile FilePath
    -- ^ output textual representation in file.
  | LogBinaryFile FilePath
    -- ^ output binary representation in file.
  | LogDP
    -- ^ output textual representation using d-p framework.
  | LogDB FilePath
    -- ^ log decision log to database.
  | LogStdout
    -- ^ Log to stdout
  | LogStderr
    -- ^ Log to stderr
  deriving (Eq, Show, Generic)

instance Migrate DecisionLogOutput where
  type MigrateFrom DecisionLogOutput = DecisionLogOutput_v0
  migrate (FileOutput_v0 f)    = LogTextFile f
  migrate (ProcessOutput_v0 _) = LogDP -- sorry no good way to do that. FIXME
  migrate  StandardOutput_v0   = LogStdout
  migrate  StandardError_v0    = LogStderr
  migrate  DPLogger_v0         = LogDP

deriveSafeCopy 0 'base ''DecisionLogOutput_v0
deriveSafeCopy 1 'extension ''DecisionLogOutput

instance Hashable DecisionLogOutput
instance ToJSON DecisionLogOutput where
  toJSON (LogTextFile fp) = object [ "type" .= ("file"::Text)
                                   , "filename" .= fp
                                   , "format" .= ("text"::Text)]
  toJSON (LogBinaryFile fp) = object [ "type" .= ("file"::Text)
                                     , "filename" .= fp
                                     , "format" .= ("binary"::Text)]
  toJSON (LogDB fp) = object ["type" .= ("db"::Text)
                             , "filename" .= fp ]
  toJSON (LogDP) = object ["type" .= ("default_logger"::Text) ]
  toJSON LogStdout = object [ "type" .= ("stdout"::Text)]
  toJSON LogStderr = object [ "type" .= ("stderr"::Text)]

-- | Specify how trace logs should be output.
data TraceLogOutput
  = TraceText FilePath
    -- ^ Send trace files in text format to the specified file.
  | TraceBinary FilePath
    -- ^ Send traces in binary formats to the specified file.
  | TraceProcess ProcessId
    -- ^ Send files to the remote process, that will handle traces.
  | TraceTextDP
    -- ^ Send trace files in text format to using D-P framework.
  | TraceNull
    -- ^ Do not output any traces.
  deriving (Eq, Show, Generic)

instance Hashable TraceLogOutput
instance ToJSON TraceLogOutput where
  toJSON (TraceText fp) = object [ "type" .= ("file"::Text)
                                 , "filename" .= fp
                                 , "format" .= ("text"::Text)]
  toJSON (TraceBinary fp) = object [ "type" .= ("file"::Text)
                                  , "filename" .= fp
                                 , "format" .= ("binary"::Text)]
  toJSON (TraceTextDP) = object ["type" .= ("dp"::Text)]
  toJSON (TraceProcess pid) = object ["type" .= ("process"::Text)
                                     , "pid" .= T.pack (show pid)]
  toJSON (TraceNull) = object ["type" .= ("no trace"::Text) ]

deriveSafeCopy 0 'base ''TraceLogOutput

-- | Decision log configuration storing 'DecisionLogOutput'
-- information. This is a legacy version of 'DecisionLogConf'.
newtype DecisionLogConf_v0 = DecisionLogConf_v0 DecisionLogOutput
    deriving (Eq, Generic, Show, Typeable)

-- | Decision log configuration storing 'DecisionLogOutput' and
-- 'TraceLogOutput'. 'DecisionLogConf_v0' exists for backwards
-- compatibility.
data DecisionLogConf = DecisionLogConf DecisionLogOutput TraceLogOutput
    deriving (Eq, Generic, Show, Typeable)

-- | Decision log 'Interface'.
interface :: Interface (CEP.Event RC.Event) ()
interface = Interface
  { ifVersion = 0
  , ifServiceName = "decision-log"
  , ifEncodeToSvc = \_v -> Just . safeEncode interface
  , ifDecodeToSvc = safeDecode
  , ifEncodeFromSvc = \_v -> Just . safeEncode interface
  , ifDecodeFromSvc = safeDecode
  }

instance HA.Service.HasInterface DecisionLogConf where
  type ToSvc DecisionLogConf = CEP.Event RC.Event
  type FromSvc DecisionLogConf = ()
  getInterface _ = interface

-- | Migrate from 'DecisionLogConf_v0' to 'DecisionLogConf' by picking
-- 'TraceNull' as a default 'TraceLogOutput'.
instance Migrate DecisionLogConf where
  type MigrateFrom DecisionLogConf = DecisionLogConf_v0
  migrate (DecisionLogConf_v0 f) = DecisionLogConf f TraceNull

instance Hashable DecisionLogConf
instance ToJSON DecisionLogConf

storageIndex ''DecisionLogConf "5c471fad-d1b2-498f-8f59-2cb89733d4a1"
serviceStorageIndex ''DecisionLogConf "1c0fbe2b-470f-48e5-95e0-b1a748b29748"

deriveSafeCopy 0 'base ''DecisionLogConf_v0
deriveSafeCopy 1 'base ''DecisionLogConf

-- | 'Schema' for decision-log configuration.
decisionLogSchema :: Schema DecisionLogConf
decisionLogSchema =
    let filepath = asum
          [ fmap LogTextFile . strOption $ long "log-text" <> metavar "DECISION_LOG_FILE"
             <> summary "store logs as human readable text"
          , fmap LogBinaryFile . strOption $ long "log-binary" <> metavar "DECISION_LOG_FILE"
             <> summary "store logs as binary data"
          , fmap LogDB . strOption $ long "log-db" <> metavar "DECISION_LOG_FILE"
             <> summary "send human readable logs to halon log subsystem"
          ]
        tracepath = asum
          [ fmap TraceText . strOption $ long "trace-file" <> metavar "TRACE_LOG_FILE"
             <> summary "store traces as human readable text"
          , fmap TraceBinary . strOption $ long "trace-binary" <> metavar "TRACE_LOG_FILE"
             <> summary "store traces as binary data"
          ]
    in DecisionLogConf <$> filepath <*> tracepath

$(generateDicts ''DecisionLogConf)
$(deriveService ''DecisionLogConf 'decisionLogSchema [])
