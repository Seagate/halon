{-# LANGUAGE CPP #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Cluster-wide configuration.

module Handler.Cluster
  ( ClusterOptions
  , parseCluster
  , cluster
  ) where

import HA.EventQueue.Producer (promulgateEQ)
import qualified HA.Resources.Castor.Initial as CI

#ifdef USE_MERO
import HA.Resources.Mero (SpielAddress(..), SyncToConfd(..))

import Control.Applicative (many, optional)
import Options.Applicative ((<>), (<|>))
#else
import Options.Applicative ((<>))
#endif

import Control.Distributed.Process
import Control.Monad (void)

import Data.Yaml
  ( decodeFileEither
  , prettyPrintParseException
  )
import qualified Options.Applicative as Opt
import qualified Options.Applicative.Extras as Opt

data ClusterOptions =
    LoadData LoadOptions
#ifdef USE_MERO
  | Sync SyncOptions
  | Dump DumpOptions
#endif
  deriving (Eq, Show)

parseCluster :: Opt.Parser ClusterOptions
parseCluster =
      ( LoadData <$> Opt.subparser ( Opt.command "load" (Opt.withDesc parseLoadOptions
        "Load initial data into the system." )))
#ifdef USE_MERO
  <|> ( Sync <$> Opt.subparser ( Opt.command "sync" (Opt.withDesc parseSyncOptions
        "Force synchronisation of RG to confd servers." )))
  <|> ( Dump <$> Opt.subparser ( Opt.command "dump" (Opt.withDesc parseDumpOptions
        "Dump embedded confd database to file." )))
#endif

cluster :: [NodeId] -> ClusterOptions -> Process ()
cluster nids (LoadData l) = dataLoad nids l
#ifdef USE_MERO
cluster nids (Sync s) = syncToConfd nids s
cluster nids (Dump s) = dumpConfd nids s
#endif

data LoadOptions = LoadOptions
    FilePath
    Bool -- ^ validate only
  deriving (Eq, Show)

parseLoadOptions :: Opt.Parser LoadOptions
parseLoadOptions = LoadOptions
  <$> Opt.strOption
      ( Opt.long "conffile"
     <> Opt.short 'f'
     <> Opt.help "File containing JSON-encoded configuration."
     <> Opt.metavar "FILEPATH"
      )
  <*> Opt.switch
      ( Opt.long "verify"
     <> Opt.short 'v'
     <> Opt.help "Verify config file without reconfiguring cluster."
      )

dataLoad :: [NodeId] -- ^ EQ nodes to send data to
         -> LoadOptions
         -> Process ()
dataLoad eqnids (LoadOptions cf verify) = do
  initData <- liftIO $ decodeFileEither cf
  case initData of
    Left err -> liftIO . putStrLn $ prettyPrintParseException err
    Right datum | verify -> liftIO $ do
      putStrLn "Initial data file parsed successfully."
      print datum
    Right (datum :: CI.InitialData) -> promulgateEQ eqnids datum
        >>= \pid -> withMonitor pid wait
      where
        wait = void (expect :: Process ProcessMonitorNotification)

#ifdef USE_MERO

data SyncOptions = SyncOptions [String] (Maybe String)
  deriving (Eq, Show)

parseSyncOptions :: Opt.Parser SyncOptions
parseSyncOptions = SyncOptions
  <$> ( many $ Opt.strOption
         ( Opt.long "confd"
        <> Opt.short 'c'
        <> Opt.help "Address of confd endpoint to push conf to."
        <> Opt.metavar "ENDPOINT"
         )
      )
  <*> ( optional $ Opt.strOption
         ( Opt.long "rm"
        <> Opt.short 'r'
        <> Opt.help "Address of RM controlling confd lock."
        <> Opt.metavar "ENDPOINT"
         )
      )

syncToConfd :: [NodeId]
            -> SyncOptions
            -> Process ()
syncToConfd eqnids so = promulgateEQ eqnids msg
        >>= \pid -> withMonitor pid wait
  where
    msg = case so of
      SyncOptions confds@(_:_) (Just rm) ->
        SyncToTheseServers $ SpielAddress confds rm
      _ -> SyncToConfdServersInRG
    wait = void (expect :: Process ProcessMonitorNotification)

newtype DumpOptions = DumpOptions FilePath
  deriving (Eq, Show)

parseDumpOptions :: Opt.Parser DumpOptions
parseDumpOptions = DumpOptions <$>
  Opt.strOption
    ( Opt.long "filename"
    <> Opt.short 'f'
    <> Opt.help "File to dump confd database to."
    <> Opt.metavar "FILENAME"
    )

dumpConfd :: [NodeId]
          -> DumpOptions
          -> Process ()
dumpConfd eqnids (DumpOptions fn) = promulgateEQ eqnids msg
        >>= \pid -> withMonitor pid wait
  where
    msg = SyncDumpToFile fn
    wait = void (expect :: Process ProcessMonitorNotification)

#endif
