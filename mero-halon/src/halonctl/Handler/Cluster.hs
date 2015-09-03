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

import Data.Aeson (decode)
import qualified Data.ByteString.Lazy as BS
import Options.Applicative ((<>))
import qualified Options.Applicative as Opt

newtype ClusterOptions = ClusterOptions FilePath
  deriving (Eq, Show)

parseCluster :: Opt.Parser ClusterOptions
parseCluster = ClusterOptions <$>
             ( Opt.strOption
             $ Opt.long "conffile"
            <> Opt.short 'f'
            <> Opt.help "File containing JSON-encoded configuration."
            <> Opt.metavar "FILEPATH"
             )

dataLoad :: [NodeId] -- ^ EQ nodes to send data to
         -> ClusterOptions
         -> Process ()
dataLoad eqnids (ClusterOptions cf) = do
  bs <- liftIO $ BS.readFile cf
  mapM_ (promulgateEQ eqnids) (decode bs :: Maybe CI.InitialData)

