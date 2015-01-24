{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
-- | A compendium of snapshotting methods
module Control.Distributed.Log.Snapshot
    ( LogSnapshot(..)
    , serializableSnapshot
    , serializableSnapshotServer
    ) where

import Control.Arrow (second)
import Control.Concurrent.MVar
import Control.Distributed.Process
import Control.Distributed.Process.Scheduler (schedulerIsEnabled)
import Control.Distributed.Process.Serializable
import Control.Exception (SomeException, throwIO, Exception)
import qualified Control.Exception as E (bracket)
import Control.Monad (forever, when)
import Control.Monad.Reader (ask)
import Control.Monad.State (put)
import Data.Acid
import Data.Binary (encode, decode, Binary)
import Data.SafeCopy
import Data.Typeable
import GHC.Generics (Generic)
import System.Directory (removeDirectoryRecursive)
import System.FilePath ((</>))


-- | Operations to initialize, read and write snapshots
data LogSnapshot s = LogSnapshot
    { logSnapshotInitialize    :: Process s
    , logSnapshotsGetAvailable :: Process [(Int, (NodeId, Int))]
    , logSnapshotRestore       :: (NodeId, Int) -> Process s
    , logSnapshotDump          :: Int -> s -> Process (NodeId, Int)
    }

-- | A newtype wrapper to provide a default instance of 'SafeCopy' for types
-- having 'Binary' instances.
newtype SafeCopyFromBinary a = SafeCopyFromBinary { binaryFromSafeCopy :: a }
  deriving Typeable

instance Serializable a => SafeCopy (SafeCopyFromBinary a) where
    getCopy = contain $ fmap (SafeCopyFromBinary . decode) $ safeGet
    putCopy = contain . safePut . encode . binaryFromSafeCopy

data SerializableSnapshot s = SerializableSnapshot Int s
                              -- watermark and snapshot
  deriving Typeable

$(deriveSafeCopy 0 'base ''SerializableSnapshot)

readLogIndex :: Query (SerializableSnapshot s) Int
readLogIndex = do SerializableSnapshot w _ <- ask
                  return w

readSnapshot :: Query (SerializableSnapshot s) (Int, s)
readSnapshot = do SerializableSnapshot w s <- ask
                  return (w, s)

writeSnapshot :: Int -> s -> Update (SerializableSnapshot s) ()
writeSnapshot w s = put $ SerializableSnapshot w s

$(makeAcidic ''SerializableSnapshot
             ['readSnapshot, 'writeSnapshot, 'readLogIndex]
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

    , logSnapshotsGetAvailable = callLocal $ do
          self <- getSelfPid
          here <- getSelfNode
          pid <- getSnapshotServer Nothing
          send pid self
          expectFrom pid >>=
            maybe (return [])
                  (\i -> return [(i, (here, i))])

    , logSnapshotRestore = \(nid, i) -> callLocal $ do
          self <- getSelfPid
          pid <- getSnapshotServer $ Just nid
          send pid (self, i)
          expectFrom pid >>=
            maybe (liftIO $ throwIO (NoSnapshot (nid, i)))
                  return

    , logSnapshotDump = \i s -> callLocal $ do
          self <- getSelfPid
          here <- getSelfNode
          pid <- getSnapshotServer Nothing
          send pid (self, (i, s))
          () <- expectFrom pid
          return (here, i)
    }

  where

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

    -- @expectFrom pid@ monitors @pid@ while it waits for a message.
    expectFrom :: Serializable a => ProcessId -> Process a
    expectFrom pid =
      withMonitor pid $ do
        receiveWait
          [ match $ \(ProcessMonitorNotification _ p r) ->
              liftIO $ throwIO $ ProcessLinkException p r
          , match return
          ]

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
        [ match $ \pid -> do
            i <- liftIO (withSnapshotAcidState here $ flip query ReadLogIndex)
            send pid $ Just (i :: Int)

        , match $ \(pid, i) -> do
            (i', s) <- liftIO $ withSnapshotAcidState here $ \acid ->
              fmap (second binaryFromSafeCopy) $ query acid ReadSnapshot
            send pid (if i == i' then Just s else Nothing)

        , match $ \(pid, (i, s)) -> do
            liftIO $ withSnapshotAcidState here $ \acid -> do
              update acid $ WriteSnapshot i (SafeCopyFromBinary s)
              createCheckpoint acid
              createArchive acid
              removeDirectoryRecursive $ snapshotDirectory here
                                         </> "Archive"
            send pid ()
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
                       (SerializableSnapshot 0 (SafeCopyFromBinary s0))
                  )
                  closeAcidState

-- | An internal type used only by 'callLocal'.
data Done = Done
  deriving (Typeable,Generic)

instance Binary Done

-- XXX pending inclusion upstream.
callLocal :: Process a -> Process a
callLocal p = do
  mv <-liftIO $ newEmptyMVar
  self <- getSelfPid
  _ <- spawnLocal $ link self >> try p >>= liftIO . putMVar mv
                      >> when schedulerIsEnabled (send self Done)
  when schedulerIsEnabled $ do Done <- expect; return ()
  liftIO $ takeMVar mv
    >>= either (throwIO :: SomeException -> IO a) return
