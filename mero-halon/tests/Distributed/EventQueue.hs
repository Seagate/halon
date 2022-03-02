{-# LANGUAGE TemplateHaskell #-}
--
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This test exhibits starting a simple cluster over two nodes and controlling
-- it with `halonctl`.
--
-- We start two instances of `halond` on two nodes. We then boostrap a node
-- agent on each of these nodes, and a tracking station on one of them. Finally,
-- we contact the tracking station to request that the Dummy service be started
-- on the satellite node.
--
import Control.Distributed.Commands.Management (withHostNames)
import Control.Distributed.Commands.Process
  ( copyFiles
  , systemThere
  , spawnNode
  , copyLog
  , expectLog
  )
import Control.Distributed.Commands.Providers
  ( getProvider
  , getHostAddress
  )

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types hiding (remoteTable)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Debug hiding (remoteTable)

import Control.Monad
import Control.Monad.Reader (asks)

import Data.ByteString ( ByteString )
import Data.List (isInfixOf)
import Data.Maybe

import Network.Transport (Transport)
import Network.Transport.TCP
import Network.Socket hiding (send)

import System.Environment (getExecutablePath)
import System.FilePath ((</>), takeDirectory)
import System.Process (readProcess)
import System.Timeout

import HA.EventQueue (EventQueue, eventQueueLabel)
import HA.EventQueue.Producer
import HA.EventQueue.Types

import RemoteTables

import Test.Framework (tryWithTimeout)

triggerEvent :: NodeId -> Int -> Process ProcessId
triggerEvent nid = promulgateEQ [nid]

remoteRC :: ProcessId -> Process ()
remoteRC controller = do
    self <- getSelfPid
    send controller self
    forever $ do
      msg <- expect
      send controller (msg :: HAEvent [ByteString])

remotable ['remoteRC ]

getBuildPath :: IO FilePath
getBuildPath = fmap (takeDirectory . takeDirectory) getExecutablePath

newRemoteRC :: Transport
            -> (LocalNode -> ProcessId -> Process ())
            -> Process ()
newRemoteRC t k = do
    self <- getSelfPid
    bracket (liftIO $ newLocalNode t (__remoteTable remoteTable))
            (liftIO . closeLocalNode) $ \ln1 ->
      bracket (spawn (localNodeId ln1) $ $(mkClosure 'remoteRC) self)
              (\_ -> say "Finished") $ k ln1

globalTimeout :: Int
globalTimeout = 30 * 1000000 -- seconds

main :: IO ()
main =
  (>>= maybe (error "test timed out") return) $ timeout (120 * 1000000) $ do
    cp        <- getProvider
    buildPath <- getBuildPath
    ip        <- getHostAddress
    Right (nt, internals) <- createTransportExposeInternals ip "4000" defaultTCPParameters

    withHostNames cp 2 $ \ms@[m0,m1] -> do
      tryWithTimeout nt (__remoteTable remoteTable) globalTimeout $ do
        self <- getSelfPid

        let m0loc = m0 ++ ":9000"
            m1loc = m1 ++ ":9000"
            halonctlloc = (++ ":9001")

        copyFiles "localhost" ms [ (buildPath </> "halonctl/halonctl", "halonctl")
                                 , (buildPath </> "halond/halond", "halond") ]

        copyLog (const True) self

        say "Spawning halond on cluster nodes from test control node"
        _ <- spawnNode m0 ("./halond -l " ++ m0loc ++ " 2>&1")
        _ <- spawnNode m1 ("./halond -l " ++ m1loc ++ " 2>&1")

        say "Spawning tracking station ..."
        systemThere [m0] ("./halonctl"
                       ++ " -l " ++ halonctlloc m0
                       ++ " -a " ++ m0loc
                       ++ " bootstrap station"
                       )

        say "Waiting for tracking station to start ..."
        expectLog [nid0] (isInfixOf "New replica started in legislature://0")
        expectLog [nid0] (isInfixOf "RS: I'm the new leader, so starting RC ...")

        whereisRemoteAsync nid0 eventQueueLabel
        WhereIsReply _ (Just eq) <- expect

        newRemoteRC nt $ \ln1 rc -> do
          send eq rc
          _ <- triggerEvent nid0 1
          HAEvent (EventId _ 1) _ <- (expect :: Process (HAEvent [ByteString]))
          say "RC forwarded the event"
          say "Simulating connection lost..."
          say $ "Remote endpoint address: " ++ show (nodeAddress nid0)

          -- Break the connection
          n0 <- asks processNode
          liftIO $ do
            sock <- socketBetween internals (nodeAddress $ localNodeId n0) (nodeAddress nid0)
            sClose sock

          r2 <- triggerEvent nid0 2
          -- EQ should reconnect to the RC, and the RC should forward the
          -- event to me.
          HAEvent (EventId r2 1) _ <- (expect :: Process (HAEvent [ByteString]))
          say "RC reconnected from broken connection from EQ."
