{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.DecisionLog.Types where

import           Prelude hiding ((<$>))
import qualified Data.ByteString      as Strict
import qualified Data.ByteString.Lazy as Lazy
import           Data.Functor ((<$>))
import           Data.Monoid ((<>))
import           Data.Typeable
import           GHC.Generics
import           System.IO

import Control.Distributed.Process hiding (bracket)
import Control.Monad.Catch (bracket)
import Control.Monad (when)
import Data.Aeson
import Data.Binary
import Data.Function (on)
import Data.List (groupBy)
import Data.Text (Text)
import Data.Defaultable
import Data.Hashable
import Data.Maybe (catMaybes)
import Data.Time (getCurrentTime)
import Options.Schema
import Options.Schema.Builder
import Network.CEP
import Text.PrettyPrint.Leijen hiding ((<>), (<$>))

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

data EntriesLogged =
    EntriesLogged
    { elRuleId  :: !Strict.ByteString
    , elInputs  :: !Lazy.ByteString
    , elEntries :: !Lazy.ByteString
    } deriving (Generic, Typeable)

instance Binary EntriesLogged

newtype WriteLogs = WriteLogs (Logs -> Process ())

ppLogs :: Logs -> Doc
ppLogs logs = vsep [ text $ logsRuleName logs
                   , indent 2 $ ppEntries entries
                   ]
  where
    entries = logsPhaseEntries logs

ppEntries :: [(String, String, String)] -> Doc
ppEntries xs = indent 2 (vsep $ fmap ppShortEntry shortEntries)
  where
    shortEntries :: [(String, [(String, String)])]
    shortEntries = catMaybes $ map (joinGroup . map collapseEntry) groups

    joinGroup [] = Nothing
    joinGroup gr@((pn, _) : _) = Just (pn, map snd gr)

    collapseEntry (pn, ctx, str) = (pn, (ctx, str))

    groups = groupBy ((==) `on` (\(pn, _, _) -> pn)) xs

ppShortEntry :: (String, [(String, String)]) -> Doc
ppShortEntry (pname, vals) = vsep $ text pname : map ppV vals
  where
    ppV (ctx, str) = indent 2 (text ctx <+> hcat [equals, rangle] <+> text str)

openLogFile :: FilePath -> Process Handle
openLogFile path = liftIO $ do
    h <- openFile path AppendMode
    hSetBuffering h LineBuffering
    return h

cleanupHandle :: Handle -> Process ()
cleanupHandle h = liftIO $ hClose h

handleLogs :: DecisionLogOutput -> Logs -> Process ()
handleLogs dlo logs = when (not . null $ logsPhaseEntries logs) $ case dlo of
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

writeLogs :: WriteLogs -> Logs -> Process ()
writeLogs (WriteLogs k) logs = k logs

printLogs :: Logs -> Process ()
printLogs = handleLogs DPLogger
