-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
--------------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE TupleSections #-}

module Handler.Bootstrap
  ( BootstrapCmdOptions
  , bootstrap
  , parseBootstrap
  )
where

import Prelude hiding ((<$>))
import Control.Distributed.Process

import Data.Typeable ( Typeable )
import GHC.Generics ( Generic )
import Options.Applicative ((<$>) , (<>))
import qualified Options.Applicative as O
import qualified Options.Applicative.Extras as O

import qualified Handler.Bootstrap.Satellite as S
import qualified Handler.Bootstrap.TrackingStation as TS
#ifdef USE_MERO
import qualified Handler.Bootstrap.Cluster as C
#endif

import System.Exit (exitFailure)
import System.IO

--------------------------------------------------------------------------------

-- | Options for bootstrapping.
data BootstrapCmdOptions =
      BootstrapNode S.Config
    | BootstrapStation TS.Config
#ifdef USE_MERO
    | BootstrapCluster C.Config
#endif
  deriving (Eq, Typeable, Generic)

parseBootstrap :: O.Parser BootstrapCmdOptions
parseBootstrap =
    O.subparser $
         O.command "satellite"
          (O.withDesc
            (BootstrapNode <$> S.schema)
            "Bootstrap a satellite")
      <> O.command "station"
          (O.withDesc
            (BootstrapStation <$> TS.schema)
            "Bootstrap a tracking station node")
#ifdef USE_MERO
      <> O.command "cluster"
          (O.withDesc
             (BootstrapCluster <$> C.schema)
             "Bootstrap cluster")
#endif

-- | Bootstrap a given node in the specified configuration.
bootstrap :: [NodeId] -- ^ NodeIds of the node to bootstrap
          -> BootstrapCmdOptions
          -> Process ()
bootstrap nids opts = case opts of
  BootstrapNode naConf -> S.startSatellitesAsync naConf nids >>= \case
    [] -> return ()
    failures -> liftIO $ do
      hPutStrLn stderr $ "nodeUp failed on following nodes: " ++ show failures
      exitFailure
  BootstrapStation tsConf -> TS.start nids tsConf
#ifdef USE_MERO
  BootstrapCluster clConf -> C.bootstrap clConf
#endif
