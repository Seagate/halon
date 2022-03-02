-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Implementation of CloudHaskell's "Network.Transport" with rpclite.
--

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Network.Transport.RPC
    ( RPCParameters(..)
    , RPCTransport(..)
    , defaultRPCParameters
    , createTransport
    , withTransport
    , encodeEndPointAddress
    , decodeEndPointAddress
    , EndPointKey(..)
    , rpcAddress
    , RPCAddress(..)
    ) where

import Control.Concurrent ( Chan, writeChan, readChan, newChan, MVar, newMVar
                          , newEmptyMVar, modifyMVar_, putMVar, takeMVar
                          , readMVar, modifyMVar, threadDelay
                          )
import Control.Exception  ( catch, finally, bracketOnError, throwIO, try
                          , mask_, uninterruptibleMask_, bracket, SomeException
                          )
import Control.Monad
import Data.Bits  (shiftL, shiftR, (.&.))
import qualified Data.ByteString as B ( length, foldl, ByteString, null, drop, take, pack
                                      , append, concat, singleton, head )
import qualified Data.ByteString.Char8 as B8 ( pack, unpack, elemIndexEnd )
import Data.Char ( isSpace )
import qualified Data.Foldable as F ( forM_ )
import Data.IORef ( IORef, newIORef, atomicModifyIORef, readIORef )
import qualified Data.Map as M (empty, lookup, insert, filter, delete, member, partition)
import Data.Map  (Map)
import Data.Word (Word32,Word64)
import Foreign.Ptr (WordPtr)
import Mero.Concurrent
import Network.Transport as T
import Network.RPC.RPCLite as R
import System.Environment     ( getEnv )
import System.FilePath        ( (</>), normalise, pathSeparator )
import System.IO
import System.IO.Unsafe ( unsafePerformIO )
#ifdef DEBUG
import GHC.Exts ( currentCallStack )
import System.IO(hPutStrLn, stderr)
#endif

data RPCParameters = RPCParameters
    { prpcConnectTimeout :: Int -- ^ timeout for connecting and disconnecting
    , prpcSendTimeout :: Int -- ^ timeout for sending messages
    , prpcReservedAddressRange :: Word32
                             -- ^ The range [0..prpcReservedAddressRange-1]
                             -- is not used for producing endpoint addresses
                             -- with 'newEndPoint'.
    }

-- | Default RPC parameters.
defaultRPCParameters :: RPCParameters
defaultRPCParameters = RPCParameters
    { prpcConnectTimeout = 5
    , prpcSendTimeout = 5
    , prpcReservedAddressRange = 10
    }

#ifdef DEBUG
globalLock :: MVar ()
globalLock = unsafePerformIO$ newMVar ()
#endif

debug :: String -> IO ()
#ifdef DEBUG
debug s = withMVar globalLock$ const$ hPutStrLn stderr s >> currentCallStack >>= mapM_ (hPutStrLn stderr . ("  "++))
#else
debug = const$ return ()
#endif

newtype EndPointKey = EndPointKey Word32
  deriving (Eq,Ord,Show)

-- | A type for identifying connections initiated locally.
newtype LocalConnectionId = LocalConnectionId Word32
  deriving (Eq,Ord,Enum,Num,Show)

-- Type or RPC connections.
-- Since the identifier of closed connections may be reused,
-- it cannot be used to identify transport connections.
type RPCConnId = WordPtr

data LocalEndPoint = LocalEndPoint
    { leEndPoint :: EndPoint
    , leQueue :: Chan Event
    , leConnIdGen :: IORef LocalConnectionId
    , leConns :: IORef (Map LocalConnectionId T.Connection)
    }

