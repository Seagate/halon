{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE TemplateHaskell            #-}
-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Logic for adding new node to the halon cluster. When node can be
-- added to cluster, one should issue 'nodeUp' call on the target node. 
--
-- 'nodeUp' requests list of the current event queue nodes and
-- acknowledge node presence to Recovery Coordinator.
-- This will update 'EQTracker' and node will try to announce itself.
-- 
-- After node announced itself with 'NodeUp' message, this message
-- will be periodically resent until Recovery coordinator will acknowledge
-- delivery.
module HA.NodeUp
  ( NodeUp(..)
  , nodeUp
  , nodeUp__static
  , nodeUp__sdict
  , nodeUp__tdict
  , __remoteTable
  )
where

import           Control.Distributed.Process hiding (catch)
import           Control.Distributed.Process.Closure
import           Control.Monad.Catch
import           Data.Function (fix)
import           Data.Hashable
import           Data.Typeable
import           GHC.Generics
import           HA.SafeCopy
import           HA.EventQueue.Producer (promulgate)
import qualified HA.EQTracker.Internal as EQT
import           Network.HostName
import           System.IO


-- | NodeUp message sent to the Recovery Coordinator when a node starts.
data NodeUp =
  -- | 'NodeUp' @nodeHostname@ @nodePid@
  NodeUp String ProcessId
  deriving (Eq, Show, Typeable, Generic, Ord)
instance Hashable NodeUp
deriveSafeCopy 0 'base ''NodeUp

-- | Process which setup EQT and then repeatedly sends 'NodeUp' messages
--   to the EQ, until one is acknowledged with a '()' reply.
nodeUp :: ( [NodeId]
          , Int
          )
        -- ^ @(eqs, delay)@: set of EQ nodes to contant and the
        -- interval between sending messages in milliseconds.
       -> Process ()
nodeUp (eqs, _delay) = do
    self <- getSelfPid

    eqNodes <- case eqs of
      -- We're trying to set the list of EQ nodes to []: that's not
      -- good because then the promulgate will not complete under
      -- normal circumstances. Instead of hoping that EQT will in the
      -- future get updated by something and promulgate completes,
      -- either send to existing EQ nodes (i.e. do nothing here) or
      -- fail if no such nodes are known about.
      [] -> withEQPid $ \retry ps -> do
        usend ps $ EQT.ReplicaRequest self
        expectTimeout 1000000 >>= \case
          Nothing -> retry
          Just (EQT.ReplicaReply (EQT.ReplicaLocation prefs eqns)) ->
            if null eqns && null prefs
            then fail "nodeUp: tried setting EQ nodes to [] with no replicas present"
            else do
              say "nodeUp: called with empty list of EQ nodes, using existing EQs instead"
              return eqns
      -- The list of requested eq nodes is not empty so we can safely
      -- update it and then use promulgate.
      eqs' -> withEQPid $ \retry ps -> do
        usend ps $ EQT.UpdateEQNodes self eqs'
        expectTimeout 1000000 >>= \case
          Just EQT.UpdateEQNodesAck -> return eqs'
          _ -> retry

    say $ "Sending NodeUp message to " ++ show eqNodes ++ " me -> " ++ (show $ processNodeId self)
    h <- liftIO getHostName
    _ <- promulgate $ NodeUp h self
    expect :: Process ()
    say "Node succesfully joined the cluster."
   `catch` \e -> do
     liftIO $ hPutStrLn stderr $
       "nodeUp exception: " ++ show (e :: SomeException)
     say $ "nodeUp exception: " ++ show e
     throwM e
  where
    withEQPid :: (Process a -> ProcessId -> Process a) -> Process a
    withEQPid act = fix $ \loop ->
      whereis EQT.name >>= maybe (receiveTimeout 100000 [] >> loop)
                                 (act loop)


remotable ['nodeUp]
