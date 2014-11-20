-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
--------------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}

module Handler.Bootstrap
  ( BootstrapCmdOptions
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
data BootstrapCmdOptions =
      BootstrapNode NA.NodeAgentConf
    | BootstrapStation TS.Config
  deriving (Eq, Typeable, Generic)

instance Binary BootstrapCmdOptions

parseBootstrap :: O.Parser BootstrapCmdOptions
parseBootstrap =
    O.subparser $
         O.command "satellite"
          (O.withDesc
            (BootstrapNode <$> mkParser schema)
            "Bootstrap a satellite")
      <> O.command "station"
          (O.withDesc
            (BootstrapStation <$> TS.schema)
            "Bootstrap a tracking station node")

-- | Bootstrap a given node in the specified configuration.
bootstrap :: [NodeId] -- ^ NodeIds of the node to bootstrap
          -> BootstrapCmdOptions
          -> Process ()
bootstrap nids opts = case opts of
  BootstrapNode naConf -> mapM_ (\nid -> NA.start nid naConf) nids
  -- We should use nids as the list of nodes on which to start the station,
  -- but at the moment we need to pass in the satellites as well, so we just
  -- use the TS conf at the moment.
  BootstrapStation tsConf ->TS.start tsConf