data TransportState = TransportState
    { tsPrpc :: RPCParameters    -- ^ the parameters supplied by the user
    , tsSe :: ServerEndpoint     -- ^ the RPC server endpoint serving the transport instance
    , tsLocalEPs :: IORef (Map EndPointKey LocalEndPoint)
        -- ^ reference to map of local endpoint keys to event queues
    , tsConnToEP :: IORef (Map RPCConnId (EndPointKey,ConnectionId))
        -- ^ reference to map of connections to endpoint keys. An invariant of
        -- this map is that every endpoint key in the map must have a corresponding
        -- entry in the 'tsLocalEPs' map.
    , tsEPKeyGen :: IORef Word32 -- ^ generator of endpoint keys. It is incremented every time an
                                 -- endpoint is created
    , tsConnectionIdGen :: IORef Word64 -- ^ generator of connection ids.
                                    -- Incremented on every connection creation.
    , tsLock :: MVar ()  -- A lock used to serialized access to RPCLite. This lock helps winnowing
                         -- concurrency bugs.
    , tsM0Thread :: M0Thread
    , tsM0Chan :: Chan (IO ())
    }


newTransportState :: RPCParameters -> ServerEndpoint -> IO TransportState
newTransportState params se = do
    eps <- newIORef M.empty
    connToEP <- newIORef M.empty
    kgen <- newIORef $ max 0 $ prpcReservedAddressRange params
    cidgen <- newIORef 0
    lock <- newMVar ()
    m0chan <- newChan
    m0t <- forkM0OS $
             flip catch (\e -> const (return ()) (e :: SomeException)) $
             forever $
             catch (join $ readChan m0chan) $
                   \e -> do
                     hPutStrLn stderr $
                       "n-t-rpc m0thread terminated with: "
                       ++ show (e :: SomeException)
                     throwIO e
    return$ TransportState
        { tsPrpc = params
        , tsSe = se
        , tsLocalEPs = eps
        , tsConnToEP = connToEP
        , tsEPKeyGen = kgen
        , tsConnectionIdGen = cidgen
        , tsLock = lock
        , tsM0Thread = m0t
        , tsM0Chan = m0chan
        }

m0Queue :: TransportState -> IO () -> IO ()
m0Queue ts = writeChan (tsM0Chan ts)

m0QueueWait :: TransportState -> IO a -> IO a
m0QueueWait ts io = do
    mv <- newEmptyMVar
    m0Queue ts $ io >>= putMVar mv
    takeMVar mv


{-# NOINLINE rpcInitCounter #-}
rpcInitCounter :: MVar Word32
rpcInitCounter = unsafePerformIO$ newMVar 0

-- | Transport type for RPC. It extends the basic 'Network.Transport.Transport'
-- with a few extra features.
--
data RPCTransport = RPCTransport
    { -- | The Network.Transport.Transport instance of the RPC transport.
      networkTransport :: Transport

    -- | @newReservedEndPoint i@ produces an endpoint with address
    -- @rpcAddress ++ \":\" ++ show i@ if @i@ is in the reserved range (see
    -- 'prpcReservedAddressRange'). If @i@ is already in use or it is beyond the
    -- reserved range,
    -- @Left (TransportError NewEndPointInsufficientResources) errorMessage@
    -- is returned instead.
    --
    , newReservedEndPoint :: Word32
                   -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)

    -- | This is the server endpoint used by this RPC transport instance.
    --
    -- This is needed by confc bindings.
    --
    , serverEndPoint :: ServerEndpoint
    }

-- | Evaluates 'initRPC' the first time createTransport is called.
-- closeTransport evaluates 'finalizeRPC' when closing the last transport.
--
-- When the transport is created an RPC server endpoint is created.
--
-- This call needs to be made from an m0_thread only.
--
createTransport :: String -- ^ a string prepended to file names that the RPC
                          -- implementation creates at startup. A transport which starts
                          -- after a crash should use the same files it was using before
                          -- the crash. We are not using any feature relying on these
                          -- files yet, but the RPC transport won’t work at all if two
                          -- transports try to use the same set of files simultaneously.
                          -- Because of this, it is also relevant to consider which is
                          -- the path to the current working directory since transports
                          -- using the same prefix on different file system directories
                          -- wouldn’t interfere with each other.
                          --
                          -- When environment variable @NTR_DB_DIR@ is set, the
                          -- directory path set by the variable will be used for Mero
                          -- databases. If @NTR_DB_DIR@ is not set, Mero database
                          -- directories will be created under current working directory.
                          --
                   -> RPCAddress  -- ^ local address to use for connections
                   -> RPCParameters -- ^ other RPC parameters
                   -> IO RPCTransport
