-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Flags where

import Prelude hiding ( (<$>), (<*>) )
import qualified Handler.Bootstrap as Bootstrap

import Options.Applicative
    ( (<$>)
    , (<*>)
    , (<>)
    )
import qualified Options.Applicative as O
import qualified Options.Applicative.Extras as O

import qualified Handler.Service as Service
import qualified Handler.Cluster as Cluster
import qualified Handler.Status as Status

import System.Environment (getProgName)
import System.IO.Unsafe (unsafePerformIO)
import System.Process (readProcess)

data Options = Options
    { optTheirAddress :: [String] -- ^ Addresses of halond nodes to control.
    , optOurAddress   :: String
    , optCommand      :: Command
    }
  deriving (Eq)

data Command =
      Bootstrap Bootstrap.BootstrapCmdOptions
    | Service Service.ServiceCmdOptions
    | Cluster Cluster.ClusterOptions
    | Status Status.StatusOptions
  deriving (Eq)

getOptions :: IO (Maybe Options)
getOptions = do
    self <- getProgName
    O.execParser $
      O.withFullDesc self parseOptions "Control nodes (halond instances)."
  where
    parseOptions :: O.Parser (Maybe Options)
    parseOptions = O.flag' Nothing (O.long "version" <> O.hidden) O.<|> (Just <$> normalOptions)
    normalOptions = Options
        <$> (O.many . O.strOption $ O.metavar "ADDRESSES" <>
               O.long "address" <>
               O.short 'a' <>
               O.help "Addresses of nodes to control.")
        <*> (O.strOption $ O.metavar "ADDRESS" <>
               O.long "listen" <>
               O.short 'l' <>
               O.value listenAddr <>
               O.help "Address halonctl binds to.")
        <*> (O.subparser $
                 (O.command "bootstrap" $ Bootstrap <$>
                    O.withDesc Bootstrap.parseBootstrap "Bootstrap a node.")
              <> (O.command "service" $ Service <$>
                    O.withDesc Service.parseService "Control services.")
              <> (O.command "cluster" $ Cluster <$>
                    O.withDesc Cluster.parseCluster "Control cluster wide options.")
              <> (O.command "status" $ Status <$>
                    O.withDesc Status.parseStatus "Query node status.")
            )
    hostname = unsafePerformIO $ readProcess "hostname" [] ""
    listenAddr = hostname ++ ":9001"
