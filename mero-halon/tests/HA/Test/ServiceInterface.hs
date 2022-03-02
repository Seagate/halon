{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE LambdaCase #-}
-- |
-- Module    : HA.Test.ServiceInterface
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Service interface communication tests.
module HA.Test.ServiceInterface (tests) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Node (localNodeId)
import           Control.Lens
import           Data.Binary (Binary)
import           Data.Proxy
import           Data.Typeable
import           Data.Vinyl
import           GHC.Generics (Generic)
import           HA.EventQueue.Types (HAEvent(..))
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.RC.Application (RC)
import           HA.Replicator (RGroup)
import           HA.Service (getInterface)
import           HA.Service.Interface
import qualified HA.Services.Ping as Ping
import           Helper.Runner
import           Network.CEP
import           Network.Transport (Transport)
import           Test.Framework

tests :: (Typeable g, RGroup g) => Transport -> Proxy g -> [TestTree]
tests t pg =
  [ testSuccess "RC same version" $ testRcSameVersion t pg
  , testSuccess "RC higher version" $ testRcHigherVersion t pg
  , testSuccess "RC lower version" $ testRcLowerVersion t pg
  ]

-- | Simple options used throughout interface tests.
simpleTestOptions :: IO TestOptions
simpleTestOptions = do
  tops <- mkDefaultTestOptions
  return $ tops { _to_run_sspl = False }

-- | Send @'Maybe' 'String'@ to given 'ProcessId'. Used to notify test
-- runners about completion/failure from test rules.
notifyCaller :: MonadProcess m => ProcessId -> Maybe String -> m ()
notifyCaller caller = liftProcess . usend caller

-- | Message used to trigger rules used throughout the interface tests.
data IfaceRuleHook = IfaceRuleHook !ProcessId !NodeId
  deriving (Generic, Typeable)
instance Binary IfaceRuleHook

-- | Make a test that sends a message to ping service and awaits
-- reply. Allows the user to plug in different ping service version
-- however the result should ultimately be the same: the message comes
-- back.
mkVersionTest :: (Typeable g, RGroup g)
              => String
              -- ^ Rule name and message content.
              -> Ping.PingConf
              -- ^ Ping service configuration used to determine its
              -- interface version.
              -> Transport
              -> Proxy g
              -> IO ()
mkVersionTest name pconf t pg = do
  topts <- simpleTestOptions
  run' t pg [rule] topts $ \ts -> do
    let [nid] = localNodeId <$> _ts_nodes ts
    [_] <- serviceStartOnNodes [processNodeId $ _ts_rc ts]
                               Ping.ping pconf
                               [nid]
    self <- getSelfPid
    usend (_ts_rc ts) $ IfaceRuleHook self nid
    expect >>= \case
      Nothing -> return ()
      Just err -> fail err
  where
    pingMsg :: Ping.PingSvcEvent
    pingMsg = Ping.DummyEvent name

    pingReplyGuard (HAEvent _ v) _ _ | v == pingMsg = return $ Just ()
    pingReplyGuard _ _ _ = return Nothing

    rule :: Definitions RC ()
    rule = define ("test-" ++ name) $ do
      rule_init <- phaseHandle "rule_init"
      ping_reply <- phaseHandle "ping_reply"
      ping_reply_timeout <- phaseHandle "ping_reply_timeout"

      setPhase rule_init $ \(IfaceRuleHook caller nid) -> do
        modify Local $ rlens fldCaller . rfield .~ Just caller
        sendSvc (getInterface Ping.ping) nid pingMsg
        switch [ping_reply, timeout 20 ping_reply_timeout]

      setPhaseIf ping_reply pingReplyGuard $ \() -> do
        Just caller <- getField . rget fldCaller <$> get Local
        notifyCaller caller Nothing

      directly ping_reply_timeout $ do
        Just caller <- getField . rget fldCaller <$> get Local
        notifyCaller caller $ Just "Timed out waiting for ping reply."

      start rule_init args
      where
        fldCaller = Proxy :: Proxy '("caller", Maybe ProcessId)
        args = fldCaller =: Nothing


-- | Send a message to the ping service of the same version as the
-- service and wait for reply.
testRcSameVersion :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testRcSameVersion = mkVersionTest "same-version" Ping.defaultConf

-- | Send a message from RC with lower version to the ping service.
--
-- Expected flow of events:
--
-- * RC sends message with version 1, interface appends _v1 to message.
--
-- * Ping service v2 receives message v1, uses knowledge about v1 to decode it.
--
-- * The service processes message. In this case it is supposed to
--   simply send message back. It encodes the message and sends v2
--   message back: it does not store the information that the message
--   it's replying to came from v1.
--
-- * RC receives message v2. It realises it can't decode and and sends
--   it back to service saying it can't decode it and includes own
--   version.
--
-- * Service v2 takes the version v1 from RC and re-encodes message
--   with it and sends v1 message to RC.
--
-- * RC decodes and processes message.
testRcLowerVersion :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testRcLowerVersion = mkVersionTest "rc-lower-version" Ping.PingConf_v2

-- | Send a message of higher version from RC to the service.
--
-- Expected flow of events:
--
-- * RC sends message with version 1, interface appends _v1 to message.
--
-- * Ping service v0 receives message v1, tells RC that it doesn't
--   know how to decode it and includes own version in reply.
--
-- * RC receives the complaint and uses its version of v0 to re-encode
--   the message. Sends message v0 to service
--
-- * The service processes message and replies to RC with message v0.
--
-- * RC receives message v0, uses its knowledge of v0 to decode and
--   process the message.
testRcHigherVersion :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testRcHigherVersion = mkVersionTest "rc-higher-version" Ping.PingConf_v0