createTransport persistencePrefix addr prpc = do
    ntrDbDir <- try (getEnv "NTR_DB_DIR") :: IO (Either SomeException FilePath)
    let (dbDir, persistencePrefix') = case ntrDbDir of
            Right dir | not (null (filter (not . isSpace) dir)) ->
                (normalise (dir ++ [pathSeparator]), dir </> persistencePrefix)
            _    -> ("", persistencePrefix)
    bracketOnError
      (rpcInit dbDir)
      (const$ rpcFinalize)
      $ const$ mask_$ do
          rec se <- listen persistencePrefix' addr
                           ListenCallbacks { receive_callback = rpcReceived ts }
              ts <- newTransportState prpc se
          return RPCTransport
            { networkTransport = Transport
                {   newEndPoint = rpcNewEndPoint ts addr
                ,   closeTransport = uninterruptibleMask_ $
                       (readIORef (tsLocalEPs ts) >>= \eps -> F.forM_ eps$ \ep ->
                           closeEndPoint (leEndPoint ep)
                          `finally` writeChan (leQueue ep) EndPointClosed
                       )
                      `finally` m0Queue ts (stopListening se)
                      `finally` m0Queue ts rpcFinalize
                      `finally` do m0Queue ts $ error "transport closed"
                                   joinM0OS (tsM0Thread ts)
                }
            , newReservedEndPoint = rpcNewReservedEndPoint ts addr
            , serverEndPoint = se
            }
  where
    rpcInit dbDir =  modifyMVar_ rpcInitCounter$ \c ->
                 if c>0 then return (c+1)
                   else initRPCAt dbDir >> return (c+1)
    rpcFinalize = modifyMVar_ rpcInitCounter$ \c ->
                    if c>1 then return (c-1)
                      else finalizeRPC >> return (c-1)

-- | Wraps an IO action with calls to 'createTransport' and 'closeTransport'.
withTransport :: String -> RPCAddress -> RPCParameters
              -> (RPCTransport -> IO a) -> IO a
withTransport pfx addr ps = bracket (createTransport pfx addr ps)
                                    (closeTransport . networkTransport)


-- | An item sent by the RPC backend can be of one of three types:
--
-- * A connection opening item
--
-- * A regular item
--
-- * A connection closing item
--
-- The connection opening message is the first message sent through a connection.
-- The message carries the key of the target endpoint and the endpoint address
-- of the source endpoint.
--
-- If there is an endpoint with the provided key, then the message is replied
-- and the connection is associated to the endpoint key in the transport state.
-- Otherwise, the message is ignored and the connection remains open but all
-- subsequent traffic is ignored. We don't know how to close the connection on
-- the server side yet.
--
-- A regular item carries a message which is delivered to the transport user
-- if the connection has an associated endpoint key in the transport state.
-- Otherwise the message is ignored.
--
-- The connection closing message is sent by the sender side to announce that the
-- connection will be closed shortly and no more messages will be delivered. It
-- is an empty message.
--
data ItemT = ItemRegular [B.ByteString]
           | ItemOpening EndPointKey EndPointAddress
           | ItemClosing
  deriving Show

-- | serializes an ItemT
item2bs :: ItemT -> B.ByteString
item2bs ItemClosing = B.singleton 2
item2bs (ItemOpening epk epa) = B.concat [B.singleton 1, epk2bs epk, endPointAddressToByteString epa]
  where
    epk2bs :: EndPointKey -> B.ByteString
    epk2bs (EndPointKey w) = B.pack [ fromIntegral (shiftR w i .&. 0xFF) | i<-[24,16,8,0] ]
item2bs (ItemRegular bs) = B.concat$ B.singleton 0:bs

-- | rebuilds an ItemT from the serialized form
bs2item :: B.ByteString -> ItemT
bs2item bs | not (B.null bs) =
    let msg = B.drop 1 bs
     in case B.head bs of
          0 -> ItemRegular [msg]
          1 | B.length msg>4 -> ItemOpening (EndPointKey$ bs2Word32$ B.take 4 msg)
                                            (EndPointAddress$ B.drop 4 msg)
          2 -> ItemClosing
          _ -> error "bs2item: unknown item"
  where
    bs2Word32 :: B.ByteString -> Word32
    bs2Word32 = B.foldl (\v w -> shiftL v 8 + fromIntegral w) (0 :: Word32)
bs2item _ = error "bs2item: unknown item"

-- | RPC background threads call this whenever an RPC item is received on the server side.
rpcReceived :: TransportState -> Item -> WordPtr -> IO Bool
rpcReceived ts it _ = do
    cid <- getConnectionId it
    msg <- getFragments it
    if null msg then
      error "Network.Transport.RPC.rpcReceived: unkown message type"
     else
      return ()
    case bs2item$ head msg of

     ItemRegular ds -> do -- This is a regular message, deliver it
        c2ep <- readIORef (tsConnToEP ts)
        eps <- readIORef (tsLocalEPs ts)
        case M.lookup cid c2ep of
          Nothing  -> return False -- No endpoint for the connection, so ignore the message
          Just (epk,trcid) -> case M.lookup epk eps of
            Nothing  -> error$ "endpoint for connection "++show cid++" is missing"
            Just ep -> do -- deliver the message
              writeChan (leQueue ep)$ Received trcid ds
              return True

     ItemOpening epk epAddr -> do -- connection opening message
        eps <- readIORef (tsLocalEPs ts)
        case M.lookup epk eps of
          Nothing  -> return False -- endpoint does not exist, so ignore message
          Just ep -> do -- note that the connection is inserted in the tsConnToEP map
                        -- only if the endpoint already exists
            trcid <- atomicModifyIORef (tsConnectionIdGen ts)$ \gcid-> (gcid+1,gcid)
            atomicModifyIORef (tsConnToEP ts)$
                \c2ep -> (M.insert cid (epk,trcid) c2ep,())
            -- after the state is modified, announce the connection to the user
            writeChan (leQueue ep)$ ConnectionOpened trcid ReliableOrdered epAddr
            return True

     ItemClosing -> do -- connection closing message
        mepk <- atomicModifyIORef (tsConnToEP ts)$ \c2ep ->
                    (M.delete cid c2ep,M.lookup cid c2ep)
        eps <- readIORef (tsLocalEPs ts)
        case mepk of
          Nothing  -> return True -- No endpoint for the connection, but respond
                                  -- for the sake of politeness.
          Just (epk,trcid) -> case M.lookup epk eps of
            Nothing  -> return False -- endpoint does not exist, so ignore message
            Just ep -> do
              writeChan (leQueue ep)$ ConnectionClosed trcid
              return True


-- | Creating an endpoint amounts to generating a new endpoint key, an event queue
-- and inserting them in the tsLocalEPs map of the transport state.
rpcNewEndPoint :: TransportState -> RPCAddress -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)
rpcNewEndPoint ts addr = do
    epk <- atomicModifyIORef (tsEPKeyGen ts)$ \kgen -> (kgen+1,kgen)
    rpcNewEndPointFromKey ts addr epk

