{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Node
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module Handler.Mero.Node
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
import qualified Handler.Mero.Node.Start as Start
import qualified Handler.Mero.Node.Stop as Remove
import qualified Handler.Mero.Node.Stop as Stop
import           Options.Applicative
import           Data.Monoid (mconcat)
import qualified Options.Applicative.Extras as Opt

data Options =
  Remove Remove.Options
  | Start Start.Options
  | Stop Stop.Options
  deriving (Show, Eq)

parser :: Parser Options
parser = subparser $ mconcat
  [ Opt.cmd "start" (Start <$> Start.parser) "Start node"
  , Opt.cmd "stop" (Stop <$> Stop.parser) "Stop node"
  , Opt.cmd "remove" (Remove <$> Remove.parser) "Remove node"
  ]

run :: [NodeId] -> Options -> Process ()
run nids (Remove opts) = Remove.run nids opts
run nids (Start opts) = Start.run nids opts
run nids (Stop opts) = Stop.run nids opts
