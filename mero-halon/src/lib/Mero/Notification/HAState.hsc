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
  , NVecRef
  , initHAState
  , finiHAState
  , doneGet
  , notify
  , readNVecRef
  , updateNVecRef
  , EntryPointRepV
  , FomV
  , entrypointReplyWakeup
  , entrypointNoReplyWakeup
  ) where

import HA.Resources.Mero.Note

import Mero.ConfC (Fid)
import Network.RPC.RPCLite
    ( ServerEndpoint(..), ClientEndpointV, RPCAddress(..) )

import Control.Exception      ( Exception, throwIO )
import Control.Monad          ( liftM2 )
import Data.Binary            ( Binary )
import Data.ByteString as B   ( useAsCString )
import Data.Dynamic           ( Typeable )
import Data.Hashable          ( Hashable )
import Data.IORef             ( atomicModifyIORef, modifyIORef, IORef
                              , newIORef
                              )
import Data.List              ( find )
import Data.Word              ( Word32, Word8 )
import Foreign.C.Types        ( CInt(..) )
import Foreign.C.String       ( CString, withCString )
import Foreign.Marshal.Alloc  ( allocaBytesAligned )
import Foreign.Marshal.Array  ( peekArray, pokeArray, withArray, withArrayLen, withArrayLen0 )
import Foreign.Marshal.Utils  ( with, withMany )
import Foreign.Ptr            ( Ptr, FunPtr, freeHaskellFunPtr, nullPtr )
import Foreign.Storable       ( Storable(..) )
import GHC.Generics           ( Generic )
import System.IO.Unsafe       ( unsafePerformIO )
import System.IO              ( hPutStrLn, stderr )

#include "hastate.h"
#include "conf/obj.h"

#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

-- | Notes telling the state of a given configuration object
data Note = Note
    { no_id :: Fid
    , no_ostate :: ConfObjectState
    } deriving (Eq, Typeable, Generic, Show)

instance Binary Note
instance Hashable Note

-- | Lists of notes
type NVec = [Note]

-- | References to NVecs
newtype NVecRef = NVecRef (Ptr NVecRef)

-- | A type for hidding the type argument of 'FunPtr's
data SomeFunPtr = forall a. SomeFunPtr (FunPtr a)

-- | A reference to the list of 'FunPtr's used by the implementation
cbRefs :: IORef [SomeFunPtr]
cbRefs = unsafePerformIO $ newIORef []

-- | @initHAState ha_state_get ha_state_set@ starts the hastate interface.
--
-- Registers callbacks to handle arriving requests.
--
-- The calling process should listen for incoming RPC connections
-- (to be setup with rpclite or some other interface to RPC).
--
-- Must be called before calling m0_init.
--
initHAState :: (NVecRef -> IO ())
               -- ^ Called when a request to get the state of some objects is
               -- received. This is expected to happen when mero calls
               -- @m0_ha_state_get(...)@.
               --
               -- When the requested state is available, doneGet must
               -- be called by passing the same note parameter and 0. If there
               -- is an error and the state could not be retrieved then NULL and
               -- an error code should be provided.
               --
               -- If the vector contains at least one invalid indentifier, the
               -- error code should be -EINVAL (or -EKEYREJECTED, or -ENOKEY ?).
            -> (NVec -> IO Int)
               -- ^ Called when a request to update the state of some objects is
               -- received. This is expected to happen when mero calls
               -- @m0_ha_state_set(...)@.
               --
               -- Returns 0 if the request was accepted or an error code
               -- otherwise.
            -> (Ptr FomV -> Ptr EntryPointRepV -> IO ())
               -- ^ Called when a request to read current confd and rm endpoints
               -- is received.
            -> IO ()
initHAState ha_state_get ha_state_set ha_state_entry =
    allocaBytesAligned #{size ha_state_callbacks_t}
                       #{alignment ha_state_callbacks_t}$ \pcbs -> do
      wget <- wrapGetCB ha_state_get
      wset <- wrapSetCB ha_state_set
      wentry <- wrapEntryCB ha_state_entry
      #{poke ha_state_callbacks_t, ha_state_get} pcbs wget
      #{poke ha_state_callbacks_t, ha_state_set} pcbs wset
      #{poke ha_state_callbacks_t, ha_state_entrypoint} pcbs wentry
      modifyIORef cbRefs ((SomeFunPtr wget:) . (SomeFunPtr wset:) . (SomeFunPtr wentry:))

      rc <- ha_state_init pcbs
      check_rc "initHAState" rc
  where
    wrapGetCB f = cwrapGetCB $ \note -> f note
    wrapSetCB f = cwrapSetCB $ \note ->
        readNVecRef note >>= fmap fromIntegral . f
    wrapEntryCB f = cwrapEntryCB f

data HAStateCallbacksV

foreign import ccall unsafe ha_state_init :: Ptr HAStateCallbacksV
                                          -> IO CInt

foreign import ccall "wrapper" cwrapGetCB :: (NVecRef -> IO ())
                                          -> IO (FunPtr (NVecRef -> IO ()))

foreign import ccall "wrapper" cwrapSetCB :: (NVecRef -> IO CInt)
                                          -> IO (FunPtr (NVecRef -> IO CInt))

