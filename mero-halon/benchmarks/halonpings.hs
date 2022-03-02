--
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This a benchmakr which spawns twelve nodes which send events to the tracking
-- station during some time. It then gathers space and time statistics.
--

{-# LANGUAGE TemplateHaskell #-}
import HA.Stats hiding (__remoteTable)
import Mero.RemoteTables (meroRemoteTable)

import Control.Concurrent (forkIO)
import Control.Distributed.Commands.Management (withHostNames)
import Control.Distributed.Commands.Process
  ( copyFiles
  , systemThere
  , spawnNode
  , NodeHandle(..)
  , copyLog
  , expectLog
  , __remoteTable
  )
import Control.Distributed.Commands.Providers
  ( getHostAddress
  , getProvider
  )
import HA.Service hiding (__remoteTable)
import qualified HA.Services.Ping as Ping

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , runProcess
  )
import Control.Distributed.Process.Internal.Primitives (SayMessage(..))

import Control.Monad
import Data.IORef
import Data.Function (fix)
import Data.List (isInfixOf)
import Data.Maybe (catMaybes)

import Network.Transport.TCP (createTransport, defaultTCPParameters)

import System.Clock
import System.Environment (getExecutablePath)
import System.FilePath ((</>), takeDirectory)
import System.IO
import System.Timeout (timeout)
import Text.Printf


getBuildPath :: IO FilePath
getBuildPath = fmap (takeDirectory . takeDirectory) getExecutablePath

main :: IO ()
main = (>>= maybe (error "test timed out") return) $
       timeout (20 * 60 * 1000000) $ do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    cp <- getProvider

    buildPath <- getBuildPath

    ip <- getHostAddress
    Right nt <- createTransport ip "4000" defaultTCPParameters
    n0 <- newLocalNode nt (meroRemoteTable $ __remoteTable initRemoteTable)
    statsRef <- newIORef Nothing
    let nSat     = 12  -- amount of satellites
        nStation =  5  -- amount of nodes in the tracking station
        nPings   = 30  -- amount of pings each satellite will do

    withHostNames cp (nStation + nSat) $  \ms@(m0 : _) -> runProcess n0 $ do
      let mlocs = map (++ ":9000") ms
          (tsLocs, stLocs) = splitAt nStation mlocs
          halonctlloc = (++ ":9001")

      say "Copying binaries ..."
      copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                               , (buildPath </> "halond/halond", "halond") ]
      self <- getSelfPid
      flip copyLog self $ \(SayMessage _ _ msg) -> any (`isInfixOf` msg)
        [ "New replica started"
        , "Starting from empty graph"
        , "New node contacted"
        , "Node succesfully joined"
        , "started ping service on"
        , "received DummyEvent"
        ]

      say "Spawning halond ..."
      nhs <- forM (zip ms mlocs) $ \(m, mloc) ->
               spawnNode m ("HALON_TRACING=none ./halond -l " ++ mloc ++ " 2>&1")
      let nids = map handleGetNodeId nhs
          (tsNids, stNids) = splitAt nStation nids
      forM_ nhs $ \nh -> liftIO $ forkIO $ fix $ \loop -> do
        e <- handleGetInput nh
        case e of
          Left rc -> putStrLn $ show (handleGetNodeId nh) ++ ": terminated " ++ show rc
          Right s -> putStrLn (show (handleGetNodeId nh) ++ ": " ++ s) >> loop

      say "Spawning the tracking station ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ concatMap (\mloc -> " -a " ++ mloc) tsLocs
                     ++ " bootstrap station"
                     ++ " -r 8000000"
                     )
      forM_ tsNids $ \nid ->
        expectLog [nid] (isInfixOf "New replica started in legislature://0")
      expectLog tsNids (isInfixOf "Starting from empty graph.")

      say "Starting satellite nodes ..."
      systemThere [m0] ("./halonctl"
                     ++ " -l " ++ halonctlloc m0
                     ++ concatMap (\mloc -> " -a " ++ mloc) stLocs
                     ++ " bootstrap satellite"
                     ++ concatMap (\mloc -> " -t " ++ mloc) tsLocs
                     )
      forM_ (zip stNids stLocs) $ \(nid, mloc) -> do
        expectLog tsNids $ isInfixOf $ "New node contacted: nid://" ++ mloc
        expectLog [nid] $ isInfixOf "Node succesfully joined the cluster."

      say "Starting ping service ..."
      systemThere [m0] $ "./halonctl"
          ++ " -l " ++ halonctlloc m0
          ++ concatMap (\mloc -> " -a " ++ mloc) stLocs
          ++ " service ping start"
          ++ concatMap (\mloc -> " -t " ++ mloc) tsLocs
          ++ " 2>&1"
      forM_ stNids $ \nid ->
        expectLog tsNids $ isInfixOf $ "started ping service on " ++ show nid

      pingPids <- forM stNids $ \nid -> do
        whereisRemoteAsync nid $ serviceLabel $ serviceName Ping.ping
        WhereIsReply _ (Just pingPid) <- expect
        return pingPid

      say "Sending a first ping ..."
      forM_ pingPids $ \pingPid -> do
        send pingPid $! Ping.DummyEvent (show pingPid)
        expectLog tsNids $ isInfixOf $ "received DummyEvent " ++ show pingPid

      say "Starting benchmark ..."
      let batchSize = 5
      tsStats <- forM [1.. nPings `div` batchSize] $ \i -> do
        t0 <- liftIO $ getTime Monotonic
        forM_ [1..batchSize] $ \j ->
          forM_ pingPids $ \pingPid ->
            send pingPid $! Ping.DummyEvent (show (pingPid, i :: Int, j :: Int))
        forM_ [1..batchSize] $ \j ->
          forM_ pingPids $ \pingPid ->
            expectLog tsNids $ isInfixOf $
              "received DummyEvent " ++ show (pingPid, i, j :: Int)
        tf <- liftIO $ getTime Monotonic
        mems <- forM tsNids $ \nid -> do
          _ <- spawn nid $ $(mkClosure 'getStats) self
          expect
        let timeSpecAsSecs = toNanoSecs (diffTimeSpec tf t0)
                               `div` 10^(9 :: Int)
            mem = case catMaybes mems of
              xs | length xs == length tsNids -> Just (maximum xs :: Integer)
              _                               -> Nothing
        return (timeSpecAsSecs, mem)

      let (ts, mems) = unzip tsStats
      liftIO $ writeIORef statsRef $ Just $
        zip3 (map (* (nSat * batchSize)) [1 :: Int, 2 ..]) (scanl1 (+) ts) mems

    Just tsStats <- readIORef statsRef
    putStrLn $ unlines $
      [ ""
      , ""
      , "Started " ++ show nStation ++ " tracking station nodes and " ++
        show nSat ++ " satellites."
      , ""
      , "    pings   time (secs)  memory (kBs)"
      ] ++
      map (\(pings, ts, mem) ->
            printf "%8d  %12d  %12s" pings ts (maybe "unavailable" show mem))
          tsStats
      ++
      [ ""
      , "The memory column lists the maximum peak resident memory size in"
      , "any tracking station."
      ]
