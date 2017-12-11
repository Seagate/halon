{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Load
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module Handler.Mero.Load
  ( Options(..)
  , parser
  , run_XXX0
  ) where

import           Control.Distributed.Process
import           Control.Monad
import           Data.Monoid ((<>))
import           Data.Proxy
import           Data.Yaml (prettyPrintParseException)
import           HA.EventQueue (promulgateEQ)
import           HA.RecoveryCoordinator.RC (subscribeOnTo, unsubscribeOnFrom)
import           HA.RecoveryCoordinator.RC.Events.Cluster
import           HA.Resources.Castor.Initial (parseInitialData_XXX0)
import           Network.CEP
import qualified Options.Applicative as Opt
import           System.Exit (exitFailure)
import           System.IO (hPutStrLn, stderr)

data Options = Options
    FilePath -- ^ Facts file
    FilePath -- ^ Mero roles file
    FilePath -- ^ Halon roles file
    Bool -- ^ Validate only
    Int -- ^ Timeout (seconds)
  deriving (Eq, Show)

parser :: Opt.Parser Options
parser = Options
  <$> Opt.strOption
      ( Opt.long "conffile"
     <> Opt.short 'f'
     <> Opt.help "File containing JSON-encoded configuration."
     <> Opt.metavar "FILEPATH"
      )
  <*> Opt.strOption
      ( Opt.long "rolesfile" -- XXX TODO: rename to "mero-roles"
     <> Opt.short 'r'
     <> Opt.help "File containing template file with Mero role mappings."
     <> Opt.metavar "FILEPATH"
     <> Opt.showDefaultWith id
     <> Opt.value "/etc/halon/mero_role_mappings"
      )
  <*> Opt.strOption
      ( Opt.long "halonrolesfile" -- XXX TODO: rename to "halon-roles"
     <> Opt.short 's'
     <> Opt.help "File containing template file with Halon role mappings."
     <> Opt.metavar "FILEPATH"
     <> Opt.showDefaultWith id
     <> Opt.value "/etc/halon/halon_role_mappings"
      )
  <*> Opt.switch
      ( Opt.long "verify"
     <> Opt.short 'v'
     <> Opt.help "Verify config file without reconfiguring cluster."
      )
  <*> Opt.option Opt.auto
    ( Opt.metavar "TIMEOUT(s)"
    <> Opt.long "timeout"
    <> Opt.help "How many seconds to wait for initial data to load before failing."
    <> Opt.value 10
    <> Opt.showDefault )

run_XXX0 :: [NodeId] -- ^ EQ nodes to send data to
    -> Options
    -> Process ()
run_XXX0 eqnids (Options facts meroRoles halonRoles verify _t) = do
  initData <- liftIO $ parseInitialData_XXX0 facts meroRoles halonRoles
  case initData of
    Left err -> liftIO $ do
      putStrLn $ prettyPrintParseException err
      exitFailure
    Right (datum, _) | verify -> liftIO $ do
      putStrLn "Initial data file parsed successfully."
      print datum
    Right (datum, _) -> do
      subscribeOnTo eqnids (Proxy :: Proxy InitialDataLoaded_XXX3)
      promulgateEQ eqnids datum >>= flip withMonitor wait
      expectTimeout (_t * 1000000) >>= \v -> do
        unsubscribeOnFrom eqnids (Proxy :: Proxy InitialDataLoaded_XXX3)
        case v of
          Nothing -> liftIO $ do
            hPutStrLn stderr "Timed out waiting for initial data to load."
            exitFailure
          Just p -> case pubValue p of
            InitialDataLoaded_XXX3 -> return ()
            InitialDataLoadFailed_XXX3 e -> liftIO $ do
              hPutStrLn stderr $ "Initial data load failed: " ++ e
              exitFailure
      where
        wait = void (expect :: Process ProcessMonitorNotification)
