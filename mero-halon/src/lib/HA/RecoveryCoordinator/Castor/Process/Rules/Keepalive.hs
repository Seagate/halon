{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE TypeFamilies     #-}
{-# LANGUAGE TypeOperators    #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Process handling.
module HA.RecoveryCoordinator.Castor.Process.Rules.Keepalive
  ( ruleProcessKeepaliveReply
  ) where


import           Control.Distributed.Process (liftIO)
import           Control.Monad (unless, void)
import           HA.EventQueue.Types (HAEvent(..))
import           HA.RecoveryCoordinator.Mero.State
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.Resources.Mero as M0
import           HA.Services.Mero.Types
import           Network.CEP

-- | Process replies to keepalive requests sent to mero.
ruleProcessKeepaliveReply :: Definitions RC ()
ruleProcessKeepaliveReply = defineSimpleIf "process-keepalive-reply" g $ \(uid, fids) -> do
  todo uid
  ps <- getProcs fids <$> getGraph
  unless (Prelude.null ps) $ do
    ct <- liftIO M0.getTime
    void . applyStateChanges $ map (\(p, t) -> stateSet p $ mkTr ct t) ps
  done uid
  where
    g (HAEvent uid (KeepaliveTimedOut fids)) _ = return $! Just (uid, fids)
    g _ _ = return Nothing

    mkTr ct t = Tr.processKeepaliveTimeout (ct - t)
    getProcs fids rg = [ (p, t) | (fid, t) <- fids
                                , Just (p :: M0.Process) <- [M0.lookupConfObjByFid fid rg]
                                ]