-- | Creates an endpoint in the reserved address range.
--
-- @rpcNewReservedEndPoint i@ produces an endpoint with address
-- @rpcAddress ++ \":\" ++ show i@ if @i@ is in the reserved range. If @i@ is
-- already in use or it is beyond the reserved range
-- @Left (TransportError NewEndPointInsufficientResources) errorMessage@
-- is returned instead.
--
rpcNewReservedEndPoint :: TransportState -> RPCAddress -> Word32
                       -> IO (Either (TransportError NewEndPointErrorCode)
                                     EndPoint
                             )
rpcNewReservedEndPoint ts addr epk = do
    if prpcReservedAddressRange (tsPrpc ts) <= epk
      then return $ Left (TransportError
                            NewEndPointInsufficientResources
                            "EndPoint id not in the reserved range."
                         )
      else do
        eps <- readIORef (tsLocalEPs ts)
        if M.member (EndPointKey epk) eps
          then return $ Left (TransportError
                                NewEndPointInsufficientResources
                                "EndPoint id is already in use."
                             )
          else rpcNewEndPointFromKey ts addr epk

-- | Creates an endpoint from an endpoint key.
--
-- The key must not be in used by another endpoint.
--
-- It creates an event queue and inserts key and queue in the tsLocalEPs map of
-- the transport state.
rpcNewEndPointFromKey :: TransportState -> RPCAddress -> Word32
                      -> IO (Either (TransportError NewEndPointErrorCode)
                                    EndPoint
                            )
