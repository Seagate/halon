{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the hastate interface. This is the HA side of the notification
-- interface.
--
module Mero.Notification.HAState
  ( Note(..)
  , NVec
  , HALink
  , ReqId
  , initHAState
  , finiHAState
  , getRPCMachine
  , notify
  , disconnect
  , entrypointReply
  , entrypointNoReply
  , HAStateException(..)
  ) where

import HA.Resources.Mero.Note

import Mero.ConfC (Fid)
import Network.RPC.RPCLite (RPCAddress(..), RPCMachine(..), RPCMachineV)

import Control.Exception      ( Exception, throwIO, SomeException, evaluate )
import Control.Monad          ( liftM2, void )
import Control.Monad.Catch    ( catch )
import Data.Binary            ( Binary )
import Data.ByteString as B   ( useAsCString )
import Data.Dynamic           ( Typeable )
import Data.Hashable          ( Hashable )
import Data.IORef             ( atomicModifyIORef, modifyIORef, IORef
                              , newIORef
                              )
import Data.Word              ( Word32, Word64 )
import Foreign.C.Types        ( CInt(..) )
import Foreign.C.String       ( CString, withCString )
import Foreign.Marshal.Alloc  ( allocaBytesAligned )
import Foreign.Marshal.Array  ( peekArray, withArray, withArrayLen, withArrayLen0, pokeArray )
import Foreign.Marshal.Utils  ( with, withMany )
import Foreign.Ptr            ( Ptr, FunPtr, freeHaskellFunPtr, nullPtr, castPtr, plusPtr )
import Foreign.Storable       ( Storable(..) )
import GHC.Generics           ( Generic )
import System.IO              ( hPutStrLn, stderr )
import System.IO.Unsafe       ( unsafePerformIO )

#include "hastate.h"
#include "conf/obj.h"

#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

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
  deriving (Show, Eq)

-- | Identifier of entrypoint requests
newtype ReqId = ReqId (Ptr ReqId)

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
            -> (HALink -> Word64 -> NVec -> IO ())
               -- ^ Called when a request to get the state of some objects is
               -- received.
               --
               -- When the requested state is available, 'notify' must
               -- be called by passing the given link.
            -> (NVec -> IO ())
               -- ^ Called when a request to update the state of some objects is
               -- received.
            -> (ReqId -> IO ())
               -- ^ Called when a request to read current confd and rm endpoints
               -- is received.
            -> (HALink -> IO ())
               -- ^ Called when a new link is established.
            -> (HALink -> IO ())
               -- ^ The link is no longer needed by the remote peer.
               -- It is safe to call 'disconnect' when all 'notify' calls
               -- using the link have completed.
            -> IO ()
initHAState (RPCAddress rpcAddr) ha_state_get ha_state_set ha_state_entry
            ha_state_link_connected ha_state_link_disconnecting =
    useAsCString rpcAddr $ \cRPCAddr ->
    allocaBytesAligned #{size ha_state_callbacks_t}
                       #{alignment ha_state_callbacks_t}$ \pcbs -> do
      wget <- wrapGetCB
      wset <- wrapSetCB
      wentry <- wrapEntryCB
      wconnected <- wrapConnectedCB
      wdisconnecting <- wrapDisconnectingCB
      #{poke ha_state_callbacks_t, ha_state_get} pcbs wget
      #{poke ha_state_callbacks_t, ha_state_set} pcbs wset
      #{poke ha_state_callbacks_t, ha_state_entrypoint} pcbs wentry
      #{poke ha_state_callbacks_t, ha_state_link_connected} pcbs wconnected
      #{poke ha_state_callbacks_t, ha_state_link_disconnecting} pcbs
         wdisconnecting
      modifyIORef cbRefs
        ( (SomeFunPtr wget:)
        . (SomeFunPtr wset:)
        . (SomeFunPtr wentry:)
        . (SomeFunPtr wconnected:)
        . (SomeFunPtr wdisconnecting:)
        )

      rc <- ha_state_init cRPCAddr pcbs
      check_rc "initHAState" rc
  where
    wrapGetCB = cwrapGetCB $ \hl w note -> catch
        (peekNote note >>= ha_state_get (HALink hl) w)
        $ \e -> hPutStrLn stderr $
                  "initHAState.wrapGetCB: " ++ show (e :: SomeException)
    wrapSetCB = cwrapSetCB $ \note -> catch
        (peekNote note >>= ha_state_set)
        $ \e -> do hPutStrLn stderr $
                     "initHAState.wrapSetCB: " ++ show (e :: SomeException)
    wrapEntryCB = cwrapEntryCB $ \reqId -> catch
        (ha_state_entry $ ReqId reqId)
        $ \e -> hPutStrLn stderr $
                  "initHAState.wrapEntryCB: " ++ show (e :: SomeException)
    wrapConnectedCB = cwrapConnectedCB $ \hl ->
        catch (ha_state_link_connected (HALink hl)) $ \e ->
          hPutStrLn stderr $
            "initHAState.wrapConnectedCB: " ++ show (e :: SomeException)
    wrapDisconnectingCB = cwrapConnectedCB $ \hl ->
        catch (ha_state_link_disconnecting (HALink hl)) $ \e ->
          hPutStrLn stderr $
            "initHAState.wrapDisconnectingCB: " ++ show (e :: SomeException)

    peekNote p = do
      nr <- #{peek struct m0_ha_msg_nvec, hmnv_nr} p :: IO Word64
      let array = #{ptr struct m0_ha_msg_nvec, hmnv_vec} p
      peekArray (fromIntegral nr) array

data HAStateCallbacksV

foreign import capi ha_state_init ::
    CString -> Ptr HAStateCallbacksV -> IO CInt

foreign import ccall "wrapper" cwrapGetCB ::
    (Ptr HALink -> Word64 ->  Ptr NVec -> IO ())
    -> IO (FunPtr (Ptr HALink -> Word64 -> Ptr NVec -> IO ()))

foreign import ccall "wrapper" cwrapSetCB :: (Ptr NVec -> IO ())
                                          -> IO (FunPtr (Ptr NVec -> IO ()))

foreign import ccall "wrapper" cwrapEntryCB ::
    (Ptr ReqId -> IO ()) -> IO (FunPtr (Ptr ReqId -> IO ()))

foreign import ccall "wrapper" cwrapConnectedCB ::
    (Ptr HALink -> IO ()) -> IO (FunPtr (Ptr HALink -> IO ()))

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
    atomicModifyIORef cbRefs (\cbs -> ([],cbs)) >>= mapM_ freeCB
    ha_state_fini
  where
    freeCB (SomeFunPtr ptr) = freeHaskellFunPtr ptr

foreign import capi unsafe ha_state_fini :: IO ()

-- | Notifies mero at the remote address that the state of some objects has
-- changed.
notify :: HALink -> Word64 -> NVec -> IO ()
notify (HALink hl) idx nvec =
  allocaBytesAligned #{size struct m0_ha_msg_nvec}
                     #{alignment struct m0_ha_msg_nvec} $ \pnvec -> do
    #{poke struct m0_ha_msg_nvec, hmnv_type} pnvec (0 :: Word64)
    #{poke struct m0_ha_msg_nvec, hmnv_id_of_get} pnvec idx
    #{poke struct m0_ha_msg_nvec, hmnv_nr} pnvec
        (fromIntegral $ length nvec :: Word64)
    pokeArray (#{ptr struct m0_ha_msg_nvec, hmnv_vec} pnvec) nvec
    void $ ha_state_notify hl pnvec

foreign import capi ha_state_notify :: Ptr HALink -> Ptr NVec -> IO Word64

-- | Disconnects a link.
disconnect :: HALink -> IO ()
disconnect (HALink hl) = ha_state_disconnect hl

foreign import capi ha_state_disconnect :: Ptr HALink -> IO ()

-- | Type of exceptions that HAState calls can produce.
data HAStateException = HAStateException String Int
  deriving (Show,Typeable)

instance Exception HAStateException

check_rc :: String -> CInt -> IO ()
check_rc _ 0 = return ()
check_rc msg i = throwIO $ HAStateException msg $ fromIntegral i

newtype {-# CTYPE "const char*" #-} ConstCString = ConstCString CString

foreign import capi ha_entrypoint_reply
  :: Ptr ReqId -> CInt
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
            ha_entrypoint_reply reqId 0 (fromIntegral cfids_len) cfids_ptr
                                (fromIntegral ceps_len) (castPtr ceps_ptr)
                                crmfid crm_ep
  where
    _ = ConstCString -- Avoid unused warning for ConstCString

-- | Replies an entrypoint request as invalid.
entrypointNoReply :: ReqId -> IO ()
entrypointNoReply (ReqId reqId) =
  ha_entrypoint_reply reqId (-1) 0 nullPtr 0 nullPtr nullPtr nullPtr

foreign import capi "hastate.h ha_state_rpc_machine" ha_state_rpc_machine :: IO (Ptr RPCMachineV)

-- | Yields the 'RPCMachine' created with 'initHAState'.
getRPCMachine :: IO (Maybe RPCMachine)
getRPCMachine = do p <- ha_state_rpc_machine
                   return $ if nullPtr == p then Nothing
                              else Just $ RPCMachine p
