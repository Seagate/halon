{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
--
-- Finds a running confd m0d process to, unsures SSPL service is not
-- running on the node the process belongs to, forcefully kills that
-- process, waits for keepalive failure and waits for the process to
-- come back online.
module HA.ST.ProcessKeepalive (test) where

import           Control.Applicative ((<|>))
import           Control.Distributed.Commands (systemLocal, systemThere)
import           Control.Distributed.Process
import           Data.Binary (Binary)
import           Data.List (isSuffixOf, nub, partition)
import           Data.Maybe (listToMaybe)
import           Data.Proxy (Proxy(..))
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           HA.EventQueue.Producer (promulgateEQ)
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.RC
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Castor.Initial as CI
import           HA.Resources.HalonVars
import           HA.Resources.Mero as M0
import           HA.Resources.Mero.Note as M0
import           HA.ST.Common
import qualified HA.Service as Service
import           HA.Services.Mero.Types (KeepaliveTimedOut(..))
import           HA.Services.SSPL (sspl)
import           Mero.ConfC (ServiceType(CST_MGS))
import           Network.CEP
import           System.Exit
import           Test.Tasty.HUnit (assertFailure)

newtype ST_ProcessKeepalive_GetInfo = ST_ProcessKeepalive_GetInfo ProcessId
  deriving (Show, Eq, Generic, Typeable)

data ST_ProcessKeepalive_GetInfo_Reply = ST_ProcessKeepalive_GetInfo_Reply
  [(Bool, String, M0.Process, M0.PID, Bool)]
  HalonVars
  deriving (Show, Eq, Generic, Typeable)

instance Binary ST_ProcessKeepalive_GetInfo
instance Binary ST_ProcessKeepalive_GetInfo_Reply

-- | Gather data about cluster state from RG and send back to the
-- test.
getInfoRule :: Definitions LoopState ()
getInfoRule = defineSimpleTask "st-process-keepalive-info" $ \(ST_ProcessKeepalive_GetInfo caller) -> do
  rg <- getLocalGraph
  hv <- getHalonVars

  let hostToIP host =
        listToMaybe [ ip | M0.LNid ip <- G.connectedTo host R.Has rg ]
        <|> listToMaybe [ ip | CI.Interface { CI.if_network = CI.Data, CI.if_ipAddrs = ip:_ }
                                 <- G.connectedTo host R.Has rg ]

      getIP node = listToMaybe [ ip' | h :: R.Host <- G.connectedFrom R.Runs node rg
                                     , Just ip <- [hostToIP h]
                                     , let ip' = if "@tcp" `isSuffixOf` ip
                                                 then take (length ip - length "@tcp") ip
                                                 else ip
                                     ]

      hasSSPL n = not $ null [ s | Just n' <- [M0.m0nodeToNode n rg]
                                 , s <- Service.lookupServiceInfo n' sspl rg ]

      -- if we picked a local node, we want to signal that we would
      -- like to use local system command
      isCallerNode m0n = Just (R.Node $ processNodeId caller) == m0nodeToNode m0n rg

      procs = [ (hasSSPL n, nodeIP, p, pid, isCallerNode n)
              | prof :: M0.Profile <- G.connectedTo R.Cluster R.Has rg
              , fs :: M0.Filesystem <- G.connectedTo prof M0.IsParentOf rg
              , n :: M0.Node <- G.connectedTo fs M0.IsParentOf rg
              , M0.getState n rg  == M0.NSOnline
              , Just nodeIP <- [getIP n]
              , p :: M0.Process <- G.connectedTo n M0.IsParentOf rg
              , M0.getState p rg == M0.PSOnline &&
                any (\s -> M0.s_type s == CST_MGS) (G.connectedTo p M0.IsParentOf rg)
              , Just pid <- [listToMaybe $ G.connectedTo p R.Has rg]
              ]

      result = ST_ProcessKeepalive_GetInfo_Reply procs hv

      ns = [ n | prof :: M0.Profile <- G.connectedTo R.Cluster R.Has rg
               , fs :: M0.Filesystem <- G.connectedTo prof M0.IsParentOf rg
               , n :: M0.Node <- G.connectedTo fs M0.IsParentOf rg ]

  phaseLog "st.debug" $ show (Just (R.Node $ processNodeId caller), map (\n -> m0nodeToNode n rg) ns)
  liftProcess $ usend caller result

test :: HASTTest
test = HASTTest "process-keepalive" [getInfoRule] $ \(TestArgs eqs _ _) step -> do
  liftIO $ step "Connected to cluster, subscribing and requesting info"
  subscribeOnTo eqs (Proxy :: Proxy KeepaliveTimedOut)
  self <- getSelfPid
  let timeout_secs = 10
  _ <- promulgateEQ eqs $ ST_ProcessKeepalive_GetInfo self
  liftIO $ step "Waiting for reply with cluster info"
  expectTimeout (timeout_secs * 1000000) >>= \case
    Nothing -> liftIO . assertFailure $
      "No reply in " ++ show timeout_secs ++ " seconds."
    Just (ST_ProcessKeepalive_GetInfo_Reply [] _) -> liftIO $ assertFailure
      "No online confd process found on any online nodes"
    Just (ST_ProcessKeepalive_GetInfo_Reply ps hv) ->
      case partition (\(sspl', _, _, _, _) -> sspl') ps of
        (failed, []) -> liftIO . assertFailure $
          "Every tried node has halon:sspl running." ++
          " Please stop it on one of these nodes before retrying: "
          ++ show (nub $ map (\(_, ip, _, _, _) -> ip) failed)

        (_, (_, ip, p, M0.PID pid, local) : _) -> do
          emptyMailbox (Proxy :: Proxy (Published KeepaliveTimedOut))
          let waitTimeout = _hv_keepalive_timeout hv + _hv_keepalive_frequency hv
          liftIO . step $ "Killing " ++ M0.showFid p ++ " on " ++ ip
          liftIO $ do
--            let runCmd = if local then systemLocal else systemThere ip
            let runCmd = systemLocal
            runCmd ("kill -9 " ++ show pid) >>= \act -> do
              let loop = act >>= \case
                    Left ExitSuccess -> step $ "Killed " ++ show pid
                    Left (ExitFailure rc) -> liftIO . assertFailure $
                      "Failed to kill process. Exit code: " ++ show rc
                    Right str -> do
                      step $ "Kill produced output: " ++ show str
                      loop
              loop
              step $ "Waiting at most " ++ show waitTimeout ++ " seconds for "
                  ++ "keepalive failure message to fly by for " ++ show (M0.fid p)
          mr <- receiveTimeout (waitTimeout * 1000000)
            [ matchIf (\(Published (KeepaliveTimedOut fids) _) ->
                         M0.fid p `elem` map fst fids)
                      (const . return $ M0.fid p) ]
          case mr of
            Nothing -> liftIO . assertFailure $
              "Didn't see timeout for " ++ show (M0.fid p) ++ " on time. Check cluster."
            Just fid' -> liftIO . step $ show fid' ++ " timed out on time!"
