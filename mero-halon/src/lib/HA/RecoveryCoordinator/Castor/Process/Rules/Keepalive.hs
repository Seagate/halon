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
import           Control.Monad (unless, void)
import           Data.Foldable (traverse_)
import           HA.EventQueue.Types (HAEvent(..))
import           HA.RecoveryCoordinator.Castor.Drive.Rules.Repair
  ( abortSnsOperations )
import           HA.RecoveryCoordinator.Mero.State
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import           HA.RecoveryCoordinator.RC.Actions
import           HA.ResourceGraph (Graph)
import qualified HA.Resources.Mero as M0
import           HA.Services.Mero.Types (MeroFromSvc(KeepaliveTimedOut))
import           Mero.ConfC (Fid)
import           Network.CEP

-- | Process replies to keepalive requests sent to mero.
ruleProcessKeepaliveReply :: Definitions RC ()
ruleProcessKeepaliveReply = defineSimpleIf "process-keepalive-reply" g $ \(uid, fids) -> do
  todo uid
  ps <- getProcs fids <$> getGraph
  traverse_ (abortSnsOperations . fst) ps
  unless (null ps) $ do
    ct <- liftIO M0.getTime
    void . applyStateChanges $ map (\(p, t) -> stateSet p $ mkTr ct t) ps
  done uid
  where
    g (HAEvent uid (KeepaliveTimedOut fids)) _ = return $! Just (uid, fids)
    g _ _ = return Nothing

    mkTr ct t = Tr.processKeepaliveTimeout (ct - t)

    getProcs :: [(Fid, M0.TimeSpec)] -> Graph -> [(M0.Process, M0.TimeSpec)]
    getProcs fids rg = [ (p, t)
                       | (fid, t) <- fids
                       , Just p <- [M0.lookupConfObjByFid fid rg]
                       ]