foreign import ccall "wrapper" cwrapEntryCB ::
    (Ptr FomV -> Ptr EntryPointRepV -> IO ())
      -> IO (FunPtr (Ptr FomV -> Ptr EntryPointRepV -> IO ()))

instance Storable Note where

  sizeOf _ = #{size struct m0_ha_note}

  alignment _ = #{alignment struct m0_ha_note}

  peek p = liftM2 Note
      (#{peek struct m0_ha_note, no_id} p)
      (fmap (toEnum . fromIntegral)
          (#{peek struct m0_ha_note, no_state} p :: IO Word8)
      )

  poke p (Note o s) = do
      #{poke struct m0_ha_note, no_id} p o
      #{poke struct m0_ha_note, no_state} p
          (fromIntegral $ fromEnum s :: Word8)

-- | Reads the list of notes from a reference.
readNVecRef :: NVecRef -> IO NVec
readNVecRef (NVecRef pnvec) = do
  nr <- #{peek struct m0_ha_nvec, nv_nr} pnvec
  notes <- #{peek struct m0_ha_nvec, nv_note} pnvec
  peekArray nr notes

-- | @updateNVecRef ref news@ updates the states of the
-- notes in @ref@ with the states contained in @news@.
--
-- Notes in @newstates@ whose objects are not mentioned in @ref@
-- are ignored.
--
updateNVecRef :: NVecRef -> NVec -> IO ()
updateNVecRef nref@(NVecRef pnvec) newstates = do
    notes <- readNVecRef nref
    pnotes <- #{peek struct m0_ha_nvec, nv_note} pnvec
    pokeArray pnotes $ update newstates notes
  where
    update news = map (\n -> maybe n id $ find (eq_id n) news)
    eq_id (Note o0 _) (Note o1 _) = o0 == o1

-- Finalizes the hastate interface.
finiHAState :: IO ()
finiHAState = do
    atomicModifyIORef cbRefs (\cbs -> ([],cbs)) >>= mapM_ freeCB
    ha_state_fini
  where
    freeCB (SomeFunPtr ptr) = freeHaskellFunPtr ptr

foreign import ccall unsafe ha_state_fini :: IO ()

-- | Indicates that a request initiated with @ha_state_get@ is complete.
--
-- It takes the state vector carrying the reply and the return code of the
-- request.
doneGet :: NVecRef -> Int -> IO ()
doneGet p = ha_state_get_done p . fromIntegral

foreign import ccall unsafe ha_state_get_done :: NVecRef -> CInt -> IO ()

-- | Notifies mero at the remote address that the state of some objects has
-- changed.
notify :: ServerEndpoint -> RPCAddress -> NVec -> Int -> IO ()
notify se (RPCAddress rpcAddr) nvec timeout_s =
  useAsCString rpcAddr $ \caddr -> withArray nvec $ \pnote ->
    allocaBytesAligned #{size struct m0_ha_nvec}
                       #{alignment struct m0_ha_nvec}$ \pnvec -> do
      #{poke struct m0_ha_nvec, nv_nr} pnvec
          (fromIntegral $ length nvec :: Word32)
      #{poke struct m0_ha_nvec, nv_note} pnvec pnote
      ha_state_notify (se_ptr se) caddr (NVecRef pnvec) (fromIntegral timeout_s)
        >>= check_rc "notify"

foreign import ccall unsafe ha_state_notify :: Ptr ClientEndpointV
                                            -> CString
                                            -> NVecRef
                                            -> CInt
                                            -> IO CInt

-- | Type of exceptions that HAState calls can produce.
data HAStateException = HAStateException String Int
  deriving (Show,Typeable)

instance Exception HAStateException

check_rc :: String -> CInt -> IO ()
check_rc _ 0 = return ()
check_rc msg i = throwIO $ HAStateException msg $ fromIntegral i

data EntryPointRepV
data FomV

foreign import ccall unsafe ha_entrypoint_reply_wakeup
  :: Ptr FomV -> Ptr EntryPointRepV -> CInt
  -> CInt -> Ptr Fid
  -> CInt -> Ptr CString
  -> Ptr Fid -> CString
  -> IO ()

-- | Fill 'EntryPointRepV' structure.
entrypointReplyWakeup :: Ptr FomV -> Ptr EntryPointRepV -> [Fid] -> [String] -> Fid -> String -> IO ()
entrypointReplyWakeup fom eprv confdFids epNames rmFid rmEp =
  withMany (withCString) epNames $ \cnames ->
    withArrayLen0 nullPtr cnames $ \ceps_len ceps_ptr ->
      withArrayLen confdFids $ \cfids_len cfids_ptr ->
        withCString rmEp $ \crm_ep ->
          with rmFid $ \crmfid ->
            ha_entrypoint_reply_wakeup fom eprv 0 (fromIntegral cfids_len) cfids_ptr
                                       (fromIntegral ceps_len) ceps_ptr crmfid crm_ep


entrypointNoReplyWakeup :: Ptr FomV -> Ptr EntryPointRepV -> IO ()
entrypointNoReplyWakeup fom eprv =
  ha_entrypoint_reply_wakeup fom eprv (-1) 0 nullPtr 0 nullPtr nullPtr nullPtr
