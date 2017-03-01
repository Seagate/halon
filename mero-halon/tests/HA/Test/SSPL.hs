{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
-- |
-- Module    : HA.Test.SSPL
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
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
module HA.Test.SSPL where

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Node
import           Control.Distributed.Static
import           Control.Exception as E
import           Control.Monad (void)
import           Data.Binary (Binary)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import           Data.Defaultable
import qualified Data.HashMap.Strict as M (fromList)
import           Data.List (isInfixOf)
import           Data.Maybe (fromJust)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Time
import           Data.Typeable
import qualified Data.UUID as UUID
import           GHC.Generics
import           HA.Aeson
import qualified HA.Aeson as Aeson
import           HA.Encode
import           HA.EventQueue.Producer (promulgateEQ)
import           HA.EventQueue.Types (HAEvent(..))
import           HA.Multimap
import           HA.NodeUp  (nodeUp)
import           HA.RecoveryCoordinator.Definitions
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Service.Events
import           HA.Resources
import           HA.SafeCopy
import           HA.Services.SSPL hiding (header)
import           HA.Services.SSPL.CEP (sendNodeCmd)
import           HA.Services.SSPL.LL.Resources
import           HA.Services.SSPL.Rabbit
import           HA.Startup (startupHalonNode, ignition)
import           Network.AMQP
import           Network.CEP
import           Network.Transport (Transport)
import           RemoteTables ( remoteTable )
import           SSPL.Bindings
import           Test.Framework
import           Test.Tasty.HUnit
import           TestRunner

newtype SChan = SChan SensorResponseMessageSensor_response_typeDisk_status_drivemanager
  deriving (Generic, Typeable)
instance Binary SChan

data TestSmartCmd = TestSmartCmd !NodeId !ByteString deriving (Generic, Typeable)

testRules :: ProcessId ->  [Definitions RC ()]
testRules pid =
  [ defineSimple "sspl-test-send" $ \(HAEvent _ (TestSmartCmd nid t)) -> do
      void $ sendNodeCmd [Node nid] Nothing (SmartTest $ T.decodeUtf8 t)
  , defineSimpleIf "sspl-test-reply" cAck $ \s -> do
      liftProcess $ say $ "TEST-CA " ++ show s
  , defineSimpleIf "sspl-test-sensor" statusDm $ \s -> do
      liftProcess $ usend pid (SChan s)
  ]
  where
    cAck (HAEvent _ (CAck s)) _ = return $! Just s
    cAck _ _ = return Nothing

    statusDm (HAEvent _ (DiskStatusDm _ s)) _ = return $! Just s
    statusDm _ _ = return Nothing

unit :: ()
unit = ()

testRC :: (ProcessId, [NodeId]) -> ProcessId -> StoreChan -> Process ()
testRC (pid, eqNids) = recoveryCoordinatorEx () (testRules pid) eqNids

remotable
  [ 'testRC, 'testRules, 'unit ]

-- | Create rabbit mq tests. This command checks if it's possible to connect
-- to the system
mkTests :: IO (Transport -> TestTree)
mkTests = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (e::AMQPException) -> return $ \_->
      testCase "SSPL"  $ error $ "RabbitMQ error: " ++ show e
    Right x -> do
      closeConnection x
      return $ \transport ->
        testGroup "SSPL"
          [ testCase "proxy test" $ testProxy transport
          , testCase "SSPL Sensor" $ testSensor transport
          , testCase "SSPL Interface tests" $ testDelivery transport
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
    let rcClosure = $(mkClosure 'recoveryCoordinatorEx) () `closureApply`
                       ($(mkClosure 'testRules) self)
    _ <- liftIO $ forkProcess n $ do
      startupHalonNode rcClosure
      usend self ()
    () <- expect
    let args = ( False :: Bool
               , [localNodeId n]
               , 1000 :: Int
               , 1000000 :: Int
               , $(mkClosure 'testRC) (self, [localNodeId n])
               , 8*1000000 :: Int
               )
    _ <- liftIO $ forkProcess n $ ignition args >> usend self ()
    () <- expect
    _ <- liftIO $ forkProcess n $ do
            nodeUp [localNodeId n]
            usend self ()
    () <- expect
    _ <- liftIO $ forkProcess n $ registerInterceptor $ interseptor self
    let ssplConf =
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
                                  (BindConf (Configured "sspl_command_ack")
                                            (Configured "halon_ack")
                                            (Configured "sspl_command_ack"))
                                  (Configured 1000000)))
    _ <- serviceStartOnNodes [localNodeId n] sspl ssplConf [localNodeId n]
    pid <- spawnLocal $ do
      link self
      rabbitMQProxy $ ConnectionConf (Configured "localhost")
                                     (Configured "/")
                                     ("guest")
                                     ("guest")
    sayTest "Clearing RMQ queues"
    purgeRmqQueues pid [ "test-queue", "sspl_dcsque"
                       , "sspl_iem", "sspl_command_ack"]
    sayTest "Starting test"
    usend pid $ MQBind    "sspl_halon" "sspl_iem" "sspl_ll"
    usend pid $ MQSubscribe "sspl_iem" self
    test pid n
    sayTest "Test finished"
    _ <- promulgateEQ [localNodeId n] $ encodeP $
          ServiceStopRequest (Node $ localNodeId n) sspl
    _ <- receiveTimeout 1000000 []
    kill pid "end of game"

testSensor :: Transport -> IO ()
testSensor transport = runSSPLTest transport interseptor test
  where
    interseptor _ _ = return ()
    test pid _ = do
      t <- formatTimeSSPL <$> liftIO getCurrentTime
      -- Message was taken from the logs of the real SSPL service.
      let rawmsg = BS.concat
            [ "{\"username\": \"sspl-ll\""
            , ", \"description\": \"Seagate Storage Platform Library - Low Level - Sensor Response\""
            , ", \"title\": \"SSPL-LL Sensor Response\""
            , ", \"expires\": 3600, \"signature\": \"None\""
            , ", \"time\": \"", BS8.pack (T.unpack t), "\""
            , ", \"message\":  {\"sspl_ll_msg_header\": {\"msg_version\": \"1.0.0\", \"schema_version\": \"1.0.0\", \"sspl_version\": \"1.0.0\"}, \"sensor_response_type\":"
            , "{\"disk_status_drivemanager\": {\"enclosureSN\":\"HLM1002010G2YD5\", \"serialNumber\": \"Z8402HS4\", \"diskNum\": 29, \"diskReason\": \"None\", \"diskStatus\": \"OK\", \"pathID\": \"/dev/disk/by-id/wwn-0x5000c5007b00ecf5\"}}"
            , "}}"
            ] :: ByteString
          Just (Just msg) = sensorResponseMessageSensor_response_typeDisk_status_drivemanager
            . sensorResponseMessageSensor_response_type
            . sensorResponseMessage <$> decodeStrict rawmsg
      sayTest "sending command"
      usend pid $ MQPublish "sspl_halon" "sspl_ll" rawmsg
      SChan s <- expect
      liftIO $ assertEqual "Correct command received" msg s

testDelivery :: Transport -> IO ()
testDelivery transport = runSSPLTest transport interseptor test
  where
    interseptor self string
      | "TEST-CA " `isInfixOf` string =
        usend self (drop (length ("TEST-CA "::String)) string)
    interseptor _ _ = return ()
    test pid n = do
      _ <- promulgateEQ [localNodeId n] (TestSmartCmd (localNodeId n) "foo")
      MQMessage _ bs <- expect
      let Just ActuatorRequest
            {actuatorRequestMessage =
              ActuatorRequestMessage
                { actuatorRequestMessageActuator_request_type = ActuatorRequestMessageActuator_request_type
                    { actuatorRequestMessageActuator_request_typeNode_controller
                        = Just (ActuatorRequestMessageActuator_request_typeNode_controller cmd)
                    }
                , actuatorRequestMessageSspl_ll_msg_header=_header
                }} = decodeStrict bs
      Just (SmartTest "foo") <- return $ parseNodeCmd cmd

      msgTime <- liftIO $ getCurrentTime
      let uuid = fromJust $ UUID.fromString "c2cc10e1-57d6-4b6f-9899-38d972112d8c"
          header = Aeson.Object $ M.fromList [
              ("schema_version", Aeson.String "1.0.0")
            , ("sspl_version", Aeson.String "1.0.0")
            , ("msg_version", Aeson.String "1.0.0")
            , ("uuid", Aeson.String . T.decodeUtf8 . UUID.toASCIIBytes $ uuid)
            ]
          msg = ActuatorResponse
                  { actuatorResponseSignature = "auth_sig"
                  , actuatorResponseTime      = formatTimeSSPL msgTime
                  , actuatorResponseExpires   = Nothing
                  , actuatorResponseUsername  = "ssplll"
                  , actuatorResponseMessage   =
                      ActuatorResponseMessage
                        { actuatorResponseMessageActuator_response_type
                            = ActuatorResponseMessageActuator_response_type
                               { actuatorResponseMessageActuator_response_typeAck =
                                  Just ActuatorResponseMessageActuator_response_typeAck
                                    { actuatorResponseMessageActuator_response_typeAckAck_msg  = "Passed"
                                    , actuatorResponseMessageActuator_response_typeAckAck_type =
                                        nodeCmdString (SmartTest "foo")
                                    }
                               , actuatorResponseMessageActuator_response_typeThread_controller = Nothing
                               , actuatorResponseMessageActuator_response_typeService_controller = Nothing
                               }
                        , actuatorResponseMessageSspl_ll_msg_header = header
                        }
                  }
      usend pid $ MQPublish "sspl_command_ack" "halon_ack" (LBS.toStrict $ encode msg)
      let scmd = "CommandAck {commandAckUUID = Just c2cc10e1-57d6-4b6f-9899-38d972112d8c"
                  ++ ", commandAckType = Just (SmartTest \"foo\"), commandAck = AckReplyPassed}" :: String
      s <- expect
      liftIO $ assertEqual "Correct command received" scmd s
      _ <- receiveTimeout 500000 []
      return ()

deriveSafeCopy 0 'base ''TestSmartCmd
