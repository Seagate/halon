module Util where

import Data.Time
import FRP.Sodium
import qualified Data.Map as Map
import Data.Monoid ((<>))
import Control.Applicative ((<$>), liftA2)
import Data.Either (isRight)

-- | A Behaviour that listens for heartbeat (or in this case temperature)
-- and death events and keeps track of which nodes are still alive
-- and the values of their latest heartbeats.
allNodes :: Ord k
         => NominalDiffTime
         -- ^ The timeout after which a node can safely be assumed to no
         -- longer be sending heartbeats.
         -> Behaviour UTCTime
         -- ^ A Behaviour indicating the current time.
         -> Event (k, v)
         -- ^ An Event that produces (source, heartbeat) pairs.
         -> Event k
         -- ^ An Event that fires when a node dies.
         -> Reactive (Behaviour (Map.Map k (Either UTCTime v)))
allNodes timeout now update delete
  = accum Map.empty $ updateNode <> deleteNode <> purgeNodes
  where
    updateNode = liftA2 (Map.insertWith (>>)) fst (Right . snd) <$> update
    deleteNode = snapshot (\k t -> Map.insert k $ Left t) delete now
    purgeNodes = Map.filter . keep <$> value now
    
    keep _  Right{}  = True
    keep t' (Left t) = diffUTCTime t' t < timeout

-- | Get a map containing only the nodes that are currently alive.
liveNodes :: Map.Map k (Either UTCTime v) -> Map.Map k v
liveNodes = Map.map (\(Right x) -> x) . Map.filter isRight

-- | Calculate the mean of a list, or zero if the list is empty.
mean :: Fractional a => [a] -> a
mean [] = 0
mean xs = sum xs / fromIntegral (length xs)