rpcNewEndPointFromKey ts addr epk = do
    rcm <- newIORef M.empty
    rconngen <- newIORef $ LocalConnectionId 0
    rconns <- newIORef M.empty
    epq <- newChan
    let epAddr = encodeEndPointAddress addr (EndPointKey epk)
        lep = LocalEndPoint ep epq rconngen rconns
        ep = EndPoint
          { receive = readChan epq
          , address = epAddr
          , T.connect = rpcConnect ts epAddr (EndPointKey epk) lep rcm
          , newMulticastGroup = error "newMulticastGroup: unimplemented"
          , resolveMulticastGroup = error "resolveMulticastGroup: unimplemented"
          , closeEndPoint = uninterruptibleMask_$ do
                conns <- atomicModifyIORef rconns$ \conns -> (M.empty,conns)
                -- Close connections now, before continuing closing the endpoint.
                -- This is necessary to avoid blocking if the endpoint has
                -- self-connections.
                F.forM_ conns close
               `finally` do
                  atomicModifyIORef (tsConnToEP ts)$
                      \c2ep -> (M.filter ((EndPointKey epk/=) . fst) c2ep,())
                  atomicModifyIORef (tsLocalEPs ts)$ \eps -> (M.delete (EndPointKey epk) eps,())
                  debug$ "RPC: closed endpoint: "++show epAddr
                  writeChan epq EndPointClosed
          }

    atomicModifyIORef (tsLocalEPs ts)$ \eps -> (M.insert (EndPointKey epk) lep eps,())
    debug$ "RPC: created endpoint: "++show epAddr
    return$ Right ep

-- | Encode end point address
encodeEndPointAddress :: RPCAddress -> EndPointKey -> EndPointAddress
encodeEndPointAddress (RPCAddress bAddr) (EndPointKey epk) =
  EndPointAddress $ B.append bAddr $ B8.pack $ ":" ++ show epk

-- | Extracts the RPC address and the endpoint key from an endpoint address.
decodeEndPointAddress :: EndPointAddress -> Maybe (RPCAddress,EndPointKey)
decodeEndPointAddress (EndPointAddress b) = case B8.elemIndexEnd ':' b of
    Nothing -> Nothing -- rpcEptReceive: invalid endpoint address
    Just i  -> case readsPrec 0 (B8.unpack$ B.drop (i+1) b) of
      []        -> Nothing -- rpcEptReceive: invalid endpoint identifier
      (epk,_):_ -> Just (RPCAddress$ B.take i b,EndPointKey epk)


