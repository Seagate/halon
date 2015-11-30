-- |
-- Copyright : (C) 2015 Xyratex Technology Limited.
-- License   : All rights reserved.
--

import Control.Distributed.Process.Consensus
import Control.Distributed.Process.Consensus.Paxos
import qualified Control.Distributed.Process.Consensus.BasicPaxos as BasicPaxos

import Control.Distributed.Process hiding (try)
import Control.Distributed.Process.Node
import Network.Transport (Transport)
import Network.Transport.TCP

import Data.IORef
import qualified Data.Map as Map
import Data.Time (getCurrentTime, diffUTCTime)
import System.FilePath ((</>))
import System.Posix.Temp (mkdtemp)
import Control.Monad
import Control.Concurrent.MVar


remoteTables :: RemoteTable
remoteTables =
  Control.Distributed.Process.Consensus.__remoteTable $
  BasicPaxos.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable

spawnAcceptor :: Process ProcessId
spawnAcceptor = do
    mref <- liftIO $ newIORef Map.empty
    vref <- liftIO $ newIORef Nothing
    spawnLocal $ do
      self <- getSelfPid
      acceptor usend
        (undefined :: Int) initialDecreeId
        (const $ return AcceptorStore
                      { storeInsert =
                          modifyIORef mref . flip (foldr (uncurry Map.insert))
                      , storeLookup = \d -> Map.lookup d <$> readIORef mref
                      , storePut = writeIORef vref . Just
                      , storeGet = readIORef vref
                      , storeTrim = const $ return ()
                      , storeList = Map.assocs <$> readIORef mref
                      , storeMap = readIORef mref
                      , storeClose = return ()
                      }
        )
        self

setup :: Transport -> Int -> ([ProcessId] -> Process ()) -> IO ()
setup transport numNodes action = do
    nodes@(node0 : _) <- replicateM numNodes $ newLocalNode transport remoteTables
    tmpdir <- mkdtemp "/tmp/tmp."

    runProcess node0 $ do
       αs <- forM nodes $ \nid -> liftIO $ do
               mv <- newEmptyMVar
               runProcess nid $ spawnAcceptor >>= liftIO . putMVar mv
               takeMVar mv
       action αs

main :: IO ()
main = do
    Right transport <- createTransport "127.0.0.1" "8080"
      defaultTCPParameters { tcpNoDelay = True }

    let iters = 100 :: Int
        numAcceptors = 5
    setup transport numAcceptors $ \them -> do
      -- warm up
      void $ runPropose $ BasicPaxos.propose 2000000 usend them (DecreeId 0 0)
                                             (0 :: Int)
      t0 <- liftIO getCurrentTime
      forM_ [1..iters] $ \i ->
        runPropose $ BasicPaxos.propose 2000000 usend them (DecreeId 0 i) i
      tf <- liftIO getCurrentTime
      liftIO $ do putStr "Proposal time: "
                  print (diffUTCTime tf t0 / fromIntegral iters)
