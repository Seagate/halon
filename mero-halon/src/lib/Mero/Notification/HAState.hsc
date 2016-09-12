{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ForeignFunctionInterface #-}

{-# OPTIONS_GHC -Wall -Werror #-}
-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the hastate interface. This is the HA side of the notification
-- interface.
--
-- TODO: Move various message types sent through new notification
-- interface into own module or into confc package.
--
-- TODO: send @data HAMsg a = HAMsg HAMsgMeta a@ for nicer receiving and access
module Mero.Notification.HAState
  ( Note(..)
  , NVec
  , HALink
  , ReqId(..)
  , initHAState
  , finiHAState
  , getRPCMachine
  , notify
  , disconnect
  , entrypointReply
  , entrypointNoReply
  , pingProcess
  , HAMsgMeta(..)
  , failureVectorReply
  , HAStateException(..)
  , ProcessEvent(..)
  , ProcessEventType(..)
  , ProcessType(..)
  , ServiceEvent(..)
  , ServiceEventType(..)
  , BEIoErr(..)
  ) where

import HA.Resources.Mero.Note

import Mero.ConfC             (Cookie, Fid, Word128, ServiceType)
import Network.RPC.RPCLite    (RPCAddress(..), RPCMachine(..), RPCMachineV)

import Control.Exception      ( Exception, throwIO, SomeException, evaluate )
import Control.Monad          ( liftM2, liftM3, liftM4, void )
import Control.Monad.Catch    ( catch )

import Data.Aeson             ( ToJSON )
import Data.Binary            ( Binary )
import Data.ByteString as B   ( useAsCString )
import Data.Dynamic           ( Typeable )
import Data.Hashable          ( Hashable )
import Data.IORef             ( atomicModifyIORef, modifyIORef, IORef
                              , newIORef
                              )
import Data.Word              ( Word8, Word32, Word64 )
import Foreign.C.Types        ( CInt(..) )
import Foreign.C.String       ( CString, withCString )
import Foreign.Marshal.Alloc  ( allocaBytesAligned, free , alloca)
import Foreign.Marshal.Array  ( peekArray, withArrayLen, withArrayLen0, pokeArray )
import Foreign.Marshal.Utils  ( with, withMany )
import Foreign.Ptr            ( Ptr, FunPtr, freeHaskellFunPtr, nullPtr, castPtr, plusPtr )
import Foreign.Storable       ( Storable(..) )
import GHC.Generics           ( Generic )
import System.IO              ( hPutStrLn, stderr )
import System.IO.Unsafe       ( unsafePerformIO )

#include "hastate.h"
#include "conf/obj.h"
#include "ha/msg.h"
#include "be/ha.h"
#include "stob/io.h"

#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

-- | ha_msg_metadata
data HAMsgMeta = HAMsgMeta
  { _hm_fid :: Fid
  , _hm_source_process :: Fid
  , _hm_source_service :: Fid
  , _hm_time :: Word64
  } deriving (Show, Eq, Ord, Typeable, Generic)

instance Binary HAMsgMeta
instance Hashable HAMsgMeta
instance ToJSON HAMsgMeta

data ProcessEvent = ProcessEvent
  { _chp_event :: ProcessEventType
  , _chp_type :: ProcessType
  , _chp_pid :: Word64
  } deriving (Show, Eq, Ord, Typeable, Generic)

instance Binary ProcessEvent
instance Hashable ProcessEvent

data {-# CTYPE "conf/ha.h" "struct m0_conf_ha_process_type" #-}
  ProcessType = TAG_M0_CONF_HA_PROCESS_OTHER
              | TAG_M0_CONF_HA_PROCESS_KERNEL
              | TAG_M0_CONF_HA_PROCESS_M0MKFS
              | TAG_M0_CONF_HA_PROCESS_M0D
              deriving (Show, Eq, Ord, Typeable, Generic)

instance Binary ProcessType
instance Hashable ProcessType

data {-# CTYPE "conf/ha.h" "struct m0_conf_ha_process_event" #-}
  ProcessEventType = TAG_M0_CONF_HA_PROCESS_STARTING
                   | TAG_M0_CONF_HA_PROCESS_STARTED
                   | TAG_M0_CONF_HA_PROCESS_STOPPING
                   | TAG_M0_CONF_HA_PROCESS_STOPPED
                   deriving (Show, Eq, Ord, Typeable, Generic)

instance Binary ProcessEventType
instance Hashable ProcessEventType

data ServiceEvent = ServiceEvent
  { _chs_event :: ServiceEventType
  , _chs_type :: ServiceType
  } deriving (Show, Eq, Ord, Typeable, Generic)

instance Binary ServiceEvent
instance Hashable ServiceEvent

data {-# CTYPE "conf/ha.h" "struct m0_conf_ha_service_event" #-}
  ServiceEventType = TAG_M0_CONF_HA_SERVICE_STARTING
                   | TAG_M0_CONF_HA_SERVICE_STARTED
                   | TAG_M0_CONF_HA_SERVICE_STOPPING
                   | TAG_M0_CONF_HA_SERVICE_STOPPED
                   | TAG_M0_CONF_HA_SERVICE_FAILED
                   deriving (Show, Eq, Ord, Typeable, Generic)

instance Binary ServiceEventType
instance Hashable ServiceEventType

data {-# CTYPE "be/ha.h" "struct m0_be_location" #-}
  BELocation =
      BE_LOC_NONE
    | BE_LOC_LOG
    | BE_LOC_SEGMENT_1
    | BE_LOC_SEGMENT_2
  deriving (Eq, Show, Ord, Typeable, Generic)

instance Binary BELocation
instance Hashable BELocation
instance ToJSON BELocation

data {-# CTYPE "stob/io.h" "struct m0_stob_io_opcode" #-}
  StobIoOpcode =
      SIO_INVALID
    | SIO_READ
    | SIO_WRITE
    | SIO_BARRIER
    | SIO_SYNC
  deriving (Eq, Show, Ord, Typeable, Generic)

instance Binary StobIoOpcode
instance Hashable StobIoOpcode
instance ToJSON StobIoOpcode

data {-# CTYPE "be/ha.h" "struct m0_be_io_err" #-}
  BEIoErr = BEIoErr {
    _ber_errcode :: Int
  , _ber_location :: BELocation
  , _ber_io_opcode :: StobIoOpcode
  } deriving (Eq, Show, Ord, Typeable, Generic)

instance Binary BEIoErr
instance Hashable BEIoErr
instance ToJSON BEIoErr

-- | Notes telling the state of a given configuration object
data Note = Note
    { no_id :: Fid
    , no_ostate :: ConfObjectState
    } deriving (Eq, Typeable, Generic, Show, Ord)

instance Binary Note
instance Hashable Note

-- | Lists of notes
type NVec = [Note]

-- | Link to communicate with a mero process
newtype HALink = HALink (Ptr HALink)
  deriving (Show, Eq, Ord)

-- | Id of the incomming entrypoint/link connected request.
newtype ReqId = ReqId Word128
  deriving (Show, Eq, Ord)

-- | A type for hidding the type argument of 'FunPtr's
data SomeFunPtr = forall a. SomeFunPtr (FunPtr a)

-- | A reference to the list of 'FunPtr's used by the implementation
cbRefs :: IORef [SomeFunPtr]
cbRefs = unsafePerformIO $ newIORef []

-- | Starts the hastate interface.
--
-- Registers callbacks to handle arriving requests.
--
-- Must be called after 'Mero.m0_init'.
--
initHAState :: RPCAddress
            -> Fid -- ^ Process Fid
            -> Fid -- ^ Profile Fid
            -> (HALink -> Word64 -> NVec -> IO ())
               -- ^ Called when a request to get the state of some objects is
               -- received.
               --
               -- When the requested state is available, 'notify' must
               -- be called by passing the given link.
            -> (HALink -> HAMsgMeta -> ProcessEvent -> IO ())
               -- ^ Called when process event notification is received
            -> (HAMsgMeta -> ServiceEvent -> IO ())
               -- ^ Called when service event notification is received
            -> (HAMsgMeta -> BEIoErr -> IO ())
               -- ^ Called when error is thrown from metadata BE.
            -> (NVec -> IO ())
               -- ^ Called when a request to update the state of some objects is
               -- received.
            -> (ReqId -> Fid -> Fid -> IO ())
               -- ^ Called when a request to read current confd and rm endpoints
               -- is received.
            -> (ReqId -> HALink -> IO ())
               -- ^ Called when a new link is established.
            -> (ReqId -> HALink -> IO ())
               -- ^ Called when an old link is reconnected, may happen in case
               -- of RM service change.
            -> (HALink -> IO ())
               -- ^ The link is no longer needed by the remote peer.
               -- It is safe to call 'disconnect' when all 'notify' calls
               -- using the link have completed.
            -> (HALink -> IO ())
               -- ^ The link was removed, no other calls should be done on this link.
            -> (HALink -> Word64 -> IO ())
               -- ^ Message on the given link was delivered.
            -> (HALink -> Word64 -> IO ())
               -- ^ Message on the given link will never be delivered.
            -> (HALink -> Cookie -> Fid -> IO ())
              -- ^ Failure vector request.
            -> (HALink -> IO ())
              -- ^ Process keepalive reply
            -> IO ()
initHAState (RPCAddress rpcAddr) procFid profFid ha_state_get ha_process_event_set
            ha_service_event_set
            ha_be_error
            ha_state_set
            ha_state_entry
            ha_state_link_connected ha_state_link_reused
            ha_state_link_disconnecting ha_state_link_disconnected
            ha_state_is_delivered ha_state_is_cancelled
            ha_state_failure p_keepalive_rep =
    useAsCString rpcAddr $ \cRPCAddr ->
    allocaBytesAligned #{size ha_state_callbacks_t}
                       #{alignment ha_state_callbacks_t}$ \pcbs -> do
      wget <- wrapGetCB
      wpset <- wrapSetProcessCB
      wsset <- wrapSetServiceCB
      wbeerror <- wrapBEErrorCB
      wset <- wrapSetCB
      wentry <- wrapEntryCB
      wconnected <- wrapConnectedCB
      wreused    <- wrapReconnectedCB
      wdisconnecting <- wrapDisconnectingCB
      wdisconnected <- wrapDisconnectedCB
      wisdelivered <- wrapIsDeliveredCB
      wiscancelled <- wrapIsCancelledCB
      wfailure <- wrapFailureCB
      wkeepaliverep <- wrapKeepAliveRepCB
      #{poke ha_state_callbacks_t, ha_state_get} pcbs wget
      #{poke ha_state_callbacks_t, ha_process_event_set} pcbs wpset
      #{poke ha_state_callbacks_t, ha_service_event_set} pcbs wsset
      #{poke ha_state_callbacks_t, ha_be_error} pcbs wbeerror
      #{poke ha_state_callbacks_t, ha_state_set} pcbs wset
      #{poke ha_state_callbacks_t, ha_state_entrypoint} pcbs wentry
      #{poke ha_state_callbacks_t, ha_state_link_connected} pcbs wconnected
      #{poke ha_state_callbacks_t, ha_state_link_reused} pcbs wconnected
      #{poke ha_state_callbacks_t, ha_state_link_disconnecting} pcbs
         wdisconnecting
      #{poke ha_state_callbacks_t, ha_state_link_disconnected} pcbs
         wdisconnected
      #{poke ha_state_callbacks_t, ha_state_is_delivered} pcbs wisdelivered
      #{poke ha_state_callbacks_t, ha_state_is_cancelled} pcbs wiscancelled
      #{poke ha_state_callbacks_t, ha_state_failure_vec} pcbs wfailure
      #{poke ha_state_callbacks_t, ha_process_keepalive_reply} pcbs wkeepaliverep
      modifyIORef cbRefs
        ( (SomeFunPtr wget:)
        . (SomeFunPtr wpset:)
        . (SomeFunPtr wsset:)
        . (SomeFunPtr wbeerror:)
        . (SomeFunPtr wset:)
        . (SomeFunPtr wentry:)
        . (SomeFunPtr wconnected:)
        . (SomeFunPtr wreused:)
        . (SomeFunPtr wdisconnecting:)
        . (SomeFunPtr wdisconnected:)
        . (SomeFunPtr wisdelivered:)
        . (SomeFunPtr wiscancelled:)
        . (SomeFunPtr wfailure:)
        . (SomeFunPtr wkeepaliverep:)
        )
      rc <- with procFid $ \procPtr -> with profFid $ \profPtr ->
              ha_state_init cRPCAddr procPtr profPtr pcbs
      check_rc "initHAState" rc
  where
    freeing p = peek p >>= \p' -> free p >> return p'

    wrapGetCB = cwrapGetCB $ \hl w note -> catch
        (peekNote note >>= ha_state_get (HALink hl) w)
        $ \e -> hPutStrLn stderr $
                  "initHAState.wrapGetCB: " ++ show (e :: SomeException)

    wrapSetProcessCB = cwrapProcessSetCB $ \hl m' pe -> catch
      (do  m <- freeing m'
           pr <- peek pe
           ha_process_event_set (HALink hl) m pr)
      $ \e -> do hPutStrLn stderr $
                     "initHAState.wrapSetProcessCB: " ++ show (e :: SomeException)

    wrapSetServiceCB = cwrapServiceSetCB $ \m' se -> catch
      (freeing m' >>= \m -> peek se >>= ha_service_event_set m)
      $ \e -> hPutStrLn stderr $
                "initHAState.wrapSetServiceCB: " ++ show (e :: SomeException)

    wrapBEErrorCB = cwrapBEErrorCB $ \m' se -> catch
      (freeing m' >>= \m -> peek se >>= ha_be_error m)
      $ \e -> hPutStrLn stderr $
                "initHAState.wrapBEErrorCB: " ++ show (e :: SomeException)

    wrapSetCB = cwrapSetCB $ \note -> catch
        (peekNote note >>= ha_state_set)
        $ \e -> do hPutStrLn stderr $
                     "initHAState.wrapSetCB: " ++ show (e :: SomeException)

    wrapEntryCB = cwrapEntryCB $ \reqId processPtr profilePtr -> catch (do
        processFid <- peek processPtr
        profileFid <- peek profilePtr
        w128       <- peek reqId
        ha_state_entry (ReqId w128) processFid profileFid)
        $ \e -> hPutStrLn stderr $
                  "initHAState.wrapEntryCB: " ++ show (e :: SomeException)
    wrapConnectedCB = cwrapConnectedCB $ \wptr hl -> do
        w128 <- peek wptr
        catch (ha_state_link_connected (ReqId w128) (HALink hl)) $ \e ->
          hPutStrLn stderr $
            "initHAState.wrapConnectedCB: " ++ show (e :: SomeException)
    wrapReconnectedCB = cwrapConnectedCB $ \wptr hl -> do
        w128 <- peek wptr
        catch (ha_state_link_reused (ReqId w128) (HALink hl)) $ \e ->
          hPutStrLn stderr $
            "initHAState.wrapReconnectedCB: " ++ show (e :: SomeException)
    wrapDisconnectingCB = cwrapDisconnectingCB $ \hl ->
        catch (ha_state_link_disconnecting (HALink hl)) $ \e ->
          hPutStrLn stderr $
            "initHAState.wrapDisconnectingCB: " ++ show (e :: SomeException)
    wrapDisconnectedCB = cwrapDisconnectingCB $ \hl ->
        catch (ha_state_link_disconnected (HALink hl)) $ \e ->
          hPutStrLn stderr $
            "initHAState.wrapDisconnectedCB: " ++ show (e :: SomeException)
    wrapIsDeliveredCB = cwrapIsDeliveredCB $ \hl tag ->
        catch (ha_state_is_delivered (HALink hl) tag) $ \e ->
          hPutStrLn stderr $
            "initHAState.wrapDisconnectingCB: " ++ show (e :: SomeException)
    wrapIsCancelledCB = cwrapIsDeliveredCB $ \hl tag ->
        catch (ha_state_is_cancelled (HALink hl) tag) $ \e ->
          hPutStrLn stderr $
            "initHAState.wrapDisconnectingCB: " ++ show (e :: SomeException)
    wrapFailureCB = cwrapFailureCB $ \hl pcookie pfid ->
        catch (do fid <- peek pfid
                  cookie <- peek pcookie
                  ha_state_failure (HALink hl) cookie fid) $ \e ->
          hPutStrLn stderr $
            "initHAState.wrapFailureCB: " ++ show (e :: SomeException)

    wrapKeepAliveRepCB = cwrapKeepAliveRepCb $ \hl ->
        catch (p_keepalive_rep $ HALink hl) $ \e ->
          hPutStrLn stderr $
            "initHAState.wrapDisconnectingCB: " ++ show (e :: SomeException)

peekNote :: Ptr NVec -> IO NVec
peekNote p = do
  nr <- #{peek struct m0_ha_msg_nvec, hmnv_nr} p :: IO Word64
  let array = #{ptr struct m0_ha_msg_nvec, hmnv_arr} p
  peekArray (fromIntegral nr) array

data HAStateCallbacksV

foreign import capi ha_state_init ::
    CString -> Ptr Fid -> Ptr Fid -> Ptr HAStateCallbacksV -> IO CInt

foreign import ccall "wrapper" cwrapGetCB ::
    (Ptr HALink -> Word64 -> Ptr NVec -> IO ())
    -> IO (FunPtr (Ptr HALink -> Word64 -> Ptr NVec -> IO ()))

foreign import ccall "wrapper" cwrapProcessSetCB ::
                (Ptr HALink -> Ptr HAMsgMeta -> Ptr ProcessEvent -> IO ())
  -> IO (FunPtr (Ptr HALink -> Ptr HAMsgMeta -> Ptr ProcessEvent -> IO ()))

foreign import ccall "wrapper" cwrapServiceSetCB ::
                (Ptr HAMsgMeta -> Ptr ServiceEvent -> IO ())
  -> IO (FunPtr (Ptr HAMsgMeta -> Ptr ServiceEvent -> IO ()))

foreign import ccall "wrapper" cwrapBEErrorCB ::
                (Ptr HAMsgMeta -> Ptr BEIoErr -> IO ())
  -> IO (FunPtr (Ptr HAMsgMeta -> Ptr BEIoErr -> IO ()))

foreign import ccall "wrapper" cwrapSetCB :: (Ptr NVec -> IO ())
                                          -> IO (FunPtr (Ptr NVec -> IO ()))

foreign import ccall "wrapper" cwrapEntryCB ::
                  (Ptr Word128 -> Ptr Fid -> Ptr Fid -> IO ())
    -> IO (FunPtr (Ptr Word128 -> Ptr Fid -> Ptr Fid -> IO ()))

foreign import ccall "wrapper" cwrapDisconnectingCB ::
                  (Ptr HALink -> IO ())
    -> IO (FunPtr (Ptr HALink -> IO ()))

foreign import ccall "wrapper" cwrapConnectedCB ::
                  (Ptr Word128 -> Ptr HALink -> IO ())
    -> IO (FunPtr (Ptr Word128 -> Ptr HALink -> IO ()))

foreign import ccall "wrapper" cwrapIsDeliveredCB ::
    (Ptr HALink -> Word64 -> IO ()) -> IO (FunPtr (Ptr HALink -> Word64 -> IO ()))

foreign import ccall "wrapper" cwrapFailureCB ::
                  (Ptr HALink -> Ptr Cookie -> Ptr Fid -> IO ())
    -> IO (FunPtr (Ptr HALink -> Ptr Cookie -> Ptr Fid -> IO ()))

foreign import ccall "wrapper" cwrapKeepAliveRepCb ::
    (Ptr HALink -> IO ()) -> IO (FunPtr (Ptr HALink -> IO()))

instance Storable Note where

  sizeOf _ = #{size struct m0_ha_note}

  alignment _ = #{alignment struct m0_ha_note}

  peek p = liftM2 Note
      (#{peek struct m0_ha_note, no_id} p)
      (evaluate =<< fmap (toEnum . fromIntegral)
          (#{peek struct m0_ha_note, no_state} p :: IO Word32)
      )

  poke p (Note o s) = do
      #{poke struct m0_ha_note, no_id} p o
      #{poke struct m0_ha_note, no_state} p
          (fromIntegral $ fromEnum s :: Word32)

-- Finalizes the hastate interface.
finiHAState :: IO ()
finiHAState = do
    ha_state_fini
    atomicModifyIORef cbRefs (\cbs -> ([],cbs)) >>= mapM_ freeCB
  where
    freeCB (SomeFunPtr ptr) = freeHaskellFunPtr ptr

foreign import capi safe ha_state_fini :: IO ()

-- | Notifies mero at the remote address that the state of some objects has
-- changed.
notify :: HALink -> Word64 -> NVec -> IO Word64
notify (HALink hl) idx nvec =
  allocaBytesAligned #{size struct m0_ha_msg_nvec}
                     #{alignment struct m0_ha_msg_nvec} $ \pnvec -> do
    #{poke struct m0_ha_msg_nvec, hmnv_type} pnvec (0 :: Word64)
    #{poke struct m0_ha_msg_nvec, hmnv_id_of_get} pnvec idx
    #{poke struct m0_ha_msg_nvec, hmnv_nr} pnvec
        (fromIntegral $ length nvec :: Word64)
    pokeArray (#{ptr struct m0_ha_msg_nvec, hmnv_arr} pnvec) nvec
    ha_state_notify hl pnvec

foreign import capi safe ha_state_notify :: Ptr HALink -> Ptr NVec -> IO Word64

-- | Disconnects a link.
disconnect :: HALink -> IO ()
disconnect (HALink hl) = ha_state_disconnect hl

foreign import capi ha_state_disconnect :: Ptr HALink -> IO ()

-- | Sends keepalive request to process on the given link
pingProcess :: Word128 -> HALink -> IO Word64
pingProcess req_id (HALink hl) = alloca $ \req_id_p -> do
  poke req_id_p req_id
  ha_state_ping_process hl req_id_p

foreign import capi safe ha_state_ping_process :: Ptr HALink -> Ptr Word128 -> IO Word64

-- | Type of exceptions that HAState calls can produce.
data HAStateException = HAStateException String Int
  deriving (Show,Typeable)

instance Exception HAStateException

check_rc :: String -> CInt -> IO ()
check_rc _ 0 = return ()
check_rc msg i = throwIO $ HAStateException msg $ fromIntegral i

newtype {-# CTYPE "const char*" #-} ConstCString = ConstCString CString

foreign import capi ha_entrypoint_reply
  :: Ptr Word128 -> CInt
  -> CInt -> Ptr Fid
  -> CInt -> Ptr ConstCString
  -> Ptr Fid -> CString
  -> IO ()

-- | Replies an entrypoint request.
entrypointReply :: ReqId -> [Fid] -> [String] -> Fid -> String -> IO ()
entrypointReply (ReqId reqId) confdFids epNames rmFid rmEp =
  withMany (withCString) epNames $ \cnames ->
    withArrayLen0 nullPtr cnames $ \ceps_len ceps_ptr ->
      withArrayLen confdFids $ \cfids_len cfids_ptr ->
        withCString rmEp $ \crm_ep ->
          with rmFid $ \crmfid ->
            with reqId $ \reqId_ptr ->
              ha_entrypoint_reply reqId_ptr 0 (fromIntegral cfids_len) cfids_ptr
                                  (fromIntegral ceps_len) (castPtr ceps_ptr)
                                  crmfid crm_ep
  where
    _ = ConstCString -- Avoid unused warning for ConstCString

-- | Replies an entrypoint request as invalid.
entrypointNoReply :: ReqId -> IO ()
entrypointNoReply (ReqId reqId) = with reqId $ \reqId_ptr ->
  ha_entrypoint_reply reqId_ptr (-1) 0 nullPtr 0 nullPtr nullPtr nullPtr

-- | Replies to failure vector request
failureVectorReply :: HALink -> Cookie -> Fid -> NVec -> IO ()
failureVectorReply (HALink hl) cookie pool fvec =
  allocaBytesAligned #{size struct m0_ha_msg_failure_vec_rep}
                     #{alignment struct m0_ha_msg_failure_vec_rep} $ \ffvec -> do
    #{poke struct m0_ha_msg_failure_vec_rep, mfp_cookie} ffvec cookie
    #{poke struct m0_ha_msg_failure_vec_rep, mfp_pool} ffvec pool
    #{poke struct m0_ha_msg_failure_vec_rep, mfp_nr} ffvec
       (fromIntegral $ length fvec :: Word64)
    pokeArray (#{ptr struct m0_ha_msg_failure_vec_rep, mfp_vec} ffvec) fvec
    void $ ha_state_failure_vec_reply hl ffvec

foreign import capi ha_state_failure_vec_reply :: Ptr HALink -> Ptr () -> IO Word64

foreign import capi "hastate.h ha_state_rpc_machine" ha_state_rpc_machine :: IO (Ptr RPCMachineV)

-- | Yields the 'RPCMachine' created with 'initHAState'.
getRPCMachine :: IO (Maybe RPCMachine)
getRPCMachine = do p <- ha_state_rpc_machine
                   return $ if nullPtr == p then Nothing
                              else Just $ RPCMachine p

-- * Boilerplate instances

instance Enum ProcessType where
  toEnum #{const M0_CONF_HA_PROCESS_OTHER} = TAG_M0_CONF_HA_PROCESS_OTHER
  toEnum #{const M0_CONF_HA_PROCESS_KERNEL} = TAG_M0_CONF_HA_PROCESS_KERNEL
  toEnum #{const M0_CONF_HA_PROCESS_M0MKFS} = TAG_M0_CONF_HA_PROCESS_M0MKFS
  toEnum #{const M0_CONF_HA_PROCESS_M0D} = TAG_M0_CONF_HA_PROCESS_M0D
  toEnum i = error $ "ProcessType toEnum failed with " ++ show i

  fromEnum TAG_M0_CONF_HA_PROCESS_OTHER = #{const M0_CONF_HA_PROCESS_OTHER}
  fromEnum TAG_M0_CONF_HA_PROCESS_KERNEL = #{const M0_CONF_HA_PROCESS_KERNEL}
  fromEnum TAG_M0_CONF_HA_PROCESS_M0MKFS = #{const M0_CONF_HA_PROCESS_M0MKFS}
  fromEnum TAG_M0_CONF_HA_PROCESS_M0D = #{const M0_CONF_HA_PROCESS_M0D}

instance Enum ProcessEventType where
  toEnum #{const M0_CONF_HA_PROCESS_STARTING} = TAG_M0_CONF_HA_PROCESS_STARTING
  toEnum #{const M0_CONF_HA_PROCESS_STARTED} = TAG_M0_CONF_HA_PROCESS_STARTED
  toEnum #{const M0_CONF_HA_PROCESS_STOPPING} = TAG_M0_CONF_HA_PROCESS_STOPPING
  toEnum #{const M0_CONF_HA_PROCESS_STOPPED} = TAG_M0_CONF_HA_PROCESS_STOPPED
  toEnum i = error $ "ProcessEventType toEnum failed with " ++ show i

  fromEnum TAG_M0_CONF_HA_PROCESS_STARTING = #{const M0_CONF_HA_PROCESS_STARTING}
  fromEnum TAG_M0_CONF_HA_PROCESS_STARTED = #{const M0_CONF_HA_PROCESS_STARTED}
  fromEnum TAG_M0_CONF_HA_PROCESS_STOPPING = #{const M0_CONF_HA_PROCESS_STOPPING}
  fromEnum TAG_M0_CONF_HA_PROCESS_STOPPED = #{const M0_CONF_HA_PROCESS_STOPPED}

instance Enum ServiceEventType where
  toEnum #{const M0_CONF_HA_SERVICE_STARTING} = TAG_M0_CONF_HA_SERVICE_STARTING
  toEnum #{const M0_CONF_HA_SERVICE_STARTED} = TAG_M0_CONF_HA_SERVICE_STARTED
  toEnum #{const M0_CONF_HA_SERVICE_STOPPING} = TAG_M0_CONF_HA_SERVICE_STOPPING
  toEnum #{const M0_CONF_HA_SERVICE_STOPPED} = TAG_M0_CONF_HA_SERVICE_STOPPED
  toEnum #{const M0_CONF_HA_SERVICE_FAILED} = TAG_M0_CONF_HA_SERVICE_FAILED
  toEnum i = error $ "ServiceEventType toEnum failed with " ++ show i

  fromEnum TAG_M0_CONF_HA_SERVICE_STARTING = #{const M0_CONF_HA_SERVICE_STARTING}
  fromEnum TAG_M0_CONF_HA_SERVICE_STARTED = #{const M0_CONF_HA_SERVICE_STARTED}
  fromEnum TAG_M0_CONF_HA_SERVICE_STOPPING = #{const M0_CONF_HA_SERVICE_STOPPING}
  fromEnum TAG_M0_CONF_HA_SERVICE_STOPPED = #{const M0_CONF_HA_SERVICE_STOPPED}
  fromEnum TAG_M0_CONF_HA_SERVICE_FAILED = #{const M0_CONF_HA_SERVICE_FAILED}

instance Enum BELocation where
  toEnum #{const M0_BE_LOC_NONE} = BE_LOC_NONE
  toEnum #{const M0_BE_LOC_LOG} = BE_LOC_LOG
  toEnum #{const M0_BE_LOC_SEGMENT_1} = BE_LOC_SEGMENT_1
  toEnum #{const M0_BE_LOC_SEGMENT_2} = BE_LOC_SEGMENT_2
  toEnum i = error $ "BELocation toEnum failed with " ++ show i

  fromEnum BE_LOC_NONE = #{const M0_BE_LOC_NONE}
  fromEnum BE_LOC_LOG = #{const M0_BE_LOC_LOG}
  fromEnum BE_LOC_SEGMENT_1 = #{const M0_BE_LOC_SEGMENT_1}
  fromEnum BE_LOC_SEGMENT_2 = #{const M0_BE_LOC_SEGMENT_2}

instance Enum StobIoOpcode where
  toEnum #{const SIO_INVALID} = SIO_INVALID
  toEnum #{const SIO_READ} = SIO_READ
  toEnum #{const SIO_WRITE} = SIO_WRITE
  toEnum #{const SIO_BARRIER} = SIO_BARRIER
  toEnum #{const SIO_SYNC} = SIO_SYNC
  toEnum i = error $ "StobIoOpcode toEnum failed with " ++ show i

  fromEnum SIO_INVALID = #{const SIO_INVALID}
  fromEnum SIO_READ = #{const SIO_READ}
  fromEnum SIO_WRITE = #{const SIO_WRITE}
  fromEnum SIO_BARRIER = #{const SIO_BARRIER}
  fromEnum SIO_SYNC = #{const SIO_SYNC}

instance Storable BEIoErr where
  sizeOf _ = #{size struct m0_be_io_err}
  alignment _ = #{alignment struct m0_be_io_err}

  peek p = liftM3 BEIoErr
      (#{peek struct m0_be_io_err, ber_errcode} p)
      (w8ToEnum <$> (#{peek struct m0_be_io_err, ber_location} p))
      (w8ToEnum <$> (#{peek struct m0_be_io_err, ber_io_opcode} p))

  poke p (BEIoErr err loc op) = do
      #{poke struct m0_be_io_err, ber_errcode} p err
      #{poke struct m0_be_io_err, ber_location} p (enumToW8 loc)
      #{poke struct m0_be_io_err, ber_io_opcode} p (enumToW8 op)

instance Storable HAMsgMeta where
  sizeOf _ = #{size ha_msg_metadata_t}
  alignment _ = #{alignment ha_msg_metadata_t}

  peek p = liftM4 HAMsgMeta
      (#{peek ha_msg_metadata_t, ha_hm_fid} p)
      (#{peek ha_msg_metadata_t, ha_hm_source_process} p)
      (#{peek ha_msg_metadata_t, ha_hm_source_service} p)
      (#{peek ha_msg_metadata_t, ha_hm_time} p)

  poke p (HAMsgMeta fid' sp ss t) = do
      #{poke ha_msg_metadata_t, ha_hm_fid} p fid'
      #{poke ha_msg_metadata_t, ha_hm_source_process} p sp
      #{poke ha_msg_metadata_t, ha_hm_source_service} p ss
      #{poke ha_msg_metadata_t, ha_hm_time} p t

instance Storable ProcessEvent where
  sizeOf _ = #{size struct m0_conf_ha_process}
  alignment _ = #{alignment struct m0_conf_ha_process}

  peek p = liftM3 ProcessEvent
      (w64ToEnum <$> (#{peek struct m0_conf_ha_process, chp_event} p))
      (w64ToEnum <$> (#{peek struct m0_conf_ha_process, chp_type} p))
      (#{peek struct m0_conf_ha_process, chp_pid} p)
  poke p (ProcessEvent ev et pid) = do
      #{poke struct m0_conf_ha_process, chp_event} p (enumToW64 ev)
      #{poke struct m0_conf_ha_process, chp_type} p (enumToW64 et)
      #{poke struct m0_conf_ha_process, chp_pid} p pid

instance Storable ServiceEvent where
  sizeOf _ = #{size struct m0_conf_ha_service}
  alignment _ = #{alignment struct m0_conf_ha_service}

  peek p = liftM2 ServiceEvent
      (w64ToEnum <$> (#{peek struct m0_conf_ha_service, chs_event} p))
      (w64ToEnum <$> (#{peek struct m0_conf_ha_service, chs_type} p))

  poke p (ServiceEvent ev et) = do
      #{poke struct m0_conf_ha_service, chs_event} p (enumToW64 ev)
      #{poke struct m0_conf_ha_service, chs_type} p (enumToW64 et)

enumToW8 :: Enum a => a -> Word8
enumToW8 = fromIntegral . fromEnum

w8ToEnum :: Enum a => Word8 -> a
w8ToEnum = toEnum . fromIntegral

enumToW64 :: Enum a => a -> Word64
enumToW64 = fromIntegral . fromEnum

w64ToEnum :: Enum a => Word64 -> a
w64ToEnum = toEnum . fromIntegral