-- | State of connections.
--
-- Initially they are in the ConnEstablished state. In this state a counter with
-- the amount of unreplied messages is kept.
--
-- When a thread attempts to close the connection, the connection enters the
-- ConnClosing state. The unreplied messages are still counted and the thread
-- waits on an MVar the next state transition. When a transition leaves the
-- ConnClosing state, the MVar is filled.
--
-- If the connection fails or the counter reaches value zero, the MVar is filled
-- and the connection state is changed to ConnClosed. The boolean value placed in
-- the MVar indicates which of the two events caused the transition (True for a
-- zero counter and False for a connection failure).
--
data ConnectionState = ConnEstablished Word32
                     | ConnClosing Word32 (MVar Bool)
                     | ConnFailed
                     | ConnClosed

-- | A type for representing the state of a request to create a connection.
data ConnectionRes = CRConn R.Connection -- ^ The connection was created.
                   | CRWaiting Bool [[B.ByteString]]
                          -- ^ The connection is being created.
                          -- Includes whether connection must be closed and
                          -- queued messages.
                   | CRFailed String -- ^ Creating the connection failed.

-- | Map of connections to their states. One such map is owned by each endpoint.
--
-- When a connection is created, it is inserted in this map.
-- When a connection is closed by upper layers, the connection is removed from the map.
-- When a send operation fails, all connections in the map which have the same
-- target endpoint are removed.
type ConnectionMap = Map R.Connection (IORef ConnectionState,EndPointAddress)

-- | Establishes an RPC connection to the RPC address of the given endpoint,
-- and then sends a connection opening message through it.
--
-- Yields @TransportError ConnectNotFound _@ if the target endpoint address is malformed.
--
-- Yields @TransportError ConnectTimeout _@ if the receiver side does not answer the
-- connection request within the timeout specified in hints or otherwise the timeout
-- specified in the sender endpoint transport parameters.
--
-- Yields @TransportError ConnectFailed _@ if the sender endpoint was closed or the
-- connection fails for any other reason.
--
rpcConnect :: TransportState -> EndPointAddress -> EndPointKey -> LocalEndPoint -> IORef ConnectionMap
              -> EndPointAddress -> Reliability -> ConnectHints
              -> IO (Either (TransportError ConnectErrorCode) T.Connection)
