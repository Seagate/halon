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
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.DecisionLog.Types where

import Data.Typeable
import GHC.Generics

import Control.Distributed.Process hiding (bracket)
import Data.Aeson
import Data.Binary (Binary)
import Data.Foldable (asum)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Hashable
import Data.Monoid ((<>))
import Data.SafeCopy
import Options.Schema
import Options.Schema.Builder

import HA.SafeCopy.OrphanInstances()
import HA.Service.TH


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

instance Binary DecisionLogOutput
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

instance Binary TraceLogOutput
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

newtype DecisionLogConf_v0 = DecisionLogConf_v0  DecisionLogOutput
    deriving (Eq, Generic, Show, Typeable)

data DecisionLogConf = DecisionLogConf DecisionLogOutput TraceLogOutput
    deriving (Eq, Generic, Show, Typeable)
     
instance Migrate DecisionLogConf where
  type MigrateFrom DecisionLogConf = DecisionLogConf_v0
  migrate (DecisionLogConf_v0 f) = DecisionLogConf f TraceNull

instance Binary DecisionLogConf
instance Hashable DecisionLogConf
instance ToJSON DecisionLogConf

deriveSafeCopy 0 'base ''DecisionLogConf_v0
deriveSafeCopy 1 'base ''DecisionLogConf

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
