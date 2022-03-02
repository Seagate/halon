{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
-- |
-- Module    : HA.Test.SSPL
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Tests creates a dummy instance of SSPL and allow to
-- test different interations of the SSPL-LL and halon.
--
-- Tests:
--   - send command from the node and check that is was received
--        by dummy SSPL
--   - halon:SSPL receives sensor message from dummy SSPL
module HA.Test.SSPL (mkTests) where

import           Control.Distributed.Process
import           Control.Exception as E
import           Data.Binary (Binary)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import           Data.String (fromString)
import qualified Data.Text as T
import           Data.Time
import           Data.Typeable
import           GHC.Generics
import           HA.Aeson
import           HA.EventQueue.Types (HAEvent(..))
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Mero
import           HA.Replicator (RGroup)
import           HA.Services.SSPL.LL.Resources
import           HA.Services.SSPL.Rabbit
import qualified Helper.Runner as H
import           Network.AMQP
import           Network.CEP
import           Network.Transport (Transport)
import           SSPL.Bindings
import           Test.Framework
import           Test.Tasty.HUnit

newtype SChan = SChan SensorResponseMessageSensor_response_typeDisk_status_drivemanager
  deriving (Generic, Typeable)
instance Binary SChan

-- | Create rabbit mq tests. This command checks if it's possible to connect
-- to the system
mkTests :: (Typeable g, RGroup g)
        => Transport -> Proxy g -> IO TestTree
mkTests transport pg = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (e :: AMQPException) -> return $
      testCase "SSPL" $ error $ "RabbitMQ error: " ++ show e
    Right x -> do
      closeConnection x
      return $ testGroup "SSPL"
        [ testCase "RMQ proxy works" $ testProxy transport pg
        , testCase "Sensor message reaches RC" $ testSensor transport pg
        ]

-- | Check that RMQ proxy is running and is taking messages. This test
-- is completely redundant because every other SSPL-using test relies
-- on this already.
testProxy :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testProxy t pg = H.run t pg [] $ \ts -> do
  self <- getSelfPid
  let exch = fromString "test-exchange"
      queue = fromString "test-queue"
      key = queue
      msg = fromString "test"
      rmq = H._rmq_pid $ H._ts_rmq ts
  purgeRmqQueues rmq [queue]
  usend rmq $ MQSubscribe queue self
  usend rmq $ MQBind    exch key queue
  usend rmq $ MQPublish exch queue msg
  Just (MQMessage q m) <- expectTimeout (10 * 1000000)
  liftIO $ assertEqual "Got message from correct queue" q queue
  liftIO $ assertEqual "Got correct message back" m msg
  purgeRmqQueues rmq [queue]

-- | Send a message to RMQ proxy which should then forward it to real
-- RMQ where it's picked up by SSPL, sent to RC and dealt with it
-- there. We listen for the message reaching RC.
testSensor :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testSensor t pg = H.run t pg [testRule] $ \ts -> do
  time <- formatTimeSSPL <$> liftIO getCurrentTime
  -- Message was taken from the logs of the real SSPL service.
  let rawmsg = BS.concat
        [ "{\"username\": \"sspl-ll\""
        , ", \"description\": \"Seagate Storage Platform Library - Low Level - Sensor Response\""
        , ", \"title\": \"SSPL-LL Sensor Response\""
        , ", \"expires\": 3600, \"signature\": \"None\""
        , ", \"time\": \"", BS8.pack (T.unpack time), "\""
        , ", \"message\":  {\"sspl_ll_msg_header\": {\"msg_version\": \"1.0.0\", \"schema_version\": \"1.0.0\", \"sspl_version\": \"1.0.0\"}, \"sensor_response_type\":"
        , "{\"disk_status_drivemanager\": {\"enclosureSN\":\"HLM1002010G2YD5\", \"serialNumber\": \"Z8402HS4\", \"diskNum\": 29, \"diskReason\": \"None\", \"diskStatus\": \"OK\", \"pathID\": \"/dev/disk/by-id/wwn-0x5000c5007b00ecf5\"}}"
        , "}}"
        ] :: ByteString
      Just (Just msg) = sensorResponseMessageSensor_response_typeDisk_status_drivemanager
        . sensorResponseMessageSensor_response_type
        . sensorResponseMessage <$> decodeStrict rawmsg
  sayTest "sending command"
  withSubscription [processNodeId $ H._ts_rc ts] (Proxy :: Proxy SChan) $ do
    H._rmq_publishSensorMsg (H._ts_rmq ts) rawmsg
    SChan s <- expectPublished
    liftIO $ assertEqual "Correct command received" msg s
  where
    testRule :: Definitions RC ()
    testRule = defineSimpleIf "sspl-test-sensor" statusDm $ \s -> do
      publish $ SChan s

    statusDm (HAEvent _ (DiskStatusDm _ s)) _ = return $! Just s
    statusDm _ _ = return Nothing
