-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}
import Network.Transport as NT hiding ( send )
import Network.Transport.RPC ( createTransport, rpcAddress, defaultRPCParameters
                             , RPCTransport(..)
                             )
import Control.Distributed.Process hiding ( spawnLocal )
import Control.Distributed.Process.Node hiding ( forkProcess )
import Control.Distributed.Process.Internal.Types
import System.Environment
import qualified Data.ByteString.Char8 as B8
import Control.Exception as Exception ( SomeException, throwIO, catch )
import Control.Monad
import Control.Monad.Reader

import Control.Concurrent ( forkIO )
import Control.Concurrent.Chan ( writeChan )
import Data.Accessor
import qualified Data.Map as Map
import Control.Distributed.Process.Internal.CQueue ( newCQueue , mkWeakCQueue )
import Control.Distributed.Process.Internal.Messaging ( impliesDeathOf )
import Control.Distributed.Process.Internal.StrictMVar
import System.IO
import System.Random ( randomIO )

main :: IO ()
main = do
  [serverAddr, remoteServerAddr0, remoteServerAddr1] <- getArgs
  transport <- fmap networkTransport $
                    createTransport "s1" (rpcAddress serverAddr)
                                    defaultRPCParameters
  n <- newLocalNode transport initRemoteTable
  runProcess n $ do
    let serverNid0 = NodeId $ EndPointAddress $ B8.pack remoteServerAddr0
        serverNid1 = NodeId $ EndPointAddress $ B8.pack remoteServerAddr1
    whereisRemoteAsync serverNid0 "pingServer"
    WhereIsReply "pingServer" (Just pid0) <- expect
    whereisRemoteAsync serverNid1 "pingServer"
    WhereIsReply "pingServer" (Just pid1) <- expect
    send pid0 "terminate"
    -- Wait for server to die
    _ <- receiveTimeout 1000000 [] :: Process (Maybe ())
    replicateM_ 2 $ do
      liftIO $ putStrLn "begin callLocal"
      callLocal $ do
        self <- getSelfPid
        liftIO $ putStrLn "sending..."
        send pid0 self
        send pid1 self
        liftIO $ putStrLn "waiting..."
        "pong" <- expect
        liftIO $ putStrLn "received"
      liftIO $ putStrLn "done callLocal"
    liftIO $ putStrLn "done!"

callLocal :: Process a -> Process a
callLocal p = do
  mv <-liftIO $ newEmptyMVar
  self <- getSelfPid
  _ <- spawnLocal $ link self >> try p >>= liftIO . putMVar mv
  liftIO $ takeMVar mv
    >>= either (throwIO :: SomeException -> IO a) return

spawnLocal :: Process () -> Process ProcessId
spawnLocal proc = do
  node <- fmap processNode ask
  liftIO $ forkProcess node proc

forkProcess :: LocalNode -> Process () -> IO ProcessId
forkProcess node proc = modifyMVar (localState node) startProcess
  where
    startProcess :: LocalNodeState -> IO (LocalNodeState, ProcessId)
    startProcess st = do
      let lpid  = LocalProcessId { lpidCounter = st ^. localPidCounter
                                 , lpidUnique  = st ^. localPidUnique
                                 }
      let pid   = ProcessId { processNodeId  = localNodeId node
                            , processLocalId = lpid
                            }
      pst <- newMVar LocalProcessState { _monitorCounter = 0
                                       , _spawnCounter   = 0
                                       , _channelCounter = 0
                                       , _typedChannels  = Map.empty
                                       }
      queue <- newCQueue
      weakQueue <- mkWeakCQueue queue (return ())
      (_, lproc) <- fixIO $ \ ~(tid, _) -> do
        let lproc = LocalProcess { processQueue  = queue
                                 , processWeakQ  = weakQueue
                                 , processId     = pid
                                 , processState  = pst
                                 , processThread = tid
                                 , processNode   = node
                                 }
        tid' <- forkIO $ do
          reason <- Exception.catch
            (runLocalProcess lproc proc >> return DiedNormal)
            (return . DiedException . (show :: SomeException -> String))

          -- [Unified: Table 4, rules termination and exiting]
          modifyMVar_ (localState node) (cleanupProcess pid)
          writeChan (localCtrlChan node) NCMsg
            { ctrlMsgSender = ProcessIdentifier pid
            , ctrlMsgSignal = Died (ProcessIdentifier pid) reason
            }
        return (tid', lproc)

      if lpidCounter lpid == maxBound
        then do
          newUnique <- randomIO
          return ( (localProcessWithId lpid ^= Just lproc)
                 . (localPidCounter ^= firstNonReservedProcessId)
                 . (localPidUnique ^= newUnique)
                 $ st
                 , pid
                 )
        else
          return ( (localProcessWithId lpid ^= Just lproc)
                 . (localPidCounter ^: (+ 1))
                 $ st
                 , pid
                 )

    cleanupProcess :: ProcessId -> LocalNodeState -> IO LocalNodeState
    cleanupProcess pid st = do
      let pid' = ProcessIdentifier pid
      let (affected, unaffected) = Map.partitionWithKey (\(fr, _to) !_v -> impliesDeathOf pid' fr) (st ^. localConnections)
      mapM_ (NT.close . fst) (Map.elems affected)
      return $ (localProcessWithId (processLocalId pid) ^= Nothing)
             . (localConnections ^= unaffected)
             $ st
