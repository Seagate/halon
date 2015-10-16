-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Tests creates a dummy instance of SSPL and allow to
-- test different interations of the SSPL-LL and halon.
--
-- Tests:
--   -- send command from the node and check that is was received
--        dummy by SSPL-LL
--   -- send reply from SSPL-LL and check that it was received by
--        RC
--   -- sensor receives message from sspl-ll
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE CPP #-}
module HA.Test.SSPL where

import Test.Framework
import Test.Tasty.HUnit

import HA.EventQueue.Producer (promulgateEQ)
import HA.EventQueue.Types (HAEvent(..))
import HA.Service
import HA.Services.SSPL
import HA.Services.SSPL.Rabbit
import HA.Services.SSPL.LL.Resources
import HA.Resources
import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.Startup (startupHalonNode, ignition)
import HA.NodeUp  (nodeUp)
import Network.CEP (Definitions, defineSimple, liftProcess)
import SSPL.Bindings

import RemoteTables ( remoteTable )

import Control.Exception as E
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Network.Transport (Transport)

import Data.Aeson
import Data.Defaultable
import Data.Binary (Binary)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Typeable
import Network.AMQP
import GHC.Generics

import TestRunner

data RChan = RChan String deriving (Generic, Typeable)

instance Binary RChan

data SChan = SChan SensorResponseMessageSensor_response_type deriving (Generic, Typeable)

instance Binary SChan

testRules :: ProcessId -> [Definitions LoopState ()]
testRules pid =
  [ defineSimple "sspl-test-sensor" $ \(HAEvent _ (_::NodeId, s) _) ->
      liftProcess $ usend pid (SChan s)
  ]

unit :: ()
unit = ()

remotable
  [ 'testRules, 'unit ]

-- | Create rabbit mq tests. This command checks if it's possible to connect
-- to the system
mkTests :: IO (Transport -> TestTree)
mkTests = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (_::AMQPException) -> return $ \_->
      testCase "SSPL tests disabled (can't connect to rabbitMQ)"  $ return ()
    Right x -> do
      closeConnection x
      return $ \transport ->
        testGroup "SSPL"
          [ testCase "proxy test" $ testProxy transport
          , testCase "SSPL Sensor" $ testSensor transport
          ]

testProxy :: Transport -> IO ()
testProxy transport = withTmpDirectory $ do
  E.bracket (newLocalNode transport remoteTable)
            (closeLocalNode)
    $ \n -> runProcess n $ do
      pid <- spawnLocal $ rabbitMQProxy $ ConnectionConf (Configured "localhost")
                                                         (Configured "/")
                                                         ("guest")
                                                         ("guest")
      link pid
      usend pid . MQSubscribe "test-queue" =<< getSelfPid
      usend pid (MQBind    "test-exchange" "test-queue" "test-queue")
      usend pid (MQPublish "test-exchange" "test-queue" "test")
      MQMessage "test-queue" "test" <- expect
      return ()


runSSPLTest :: Transport
            -> (ProcessId -> String -> Process ()) -- interseptor callback
            -> (ProcessId -> LocalNode -> Process ()) -- actual test
            -> Assertion
