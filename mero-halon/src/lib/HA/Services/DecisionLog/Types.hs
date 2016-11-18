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

import           Prelude hiding ((<$>))
import qualified Data.ByteString      as Strict
import qualified Data.ByteString.Lazy as Lazy
import           Data.Functor ((<$>))
import           Data.Typeable
import           GHC.Generics
import           System.IO

import Control.Distributed.Process hiding (bracket)
import Control.Monad.Catch (bracket)
import Data.Aeson
import Data.Binary (Binary)
import Data.Text (Text)
import Data.Defaultable
import Data.Hashable
import Data.Monoid ((<>))
import Data.SafeCopy
import Data.Time (getCurrentTime)
import Options.Schema
import Options.Schema.Builder
import qualified Network.CEP.Log as CL
import Text.PrettyPrint.Leijen hiding ((<>),(<$>))

import qualified HA.RecoveryCoordinator.Log as Log
import HA.SafeCopy.OrphanInstances()
import HA.Service.TH


data DecisionLogOutput
    = FileOutput FilePath
      -- ^ File path of a file.
    | ProcessOutput ProcessId
      -- ^ Sends any log to the specified 'Process'.
    | StandardOutput
      -- ^ Writes to stdout.
    | StandardError
      -- ^ Writes to stderr.
    | DPLogger
      -- ^ Sends logs to the logger of d-p in the local node.
    deriving (Eq, Show, Generic)

deriveSafeCopy 0 'base ''DecisionLogOutput

instance Binary DecisionLogOutput
instance Hashable DecisionLogOutput
instance ToJSON DecisionLogOutput where
  toJSON (FileOutput fp) = object ["type" .= ("file"::Text), "filename" .= fp]
  toJSON (ProcessOutput p) = object ["type" .= ("process"::Text), "process" .= show p]
  toJSON (StandardOutput)  = object ["type" .= ("stdout"::Text) ]
  toJSON (StandardError)   = object ["type" .= ("stderr"::Text) ]
  toJSON (DPLogger)        = object ["type" .= ("default_logger"::Text) ]


-- | Writes any log to a file. It will append the content from the end of the
--   file.
fileOutput :: FilePath -> DecisionLogOutput
fileOutput = FileOutput

-- | Sends any log to that 'Process'.
processOutput :: ProcessId -> DecisionLogConf
processOutput = DecisionLogConf . ProcessOutput


-- | Writes any log to stdout.
standardOutput :: DecisionLogConf
standardOutput = DecisionLogConf StandardOutput

newtype DecisionLogConf = DecisionLogConf  DecisionLogOutput
    deriving (Eq, Generic, Show, Typeable)

instance Binary DecisionLogConf
instance Hashable DecisionLogConf
instance ToJSON DecisionLogConf

decisionLogSchema :: Schema DecisionLogConf
decisionLogSchema =
    let _filepath = strOption
                   $  long "file"
                   <> short 'f'
                   <> metavar "DECISION_LOG_FILE"
        filepath = FileOutput <$> _filepath in
    fmap (DecisionLogConf . fromDefault) $ defaultable StandardOutput filepath

$(generateDicts ''DecisionLogConf)
$(deriveService ''DecisionLogConf 'decisionLogSchema [])
deriveSafeCopy 0 'base ''DecisionLogConf

data EntriesLogged =
    EntriesLogged
    { elRuleId  :: !Strict.ByteString
    , elInputs  :: !Lazy.ByteString
    , elEntries :: !Lazy.ByteString
    } deriving (Generic, Typeable)

instance Binary EntriesLogged

newtype WriteLogs = WriteLogs (CL.Event Log.Event -> Process ())

-- | Pretty-print a log entry
ppLogs :: CL.Event Log.Event -> Doc
ppLogs evt =
    ppLoc (CL.evt_loc evt) <+> ppEvt (CL.evt_log evt)
  where
    ppLoc CL.Location{..} = encloseSep lbrace rbrace colon
      $ text <$> [loc_rule_name, show loc_sm_id, loc_phase_name]
    ppJump (CL.NormalJump s) = text s
    ppJump (CL.TimeoutJump t s) =
      text "timeout" <+> parens (text $ show t) <+> text s
    ppEvt (CL.PhaseLog CL.PhaseLogInfo{..}) =
      text pl_key <+> hcat [equals, rangle] <+> text pl_value
    ppEvt CL.PhaseEntry = text "ENTER_PHASE"
    ppEvt CL.Stop = text "STOP"
    ppEvt CL.Suspend = text "SUSPEND"
    ppEvt (CL.Continue CL.ContinueInfo{..}) =
      text "CONTINUE" <+> ppJump c_continue_phase
    ppEvt (CL.Switch CL.SwitchInfo{..}) =
      text "SWITCH" <+> ( encloseSep lbracket rbracket comma
                        $ ppJump <$> s_switch_phases)
    ppEvt _ = empty

openLogFile :: FilePath -> Process Handle
openLogFile path = liftIO $ do
    h <- openFile path AppendMode
    hSetBuffering h LineBuffering
    return h

cleanupHandle :: Handle -> Process ()
cleanupHandle h = liftIO $ hClose h

handleLogs :: DecisionLogOutput -> CL.Event Log.Event -> Process ()
handleLogs dlo logs = case dlo of
    ProcessOutput pid -> usend pid logs
    StandardOutput -> liftIO $ do
      putDoc $ ppLogs logs
      putStr "\n"
    StandardError -> liftIO $ do
      hPutDoc stderr $ ppLogs logs
      hPutStr stderr "\n"
    DPLogger -> say $ displayS (renderPretty 0.4 80 $ ppLogs logs) ""
    FileOutput path ->
      bracket (openLogFile path) cleanupHandle $ \h -> liftIO $ do
        hPutStrLn h . show =<< getCurrentTime
        hPutDoc h $ ppLogs logs
        hPutStr h "\n"

newWriteLogs :: DecisionLogOutput -> WriteLogs
newWriteLogs tpe = WriteLogs $ handleLogs tpe

writeLogs :: WriteLogs -> CL.Event Log.Event -> Process ()
writeLogs (WriteLogs k) logs = k logs

printLogs :: CL.Event Log.Event -> Process ()
printLogs = handleLogs DPLogger
