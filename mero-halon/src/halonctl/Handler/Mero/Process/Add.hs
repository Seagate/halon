{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Process.Add
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module Handler.Mero.Process.Add
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
import qualified Options.Applicative as Opt

data Options = Options ()
  deriving (Show, Eq)

parser :: Opt.Parser Options
parser = pure $ Options ()

run :: [NodeId] -> Options -> Process ()
run _ _ = error "Handler.Mero.Process.Add not implemented"