runSSPLTest transport interseptor test =
  runTest 2 20 15000000 transport (HA.Test.SSPL.__remoteTable remoteTable) $ \[n] -> do
    self <- getSelfPid
    -- Startup halon
    let rcClosure = ($(mkClosure 'recoveryCoordinatorEx) () `closureApply`
                       ($(mkClosure 'testRules) self)) `closureCompose`
                    $(mkStaticClosure 'ignitionArguments)
    _ <- liftIO $ forkProcess n $ do
      startupHalonNode rcClosure
      usend self ()
    () <- expect
    let args = ( False :: Bool
               , [localNodeId n]
               , 1000 :: Int
               , 1000000 :: Int
               , $(mkClosure 'recoveryCoordinatorEx) ()
                   `closureApply` ($(mkClosure 'testRules) self)
                   `closureApply` ($(mkClosure 'ignitionArguments) [localNodeId n])
               , 3*1000000 :: Int
               )
    _ <- liftIO $ forkProcess n $ ignition args >> usend self ()
    () <- expect
    _ <- liftIO $ forkProcess n $ do
            nodeUp ([localNodeId n], 1000000)
            usend self ()
    () <- expect
    _ <- liftIO $ forkProcess n $ registerInterceptor $ \string ->
      case string of
        str@"Starting service sspl"   -> usend self str
        str@"Register channels"       -> usend self (RChan str)
        x -> interseptor self x
    _ <- promulgateEQ [localNodeId n] $ encodeP $
      ServiceStartRequest Start (Node (localNodeId n)) sspl
          (SSPLConf (ConnectionConf (Configured "127.0.0.1")
                                    (Configured "/")
                                    ("guest")
                                    ("guest"))
                    (SensorConf   (BindConf (Configured "sspl_halon")
                                            (Configured "sspl_ll")
                                            (Configured "sspl_dcsque")))
                    (ActuatorConf (BindConf (Configured "sspl_iem")
                                            (Configured "sspl_ll")
                                            (Configured "sspl_iem"))
                                  (BindConf (Configured "sspl_halon")
                                            (Configured "sspl_ll")
                                            (Configured "sspl_halon"))
                                  (Configured 1000000)))
          []
    ("Starting service sspl" :: String) <- expect
    RChan "Register channels" <- expect
    pid <- spawnLocal $ do
      link self
      rabbitMQProxy $ ConnectionConf (Configured "localhost")
                                     (Configured "/")
                                     ("guest")
                                     ("guest")
    usend pid $ MQBind    "sspl_halon" "sspl_iem" "sspl_ll"
    usend pid $ MQSubscribe "sspl_iem" self
    test pid n
    _ <- promulgateEQ [localNodeId n] $ encodeP $
          ServiceStopRequest (Node $ localNodeId n) sspl
    _ <- receiveTimeout 1000000 []
    kill pid "end of game"

testSensor :: Transport -> IO ()
testSensor transport = runSSPLTest transport interseptor test
  where
    interseptor _ _ = return ()
    test pid _ = do
      -- Message was taken from the logs of the real SSPL service.
      let rawmsg = BS.concat
            [ "{\"username\": \"sspl-ll\""
            , ", \"description\": \"Seagate Storage Platform Library - Low Level - Sensor Response\""
            , ", \"title\": \"SSPL-LL Sensor Response\""
            , ", \"expires\": 3600, \"signature\": \"None\""
            , ", \"time\": \"2015-10-19 11:49:34.706694\""
            , ", \"message\": {\"sspl_ll_msg_header\": {\"msg_version\": \"1.0.0\", \"schema_version\": \"1.0.0\", \"sspl_version\": \"1.0.0\"}, \"sensor_response_type\": {\"host_update\": {\"loggedInUsers\": [\"vagrant\"], \"runningProcessCount\": 2, \"hostId\": \"devvm.seagate.com\", \"totalMem\": {\"units\": \"MB\", \"value\": 1930}, \"upTime\": 1445251379, \"uname\": \"Linux devvm.seagate.com 3.10.0-229.7.2.el7.x86_64 #1 SMP Tue Jun 23 22:06:11 UTC 2015 x86_64\", \"bootTime\": \"2015-10-19 10:42:59 \", \"processCount\": 126, \"freeMem\": {\"units\": \"MB\", \"value\": 142}, \"localtime\": \"2015-10-19 11:49:34 \"}}}}"
            ] :: ByteString
          Just msg = sensorResponseMessageSensor_response_type
            . sensorResponseMessage <$> decodeStrict rawmsg
      say "sending command"
      usend pid $ MQPublish "sspl_halon" "sspl_ll" rawmsg
      (SChan s) <- expect
      liftIO $ assertEqual "Correct command received" msg s
