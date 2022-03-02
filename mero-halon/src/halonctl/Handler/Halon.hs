{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Halon
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module Handler.Halon
 ( Options(..)
 , parser
 , halon
 ) where

import           Control.Distributed.Process
import           Data.Monoid (mconcat)
import qualified Handler.Halon.Info as Info
import qualified Handler.Halon.Node as Node
import qualified Handler.Halon.Service as Service
import qualified Handler.Halon.Station as Station
import           Options.Applicative
import           Options.Applicative.Extras (command')

data Options =
  Info Info.Options
  | Node Node.Options
  | Service Service.Options
  | Station Station.Options
  deriving (Show, Eq)

parser :: Parser Options
parser = hsubparser $ mconcat
  [ command' "info" (Info <$> Info.parser) "Halon information."
  , command' "node" (Node <$> Node.parser) "Node commands."
  , command' "service" (Service <$> Service.parser) "Service commands."
  , command' "station" (Station <$> Station.parser) "Tracking station commands."
  ]

halon :: [NodeId] -> Options -> Process ()
halon nids (Node opts) = Node.run nids opts
halon nids (Info opts) = Info.info nids opts
halon nids (Service opts) = Service.service nids opts
halon nids (Station opts) = Station.start nids opts
