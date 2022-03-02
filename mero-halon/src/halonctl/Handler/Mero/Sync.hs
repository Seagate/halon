{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Sync
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
module Handler.Mero.Sync
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
import           Control.Monad (void)
import           Data.Monoid ((<>))
import           HA.EventQueue (promulgateEQ)
import qualified HA.Resources.Mero as M0
import qualified Options.Applicative as Opt

data Options = Options
  { _syncOptForce :: Bool }
  deriving (Eq, Show)

parser :: Opt.Parser Options
parser = Options
  <$> Opt.switch
    ( Opt.long "force"
    <> Opt.help "Force transaction sync even if configuration tree didn't change")

run :: [NodeId] -> Options -> Process ()
run eqnids (Options force) = do
  say "Synchonizing cluster to confd."
  promulgateEQ eqnids (M0.SyncToConfdServersInRG force) >>= (`withMonitor` wait)
  where
    wait = void (expect :: Process ProcessMonitorNotification)
