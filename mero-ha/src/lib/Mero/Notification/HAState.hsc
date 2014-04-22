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
  ) where

import HA.Resources.Mero

import Network.Transport.RPC.RPCLite
    ( ServerEndpoint(..), ServerEndpointV, RPCAddress(..) )

import Control.Exception      ( Exception, throwIO )
import Control.Monad          ( liftM2, liftM3 )
import Data.Binary            ( Binary )
import Data.ByteString as B   ( useAsCString )
import Data.Dynamic           ( Typeable )
import Data.IORef             ( atomicModifyIORef, modifyIORef, IORef
                              , newIORef
                              )
import Data.List              ( find )
import Data.Word              ( Word32, Word8 )
import Foreign.C.Types        ( CInt(..) )
import Foreign.C.String       ( CString )
import Foreign.Marshal.Alloc  ( allocaBytesAligned )
import Foreign.Marshal.Array  ( peekArray, pokeArray, withArray )
import Foreign.Ptr            ( Ptr, FunPtr, freeHaskellFunPtr )
import Foreign.Storable       ( Storable(..) )
import GHC.Generics           ( Generic )
import System.IO.Unsafe       ( unsafePerformIO )

#include "rpclite.h"
#include "hastate.h"
#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

-- | Notes telling the state of a given configuration object
data Note = Note
    { no_id :: UUID
    , no_otype :: ConfType
    , no_ostate :: ConfObjectState
    } deriving (Eq, Typeable, Generic)

instance Binary Note

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
-- The calling process should be listening for incoming RPC connections
-- (to be setup with rpclite or some other interface to RPC).
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
            -> IO ()
initHAState ha_state_get ha_state_set =
    allocaBytesAligned #{size ha_state_callbacks_t}
                       #{alignment ha_state_callbacks_t}$ \pcbs -> do
      wget <- wrapGetCB ha_state_get
      wset <- wrapSetCB ha_state_set
      #{poke ha_state_callbacks_t, ha_state_get} pcbs wget
      #{poke ha_state_callbacks_t, ha_state_set} pcbs wset
      modifyIORef cbRefs ((SomeFunPtr wget:) . (SomeFunPtr wset:))
      ha_state_init pcbs >>= check_rc "initHAState"
  where
    wrapGetCB f = cwrapGetCB $ \note -> f note
    wrapSetCB f = cwrapSetCB $ \note ->
        readNVecRef note >>= fmap fromIntegral . f

data HAStateCallbacksV

foreign import ccall unsafe ha_state_init :: Ptr HAStateCallbacksV
                                          -> IO CInt

foreign import ccall "wrapper" cwrapGetCB :: (NVecRef -> IO ())
                                          -> IO (FunPtr (NVecRef -> IO ()))

foreign import ccall "wrapper" cwrapSetCB :: (NVecRef -> IO CInt)
                                          -> IO (FunPtr (NVecRef -> IO CInt))

instance Storable UUID where

  sizeOf _ = #{size struct m0_uint128}

  alignment _ = #{alignment struct m0_uint128}

  peek p = liftM2 UUID
    (#{peek struct m0_uint128, u_hi} p)
    (#{peek struct m0_uint128, u_lo} p)

  poke p (UUID hi lo) = do
    #{poke struct m0_uint128, u_hi} p hi
    #{poke struct m0_uint128, u_lo} p lo

instance Storable Note where

  sizeOf _ = #{size struct m0_ha_note}

  alignment _ = #{alignment struct m0_ha_note}

  peek p = liftM3 Note
      (#{peek struct m0_ha_note, no_id} p)
      (fmap (toEnum . fromIntegral)
          (#{peek struct m0_ha_note, no_otype} p :: IO Word8)
      )
      (fmap (toEnum . fromIntegral)
          (#{peek struct m0_ha_note, no_state} p :: IO Word8)
      )

  poke p (Note o t s) = do
      #{poke struct m0_ha_note, no_id} p o
      #{poke struct m0_ha_note, no_otype} p
          (fromIntegral $ fromEnum t :: Word8)
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
    eq_id (Note o0 t0 _) (Note o1 t1 _) = o0 == o1 && t0 == t1

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

foreign import ccall unsafe ha_state_notify :: Ptr ServerEndpointV
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
