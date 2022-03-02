{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Node.Remove
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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
parser = pure $ Options ()

run :: [NodeId] -> Options -> Process ()
run = error "Handler.Mero.Node.Remove not implemented"
