-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Services are uniquely named on a given node by a string. For example
-- "ioservice" may identify the IO service running on a node.

{-# LANGUAGE TemplateHaskell, ExistentialQuantification #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.NodeAgent
      ( module HA.NodeAgent.Messages
      , Service(..)
      , service
      , nodeAgent
      , updateEQ
      , updateEQNodes
      , expire
      , __remoteTableDecl ) where

import HA.Call
import HA.NodeAgent.Messages
import HA.NodeAgent.Lookup (lookupNodeAgent,nodeAgentLabel)
import HA.Network.Address (Address,readNetworkGlobalIVar)
import HA.EventQueue (eventQueueLabel)
import HA.EventQueue.Types (HAEvent(..), EventId(..))
import HA.EventQueue.Producer (expiate)
import HA.Resources(Service(..),ServiceUncaughtException(..),Node(..))

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static (closureApply)
import Control.Distributed.Process.Serializable (Serializable)

import Control.Monad (when, void)
import Control.Applicative ((<$>))
import Control.Exception (Exception, throwIO, SomeException(..))
import Data.Binary (encode)
import Data.Maybe (catMaybes)
import Data.ByteString (ByteString)
import Data.Typeable (Typeable)
import Data.Word (Word64)

data ExpireReason = forall why. Serializable why => ExpireReason why
  deriving (Typeable)

instance Show ExpireReason where
  show _ = "ExpireReason"

data ExpireException = ExpireException ExpireReason
  deriving (Typeable, Show)

instance Exception ExpireException

expire :: Serializable a => a -> Process b
expire why = liftIO $ throwIO $ ExpireException $ ExpireReason why

serialCall :: (Serializable a, Serializable b) =>
              String ->
              [NodeId] -> a ->
              Timeout -> Process (Maybe b)
serialCall _ [] _ _ = return (Nothing)
serialCall name (node:nodes) msg timeOut =
  do whereisRemoteAsync node name
     mpid <- receiver [
              matchIf (\(WhereIsReply name' mpid') ->
                          name' == name && maybe False ((==)node . processNodeId) mpid')
                      (\(WhereIsReply _ mpid') -> return mpid')
            ]
     case mpid of
       Just (Just pid) -> do
          ret <- callTimeout pid msg timeOut
          case ret of
            Just b -> return (Just b)
            _ -> serialCall name nodes msg timeOut
       _ -> serialCall name nodes msg timeOut
  where receiver =
          case timeOut of
            Just n -> receiveTimeout n
            Nothing -> fmap Just . receiveWait

updateEQ :: ProcessId -> [Address] -> Process Result
updateEQ pid addrs =
  do network <- liftIO readNetworkGlobalIVar
     mns <- mapM (lookupNodeAgent network) addrs
     let nodes = map processNodeId $ catMaybes mns
     updateEQNodes pid nodes

updateEQNodes :: ProcessId -> [NodeId] -> Process Result
updateEQNodes pid nodes =
     maybe CantUpdateEQ id <$> callAt pid (UpdateEQ nodes)

remotableDecl [ [d|
    sdictServiceInfo :: SerializableDict (String, Closure (Process ()))
    sdictServiceInfo = SerializableDict

    serviceWrapper :: (String, Closure (Process ())) -> Process () -> Process ()
    serviceWrapper (name,cp) p = do
        self <- getSelfPid
        either (\(ProcessRegistrationException _) -> return ()) (const go) =<<
            try (register name self)
      where
        generalExpiate desc = do
          mbpid <- whereis nodeAgentLabel
          case mbpid of
             Nothing -> error "NodeAgent is not registered."
             Just na -> expiate $ ServiceUncaughtException (Node na) (Service name cp) desc
        myCatches n handler =
           (n >> handler (generalExpiate "Service died without exception")) `catches`
             [ Handler $ \(ExpireException (ExpireReason why)) -> handler $ expiate why,
               Handler $ \(SomeException e) -> handler $ generalExpiate $ show e ]
        go = myCatches p $ \res -> do
               self <- getSelfPid
               void $ spawnLocal $ do
                 ref <- monitor self

                 -- Wait for main service process to die before sending expiate. This will
                 -- ensure that any linked child processes are notified not after expiate.
                 receiveWait [
                    matchIf (\(ProcessMonitorNotification ref' _ _) -> ref' == ref)
                            (const $ return ()) ]
                 res

    -- | Wrapper function for services. Use as follows:
    --
    -- > remoteDecl [ [d|
    -- >   foo = service "foo" $(mkStaticClosure 'fooProcess)
    -- >
    -- >   fooProcess = ...
    -- >   |] ]
    --
    service :: String -> Closure (Process ()) -> Service
    service name p =
        Service name $
        $(mkStaticClosure 'serviceWrapper) `closureApply`
        closure (staticDecode $(mkStatic 'sdictServiceInfo)) (encode (name,p)) `closureApply`
        p

    -- | The master node agent process.
    nodeAgent :: Service
    nodeAgent = service nodeAgentLabel $(mkStaticClosure 'nodeAgentProcess)

    nodeAgentProcess :: Process ()
    nodeAgentProcess = go (0,[])
      where
        go :: (Word64, [NodeId]) -> Process a
        go (eventCounter, eqs) = do
              self <- getSelfPid
              receiveWait
                [ callResponse $ \servicemsg ->
                case servicemsg of
                  UpdateEQ eqnids -> do
                      return $ (Ok, (eventCounter, eqnids))
                  -- match a pre-serialized event sent from service
                , callResponseAsync (const $ Just (eventCounter + 1, eqs)) $ \content -> do
                    when (null eqs) $ say $
                        "Warning: service event cannot proceed, since \
                        \no event queues are registed in the node agent"
                    let timeOut = Just 1000000
                        ev = HAEvent { eventId = EventId self eventCounter
                                     , eventPayload = content :: [ByteString] }
                    ret <- serialCall eventQueueLabel eqs ev timeOut
                    case ret of
                      Just () -> return True
                      Nothing -> return False
                ] >>= go
    |] ]
