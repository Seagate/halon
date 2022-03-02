{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ForeignFunctionInterface   #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes                 #-}
-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- rpclite is an abstraction layer over RPC.
--
-- The purpose of this library is to hide all the details of Mero RPC that are
-- not necessary for the simplest inter-process communication.
--
module Network.RPC.RPCLite
    ( initRPC
    , finalizeRPC
    -- * Client side API
    , ClientEndpoint
    , ClientEndpointV
    , RPCAddress(..)
    , rpcAddress
    , createClientEndpoint
    , destroyClientEndpoint
    , Connection
    , connect
    , connect_se
    , connect_rpc_machine
    , disconnect
    , releaseConnection
    , send
    , sendBlocking
    , RPCMachine(..)
    , RPCMachineV
    , getRPCMachine_se
    , Session(..)
    , SessionV
    , getConnectionSession
    -- * Server side API
    , ServerEndpoint(se_ptr)
    , ListenCallbacks(..)
    , listen
    , stopListening
    , Item
    , getFragments
    , unsafeGetFragments
    , getConnectionId
    , Status(..)
    , RPCException(..)
    , sendEpochBlocking
    ) where

import Control.Exception      ( Exception, throwIO )
import Control.Monad          ( forM )
import Control.Monad.Fix      ( mfix )
import Data.ByteString as B   ( ByteString, useAsCString, packCStringLen )
import Data.ByteString.Char8 as B8 ( pack )
import Data.ByteString.Unsafe ( unsafeUseAsCStringLen, unsafePackCStringLen )
import Data.Dynamic           ( Typeable )
import Data.Binary            ( Binary )
import Data.Word              ( Word64 )
import Foreign.C.Types        ( CInt(..), CULong(..) )
import Foreign.C.String       ( CString, CStringLen )
import Foreign.Marshal.Alloc  ( alloca, allocaBytesAligned )
import Foreign.Ptr            ( Ptr, FunPtr, plusPtr, WordPtr, ptrToWordPtr
                              , nullPtr, freeHaskellFunPtr )
import Foreign.Storable       ( Storable(..) )

#include <errno.h>
#include "rpclite.h"

#if __GLASGOW_HASKELL__ < 800
#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__); }, y__)
#endif

-- | Initializes RPC stack with creating database directory in CWD.
--
-- Evaluate this action only once before calling 'finalizeRPC'.
--
initRPC :: IO ()
initRPC = rpc_init >>= check_rc

foreign import ccall rpc_init :: IO CInt

-- | Frees any resources allocated during initialization of the RPC stack.
--
-- Evaluate this action only once after calling 'initRPC'.
finalizeRPC :: IO ()
finalizeRPC = rpc_fini

foreign import ccall rpc_fini :: IO ()


data ClientEndpointV

-- | A client endpoint handles multiple outgoing connections.
data ClientEndpoint = ClientEndpoint (Ptr ClientEndpointV)

-- | An RPCAddress is an LNET address together with an integer identifying a
-- pool of buffers which is separated by an extra colon, e.g. `0@lo:12345:34:1`
newtype RPCAddress = RPCAddress ByteString
  deriving (Eq, Show, Typeable, Binary)

-- | Creates an RPCAddress from a String.
rpcAddress :: String -> RPCAddress
rpcAddress = RPCAddress . B8.pack


-- | Creates a client endpoint that handles connections going out from the
-- provided RPC address.
createClientEndpoint :: RPCAddress -> IO ClientEndpoint
createClientEndpoint (RPCAddress rpcAddr) =
    alloca$ \pce -> useAsCString rpcAddr$ \cRPCAddr ->
      rpc_create_endpoint cRPCAddr pce >>= check_rc >> fmap ClientEndpoint (peek pce)

foreign import ccall rpc_create_endpoint :: CString -> Ptr (Ptr ClientEndpointV) -> IO CInt


-- | Frees resources used by a client endpoint. Calls involving the
-- destroyed endpoint are undefined after evaluating this action.
destroyClientEndpoint :: ClientEndpoint -> IO ()
destroyClientEndpoint (ClientEndpoint pce) = rpc_destroy_endpoint pce

foreign import ccall rpc_destroy_endpoint :: Ptr ClientEndpointV -> IO ()

-- | In Mero RPC, a connection has sessions. Each session deals with specific
-- QoS and authentication data.
--
-- A Connection in this API is a Mero RPC connection with one session.
--
data Connection = Connection (Ptr ConnectionV)
  deriving (Eq,Ord,Show)
data ConnectionV

-- | Creates an RPC connection. The RPC connection has a session.
--
connect :: ClientEndpoint     -- ^ local endpoint to use for the connection
           -> RPCAddress      -- ^ address of the target endpoint
           -> Int             -- ^ timeout in seconds to wait for the connection
           -> IO Connection
connect (ClientEndpoint pce) (RPCAddress rpcAddr) timeout_s =
    alloca$ \pc -> useAsCString rpcAddr$ \cRPCAddr ->
      rpc_connect pce cRPCAddr (fromIntegral timeout_s) pc
        >>= check_rc >> fmap Connection (peek pc)

foreign import ccall rpc_connect :: Ptr ClientEndpointV -> CString -> CInt -> Ptr (Ptr ConnectionV) -> IO CInt


-- | Disconnects and releases any resources associated with the connection.
--
-- Since disconnection involves communication with the remote side, a timeout
-- must be provided.
disconnect :: Connection -> Int -> IO ()
disconnect (Connection pc) timeout_s = rpc_disconnect pc (fromIntegral timeout_s) >>= check_rc

foreign import ccall rpc_disconnect :: Ptr ConnectionV -> CInt -> IO CInt


-- | Releases any resources associated with the connection.
--
-- This is intended to be called only on failed connections.
-- If the connection is good, use 'disconnect' instead.
releaseConnection :: Connection -> IO ()
releaseConnection (Connection pc) = rpc_release_connection pc

foreign import ccall rpc_release_connection :: Ptr ConnectionV -> IO ()


-- | Sends a message and blocks until a reply is received or the timeout expires.
sendBlocking :: Connection  -- ^ connection on which to send the message
                -> [ByteString] -- ^ message to send as a list of discontiguos buffers
                -> Int          -- ^ timeout in seconds to wait for a reply
                -> IO ()
sendBlocking (Connection pc) msgs timeout_s =
    unsafeUseAsCStringLens msgs [] 0$ \cmsgs clen ->
      allocaBytesAligned (clen * #{size struct iovec}) #{alignment struct iovec}$ \piovecs -> do
        sequence_ (zipWith (write_iovec piovecs) [clen-1,clen-2..0] cmsgs)
        rpc_send_blocking pc piovecs (fromIntegral clen) (fromIntegral timeout_s) >>= check_rc


unsafeUseAsCStringLens :: Num b => [ByteString] -> [CStringLen] -> b -> ([CStringLen] -> b -> IO a) -> IO a
unsafeUseAsCStringLens (x:xs) acc len f
    | seq len True = unsafeUseAsCStringLen x$ \cx -> unsafeUseAsCStringLens xs (cx:acc) (len+1) f
unsafeUseAsCStringLens _ acc len f = f acc len

write_iovec :: Ptr IOVec -> Int -> CStringLen -> IO ()
write_iovec piovecs offs (cmsg,clen) = do
    let p = plusPtr piovecs (offs * #{size struct iovec})
    #{poke struct iovec, iov_base} p cmsg
    #{poke struct iovec, iov_len} p clen

data IOVec

foreign import ccall rpc_send_blocking :: Ptr ConnectionV -> Ptr IOVec -> CInt -> CInt -> IO CInt

-- | Sends a message without blocking the caller. When a reply is received or when
-- the timeout expires, the supplied callback is evaluated.
send :: Connection      -- ^ connection on which to send the message
        -> [ByteString] -- ^ message to send as a list of discontiguous buffers
        -> Int          -- ^ timeout in seconds to wait for a reply
        -> (Status -> IO ()) -- ^ callback to be evaluated when the reply arrives or when
                             -- the timeout expires.
        -> IO ()
send (Connection pc) msgs timeout_s cb =
    unsafeUseAsCStringLens msgs [] 0$ \cmsgs clen ->
      allocaBytesAligned (clen * #{size struct iovec}) #{alignment struct iovec}$ \piovecs -> do
        sequence_ (zipWith (write_iovec piovecs) [clen-1,clen-2..0] cmsgs)
        wcb <- wrapSendCB cb
        rpc_send pc piovecs (fromIntegral clen) wcb nullPtr (fromIntegral timeout_s) >>= check_rc
  where
    wrapSendCB :: (Status -> IO ())
                  -> IO (FunPtr (Ptr ConnectionV -> Ptr () -> CInt -> IO ()))
    wrapSendCB f = mfix$ \funPtr ->
        cwrapSendCB$ \_ _ wst -> do
            f$ toEnum$ fromIntegral wst
            freeHaskellFunPtr funPtr

foreign import ccall rpc_send :: Ptr ConnectionV -> Ptr IOVec -> CInt ->  FunPtr (Ptr ConnectionV -> Ptr () -> CInt -> IO ()) -> Ptr () -> CInt -> IO CInt

foreign import ccall "wrapper" cwrapSendCB :: (Ptr ConnectionV -> Ptr () -> CInt -> IO ())
  -> IO (FunPtr (Ptr ConnectionV -> Ptr () -> CInt -> IO ()))


-- | An RPC item holds a received message.
--
-- The message can be retrieved with either 'getFragments' or 'unsafeGetFragments'.
-- The result of the former is garbage collected only when no more references to it
-- remain. The result of the latter is valid for as long as the item remains valid.
data Item = Item (Ptr ItemV)
data ItemV


-- | Retrieves the received message from an RPC item.
getFragments :: Item -> IO [ByteString]
getFragments = getFragments' B.packCStringLen

-- | Retrieves the received message from an RPC item.
-- The result is safe to use only while the provided item is valid.
--
-- Since this avoids copying the data this function might be preferred
-- over 'getFragments' in some situations.
--
unsafeGetFragments :: Item -> IO [ByteString]
unsafeGetFragments = getFragments' unsafePackCStringLen


getFragments' :: (CStringLen -> IO ByteString) -> Item -> IO [ByteString]
getFragments' bpack (Item pit) = do
    nf <- rpc_get_fragments_count pit
    forM [0..nf-1]$ \i -> do
      flen <- rpc_get_fragment_count pit i
      fdata <- rpc_get_fragment pit i
      bpack (fdata,fromIntegral flen)


foreign import ccall unsafe rpc_get_fragments_count :: Ptr ItemV -> IO CInt

foreign import ccall unsafe rpc_get_fragment_count :: Ptr ItemV -> CInt -> IO CInt

foreign import ccall unsafe rpc_get_fragment :: Ptr ItemV -> CInt -> IO CString

-- | Yields the identifier of the connection on which the item was received.
--
-- RPC may reuse identifiers of closed connections.
getConnectionId :: Item -> IO WordPtr
getConnectionId (Item p) = fmap ptrToWordPtr (rpc_get_connection_id p)



foreign import ccall unsafe rpc_get_connection_id :: Ptr ItemV -> IO (Ptr ())

-- | Type for RPC machines. These are the artifacts of mero used to create
-- connections. Exposing the type is not necessary for using RPC but
-- other Mero bindings do need this exposure, e.g., confc.
newtype RPCMachine = RPCMachine (Ptr RPCMachineV)
data RPCMachineV

-- | Yields the RPC machine of a server endpoint.
getRPCMachine_se :: ServerEndpoint -> IO RPCMachine
getRPCMachine_se (ServerEndpoint _ pse) =
    fmap RPCMachine $ rpc_get_rpc_machine pse

foreign import ccall unsafe rpc_get_rpc_machine :: Ptr ClientEndpointV
                                                -> IO (Ptr RPCMachineV)

-- | A server endpoint handles multiple incoming connections.
data ServerEndpoint = ServerEndpoint
  { _se_cbs :: [SomeFunPtr]
  , se_ptr  :: Ptr ClientEndpointV -- ^ Pointer to the server endpoint. This
                                   -- is needed if other C libraries want to
                                   -- use the endpoint.
  }
data SomeFunPtr = forall a. SomeFunPtr (FunPtr a)

data ListenCallbacksV

-- | Callbacks associated with a server endpoint.
data ListenCallbacks = ListenCallbacks
    { receive_callback :: Item -> WordPtr -> IO Bool
      -- ^ called whenever a message arrives. Should not block or block little time,
      -- otherwise, processing of incoming messages may stall if multiple callbacks
      -- block simultaneously. The Item parameter is only valid until the callback
      -- completes.
      --
      -- The retunr value should be @True@ if the item must be replied and @False@ if it
      -- should be ignored.
    }

-- | Creates a server endpoint at the specified RPC address.
listen :: RPCAddress       -- ^ address of the service
       -> ListenCallbacks  -- ^ service callbacks
       -> IO ServerEndpoint
listen (RPCAddress rpcAddr) cbs = do
    alloca$ \pse ->
      useAsCString rpcAddr$ \cRPCAddr ->
        allocaBytesAligned #{size rpc_listen_callbacks_t}
                           #{alignment rpc_listen_callbacks_t}$ \pcbs -> do
          wrecv <- wrapRecvCB$ receive_callback cbs
          #{poke rpc_listen_callbacks_t, receive_callback} pcbs wrecv
          #{poke rpc_listen_callbacks_t, connection_callback} pcbs nullPtr
          #{poke rpc_listen_callbacks_t, disconnected_callback} pcbs nullPtr
          rpc_listen cRPCAddr pcbs pse >>= check_rc
            >> fmap (ServerEndpoint [SomeFunPtr wrecv]) (peek pse)
  where
    wrapRecvCB f = cwrapRecvCB$ \pit ctx -> fmap not$ f (Item pit) (ptrToWordPtr ctx)

foreign import ccall rpc_listen :: CString -> Ptr ListenCallbacksV -> Ptr (Ptr ClientEndpointV) -> IO CInt

foreign import ccall "wrapper" cwrapRecvCB :: (Ptr ItemV -> Ptr () -> IO Bool)
  -> IO (FunPtr (Ptr ItemV -> Ptr () -> IO Bool))


-- | Releases resources allocated by listen.
stopListening :: ServerEndpoint -> IO ()
stopListening (ServerEndpoint cbs pse) =
    rpc_destroy_endpoint pse >> mapM_ (withSomeFunPtr freeHaskellFunPtr) cbs
  where
    withSomeFunPtr :: (forall a. FunPtr a -> b) -> SomeFunPtr -> b
    withSomeFunPtr f (SomeFunPtr p) = f p

-- | Like 'connect' but creates an RPC connection using a server endpoint instead.
-- The RPC connection has a session.
--
connect_se :: ServerEndpoint  -- ^ local endpoint to use for the connection
           -> RPCAddress      -- ^ address of the target endpoint
           -> Int             -- ^ timeout in seconds to wait for the connection
           -> IO Connection
connect_se (ServerEndpoint _ pse) (RPCAddress rpcAddr) timeout_s =
    alloca$ \pc -> useAsCString rpcAddr$ \cRPCAddr ->
      rpc_connect pse cRPCAddr (fromIntegral timeout_s) pc
        >>= check_rc >> fmap Connection (peek pc)

foreign import ccall rpc_connect_rpc_machine
    :: Ptr RPCMachineV -> CString -> CInt -> Ptr (Ptr ConnectionV) -> IO CInt

connect_rpc_machine :: RPCMachine  -- ^ local rpc machine to use for the connection
                    -> RPCAddress  -- ^ address of the target endpoint
                    -> Int         -- ^ timeout in seconds to wait for the connection
                    -> IO Connection
connect_rpc_machine (RPCMachine rpcm) (RPCAddress rpcAddr) timeout_s =
    alloca$ \pc -> useAsCString rpcAddr$ \cRPCAddr ->
      rpc_connect_rpc_machine rpcm cRPCAddr (fromIntegral timeout_s) pc
        >>= check_rc >> fmap Connection (peek pc)

-- | Type of exceptions that RPC calls can produce.
data RPCException = RPCException Status
  deriving (Show,Typeable)

instance Exception RPCException

check_rc :: CInt -> IO ()
check_rc 0 = return ()
check_rc i = throwIO$ RPCException$ toEnum$ fromIntegral i


-- | Status values for RPC operations.
data Status = RPC_OK
            | RPC_TIMEDOUT
            | RPC_HOSTDOWN
            | RPC_HOSTUNREACHABLE
            | RPC_FAILED Int
  deriving (Eq, Show)

instance Enum Status where
  toEnum 0 = RPC_OK
  toEnum (- #{const ETIMEDOUT}) = RPC_TIMEDOUT
  toEnum (- #{const EHOSTUNREACH}) = RPC_HOSTUNREACHABLE
  toEnum (- #{const EHOSTDOWN}) = RPC_HOSTDOWN
  toEnum i = RPC_FAILED i

  fromEnum RPC_OK         = 0
  fromEnum RPC_TIMEDOUT   = (- #{const ETIMEDOUT})
  fromEnum RPC_HOSTUNREACHABLE  = (- #{const EHOSTUNREACH})
  fromEnum RPC_HOSTDOWN  = (- #{const EHOSTDOWN})
  fromEnum (RPC_FAILED i) = i


foreign import ccall rpc_send_epoch_blocking :: Ptr ConnectionV -> CULong ->
                                                CInt -> Ptr CULong -> IO CInt

-- | Sends an epoch through an existing connection and blocks until the
-- receiver's updated epoch arrives or the timeout expires.
sendEpochBlocking :: Connection        -- ^ connection on which to send
                  -> Word64            -- ^ our epoch
                  -> Int               -- ^ timeout in secs to wait for a reply
                  -> IO (Maybe Word64) -- ^ their epoch
sendEpochBlocking (Connection pc) epoch timeout_s =
    alloca $ \theirEpoch ->
    rpc_send_epoch_blocking pc
                            (fromIntegral epoch)
                            (fromIntegral timeout_s)
                            theirEpoch
    >>= check theirEpoch
  where
    check pep 0 =
      do
        CULong ep <- peek pep
        return $ Just ep
    check _ err |    err == (- #{const ETIMEDOUT})
                  || err == (- #{const EHOSTUNREACH})
                  || err == (- #{const EHOSTDOWN}) = return Nothing
                | otherwise = throwIO $ RPCException $ toEnum $ fromIntegral err


newtype Session = Session (Ptr SessionV)
data SessionV

foreign import ccall "<rpclite.h> rpc_get_session"
  c_rpc_get_session :: Ptr ConnectionV -> IO (Ptr SessionV)

-- | Yeilds the rpc session used by a connection.
getConnectionSession :: Connection -> IO Session
getConnectionSession (Connection v) = fmap Session (c_rpc_get_session v)
