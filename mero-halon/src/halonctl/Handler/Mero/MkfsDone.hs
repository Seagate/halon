{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.MkfsDone
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
module Handler.Mero.MkfsDone
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
import           Data.Monoid ((<>))
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import           Handler.Mero.Helpers
import qualified Options.Applicative as Opt

newtype Options = Options Bool deriving (Eq, Show)

parser :: Opt.Parser Options
parser = Options
  <$> Opt.switch
    ( Opt.long "confirm"
    <> Opt.help "Confirm that the cluster fits all requirements for running this call."
    )

run :: [NodeId] -> Options -> Process ()
run _ (Options False) =
  say "Please check that the cluster fits all requirements first."
run nids (Options True) =
  clusterCommand nids Nothing MarkProcessesBootstrapped (const $ say "Done.")
