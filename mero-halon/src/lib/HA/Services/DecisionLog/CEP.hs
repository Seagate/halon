{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.DecisionLog.CEP where

import           Prelude hiding (id)
import           Control.Category
import qualified Data.ByteString.Lazy as Lazy
import           Data.Monoid ((<>))
import           System.IO

import Control.Distributed.Process
import Control.Monad.Trans
import Network.CEP

import HA.Services.DecisionLog.Types

decisionLogRules :: Handle -> RuleM s ()
decisionLogRules h =
    define "entries-submitted" id $ \entries -> do
      writeEntriesLogged h entries
      liftProcess $ say "entries submitted"

writeEntriesLogged :: MonadIO m => Handle -> EntriesLogged -> m ()
writeEntriesLogged h EntriesLogged{..} = liftIO $ do
    Lazy.hPut h dump
    Lazy.hPut h "\n"
  where
    dump =
        "rule-id="               <>
        Lazy.fromStrict elRuleId <>
        ";inputs="               <>
        elInputs                 <>
        ";entries="              <>
        elEntries
