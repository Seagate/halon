{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the hastate interface. This is the HA side of the notification
-- interface.
--
-- TODO: Move various message types sent through new notification
-- interface into own module or into confc package.
module Mero.Notification.HAState
  ( Note(..)
  , HAStateCallbacks(..)
  , NVec
  , HALink
  , HAMsgPtr
  , ReqId(..)
  , initHAState
  , finiHAState
  , getRPCMachine
  , notify
  , disconnect
  , delivered
  , entrypointReply
  , entrypointNoReply
  , pingProcess
  , HAMsg(..)
  , HAMsgMeta(..)
  , failureVectorReply
  , HAStateException(..)
  , ProcessEvent(..)
  , ProcessEventType(..)
  , ProcessType(..)
  , ServiceEvent(..)
  , ServiceEventType(..)
  , BEIoErr(..)
  , StobId(..)
  , StobIoOpcode(..)
  , StobIoqError(..)
  , RpcEvent(..)
  , m0_time_now
  ) where

import HA.Resources.Mero.Note
import HA.SafeCopy
import HA.Aeson (ToJSON)

import Mero.ConfC (Cookie, Fid, m0_fid0, Word128, ServiceType)
import Network.RPC.RPCLite (RPCAddress(..), RPCMachine(..), RPCMachineV)

import Control.Exception (Exception, throwIO, SomeException, evaluate)
import Control.Monad (liftM2, liftM3, liftM5, void)
import Control.Monad.Catch (catch)

import Data.ByteString as B (useAsCString)
import Data.Dynamic (Typeable)
import Data.Hashable (Hashable)
import Data.IORef (atomicModifyIORef, modifyIORef, IORef , newIORef)
import Data.Int
import Data.Word (Word8, Word32, Word64)
import Foreign.C.Types (CInt(..))
import Foreign.C.String (CString, withCString)
import Foreign.Marshal.Alloc (allocaBytesAligned, alloca)
import Foreign.Marshal.Array (peekArray, withArrayLen, withArrayLen0, pokeArray)
import Foreign.Marshal.Utils (with, withMany)
import Foreign.Ptr (Ptr, FunPtr, freeHaskellFunPtr, nullPtr, castPtr, plusPtr)
import Foreign.Storable (Storable(..))
import GHC.Generics (Generic)
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

#include "hastate.h"

#include "be/ha.h"
#include "conf/obj.h"
#include "ha/msg.h"
#include "rpc/ha.h"
#include "stob/io.h"
#include "stob/ioq_error.h"
#include "lib/time.h"

#if __GLASGOW_HASKELL__ < 800
#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__); }, y__)
#endif

-- | m0_ha_msg metadata
data HAMsgMeta = HAMsgMeta
  { _hm_fid :: Fid
  , _hm_source_process :: Fid
  , _hm_source_service :: Fid
  , _hm_time :: Word64
  , _hm_epoch :: Word64
  } deriving (Show, Eq, Ord, Typeable, Generic)

instance Hashable HAMsgMeta
instance ToJSON HAMsgMeta
instance Monoid HAMsgMeta where
  mempty = HAMsgMeta m0_fid0 m0_fid0 m0_fid0 0 0
  mappend = max
deriveSafeCopy 0 'base ''HAMsgMeta

-- | Represents @m0_ha_msg@.
data HAMsg a = HAMsg
  { _ha_msg_data :: a
  -- ^ @m0_ha_msg_data@
  , _ha_msg_meta :: HAMsgMeta
  -- ^ Collection of information from @m0_ha_msg@ that's useful to
  -- carry around with the content of the message. Often the content
  -- itself does not duplicate this information.
  } deriving (Eq, Show, Ord, Typeable, Generic)

instance Hashable a => Hashable (HAMsg a)
instance ToJSON a => ToJSON (HAMsg a)
deriveSafeCopy 0 'base ''HAMsg

-- | Represents a pointer to @m0_ha_msg@.
newtype {-# CTYPE "ha/msg.h" "const struct m0_ha_msg" #-} HAMsgPtr = HAMsgPtr (Ptr HAMsgPtr)

-- | @m0_conf_ha_process_type@.
data {-# CTYPE "conf/ha.h" "struct m0_conf_ha_process_type" #-}
  ProcessType = TAG_M0_CONF_HA_PROCESS_OTHER
              | TAG_M0_CONF_HA_PROCESS_KERNEL
              | TAG_M0_CONF_HA_PROCESS_M0MKFS
              | TAG_M0_CONF_HA_PROCESS_M0D
              deriving (Show, Eq, Ord, Typeable, Generic)

instance Hashable ProcessType
deriveSafeCopy 0 'base ''ProcessType

-- | @m0_conf_ha_process_event@.
data {-# CTYPE "conf/ha.h" "struct m0_conf_ha_process_event" #-}
  ProcessEventType = TAG_M0_CONF_HA_PROCESS_STARTING
                   | TAG_M0_CONF_HA_PROCESS_STARTED
                   | TAG_M0_CONF_HA_PROCESS_STOPPING
                   | TAG_M0_CONF_HA_PROCESS_STOPPED
                   deriving (Show, Eq, Ord, Typeable, Generic)

instance Hashable ProcessEventType
deriveSafeCopy 0 'base ''ProcessEventType

-- | @m0_conf_ha_process@.
data ProcessEvent = ProcessEvent
  { _chp_event :: ProcessEventType
  , _chp_type :: ProcessType
  , _chp_pid :: Word64
  } deriving (Show, Eq, Ord, Typeable, Generic)

instance Hashable ProcessEvent
deriveSafeCopy 0 'base ''ProcessEvent

-- | @m0_conf_ha_service_event@.
data {-# CTYPE "conf/ha.h" "struct m0_conf_ha_service_event" #-}
  ServiceEventType = TAG_M0_CONF_HA_SERVICE_STARTING
                   | TAG_M0_CONF_HA_SERVICE_STARTED
                   | TAG_M0_CONF_HA_SERVICE_STOPPING
                   | TAG_M0_CONF_HA_SERVICE_STOPPED
                   | TAG_M0_CONF_HA_SERVICE_FAILED
                   deriving (Show, Eq, Ord, Typeable, Generic)

instance Hashable ServiceEventType
deriveSafeCopy 0 'base ''ServiceEventType

-- | @m0_conf_ha_service@
data ServiceEvent = ServiceEvent
  { _chs_event :: ServiceEventType
  , _chs_type :: ServiceType
  , _chs_pid :: Word64
  } deriving (Show, Eq, Ord, Typeable, Generic)

instance Hashable ServiceEvent

deriveSafeCopy 0 'base ''ServiceEvent

-- | @m0_be_location@.
data {-# CTYPE "be/ha.h" "struct m0_be_location" #-}
  BELocation =
      BE_LOC_NONE
    | BE_LOC_LOG
    | BE_LOC_SEGMENT_1
    | BE_LOC_SEGMENT_2
  deriving (Eq, Show, Ord, Typeable, Generic)

instance Hashable BELocation
instance ToJSON BELocation
deriveSafeCopy 0 'base ''BELocation

-- | @m0_stob_io_opcode@.
data {-# CTYPE "stob/io.h" "struct m0_stob_io_opcode" #-}
  StobIoOpcode =
      SIO_INVALID
    | SIO_READ
    | SIO_WRITE
    | SIO_BARRIER
    | SIO_SYNC
  deriving (Eq, Show, Ord, Typeable, Generic)

instance Hashable StobIoOpcode
instance ToJSON StobIoOpcode
deriveSafeCopy 0 'base ''StobIoOpcode

-- | @m0_be_io_err@.
data {-# CTYPE "be/ha.h" "struct m0_be_io_err" #-}
  BEIoErr = BEIoErr {
    _ber_errcode :: Word32
  , _ber_location :: BELocation
  , _ber_io_opcode :: StobIoOpcode
  } deriving (Eq, Show, Ord, Typeable, Generic)

instance Hashable BEIoErr
instance ToJSON BEIoErr
deriveSafeCopy 0 'base ''BEIoErr

-- | @m0_stob_id@.
data {-# CTYPE "stob/stob.h" "struct m0_stob_id" #-}
  StobId = StobId { _si_domain_fid :: Fid
                  , _si_fid :: Fid }
  deriving (Eq, Show, Ord, Typeable, Generic)

instance Hashable StobId
instance ToJSON StobId
deriveSafeCopy 0 'base ''StobId

-- | @m0_be_ioq_error@.
data {-# CTYPE "stob/ioq_error.h" "struct m0_be_ioq_error" #-}
  StobIoqError = StobIoqError
    { _sie_conf_sdev :: Fid
    , _sie_stob_id :: StobId
    , _sie_fd :: Int64
    , _sie_opcode :: StobIoOpcode
    , _sie_rc :: Int64
    , _sie_offset :: Word64
    , _sie_size :: Word64
    , _sie_bshift :: Word32
    } deriving (Eq, Show, Ord, Typeable, Generic)

instance Hashable StobIoqError
instance ToJSON StobIoqError
deriveSafeCopy 0 'base ''StobIoqError

-- | @m0_ha_msg_rpc@.
data {-# CTYPE "rpc/ha.h" "struct m0_ha_msg_rpc" #-}
  RpcEvent = RpcEvent
    { _hmr_attempts :: Word64
    , _hmr_state :: ConfObjectState
    } deriving (Eq, Show, Ord, Typeable, Generic)

instance Hashable RpcEvent
instance ToJSON RpcEvent
deriveSafeCopy 0 'base ''RpcEvent

-- | Notes telling the state of a given configuration object
data Note = Note
    { no_id :: Fid
    , no_ostate :: ConfObjectState
    } deriving (Eq, Typeable, Generic, Show, Ord)

instance Hashable Note
deriveSafeCopy 0 'base ''Note

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

-- | List of callbacks beign used by notification interface
data HAStateCallbacks = HSC
  { hscStateGet :: HAMsgPtr -> HALink -> Word64 -> NVec -> IO ()
    -- ^ Called when a request to get the state of some objects is
    -- received.
    --
    -- When the requested state is available, 'notify' must
    -- be called by passing the given link.
  , hscProcessEvent :: HAMsgPtr -> HALink -> HAMsgMeta -> ProcessEvent -> IO ()
    -- ^ Called when process event notification is received
  , hscStobIoqError :: HAMsgPtr -> HALink -> HAMsgMeta -> StobIoqError -> IO ()
    -- ^ Called when @m0_stob_ioq_error@ is received
  , hscServiceEvent :: HAMsgPtr -> HALink -> HAMsgMeta -> ServiceEvent -> IO ()
    -- ^ Called when service event notification is received
  , hscBeError :: HAMsgPtr -> HALink -> HAMsgMeta -> BEIoErr -> IO ()
    -- ^ Called when error is thrown from metadata BE.
  , hscStateSet :: HAMsgPtr -> HALink -> NVec -> HAMsgMeta -> IO ()
    -- ^ Called when a request to update the state of some objects is
    -- received.
  , hscFailureVector :: HAMsgPtr -> HALink -> Cookie -> Fid -> IO ()
    -- ^ Failure vector request.
  , hscKeepalive :: HALink -> Word128 -> Word64 -> IO ()
    -- ^ Process keepalive reply
  , hscRPCEvent :: HAMsgPtr -> HALink -> HAMsgMeta -> RpcEvent -> IO ()
  }


-- | Starts the hastate interface.
--
-- Registers callbacks to handle arriving requests.
--
-- Must be called after 'Mero.m0_init'.
--
initHAState :: RPCAddress
            -> Fid -- ^ Process Fid
            -> Fid -- ^ HA Service Fid
            -> Fid -- ^ RM Service Fid
            -> HAStateCallbacks
            -> (ReqId -> Fid -> Fid -> IO ())
               -- ^ Called when a request to read current confd and rm endpoints
               -- is received.
            -> (ReqId -> HALink -> IO ())
               -- ^ Called when a new link is established.
            -> (ReqId -> HALink -> IO ())
               -- ^ Called when an old link is reconnected, may happen in case
               -- of RM service change.
            -> (ReqId -> IO ())
               -- ^ Called when it will be no link for the incoming entrypoint
               -- request
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
            -> IO ()
initHAState (RPCAddress rpcAddr) procFid haFid rmFid hsc
            ha_state_entrypoint_cb
            ha_state_link_connected ha_state_link_reused ha_state_link_absent
            ha_state_link_disconnecting ha_state_link_disconnected
            ha_state_is_delivered ha_state_is_cancelled =
    useAsCString rpcAddr $ \cRPCAddr ->
    allocaBytesAligned #{size ha_state_callbacks_t}
                       #{alignment ha_state_callbacks_t}$ \pcbs -> do
      wentry <- wrapEntryCB
      wconnected <- wrapConnectedCB
      wreused    <- wrapReconnectedCB
      wabsent    <- wrapAbsentCB
      wdisconnecting <- wrapDisconnectingCB
      wdisconnected <- wrapDisconnectedCB
      wisdelivered <- wrapIsDeliveredCB
      wiscancelled <- wrapIsCancelledCB
      wmsgcallback <- wrapGenericCallback
      #{poke ha_state_callbacks_t, ha_state_entrypoint} pcbs wentry
      #{poke ha_state_callbacks_t, ha_state_link_connected} pcbs wconnected
      #{poke ha_state_callbacks_t, ha_state_link_reused} pcbs wreused
      #{poke ha_state_callbacks_t, ha_state_link_absent} pcbs wabsent
      #{poke ha_state_callbacks_t, ha_state_link_disconnecting} pcbs
         wdisconnecting
      #{poke ha_state_callbacks_t, ha_state_link_disconnected} pcbs
         wdisconnected
      #{poke ha_state_callbacks_t, ha_state_is_delivered} pcbs wisdelivered
      #{poke ha_state_callbacks_t, ha_state_is_cancelled} pcbs wiscancelled
      #{poke ha_state_callbacks_t, ha_message_callback} pcbs wmsgcallback
      modifyIORef cbRefs
        ( (SomeFunPtr wentry:)
        . (SomeFunPtr wconnected:)
        . (SomeFunPtr wreused:)
        . (SomeFunPtr wdisconnecting:)
        . (SomeFunPtr wdisconnected:)
        . (SomeFunPtr wisdelivered:)
        . (SomeFunPtr wiscancelled:)
        . (SomeFunPtr wmsgcallback:)
        )
      rc <- with procFid $ \procPtr ->
            with haFid $ \haPtr ->
            with rmFid $ \rmPtr ->
            ha_state_init cRPCAddr procPtr haPtr rmPtr pcbs
      check_rc "initHAState" rc
  where

    msgCallback :: HALink -> HAMsgPtr -> IO ()
    msgCallback hl p@(HAMsgPtr msg) = do
      meta <- HAMsgMeta
                 <$> (#{peek struct m0_ha_msg, hm_fid} msg)
                 <*> (#{peek struct m0_ha_msg, hm_source_process} msg)
                 <*> (#{peek struct m0_ha_msg, hm_source_service} msg)
                 <*> (#{peek struct m0_ha_msg, hm_time} msg)
                 <*> (#{peek struct m0_ha_msg, hm_epoch} msg)
      let payload = #{ptr struct m0_ha_msg, hm_data} msg :: Ptr ()
      mtype <- #{peek struct m0_ha_msg_data, hed_type} payload :: IO Word64
      case mtype of
        #{const M0_HA_MSG_STOB_IOQ} -> do
             ioq <- #{peek struct m0_ha_msg_data, u.hed_stob_ioq} payload
             hscStobIoqError hsc p hl meta ioq
        #{const M0_HA_MSG_NVEC} -> do
             let pl = #{ptr struct m0_ha_msg_data, u.hed_nvec} payload :: Ptr NVec
             vtype <- #{peek struct m0_ha_msg_nvec, hmnv_type} pl :: IO Word64
             xid   <- #{peek struct m0_ha_msg_nvec, hmnv_id_of_get} pl :: IO Word64
             nts   <- peekNote pl
             if vtype > 0
             then hscStateGet hsc p hl xid nts
             else hscStateSet hsc p hl nts meta
        #{const M0_HA_MSG_FAILURE_VEC_REQ} -> do
             let pl = #{ptr struct m0_ha_msg_data, u.hed_fvec_req} payload :: Ptr ()
             pool   <- #{peek struct m0_ha_msg_failure_vec_req, mfq_pool} pl
             cookie <- #{peek struct m0_ha_msg_failure_vec_req, mfq_cookie} pl
             hscFailureVector hsc p hl cookie pool
        #{const M0_HA_MSG_KEEPALIVE_REP} -> do
             let pl = #{ptr struct m0_ha_msg_data, u.hed_keepalive_rep} payload :: Ptr ()
             kap_id <- #{peek struct m0_ha_msg_keepalive_rep, kap_id} pl
             kap_counter <- #{peek struct m0_ha_msg_keepalive_rep, kap_counter} pl
             hscKeepalive hsc hl kap_id kap_counter
             delivered hl p
        #{const M0_HA_MSG_EVENT_PROCESS} -> do
             pevent <- #{peek struct m0_ha_msg_data, u.hed_event_process} payload
             hscProcessEvent hsc p hl meta pevent
        #{const M0_HA_MSG_EVENT_SERVICE} -> do
             sevent <- #{peek struct m0_ha_msg_data, u.hed_event_service} payload
             hscServiceEvent hsc p hl meta sevent
        #{const M0_HA_MSG_EVENT_RPC} -> do
             revent <- #{peek struct m0_ha_msg_data, u.hed_event_rpc} payload
             hscRPCEvent hsc p hl meta revent
        #{const M0_HA_MSG_BE_IO_ERR} -> do
             sevent <- #{peek struct m0_ha_msg_data, u.hed_be_io_err} payload
             hscBeError hsc p hl meta sevent
        _ | otherwise -> do
             ha_msg_debug_print p "unsupported message"
             delivered hl p

    wrapGenericCallback = cwrapGenericCB $ \hl msg -> catch
       (msgCallback (HALink hl) (HAMsgPtr msg))
       $ \e -> hPutStrLn stderr $
                  "initHAState.wrapGenericCallback: " ++ show (e :: SomeException)

    wrapEntryCB = cwrapEntryCB $ \reqId processPtr profilePtr -> catch (do
        processFid <- peek processPtr
        profileFid <- peek profilePtr
        w128       <- peek reqId
        ha_state_entrypoint_cb (ReqId w128) processFid profileFid)
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
    wrapAbsentCB = cwrapAbsentCB $ \wptr -> do
        w128 <- peek wptr
        catch (ha_state_link_absent (ReqId w128)) $ \e ->
          hPutStrLn stderr $
            "initHAState.wrapAbsentCB: " ++ show (e :: SomeException)
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
            "initHAState.wrapIsDeliveredCB: " ++ show (e :: SomeException)
    wrapIsCancelledCB = cwrapIsDeliveredCB $ \hl tag ->
        catch (ha_state_is_cancelled (HALink hl) tag) $ \e ->
          hPutStrLn stderr $
            "initHAState.wrapIsCancelledCB: " ++ show (e :: SomeException)

peekNote :: Ptr NVec -> IO NVec
peekNote p = do
  nr <- #{peek struct m0_ha_msg_nvec, hmnv_nr} p :: IO Word64
  let array = #{ptr struct m0_ha_msg_nvec, hmnv_arr} p
  peekArray (fromIntegral nr) array

data HAStateCallbacksV

foreign import capi ha_state_init ::
    CString -> Ptr Fid -> Ptr Fid -> Ptr Fid -> Ptr HAStateCallbacksV -> IO CInt

foreign import ccall "wrapper" cwrapEntryCB ::
                  (Ptr Word128 -> Ptr Fid -> Ptr Fid -> IO ())
    -> IO (FunPtr (Ptr Word128 -> Ptr Fid -> Ptr Fid -> IO ()))

foreign import ccall "wrapper" cwrapDisconnectingCB ::
                  (Ptr HALink -> IO ())
    -> IO (FunPtr (Ptr HALink -> IO ()))

foreign import ccall "wrapper" cwrapConnectedCB ::
                  (Ptr Word128 -> Ptr HALink -> IO ())
    -> IO (FunPtr (Ptr Word128 -> Ptr HALink -> IO ()))

foreign import ccall "wrapper" cwrapAbsentCB ::
                  (Ptr Word128 -> IO ())
    -> IO (FunPtr (Ptr Word128 -> IO ()))

foreign import ccall "wrapper" cwrapIsDeliveredCB ::
    (Ptr HALink -> Word64 -> IO ()) -> IO (FunPtr (Ptr HALink -> Word64 -> IO ()))

foreign import ccall "wrapper" cwrapGenericCB ::
                  (Ptr HALink -> Ptr HAMsgPtr -> IO ())
    -> IO (FunPtr (Ptr HALink -> Ptr HAMsgPtr -> IO ()))

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

-- | Finalizes the hastate interface.
finiHAState :: IO ()
finiHAState = do
    ha_state_fini
    atomicModifyIORef cbRefs (\cbs -> ([],cbs)) >>= mapM_ freeCB
  where
    freeCB (SomeFunPtr ptr) = freeHaskellFunPtr ptr

foreign import capi safe ha_state_fini :: IO ()

-- | Notifies mero at the remote address that the state of some objects has
-- changed.
notify :: HALink -> Word64 -> NVec -> Fid -> Fid -> Word64 -> IO Word64
notify (HALink hl) idx nvec ha_pfid ha_sfid epoch =
  allocaBytesAligned #{size struct m0_ha_msg_nvec}
                     #{alignment struct m0_ha_msg_nvec} $ \pnvec -> do
    #{poke struct m0_ha_msg_nvec, hmnv_type} pnvec (0 :: Word64)
    #{poke struct m0_ha_msg_nvec, hmnv_id_of_get} pnvec idx
    #{poke struct m0_ha_msg_nvec, hmnv_ignore_same_state} pnvec (0 :: Word64)
    #{poke struct m0_ha_msg_nvec, hmnv_nr} pnvec
        (fromIntegral $ length nvec :: Word64)
    pokeArray (#{ptr struct m0_ha_msg_nvec, hmnv_arr} pnvec) nvec
    with ha_pfid $ \ha_pfid_ptr -> with ha_sfid $ \ha_sfid_ptr -> do
      ha_state_notify hl pnvec ha_pfid_ptr ha_sfid_ptr epoch

foreign import capi safe "hastate.h ha_state_notify"
  ha_state_notify :: Ptr HALink -> Ptr NVec -> Ptr Fid -> Ptr Fid -> Word64 -> IO Word64

-- | Disconnects a link.
disconnect :: HALink -> IO ()
disconnect (HALink hl) = ha_state_disconnect hl

foreign import capi "hastate.h ha_state_disconnect"
  ha_state_disconnect :: Ptr HALink -> IO ()

-- | Sends keepalive request to process on the given link
pingProcess :: Word128 -> HALink -> Fid -> Fid -> Fid -> IO Word64
pingProcess req_id (HALink hl) pingfid pfid sfid = alloca $ \req_id_p -> do
  poke req_id_p req_id
  with pingfid $ \pingfid_ptr ->
    with pfid $ \pfid_ptr ->
      with sfid $ \sfid_ptr -> do
        ha_state_ping_process hl req_id_p pingfid_ptr pfid_ptr sfid_ptr

foreign import capi safe "hastate.h ha_state_ping_process"
  ha_state_ping_process :: Ptr HALink -> Ptr Word128 -> Ptr Fid -> Ptr Fid
                        -> Ptr Fid -> IO Word64

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
  -> Word32 -> Ptr Fid
  -> Ptr ConstCString
  -> Word32
  -> Ptr Fid -> CString
  -> IO ()

-- | Replies an entrypoint request.
entrypointReply :: ReqId -> [Fid] -> [String] -> Int -> Fid -> String -> IO ()
entrypointReply (ReqId reqId) confdFids epNames quorum rmFid rmEp =
  withMany (withCString) epNames $ \cnames ->
    withArrayLen0 nullPtr cnames $ \_ ceps_ptr ->
      withArrayLen confdFids $ \cfids_len cfids_ptr ->
        withCString rmEp $ \crm_ep ->
          with rmFid $ \crmfid ->
            with reqId $ \reqId_ptr ->
              ha_entrypoint_reply reqId_ptr 0 (fromIntegral cfids_len) cfids_ptr
                                  (castPtr ceps_ptr) (fromIntegral quorum)
                                  crmfid crm_ep
  where
    _ = ConstCString -- Avoid unused warning for ConstCString

-- | Replies an entrypoint request as invalid.
entrypointNoReply :: ReqId -> IO ()
entrypointNoReply (ReqId reqId) = with reqId $ \reqId_ptr ->
  ha_entrypoint_reply reqId_ptr (-1) 0 nullPtr nullPtr 0 nullPtr nullPtr

-- | Replies to failure vector request
failureVectorReply :: HALink -> Cookie -> Fid -> Fid -> Fid -> NVec -> IO ()
failureVectorReply (HALink hl) cookie pool pfid sfid fvec =
  allocaBytesAligned #{size struct m0_ha_msg_failure_vec_rep}
                     #{alignment struct m0_ha_msg_failure_vec_rep} $ \ffvec -> do
    #{poke struct m0_ha_msg_failure_vec_rep, mfp_cookie} ffvec cookie
    #{poke struct m0_ha_msg_failure_vec_rep, mfp_pool} ffvec pool
    #{poke struct m0_ha_msg_failure_vec_rep, mfp_nr} ffvec
       (fromIntegral $ length fvec :: Word64)
    pokeArray (#{ptr struct m0_ha_msg_failure_vec_rep, mfp_vec} ffvec) fvec
    with pfid $ \pfid_ptr ->
      with sfid $ \sfid_ptr -> do
        void $ ha_state_failure_vec_reply hl ffvec pfid_ptr sfid_ptr

foreign import capi "hastate.h ha_state_failure_vec_reply"
  ha_state_failure_vec_reply :: Ptr HALink -> Ptr () -> Ptr Fid -> Ptr Fid -> IO Word64

foreign import capi "hastate.h ha_state_rpc_machine"
  ha_state_rpc_machine :: IO (Ptr RPCMachineV)

-- | Yields the 'RPCMachine' created with 'initHAState'.
getRPCMachine :: IO (Maybe RPCMachine)
getRPCMachine = do p <- ha_state_rpc_machine
                   return $ if nullPtr == p then Nothing
                              else Just $ RPCMachine p

-- | Mark the given 'HAMsgPtr' as delivered ('ha_state_delivered').
delivered :: HALink -> HAMsgPtr -> IO ()
delivered (HALink hl) (HAMsgPtr msg) = ha_state_delivered hl msg

foreign import capi "hastate.h ha_state_delivered"
  ha_state_delivered :: Ptr HALink -> Ptr HAMsgPtr -> IO ()

ha_msg_debug_print :: HAMsgPtr -> String -> IO ()
ha_msg_debug_print (HAMsgPtr msg) s = withCString s $ m0_ha_msg_debug_print msg

foreign import capi "ha/msg.h m0_ha_msg_debug_print"
  m0_ha_msg_debug_print :: Ptr HAMsgPtr -> CString -> IO ()

foreign import capi "lib/time.h m0_time_now"
  m0_time_now :: IO Word64

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

instance Storable StobId where
  sizeOf _ = #{size struct m0_stob_id}
  alignment _ = #{alignment struct m0_stob_id}

  peek p = liftM2 StobId
    (#{peek struct m0_stob_id, si_domain_fid} p)
    (#{peek struct m0_stob_id, si_fid} p)

  poke p (StobId sdfid sfid) = do
    #{poke struct m0_stob_id, si_domain_fid} p sdfid
    #{poke struct m0_stob_id, si_fid} p sfid

instance Storable StobIoqError where
  sizeOf _ = #{size struct m0_stob_ioq_error}
  alignment _ = #{alignment struct m0_stob_ioq_error}

  peek p = do
    sdev <- (#{peek struct m0_stob_ioq_error, sie_conf_sdev} p)
    stob_id <- (#{peek struct m0_stob_ioq_error, sie_stob_id} p)
    fd <- (#{peek struct m0_stob_ioq_error, sie_fd} p)
    opcode <- w8ToEnum <$> (#{peek struct m0_stob_ioq_error, sie_opcode} p)
    rc <- (#{peek struct m0_stob_ioq_error, sie_rc} p)
    offset <- (#{peek struct m0_stob_ioq_error, sie_offset} p)
    size <- (#{peek struct m0_stob_ioq_error, sie_size} p)
    bshift <- (#{peek struct m0_stob_ioq_error, sie_bshift} p)
    return $ StobIoqError sdev stob_id fd opcode rc offset size bshift

  poke p (StobIoqError sdev stob_id fd opcode rc offset size bshift) = do
    #{poke struct m0_stob_ioq_error, sie_conf_sdev} p sdev
    #{poke struct m0_stob_ioq_error, sie_stob_id} p stob_id
    #{poke struct m0_stob_ioq_error, sie_fd} p fd
    #{poke struct m0_stob_ioq_error, sie_opcode} p (enumToW8 opcode)
    #{poke struct m0_stob_ioq_error, sie_rc} p rc
    #{poke struct m0_stob_ioq_error, sie_offset} p offset
    #{poke struct m0_stob_ioq_error, sie_size} p size
    #{poke struct m0_stob_ioq_error, sie_bshift} p bshift

instance Storable HAMsgMeta where
  sizeOf _ = #{size ha_msg_metadata_t}
  alignment _ = #{alignment ha_msg_metadata_t}

  peek p = liftM5 HAMsgMeta
      (#{peek ha_msg_metadata_t, ha_hm_fid} p)
      (#{peek ha_msg_metadata_t, ha_hm_source_process} p)
      (#{peek ha_msg_metadata_t, ha_hm_source_service} p)
      (#{peek ha_msg_metadata_t, ha_hm_time} p)
      (#{peek ha_msg_metadata_t, ha_hm_epoch} p)

  poke p (HAMsgMeta fid' sp ss t e) = do
      #{poke ha_msg_metadata_t, ha_hm_fid} p fid'
      #{poke ha_msg_metadata_t, ha_hm_source_process} p sp
      #{poke ha_msg_metadata_t, ha_hm_source_service} p ss
      #{poke ha_msg_metadata_t, ha_hm_time} p t
      #{poke ha_msg_metadata_t, ha_hm_epoch} p e

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

  peek p = liftM3 ServiceEvent
      (w64ToEnum <$> (#{peek struct m0_conf_ha_service, chs_event} p))
      (w64ToEnum <$> (#{peek struct m0_conf_ha_service, chs_type} p))
      (#{peek struct m0_conf_ha_service, chs_pid} p)

  poke p (ServiceEvent ev et pid) = do
      #{poke struct m0_conf_ha_service, chs_event} p (enumToW64 ev)
      #{poke struct m0_conf_ha_service, chs_type} p (enumToW64 et)
      #{poke struct m0_conf_ha_service, chs_pid} p pid

instance Storable RpcEvent where
  sizeOf _ = #{size struct m0_ha_msg_rpc}
  alignment _ = #{alignment struct m0_ha_msg_rpc}

  peek p = liftM2 RpcEvent
    (#{peek struct m0_ha_msg_rpc, hmr_attempts} p)
    (w64ToEnum <$> (#{peek struct m0_ha_msg_rpc, hmr_state} p))

  poke p (RpcEvent attempts st) = do
    #{poke struct m0_ha_msg_rpc, hmr_attempts} p attempts
    #{poke struct m0_ha_msg_rpc, hmr_state} p (enumToW64 st)

enumToW8 :: Enum a => a -> Word8
enumToW8 = fromIntegral . fromEnum

w8ToEnum :: Enum a => Word8 -> a
w8ToEnum = toEnum . fromIntegral

enumToW64 :: Enum a => a -> Word64
enumToW64 = fromIntegral . fromEnum

w64ToEnum :: Enum a => Word64 -> a
w64ToEnum = toEnum . fromIntegral
