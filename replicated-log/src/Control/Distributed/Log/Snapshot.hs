{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}
-- | A compendium of snapshotting methods
module Control.Distributed.Log.Snapshot
    ( LogSnapshot(..)
    , serializableSnapshot
    , serializableSnapshotServer
    ) where

import Control.Arrow (second)
import Control.Distributed.Log () -- SafeCopy LegislatureId instance
import Control.Distributed.Log.Internal (callLocal)
import Control.Distributed.Process.Consensus (DecreeId(..))
import Control.Distributed.Process hiding (callLocal, send)
import Control.Distributed.Process.Serializable
import Control.Exception (throwIO, Exception)
import qualified Control.Exception as E (bracket)
import Control.Monad (forever)
import Control.Monad.Reader (ask)
import Control.Monad.State (put)
import Data.Acid
import Data.Binary (encode, decode)
import Data.SafeCopy
import Data.Typeable


-- | Operations to initialize, read and write snapshots
data LogSnapshot s = LogSnapshot
    { logSnapshotInitialize    :: Process s
    , logSnapshotsGetAvailable :: Process [(DecreeId, (NodeId, Int))]
    , logSnapshotRestore       :: (NodeId, Int) -> Process s
    , logSnapshotDump          :: DecreeId -> s -> Process (NodeId, Int)
    }

-- | A newtype wrapper to provide a default instance of 'SafeCopy' for types
-- having 'Binary' instances.
newtype SafeCopyFromBinary a = SafeCopyFromBinary { binaryFromSafeCopy :: a }
  deriving Typeable

instance Serializable a => SafeCopy (SafeCopyFromBinary a) where
    getCopy = contain $ fmap (SafeCopyFromBinary . decode) $ safeGet
    putCopy = contain . safePut . encode . binaryFromSafeCopy

data SerializableSnapshot s = SerializableSnapshot DecreeId s
                              -- watermark and snapshot
  deriving Typeable

