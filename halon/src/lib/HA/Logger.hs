-- |
-- Module:     Control.Distributed.Process.Logs
-- Copyright:  (C) 2015 Seagate Technology Limited.
module HA.Logger
  ( mkHalonTracer
  ) where

import Control.Distributed.Process

import Data.Char
import System.IO.Unsafe
import System.Environment

-- | Create a logger that could be enabled by setting
-- proper environment variable
--
-- Examples:
--
-- @@
-- logger :: String -> Process ()
-- logger = mkHalonTracer "EQ.producer"
-- @@
--
-- Now we could run program with:
--
-- @@
-- HALON_TRACING="EQ.producer smth-else" ./program-name
-- @@
-- and get logging enabled, it's possible to use @*@ in
-- @HALON_TRACING@ variable, then all subsystemd will be enabled
mkHalonTracer :: String
              -> (String -> Process ())
mkHalonTracer subsystem = unsafePerformIO $ do
    mx <- lookupEnv "HALON_TRACING"
    case mx of
      Nothing -> return $ const $ return ()
      Just ss -> do
        let subsystems = words $ map toLower ss
        if (map toLower subsystem) `elem` subsystems || "*" `elem` subsystems
           then return logger
           else return $ const $ return ()
  where
    logger s = say $ "[" ++ subsystem ++ "] " ++ s
