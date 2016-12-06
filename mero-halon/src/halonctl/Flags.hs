-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Flags where

import qualified Handler.Bootstrap as Bootstrap

import Options.Applicative
import qualified Options.Applicative as O
import qualified Options.Applicative.Extras as O

import qualified Handler.Service as Service
import qualified Handler.Cluster as Cluster
import qualified Handler.Debug as Debug
import qualified Handler.Status as Status
import qualified Handler.Node as Node

import Data.Char
import Data.Monoid
import Data.List

import System.Environment (getProgName)
import System.IO.Unsafe (unsafePerformIO)
import System.Process (readProcess)
import System.Directory

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
    | Debug Debug.DebugOptions
    | Node  Node.NodeOptions
  deriving (Eq)

data SystemOptions = SystemOptions { soListen :: Last (String, String)
                                   } deriving (Show)

instance Monoid SystemOptions where
  mempty = SystemOptions mempty
  (SystemOptions a1) `mappend` (SystemOptions a2) = SystemOptions (a1 <> a2)

getOptions :: IO (Maybe Options)
getOptions = do
    self <- getProgName
    exists <- doesFileExist sysconfig
    defaults <- if exists
                then mconcat . fmap toSystemOptions . lines <$> readFile sysconfig
                else return mempty
    O.execParser $
      O.withFullDesc self (parseOptions defaults) "Control nodes (halond instances)."
  where
    parseOptions :: SystemOptions -> O.Parser (Maybe Options)
    parseOptions o = O.flag' Nothing (O.long "version" <> O.hidden) O.<|> (Just <$> normalOptions o)
    normalOptions (SystemOptions la) = Options
        <$> (maybe O.some  (\(h,p) -> \x -> O.some x <|> pure [h++":"++p]) (getLast la) $
               O.strOption $ O.metavar "ADDRESSES" <>
                 O.long "address" <>
                 O.short 'a' <>
                 O.help "Addresses of nodes to control.")
        <*> (O.strOption $ O.metavar "ADDRESS" <>
               O.long "listen" <>
               O.short 'l' <>
               O.value (maybe (listenAddr hostname) 
                              (listenAddr . fst) $ getLast la) <>
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
              <> (O.command "debug" $ Debug <$>
                    O.withDesc Debug.parseDebug "Print Halon debugging information.")
              <> (O.command "node" $ Node <$>
                    O.withDesc Node.parseOptions "Control node wide options.")
            )
    hostname = unsafePerformIO $ readProcess "hostname" [] ""
    listenAddr :: String -> String
    listenAddr h = trim $ h ++ ":0"
    toSystemOptions line
      | "HALOND_LISTEN" `isPrefixOf` line = SystemOptions $ Last . Just $ extractIp (tail . snd $ span (/='=') line)
      | otherwise = SystemOptions $ Last Nothing
    extractIp = fmap tail . span (/= ':')
    sysconfig :: String
    sysconfig = "/etc/sysconfig/halond"

    trim = filter (liftA2 (||) isAlphaNum isPunctuation)
