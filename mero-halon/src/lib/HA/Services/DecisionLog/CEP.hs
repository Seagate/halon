{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.DecisionLog.CEP where

import qualified Data.ByteString.Lazy as Lazy
import           Data.ByteString.Lazy.Char8 (pack)
import           System.IO

import Control.Distributed.Process
import Control.Monad.Trans
import Network.CEP

decisionLogRules :: Handle -> Definitions s ()
decisionLogRules h =
    defineSimple "entries-submitted" $ \logs -> do
      writeEntriesLogged h logs
      liftProcess $ say "entries submitted"

writeEntriesLogged :: MonadIO m => Handle -> Logs -> m ()
writeEntriesLogged h logs = liftIO $ do
    Lazy.hPut h $ pack $ show logs
    Lazy.hPut h "\n"