rpcConnect ts sourceEpAddr lepk lep rcm targetEpAddr _ hints = do
    debug$ "RPC: connecting to "++show targetEpAddr
    case decodeEndPointAddress targetEpAddr of
      Nothing -> return$ Left$ TransportError ConnectNotFound ""
      Just (addr,epk) -> readIORef (tsLocalEPs ts) >>= \leps ->
        if not$ M.member lepk leps then return$ Left$ TransportError ConnectFailed "" else do
        let timeout_s = maybe (prpcConnectTimeout$ tsPrpc ts) id$ connectTimeout hints
        connMVar <- newMVar $ CRWaiting False []
        rConnState <- newIORef $ ConnEstablished 0
        lcid <- atomicModifyIORef (leConnIdGen lep) $ \k -> (k+1,k)
        let tc = T.Connection
                   { T.send = rpcSend ts connMVar rConnState (leQueue lep) rcm targetEpAddr
                   , close = m0QueueWait ts $
                             rpcClose lep connMVar lcid rConnState rcm True timeout_s
                   }
        uninterruptibleMask_ $ do
          atomicModifyIORef (leConns lep) $ \conns -> (M.insert lcid tc conns,())
          m0Queue ts $ flip catch
                   (\e -> do
                     modifyMVar_ connMVar $ \_ ->
                            return $ CRFailed $ show (e :: SomeException)
                   ) $ do
            c <- R.connect_se (tsSe ts) addr timeout_s
            do sendBlocking c [item2bs$ ItemOpening epk sourceEpAddr] timeout_s
               atomicModifyIORef rcm$ \cm -> (M.insert c (rConnState,targetEpAddr) cm,())
              `catch` (\e -> let _ = e :: RPCException
                              in {- releaseConnection c >> -} throwIO e
                      )
            debug $ "RPC: connected to " ++ show targetEpAddr ++ " with " ++ show c
            let go = do
                  cr <- modifyMVar connMVar $ \cr -> case cr of
                      CRWaiting False [] -> return (CRConn c,cr)
                      CRWaiting False _ -> return (CRWaiting False [],cr)
                      _ -> return (cr,cr)
                  case cr of
                    CRWaiting bclose msgs -> do
                      mv <- newMVar $ CRConn c
                      F.forM_ (reverse msgs) $
                        rpcSend ts mv rConnState (leQueue lep) rcm targetEpAddr
                      if bclose then do
                        rpcClose lep mv lcid rConnState rcm True timeout_s
                        modifyMVar_ connMVar $ \_ -> return $ CRConn c
                       else
                        go
                    _ -> return ()
            go
        return $ Right tc {
              close = m0QueueWait ts $
                      rpcClose lep connMVar lcid rConnState rcm False timeout_s
            }

       `catch` (\e -> return$ Left$ case e of
                  RPCException RPC_TIMEDOUT ->
                      TransportError ConnectTimeout $ show targetEpAddr
                  RPCException RPC_HOSTDOWN ->
                      TransportError ConnectNotFound $ show targetEpAddr
                  RPCException RPC_HOSTUNREACHABLE ->
                      TransportError ConnectNotFound $ show targetEpAddr
                  RPCException st ->
                      TransportError ConnectFailed $ show st
               )


-- | Closes a connection. It waits for all pending sends to complete, whatever
-- time it takes, and then sends the closing message waiting with the given timeout.
-- Finally, it disconnects the RPC connection.
rpcClose :: LocalEndPoint -> MVar ConnectionRes -> LocalConnectionId
            -> IORef ConnectionState -> IORef ConnectionMap
            -> Bool -> Int -> IO ()
rpcClose lep connMVar lcid rConnState rcm blocking timeout_s =
    let go | blocking = do
                mc <- readMVar connMVar
                case mc of
                 CRWaiting _ _ -> threadDelay 10000 >> go
                 _ -> return mc
           | otherwise = readMVar connMVar

     in uninterruptibleMask_ $ do
    modifyMVar_ connMVar $ \mc -> case mc of
        CRWaiting _ xs -> return $ CRWaiting True xs
        _ -> return mc

    mc <- go
    case mc of
      CRConn c -> do
        done <- newEmptyMVar
        -- insert an MVar to get notified when the pending counter reaches 0
        -- or when the connection fails
        cs <- atomicModifyIORef rConnState$ \cs -> case cs of
                ConnEstablished i -> (ConnClosing i done,cs)
                ConnFailed        -> (ConnClosed,cs)
                _                 -> (cs,cs)
        atomicModifyIORef (leConns lep)$ \conns -> (M.delete lcid conns,())
        case cs of
          ConnEstablished i -> do
            let closeConn = do sendBlocking c [item2bs ItemClosing] timeout_s -- `onException` releaseConnection c
                               disconnect c timeout_s
            st <- (if i==0 then return True else takeMVar done)
                  `finally` atomicModifyIORef rcm (\cm -> (M.delete c cm,())) -- remove connection from connection map
            -- send the closing message if the connection has not failed
            if st then closeConn else return () -- releaseConnection c

          ConnFailed -> return () -- releaseConnection c
          _          -> return ()
        debug$ "RPC: closed connection "++show c

       `catch` (\e -> case e of
                        RPCException RPC_TIMEDOUT -> return ()
                        _ -> throwIO e
               )
      _ ->
        return ()


