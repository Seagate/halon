{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Halon
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
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
import qualified Options.Applicative.Extras as Opt

data Options =
  Info Info.Options
  | Node Node.Options
  | Service Service.Options
  | Station Station.Options
  deriving (Show, Eq)

parser :: Parser Options
parser = subparser $ mconcat
  [ Opt.cmd "info" (Info <$> Info.parser) "Halon information."
  , Opt.cmd "node" (Node <$> Node.parser) "Node commands."
  , Opt.cmd "service" (Service <$> Service.parser) "Service commands."
  , Opt.cmd "station" (Station <$> Station.parser) "Tracking station commands."
  ]

halon :: [NodeId] -> Options -> Process ()
halon nids (Node opts) = Node.run nids opts
halon nids (Info opts) = Info.info nids opts
halon nids (Service opts) = Service.service nids opts
halon nids (Station opts) = Station.start nids opts
