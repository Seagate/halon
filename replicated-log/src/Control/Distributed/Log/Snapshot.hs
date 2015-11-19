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

import Control.Applicative (liftA2)
import Control.Distributed.Log () -- SafeCopy LegislatureId instance
import Control.Distributed.Log.Persistence as P
import Control.Distributed.Log.Persistence.LevelDB
import Control.Distributed.Process.Consensus (DecreeId(..))
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Exception (throwIO, Exception)
import qualified Control.Exception as E (bracket)
import Control.Monad (forever)
import Data.Binary (encode, decode)
import qualified Data.ByteString.Lazy as BSL (ByteString)
import Data.String (fromString)
import Data.Typeable


-- | Operations to initialize, read and write snapshots
data LogSnapshot s = LogSnapshot
    { logSnapshotInitialize    :: !(Process s)
    , logSnapshotsGetAvailable :: !(Process [(DecreeId, (NodeId, Int))])
    , logSnapshotRestore       :: !((NodeId, Int) -> Process s)
    , logSnapshotDump          :: !(DecreeId -> s -> Process (NodeId, Int))
    }

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
          return $! decode s

    , logSnapshotDump = \d s -> apiLogSnapshotDump d (encode s)
    }

  where

    apiLogSnapshotDump :: DecreeId -> BSL.ByteString -> Process (NodeId, Int)
    apiLogSnapshotDump d s = callLocal $ do
        here <- getSelfNode
        pid <- getSnapshotServer Nothing
        link pid
        -- Place the write request in the mailbox of the server.
        self <- getSelfPid
        usend pid (self, (d, s))
        worker <- expect
        -- Answer the ping of the server to test if we are still interested.
        -- With big snapshots we might be interrupted before the server can
        -- handle our request.
        usend worker ()
        () <- expect
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

-- | Takes the snapshots server label and the filepath for saving snapshots.
--
-- It spawns the snapshot server and returns its pid.
serializableSnapshotServer :: String
                           -> (NodeId -> FilePath)
                           -> Process ProcessId
serializableSnapshotServer serverLbl snapshotDirectory = do
    here <- getSelfNode
    pid <- spawnLocal $ forever $ receiveWait
        [ match $ \(pid, ()) -> do
            md <- liftIO $ withPersistentStore here $ \_ pm ->
                    fmap (fmap decode) $ P.lookup pm 0
            usend pid (md :: Maybe DecreeId)

        , match $ \(pid, i) -> do
            (md, ms) <- liftIO $ withPersistentStore here $ \_ pm ->
              liftA2 (,) (P.lookup pm 0) (P.lookup pm 1)
            usend pid $ case liftA2 (,) (fmap decode md) ms of
              Just (d, s) | decreeNumber d == i -> Just (d, s)
              _                                 -> Nothing

        , match $ \(pid, (d :: DecreeId, s)) -> callLocal $ do
            ref <- monitor pid
            -- Test if the client is still there. The message could have been
            -- resting in our mailbox for a while.
            getSelfPid >>= usend pid
            receiveWait
              [ match $ \() -> do
                  liftIO $ withPersistentStore here $ \ps pm -> do
                    P.atomically ps [ Insert pm 0 (encode d)
                                    , Insert pm 1 s
                                    ]
                  usend pid ()
              , matchIf (\(ProcessMonitorNotification ref' _ _) -> ref' == ref)
                        (\_ -> return ())
              ]
        ]
    register serverLbl pid
    return pid

  where

    withPersistentStore :: NodeId
                        -> (PersistentStore -> PersistentMap Int -> IO a)
                        -> IO a
    withPersistentStore nid action =
        E.bracket (openPersistentStore (snapshotDirectory nid)) P.close $
          \ps -> P.getMap ps (fromString serverLbl) >>= action ps
