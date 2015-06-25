{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}


-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the spiel interface.
--

module Mero.Spiel.Internal
  ( module Mero.Spiel.Internal
  , RunningService
  ) where

import Mero.ConfC
  ( Fid )
import Mero.Spiel.Context

import Network.RPC.RPCLite
  ( RPCMachine(..) )

import Data.Monoid ((<>))

import Foreign.C.String
  ( CString )
import Foreign.C.Types
import Foreign.Marshal.Error
  ( throwIf_ )
import Foreign.Ptr
  ( Ptr )
import Foreign.Storable

import qualified Language.C.Inline as C

import System.IO.Unsafe (unsafePerformIO)

#include "spiel/spiel.h"
#include "rpc/rpc_machine.h"

#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

-- | m0_reqh
data ReqHV

-- | Extract the request handler from RPC machine
rm_reqh :: RPCMachine -> Ptr ReqHV
rm_reqh (RPCMachine rpcmach) = unsafePerformIO $
  #{peek struct m0_rpc_machine, rm_reqh} rpcmach

-- | m0_spiel
data SpielContextV

-- | Size of m0_spiel struct for allocation
m0_spiel_size :: Int
m0_spiel_size = #{size struct m0_spiel}

foreign import ccall "spiel.h m0_spiel_start"
  c_spiel_start :: Ptr SpielContextV
                -> Ptr ReqHV
                -> Ptr CString
                -> CString
                -> IO CInt

foreign import ccall "spiel.h m0_spiel_stop"
  c_spiel_stop :: Ptr SpielContextV
               -> IO ()

---------------------------------------------------------------
-- Transactions                                              --
---------------------------------------------------------------

-- | m0_spiel_tx
data SpielTransaction

foreign import ccall "spiel.h m0_spiel_tx_open"
  c_spiel_tx_open :: Ptr SpielContextV
                  -> Ptr SpielTransaction
                  -> IO (Ptr SpielTransaction)

foreign import ccall "spiel.h m0_spiel_tx_close"
  c_spiel_tx_close :: Ptr SpielTransaction
                   -> IO ()

foreign import ccall "spiel.h m0_spiel_tx_commit"
  c_spiel_tx_commit :: Ptr SpielTransaction
                    -> IO ()

---------------------------------------------------------------
-- Configuration management                                  --
---------------------------------------------------------------

-- TODO Configuration management

---------------------------------------------------------------
-- Command interface                                         --
---------------------------------------------------------------

-- | m0_service_health
newtype ServiceHealth = ServiceHealth CInt
#{enum ServiceHealth, ServiceHealth,
    _sh_good = M0_HEALTH_GOOD
  , _sh_bad = M0_HEALTH_BAD
  , _sh_inactive = M0_HEALTH_INACTIVE
  , _sh_unknown = M0_HEALTH_UNKNOWN
 }

foreign import ccall "spiel.h m0_spiel_service_init"
  c_spiel_service_init :: Ptr SpielContextV
                       -> Ptr Fid
                       -> IO CInt

foreign import ccall "spiel.h m0_spiel_service_start"
  c_spiel_service_start :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import ccall "spiel.h m0_spiel_service_stop"
  c_spiel_service_stop :: Ptr SpielContextV
                       -> Ptr Fid
                       -> IO CInt

foreign import ccall "spiel.h m0_spiel_service_health"
  c_spiel_service_health :: Ptr SpielContextV
                         -> Ptr Fid
                         -> IO CInt

foreign import ccall "spiel.h m0_spiel_service_quiesce"
  c_spiel_service_quiesce :: Ptr SpielContextV
                          -> Ptr Fid
                          -> IO CInt

foreign import ccall "spiel.h m0_spiel_device_attach"
  c_spiel_device_attach :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import ccall "spiel.h m0_spiel_device_detach"
  c_spiel_device_detach :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import ccall "spiel.h m0_spiel_device_format"
  c_spiel_device_format :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import ccall "spiel.h m0_spiel_process_stop"
  c_spiel_process_stop :: Ptr SpielContextV
                       -> Ptr Fid
                       -> IO CInt

foreign import ccall "spiel.h m0_spiel_process_reconfig"
  c_spiel_process_reconfig :: Ptr SpielContextV
                           -> Ptr Fid
                           -> IO CInt

foreign import ccall "spiel.h m0_spiel_process_health"
  c_spiel_process_health :: Ptr SpielContextV
                         -> Ptr Fid
                         -> IO CInt

foreign import ccall "spiel.h m0_spiel_process_quiesce"
  c_spiel_process_quiesce :: Ptr SpielContextV
                          -> Ptr Fid
                          -> IO CInt

foreign import ccall "spiel.h m0_spiel_process_list_services"
  c_spiel_process_list_services :: Ptr SpielContextV
                                -> Ptr Fid
                                -> Ptr (Ptr RunningService)
                                -> IO CInt

foreign import ccall "spiel.h m0_spiel_pool_repair_start"
  c_spiel_pool_repair_start :: Ptr SpielContextV
                            -> Ptr Fid
                            -> IO CInt

foreign import ccall "spiel.h m0_spiel_pool_repair_quiesce"
  c_spiel_pool_repair_quiesce :: Ptr SpielContextV
                              -> Ptr Fid
                              -> IO CInt

foreign import ccall "spiel.h m0_spiel_pool_rebalance_start"
  c_spiel_pool_rebalance_start :: Ptr SpielContextV
                               -> Ptr Fid
                               -> IO CInt

foreign import ccall "spiel.h m0_spiel_pool_rebalance_quiesce"
  c_spiel_pool_rebalance_quiesce :: Ptr SpielContextV
                                 -> Ptr Fid
                                 -> IO CInt

---------------------------------------------------------------
-- Utility                                                   --
---------------------------------------------------------------

C.context $ C.baseCtx <> spielCtx

C.include "lib/memory.h"
C.include "spiel/spiel.h"

freeRunningServices :: Ptr RunningService -- ^ Pointer to head of array
                    -> IO CInt
freeRunningServices arr = [C.block| int {
    struct m0_spiel_running_svc *arr = $(struct m0_spiel_running_svc *arr);
    m0_free(arr);
  }
|]

throwIfNonZero_ :: (Eq a, Num a) => (a -> String) -> IO a -> IO ()
throwIfNonZero_ = throwIf_ (/= 0)