-- | Sends a message through the RPC connection. It doesn't block waiting for an aknowledgement.
-- Messages are considered in flight until an acknowledgement is received. If the acknowledgement
-- does not arrive within the timeout especified in the 'RPCParameters'of the transport, the
-- connection is moved to failed state by an RPC thread.
--
-- Yields @TransportError SendClosed _@ if the connection is in ConnClosed or ConnClosing state.
-- Yields @TransportError SendFailed _@ if the connection is in ConnFailed state or
-- the call to RPC send fails.
rpcSend :: TransportState -> MVar ConnectionRes -> IORef ConnectionState
           -> Chan Event
           -> IORef ConnectionMap -> EndPointAddress -> [B.ByteString]
           -> IO (Either (TransportError SendErrorCode) ())
rpcSend ts connMVar rConnState epq rcm targetEpAddr msg = m0QueueWait ts $
    join $ modifyMVar connMVar $ \mc -> do
    case mc of
      CRConn c -> return $ (,) mc $
        (bracketOnError
          (atomicModifyIORef rConnState$ \cs -> case cs of
               ConnEstablished i -> (ConnEstablished (i+1),cs)
               _ -> (cs,cs)
          )
          (const$ atomicModifyIORef rConnState$ \cs -> case cs of
               ConnEstablished i -> (ConnEstablished (i-1),cs)
               _ -> (cs,cs)
          )
          $ \cs ->
        case cs of
          ConnEstablished _ ->
            fmap Right (R.sendBlocking c [item2bs $ ItemRegular msg]
                                 (prpcSendTimeout $ tsPrpc ts) >> replied c RPC_OK
                       )
          -- allow no sends if the connection is not open
          ConnFailed -> return $ Left $ TransportError SendFailed "connection failed"
          _ -> return $ Left $ TransportError SendClosed ""
        )
       `catch` \(RPCException st) -> do
                       replied c st
                       return $ Left $ TransportError SendFailed $ show st
      CRWaiting False msgs ->
        return ( CRWaiting False $ msg : msgs
               , return $ Right ()
               )
      CRWaiting True _ ->
        return (mc, return $ Left $ TransportError SendClosed "")
      CRFailed str ->
        return ( mc, return $ Left $ TransportError SendFailed str )
  where
    -- this function is called by an RPC thread when an acknowledgement arrives
    -- or when the timeout expires.
    replied _ RPC_OK = do -- acknowledgement arrived
      -- The next line returns @Just mv@ iff the MVar @mv@ needs to be filled,
      -- and that happens only when a transition out of the ConnClosing state
      -- is done.
      mmv <- atomicModifyIORef rConnState$ \cs ->
                 case cs of
                   ConnEstablished i             -> (ConnEstablished (i-1),Nothing)
                   -- there was not an error and we reached 0
                   ConnClosing 1 mv              -> (ConnClosed           ,Just mv)
                   -- if we didn't reach 0 yet
                   ConnClosing i mv              -> (ConnClosing (i-1) mv ,Nothing)
                   -- every other case
                   _                             -> (cs,Nothing)
      -- If @mmv==Just mv@, @mv@ is empty before the next line because only
      -- one thread makes a transition out of the ConnClosing state, and that
      -- thread is the only that will fill the MVar.
      maybe (return ()) (flip putMVar True) mmv

    replied c st = do -- the connection failed
      cm <- atomicModifyIORef rcm$ \cm -> M.partition ((/=targetEpAddr) . snd) cm
      F.forM_ cm$ \(rCS,_) -> do
                cs <- atomicModifyIORef rCS$ \cs -> case cs of
                          ConnClosing _ _ -> (ConnClosed,cs)
                          _               -> (ConnFailed,cs)
                case cs of
                  ConnClosing _ mv  -> putMVar mv False
                  _                 -> return ()
      when (M.member c cm)$ writeChan epq$
          ErrorEvent$ TransportError (EventConnectionLost targetEpAddr)$ "send failed: "++show st
