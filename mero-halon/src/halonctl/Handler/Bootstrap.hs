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
import Control.Distributed.Process.Node (forkProcess)
import Control.Distributed.Process.Internal.Types

import Control.Monad
import Control.Monad.Reader (ask)
import Data.Binary ( Binary )
import Data.Maybe (catMaybes)
import Data.Typeable ( Typeable )
import GHC.Generics ( Generic )
import Options.Applicative ((<$>) , (<>))
import qualified Options.Applicative as O
import qualified Options.Applicative.Extras as O

import qualified Handler.Bootstrap.Satellite as S
import qualified Handler.Bootstrap.TrackingStation as TS

import System.Exit (exitFailure)
import System.IO

--------------------------------------------------------------------------------

-- | Options for bootstrapping.
data BootstrapCmdOptions =
      BootstrapNode S.Config
    | BootstrapStation TS.Config
  deriving (Eq, Typeable, Generic)

instance Binary BootstrapCmdOptions

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

-- | Bootstrap a given node in the specified configuration.
bootstrap :: [NodeId] -- ^ NodeIds of the node to bootstrap
          -> BootstrapCmdOptions
          -> Process ()
bootstrap nids opts = case opts of
  BootstrapNode naConf -> startSatellitesAsync naConf >>= \case
    [] -> return ()
    failures -> liftIO $ do
      hPutStrLn stderr $ "nodeUp failed on following nodes: " ++ show failures
      exitFailure
  BootstrapStation tsConf -> TS.start nids tsConf

  where
    -- Fork start process, wait for results from each, output
    -- information about any failures.
    startSatellitesAsync :: S.Config -> Process [(NodeId, String)]
    startSatellitesAsync conf = do
      self <- getSelfPid
      localNode <- fmap processNode ask
      liftIO . forM_ nids $ \nid -> do
        forkProcess localNode $ do
          res <- S.start nid conf
          usend self $ (nid,) <$> res
      catMaybes <$> forM nids (const expect)
