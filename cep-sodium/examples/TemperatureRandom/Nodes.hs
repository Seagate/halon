-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- The various nodes running in the example.
-- 

module Nodes where

import           Types
import           Util

import           FRP.Sodium
import           FRP.Sodium.Util (periodically, averageOver, epoch)
import           Control.Arrow ((&&&))
import           Control.Lens
import           Data.Time (UTCTime, diffUTCTime)
import qualified Data.Map as Map
import           Network.CEP.Processor.Sodium

import           Control.Applicative ((<$>))

-- | A node that periodically broadcasts the given temperature
-- at an interval of one second.
temperatureSource :: Temperature -> Behaviour UTCTime -> Processor s ()
temperatureSource temp time = do
    me    <- getProcessorPid
    death <- filterE ((== me) . (^. payload . removedNode)) <$> subscribe
    dieOn death
    tick  <- liftReactive $
               periodically (fmap (> 1) . flip diffUTCTime) epoch time
    publish $ const temp <$> tick

-- | A node that listens for Temperature events and averages them.
averageTemperature :: Behaviour UTCTime -> Processor s ()
averageTemperature now = do
    temperatureE <- fmap ((^. source) &&& (^. payload)) <$> subscribe
    removalE     <- fmap (^. payload . removedNode)     <$> subscribe
    avg <- liftReactive $ do
      nodes <- allNodes 1 now temperatureE removalE
      let poolTemperature = mean . Map.elems . liveNodes <$> nodes
      averageOver 3 now poolTemperature
    publish $ AverageTemperature <$> value avg
