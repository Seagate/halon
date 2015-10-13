-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Cluster-wide configuration.

module Handler.Cluster
  ( ClusterOptions
  , parseCluster
  , dataLoad
  ) where

import HA.EventQueue.Producer (promulgateEQ)
import qualified HA.Resources.Castor.Initial as CI

import Control.Distributed.Process
import Control.Monad (void)

import Data.Yaml
  ( decodeFileEither
  , prettyPrintParseException
  , ParseException
  , Value (..)
  )
import qualified Data.ByteString.Lazy as BS
import Options.Applicative ((<>))
import qualified Options.Applicative as Opt

data ClusterOptions = ClusterOptions
    FilePath
    Bool -- ^ validate only
  deriving (Eq, Show)

parseCluster :: Opt.Parser ClusterOptions
parseCluster = ClusterOptions
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
         -> ClusterOptions
         -> Process ()
dataLoad eqnids (ClusterOptions cf verify) = do
  initData <- liftIO $ decodeFileEither cf
  case initData of
    Left err -> liftIO . putStrLn $ prettyPrintParseException err
    Right datum | verify -> liftIO $ do
      putStrLn "Initial data file parsed successfully."
      print datum
    Right (datum :: CI.InitialData) -> void $ promulgateEQ eqnids datum
