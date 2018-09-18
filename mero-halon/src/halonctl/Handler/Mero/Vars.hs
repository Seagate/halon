{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData      #-}
-- |
-- Module    : Handler.Mero.Vars
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module Handler.Mero.Vars
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process hiding (bracket_, die)
import           Control.Monad
import           Data.Monoid ((<>), mconcat)
import           HA.EventQueue (promulgateEQ)
import           HA.RecoveryCoordinator.RC.Events
import qualified HA.Resources.Castor as Castor
import qualified HA.Resources.HalonVars as Castor
import           Handler.Mero.Helpers (clusterCommand)
import qualified Options.Applicative as Opt
import qualified Options.Applicative.Extras as Opt
import           System.Exit (die)

data Options
       = VarsGet
       | VarsSet
          -- TODO: write simple package with generics for this
          { recoveryExpirySeconds :: Maybe Int
          , recoveryMaxRetries    :: Maybe Int
          , keepaliveFrequency    :: Maybe Int
          , keepaliveTimeout      :: Maybe Int
          , driveResetMaxRetries  :: Maybe Int
          , disableSmartCheck     :: Maybe Bool
          , disableNotificationFailure :: Maybe Bool
          }
       deriving (Show, Eq)

run :: [NodeId] -> Options -> Process ()
run nids VarsGet = clusterCommand nids Nothing GetHalonVars (say . show)
run nids VarsSet{..} = do
  (sp, rp) <- newChan
  _ <- promulgateEQ nids (GetHalonVars sp) >>= flip withMonitor wait
  mc <- receiveTimeout 10000000 [matchChan rp return]
  case mc of
    Nothing -> liftIO $ die "Failed to contact EQ in 10s."
    Just  c ->
      let hv = foldr ($) c
                 [ maybe id (\s -> \x -> x{Castor._hv_recovery_expiry_seconds = s}) recoveryExpirySeconds
                 , maybe id (\s -> \x -> x{Castor._hv_recovery_max_retries = s}) recoveryMaxRetries
                 , maybe id (\s -> \x -> x{Castor._hv_keepalive_frequency = s}) keepaliveFrequency
                 , maybe id (\s -> \x -> x{Castor._hv_keepalive_timeout = s}) keepaliveTimeout
                 , maybe id (\s -> \x -> x{Castor._hv_drive_reset_max_retries = s}) driveResetMaxRetries
                 , maybe id (\s -> \x -> x{Castor._hv_disable_smart_checks = s}) disableSmartCheck
                 , maybe id (\s -> \x -> x{Castor._hv_failed_notification_fails_process = not s}) disableNotificationFailure
                 ]
      in promulgateEQ nids (Castor.SetHalonVars hv) >>= flip withMonitor wait
  where
    wait = void (expect :: Process ProcessMonitorNotification)

parser :: Opt.Parser Options
parser = Opt.subparser $ mconcat
  [ Opt.cmd "get" (pure VarsGet) "Load variables"
  , Opt.cmd "set" inner "Set variables"
  ]
   where
     inner :: Opt.Parser Options
     inner = VarsSet <$> recoveryExpiry
                     <*> recoveryRetry
                     <*> keepaliveFreq
                     <*> keepaliveTimeout
                     <*> driveResetMax
                     <*> disableSmartCheck
                     <*> disableNotificationFailure
     recoveryExpiry = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "recovery-expiry"
       <> Opt.metavar "[SECONDS]"
       <> Opt.help "How long we want node recovery to last overall (sec).")
     recoveryRetry = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "recovery-retry"
       <> Opt.metavar "[SECONDS]"
       <> Opt.help "Number of tries to try recovery, negative for infinite.")
     keepaliveFreq = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "keepalive-frequency"
       <> Opt.metavar "[SECONDS]"
       <> Opt.help "How ofter should we try to send keepalive messages. Seconds.")
     keepaliveTimeout = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "keepalive-timeout"
       <> Opt.metavar "[SECONDS]"
       <> Opt.help "How long to allow process to run without replying to keepalive.")
     driveResetMax = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "drive-reset-max-retries"
       <> Opt.metavar "[NUMBER]"
       <> Opt.help "Number of times we could try to reset drive.")
     disableSmartCheck = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "disable-smart-check"
       <>  Opt.metavar "[True|False]"
       <>  Opt.help "Disable smart check by sspl.")
     disableNotificationFailure = Opt.optional $ Opt.option Opt.auto
       ( Opt.long "disable-notification-failure"
       <> Opt.metavar "[True|False]"
       <> Opt.help "Disable failing a process when notification sending to it fails.")
