{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Process
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module Handler.Mero.Process
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
import           Data.Monoid (mconcat)
import qualified Handler.Mero.Process.Add as Add
import qualified Handler.Mero.Process.Configuration as Configuration
import qualified Handler.Mero.Process.Remove as Remove
import qualified Handler.Mero.Process.Start as Start
import qualified Handler.Mero.Process.Stop as Stop
import           Options.Applicative
import           Options.Applicative.Extras

data Options =
  Add !Add.Options
  | Configuration !Configuration.Options
  | Remove !Remove.Options
  | Start !Start.Options
  | Stop !Stop.Options
  deriving (Show, Eq)

parser :: Parser Options
parser = subparser $ mconcat
  [ cmd "add" (Add <$> Add.parser) "Add process"
  , cmd "configuration" (Configuration <$> Configuration.parser)
      "Show configuration for process."
  , cmd "remove" (Remove <$> Remove.parser) "Remove process"
  , cmd "start" (Start <$> Start.parser) "Start process"
  , cmd "stop" (Stop <$> Stop.parser) "Stop process"
  ]

run :: [NodeId] -> Options -> Process ()
run nids (Add opts) = Add.run nids opts
run nids (Configuration opts) = Configuration.run nids opts
run nids (Remove opts) = Remove.run nids opts
run nids (Start opts) = Start.run nids opts
run nids (Stop opts) = Stop.run nids opts
