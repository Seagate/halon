-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- An action that is responsible for creating and destroying nodes at random.
-- 

module NodeController where

import           Types
import           Util
import           Nodes

import           FRP.Sodium
import           Network.CEP.Processor.Sodium
import           Network.Transport (Transport)
import           Control.Distributed.Process (ProcessId)
import           Control.Lens

import           Control.Applicative ((<$>))
import           Control.Arrow ((&&&))
import           Control.Concurrent (threadDelay, forkIO)
import           Control.Monad (forever, when, void)
import           Control.Monad.Trans (liftIO)
import           Data.Time (UTCTime)
import qualified Data.Map as Map
import           Data.Maybe (listToMaybe)
import           System.Random (randomRIO)

-- | Repeatedly spawn and kill nodes at random times.
spawnNodes :: Behaviour UTCTime -> Transport -> Config -> IO ()
spawnNodes now transport config = do
    -- Events used to trigger the spawner/killer nodes
    (add,  pushAdd)  <- liftIO $ sync newEvent
    (kill, pushKill) <- liftIO $ sync newEvent

    void . liftIO . forkIO $ nodeSpawner add  now transport config
    void . liftIO . forkIO $ nodeKiller  kill now transport config

    forever . liftIO $ do
      threadDelay 200000

      rand <- randomRIO (0 :: Int, 5)

      if rand == 0
      then sync $ pushAdd  () -- if we rolled 0
      else when (rand < 3) . sync $ pushKill () -- if we rolled 1 or 2

-- | An action that spawns a new node on receipt on the firing of an Event.
nodeSpawner :: Event a -> Behaviour UTCTime -> Transport -> Config -> IO ()
nodeSpawner trigger now transport config = runProcessor transport config $
    void . liftReactive . listen trigger $ \_ -> do
      temp <- Temperature . fromIntegral <$> randomRIO (0 :: Int, 11)
      liftIO . void . forkIO $ runProcessor transport config $
        temperatureSource temp now

-- | An action that kills the node with the lowest ProcessId on the firing
-- of an event.
nodeKiller :: Event a -> Behaviour UTCTime -> Transport -> Config -> IO ()
nodeKiller trigger now transport config = runProcessor transport config $ do
    tempE    <- fmap (view source &&& view payload) <$> subscribe
                  :: Processor s (Event (ProcessId, Temperature))
    removalE <- fmap ((^. removedNode) . (^. payload)) <$> subscribe
    nodes    <- liftReactive $ allNodes 1 now tempE removalE
    let node =  listToMaybe . Map.keys . liveNodes <$> nodes
    publish . filterJust $ snapshot (const $ fmap NodeRemoval) trigger node
