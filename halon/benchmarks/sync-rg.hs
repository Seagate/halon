{-# LANGUAGE CPP                        #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

import Control.DeepSeq (NFData(rnf))
import Control.Distributed.Process
  ( Process
  , liftIO
  , catch
  , getSelfNode
  , unClosure
  , newChan
  , receiveChan
  , sendChan
  , link
  )
import Control.Distributed.Process.Closure (mkStatic)
import Control.Distributed.Process.Node (runProcess)
import Control.Distributed.Process.Serializable (SerializableDict(..))
import Control.Exception (SomeException, throwIO)
import Control.Monad (void)
import Criterion.Main

import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.List (foldl')
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Network.Transport (Transport)

import HA.Multimap (defaultMetaInfo, MetaInfo, StoreChan)
import HA.Multimap.Implementation (Multimap, fromList)
import HA.Multimap.Process (startMultimap)
import HA.Replicator (RGroup(..))
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock (MC_RG)
#else
import HA.Replicator.Log (MC_RG)
#endif
import HA.ResourceGraph hiding (__remoteTable)
import HA.Resources.TH

import RemoteTables (remoteTable)
import Test.Framework hiding (defaultMain)
import Test.Transport (mkInMemoryTransport, getTransport)

import HA.ResourceGraph.Tests (rGroupTest)

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

instance NFData Transport where
  rnf a = seq a ()

mmSDict :: SerializableDict (MetaInfo, Multimap)
mmSDict = SerializableDict

data NodeA = NodeA Int
  deriving (Eq, Typeable, Generic, Show)

instance Hashable NodeA
instance Binary NodeA

data EdgeA = EdgeA
  deriving (Eq, Typeable, Generic, Show)

instance Hashable EdgeA
instance Binary EdgeA

$(mkDicts
  [ ''NodeA ]
  [ (''NodeA, ''EdgeA, ''NodeA) ]
 )

$(mkResRel
  [ ''NodeA ]
  [ (''NodeA, ''EdgeA, ''NodeA) ]
  [ 'mmSDict ]
 )

--------------------------------------------------------------------------------
-- Test helpers                                                               --
--------------------------------------------------------------------------------

makeTransport :: IO Transport
makeTransport = mkInMemoryTransport >>= return . getTransport

tryRunProcessLocal :: Transport -> Process () -> IO ()
tryRunProcessLocal transport process =
    withTmpDirectory $
      withLocalNode transport (__remoteTable remoteTable) $ \node ->
        runProcess node process

rGroupTest :: (RGroup g, Typeable g)
           => Transport -> g (MetaInfo, Multimap)
           -> (StoreChan -> Process ()) -> IO ()
rGroupTest transport g p = tryRunProcessLocal transport $ do
  nid <- getSelfNode
  rGroup <- newRGroup $(mkStatic 'mmSDict) 20 1000000 [nid] (defaultMetaInfo, fromList [])
              >>= unClosure >>= (`asTypeOf` return g)
  (mmpid, mmchan) <- startMultimap rGroup $ \loop -> do
    catch loop $ \e -> liftIO (print (e :: SomeException) >> throwIO e)
  link mmpid
  p mmchan

--------------------------------------------------------------------------------
-- Tests                                                                      --
--------------------------------------------------------------------------------

main :: IO ()
main = defaultMain [
    env makeTransport $ \ t -> bgroup "small" [
      bench "1" $ whnfIO $ testSyncLarge t 1
{-
    , bench "3" $ whnfIO $ testSyncLarge t 3
    , bench "5" $ whnfIO $ testSyncLarge t 5
    , bench "7" $ whnfIO $ testSyncLarge t 7
    , bench "9" $ whnfIO $ testSyncLarge t 9
-}
    ]
{-
  , env makeTransport $ \ t -> bgroup "medium" [
      bench "10" $ whnfIO $ testSyncLarge t 10
    , bench "30" $ whnfIO $ testSyncLarge t 30
    , bench "50" $ whnfIO $ testSyncLarge t 50
    , bench "70" $ whnfIO $ testSyncLarge t 70
    , bench "90" $ whnfIO $ testSyncLarge t 90
    ]
  , env makeTransport $ \ t -> bgroup "large" [
      bench "100" $ whnfIO $ testSyncLarge t 100
    , bench "300" $ whnfIO $ testSyncLarge t 300
    , bench "500" $ whnfIO $ testSyncLarge t 500
    , bench "700" $ whnfIO $ testSyncLarge t 700
    , bench "900" $ whnfIO $ testSyncLarge t 900
    ]
-}
  ]


testSyncLarge :: Transport -> Int -> IO ()
testSyncLarge t n = HA.ResourceGraph.Tests.rGroupTest t g $ \mm -> do
    return ()
{-
    g1 <- syncWait =<< getGraph mm
    let g2 = buildCompleteGraph n g1
    void $ syncWait g2
-}
  where
    g = undefined :: MC_RG (MetaInfo, Multimap)

syncWait :: Graph -> Process Graph
syncWait g = do
    (sp, rp) <- newChan
    sync g (sendChan sp ()) <* receiveChan rp

buildCompleteGraph :: Int -> Graph -> Graph
buildCompleteGraph n = addResources . addEdges where
  addResources = foldl' (.) id $ fmap (newResource . NodeA) range
  addEdges = foldl' (.) id
              $ fmap (\(a,b) -> connect (NodeA a) EdgeA (NodeA b))
              $ pairs range
  range = [1 .. n]
  pairs :: [a] -> [(a,a)]
  pairs [] = []
  pairs (x:xs) = [(x,y)|y <- xs] ++ pairs xs
