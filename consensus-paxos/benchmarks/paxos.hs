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

import Data.Time (getCurrentTime, diffUTCTime)
import System.FilePath ((</>))
import System.Posix.Temp (mkdtemp)
import Control.Monad
import Control.Concurrent.MVar
import Statistics.Regression (olsRegress)
import qualified Data.Vector.Unboxed as UV (fromList, replicate)


remoteTables :: RemoteTable
remoteTables =
  Control.Distributed.Process.Consensus.__remoteTable $
  BasicPaxos.__remoteTable $
  Control.Distributed.Process.Node.initRemoteTable

setup :: Transport -> Int -> ([ProcessId] -> Process ()) -> IO ()
setup transport numNodes action = do
    nodes@(node0 : _) <- replicateM numNodes $ newLocalNode transport remoteTables
    tmpdir <- mkdtemp "/tmp/tmp."

    runProcess node0 $ do
       αs <- forM (zip [0..] nodes) $ \(i, nid) -> liftIO $ do
               mv <- newEmptyMVar
               runProcess nid $ do
                 pid <- spawnLocal $ acceptor (undefined :: Int)
                                       ((tmpdir </>) . show) (i :: Int)
                 liftIO $ putMVar mv pid
               takeMVar mv
       action αs

main :: IO ()
main = do
    Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters

    let iters = 1000
        numAcceptors = 5
    setup transport numAcceptors $ \them -> do
      -- warm up
      void $ runPropose $ BasicPaxos.propose them (DecreeId 0 0) (0 :: Int)

      rs <- forM [1..iters] $ \i -> do
        t0 <- liftIO getCurrentTime
        runPropose $ BasicPaxos.propose them (DecreeId 0 i) i
        tf <- liftIO getCurrentTime
        return $ diffUTCTime tf t0
      liftIO $ do
        putStr "Proposal time: "
        -- print (diffUTCTime tf t0 / fromIntegral iters)
        let (xs, r) = olsRegress
                        [ UV.fromList $ map fromIntegral [1 .. length rs] ]
                        (UV.fromList $ map realToFrac rs)
        mapM_ print rs
        print xs
        putStrLn $ "r^2: " ++ show r
