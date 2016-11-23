{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE TypeFamilies     #-}
{-# LANGUAGE TypeOperators    #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Process handling.
module HA.RecoveryCoordinator.Castor.Process.Rules.Keepalive
  ( ruleProcessKeepaliveReply
  ) where


import           Control.Distributed.Process (liftIO)
import           Control.Monad (unless)
import           HA.RecoveryCoordinator.RC.Actions
import           HA.RecoveryCoordinator.Mero.State
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import qualified HA.Resources.Mero as M0
import           HA.Services.Mero.Types
import           Network.CEP

-- | Process replies to keepalive requests sent to mero.
ruleProcessKeepaliveReply :: Definitions RC ()
ruleProcessKeepaliveReply = defineSimpleTask "process-keepalive-reply" $ \(KeepaliveTimedOut fids) -> do
  ps <- getProcs fids <$> getLocalGraph
  unless (Prelude.null ps) $ do
    ct <- liftIO M0.getTime
    applyStateChanges $ map (\(p, t) -> stateSet p $ mkTr ct t) ps
  where
    mkTr ct t = Tr.processFailed $ "No keepalive for " ++ show (ct - t)
    getProcs fids rg = [ (p, t) | (fid, t) <- fids
                                , Just (p :: M0.Process) <- [M0.lookupConfObjByFid fid rg]
                                ]