$(deriveSafeCopy 0 'base ''SerializableSnapshot)

readDecreeId :: Query (SerializableSnapshot s) DecreeId
readDecreeId = do SerializableSnapshot w _ <- ask
                  return w

readSnapshot :: Query (SerializableSnapshot s) (DecreeId, s)
readSnapshot = do SerializableSnapshot w s <- ask
                  return (w, s)

writeSnapshot :: DecreeId -> s -> Update (SerializableSnapshot s) ()
writeSnapshot w s = put $ SerializableSnapshot w s

$(makeAcidic ''SerializableSnapshot
             ['readSnapshot, 'writeSnapshot, 'readDecreeId]
 )

newtype NoSnapshotServer = NoSnapshotServer NodeId
  deriving (Typeable, Show)

instance Exception NoSnapshotServer

newtype NoSnapshot = NoSnapshot (NodeId, Int)
  deriving (Typeable, Show)

instance Exception NoSnapshot

-- | Reads and writes snapshots in the given directory.
--
-- Sends snapshots in one message over the network.
--
-- Takes as argument the label of the snapshot server and the initial state.
serializableSnapshot :: forall s. Serializable s => String -> s -> LogSnapshot s
serializableSnapshot serverLbl s0 = LogSnapshot
    { logSnapshotInitialize = return s0

    , logSnapshotsGetAvailable = do
          here <- getSelfNode
          pid <- getSnapshotServer Nothing
          callWait pid () >>=
            maybe (return [])
                  (\d -> return [(d, (here, decreeNumber d))])

    , logSnapshotRestore = \(nid, i) -> do
          pid <- getSnapshotServer $ Just nid
          (d, s) <- callWait pid i >>=
                      maybe (liftIO $ throwIO (NoSnapshot (nid, i)))
                            return
          -- Dump the snapshot locally so it is available at a
          -- later time.
          _ <- apiLogSnapshotDump d s
          return s

    , logSnapshotDump = apiLogSnapshotDump
    }

  where

    apiLogSnapshotDump d s = do
        here <- getSelfNode
        pid <- getSnapshotServer Nothing
        () <- callWait pid (d, s)
        return (here, decreeNumber d)

    -- Retrieves the ProcessId of the snapshot server on a given node.
    --
    -- If 'Nothing' is given as argument, then the 'ProcessId' of the local
    -- snapshot server is retrieved.
    getSnapshotServer :: Maybe NodeId -> Process ProcessId
    getSnapshotServer mnid = do
      here <- getSelfNode
      case mnid of
        Just nid | here /= nid ->
          callLocal $ bracket (monitorNode nid) unmonitor $ \_ -> do
          -- Get the ProcessId of the snapshot server.
          whereisRemoteAsync nid serverLbl
          receiveWait
            [ match $ \(NodeMonitorNotification _ n r) ->
                liftIO $ throwIO $ NodeLinkException n r
            , match $ \(WhereIsReply _ mpid) ->
                maybe (liftIO $ throwIO $ NoSnapshotServer nid) return mpid
            ]

        _ -> do
          whereis serverLbl >>=
            maybe (liftIO $ throwIO $ NoSnapshotServer here) return

    -- @callWait pid a@ sends @(tmp,a)@ to @pid@ and waits for a reply of type
    -- @b@ sent to @tmp@. @tmp@ is the 'ProcessId' of a temporary process used
    -- to collect the reply.
    --
    -- Throws a @ProcessLinkException@ if it gets disconnected from @pid@ before
    -- receiving the reply.
    callWait :: (Serializable a, Serializable b) => ProcessId -> a -> Process b
    callWait pid a = callLocal $ do
        self <- getSelfPid
        -- @link@ works here because the target process is expected to be
        -- non-terminating. Otherwise, the death notification could arrive
        -- before the reply.
        link pid
        usend pid (self, a)
        expect

-- | Takes the snapshots server label, the filepath for saving snapshots
-- and the initial state.
--
-- It spawns the snapshot server and returns its pid.
serializableSnapshotServer :: forall s . Serializable s
                           => String
                           -> (NodeId -> FilePath)
                           -> s
                           -> Process ProcessId
serializableSnapshotServer serverLbl snapshotDirectory s0 = do
    here <- getSelfNode
    pid <- spawnLocal $ forever $ receiveWait
        [ match $ \(pid, ()) -> do
            d <- liftIO (withSnapshotAcidState here $ flip query ReadDecreeId)
            usend pid $ -- if i == 0 then Nothing
                                   Just (d :: DecreeId)

        , match $ \(pid, i) -> do
            (d, s) <- liftIO $ withSnapshotAcidState here $ \acid ->
              fmap (second binaryFromSafeCopy) $ query acid ReadSnapshot
            usend pid $ if decreeNumber d == i then Just (d, s) else Nothing

        , match $ \(pid, (d, s)) -> do
            liftIO $ withSnapshotAcidState here $ \acid -> do
              update acid $ WriteSnapshot d (SafeCopyFromBinary s)
              -- TODO: fix checkpoints in acid-state.
              -- "log-size-remains-bounded" and "durability" were failing
              -- because acid-state would complain that the checkpoint file is
              -- missing.
              --
              -- createCheckpoint acid
              -- createArchive acid
              -- removeDirectoryRecursive $ snapshotDirectory here
              --                           </> "Archive"
            usend pid ()
        ]
    register serverLbl pid
    return pid

  where

    withSnapshotAcidState
          :: NodeId
          -> (AcidState (SerializableSnapshot (SafeCopyFromBinary s)) -> IO a)
          -> IO a
    withSnapshotAcidState nid =
        E.bracket (openLocalStateFrom (snapshotDirectory nid)
                       (SerializableSnapshot (DecreeId 0 0)
                                             (SafeCopyFromBinary s0)
                       )
                  )
                  closeAcidState
