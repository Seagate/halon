-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
--------------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}

module Handler.Bootstrap
  ( BootstrapOptions
  , bootstrap
  , parseBootstrap
  )
where

import Control.Distributed.Process
  ( NodeId
  , Process
  )

import Data.Binary
  ( Binary )
import Data.Typeable
  ( Typeable )
import GHC.Generics
  ( Generic )

import Options.Applicative
    ( (<$>)
    , (<>)
    )
import qualified Options.Applicative as O
import qualified Options.Applicative.Extras as O
import Options.Schema.Applicative (mkParser)

import qualified Handler.Bootstrap.NodeAgent as NA
import qualified Handler.Bootstrap.TrackingStation as TS
import HA.Service (schema)

--------------------------------------------------------------------------------

-- | Options for bootstrapping.
data BootstrapOptions =
      BootstrapNode NA.NodeAgentConf
    | BootstrapStation TS.TrackingStationOpts
  deriving (Eq, Typeable, Generic)

instance Binary BootstrapOptions

parseBootstrap :: O.Parser BootstrapOptions
parseBootstrap =
    O.subparser $
         O.command "satellite"
          (O.withDesc
            (BootstrapNode <$> mkParser schema)
            "Bootstrap a satellite")
      <> O.command "station"
          (O.withDesc
            (BootstrapStation <$> TS.tsSchema)
            "Bootstrap a tracking station node")

bootstrap :: [NodeId] -- ^ NodeIds of the node to bootstrap
          -> BootstrapOptions
          -> Process ()
bootstrap nids opts = case opts of
  BootstrapNode naConf -> mapM_ (\nid -> NA.startNA nid naConf) nids
  BootstrapStation tsConf -> mapM_ (\nid -> TS.startTS nid tsConf) nids
