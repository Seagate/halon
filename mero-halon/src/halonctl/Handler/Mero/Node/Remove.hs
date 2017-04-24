{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Node.Remove
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module Handler.Mero.Node.Remove
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
import qualified Options.Applicative as Opt

data Options = Options ()
  deriving (Show, Eq)

parser :: Opt.Parser Options
parser = pure "not implemented"

run :: [NodeId] -> Options -> Process ()
run = error "not implemented"