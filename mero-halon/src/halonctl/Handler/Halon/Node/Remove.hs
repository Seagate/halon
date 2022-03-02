{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Halon.Node.Remove
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module Handler.Halon.Node.Remove
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
run _ _ = error "Handler.Halon.Node.Remove not implemented"
