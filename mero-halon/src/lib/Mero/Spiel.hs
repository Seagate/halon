-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the spiel interface.
--

module Mero.Spiel where

import Mero.ConfC
import Mero.Spiel.Internal

import Network.RPC.RPCLite
  ( RPCMachine )

import Control.Exception
  ( bracket
  , mask
  )
import Control.Monad ( void )

import Foreign.C.String
  ( newCString
  , withCAString
  )
import Foreign.ForeignPtr
  ( ForeignPtr
  , mallocForeignPtrBytes
  , withForeignPtr
  )
import Foreign.Marshal.Alloc
  ( alloca
  , free
  )
import Foreign.Marshal.Array
  ( peekArray
  , withArray
  )
import Foreign.Marshal.Error
  ( throwIfNeg
  , throwIfNull
  )
import Foreign.Marshal.Utils
  ( with )
import Foreign.Storable
  ( peek
  , poke
  )

newtype SpielContext = SpielContext (ForeignPtr SpielContextV)

-- | Open a Spiel context
start :: RPCMachine -- ^ Request handler
      -> [String] -- ^ Confd endpoints
      -> String -- ^ Network endpoint of Resource Manager service.
      -> IO SpielContext
start rpcmach eps rm_ep = withCAString rm_ep $ \c_rm_ep -> do
  let reqh = rm_reqh rpcmach
  bracket
    (mapM newCString eps)
    (mapM_ free)
    (\eps_arr -> withArray eps_arr $ \c_eps -> do
      sc <- mallocForeignPtrBytes m0_spiel_size
      throwIfNonZero_ (\rc -> "Cannot initialize Spiel context: " ++ show rc)
                      $ withForeignPtr sc
                        $ \ptr -> c_spiel_start ptr reqh c_eps c_rm_ep
      return $ SpielContext sc
    )

-- | Close a Spiel context
stop :: SpielContext
     -> IO ()
stop (SpielContext ptr) = withForeignPtr ptr c_spiel_stop

withSpiel :: RPCMachine -- ^ Request handler
          -> [String] -- ^ Confd endpoints
          -> String -- ^ Network endpoint of Resource Manager service.
          -> (SpielContext -> IO a) -- ^ Action to undertake with Spiel
          -> IO a
withSpiel rpcmach eps rm_ep = bracket
  (start rpcmach eps rm_ep)
  stop

---------------------------------------------------------------
-- Configuration management                                  --
---------------------------------------------------------------

newtype SpielTransaction = SpielTransaction (ForeignPtr SpielTransactionV)

openTransaction :: SpielContext
                -> IO (SpielTransaction)
openTransaction (SpielContext fsc) = withForeignPtr fsc $ \sc -> do
  st <- mallocForeignPtrBytes m0_spiel_tx_size
  void $ throwIfNull "Cannot open Spiel transaction."
                      $ withForeignPtr st
                        $ \ptr -> c_spiel_tx_open sc ptr
  return $ SpielTransaction st

closeTransaction :: SpielTransaction
                 -> IO ()
closeTransaction (SpielTransaction ptr) = withForeignPtr ptr c_spiel_tx_close

commitTransaction :: SpielTransaction
                  -> IO ()
commitTransaction (SpielTransaction ptr) =
  throwIfNonZero_ (\rc -> "Cannot close Spiel transaction: " ++ show rc)
                  $ withForeignPtr ptr c_spiel_tx_commit

withTransaction :: SpielContext
                -> (SpielTransaction -> IO a)
                -> IO a
withTransaction sc = bracket
  (openTransaction sc)
  (\t -> commitTransaction t >> closeTransaction t)

---------------------------------------------------------------
-- Command interface                                         --
---------------------------------------------------------------

serviceInit :: SpielContext
            -> Service
            -> IO ()
serviceInit (SpielContext fsc) cs = withForeignPtr fsc $ \sc ->
  with (cs_fid cs) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot initialise service: " ++ show rc)
      $ c_spiel_service_init sc fid_ptr

serviceStart :: SpielContext
             -> Service
             -> IO ()
serviceStart (SpielContext fsc) cs = withForeignPtr fsc $ \sc ->
  with (cs_fid cs) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot start service: " ++ show rc)
      $ c_spiel_service_start sc fid_ptr

serviceStop :: SpielContext
            -> Service
            -> IO ()
serviceStop (SpielContext fsc) cs = withForeignPtr fsc $ \sc ->
  with (cs_fid cs) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot stop service: " ++ show rc)
      $ c_spiel_service_stop sc fid_ptr

serviceHealth :: SpielContext
              -> Service
              -> IO ServiceHealth
serviceHealth (SpielContext fsc) cs = withForeignPtr fsc $ \sc ->
  with (cs_fid cs) $ \fid_ptr ->
    fmap ServiceHealth
      $ throwIfNeg (\rc -> "Cannot query service health: " ++ show rc)
        $ fmap (fromIntegral) $ c_spiel_service_health sc fid_ptr

serviceQuiesce :: SpielContext
               -> Service
               -> IO ()
serviceQuiesce (SpielContext fsc) cs = withForeignPtr fsc $ \sc ->
  with (cs_fid cs) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce service: " ++ show rc)
      $ c_spiel_service_quiesce sc fid_ptr

deviceAttach :: SpielContext
             -> Disk
             -> IO ()
deviceAttach (SpielContext fsc) ck = withForeignPtr fsc $ \sc ->
  with (ck_fid ck) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot attach device: " ++ show rc)
      $ c_spiel_device_attach sc fid_ptr

deviceDetach :: SpielContext
             -> Disk
             -> IO ()
deviceDetach (SpielContext fsc) ck = withForeignPtr fsc $ \sc ->
  with (ck_fid ck) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot detach device: " ++ show rc)
      $ c_spiel_device_detach sc fid_ptr

deviceFormat :: SpielContext
             -> Disk
             -> IO ()
deviceFormat (SpielContext fsc) ck = withForeignPtr fsc $ \sc ->
  with (ck_fid ck) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot format device: " ++ show rc)
      $ c_spiel_device_format sc fid_ptr

processStop :: SpielContext
            -> Process
            -> IO ()
processStop (SpielContext fsc) pc = withForeignPtr fsc $ \sc ->
  with (pc_fid pc) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot stop process: " ++ show rc)
      $ c_spiel_process_stop sc fid_ptr

processReconfig :: SpielContext
                -> Process
                -> IO ()
processReconfig (SpielContext fsc) pc = withForeignPtr fsc $ \sc ->
  with (pc_fid pc) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot reconfigure process: " ++ show rc)
      $ c_spiel_process_reconfig sc fid_ptr

processHealth :: SpielContext
              -> Process
              -> IO ServiceHealth
processHealth (SpielContext fsc) pc = withForeignPtr fsc $ \sc ->
  with (pc_fid pc) $ \fid_ptr ->
    fmap ServiceHealth
      $ throwIfNeg (\rc -> "Cannot query process health: " ++ show rc)
        $ fmap (fromIntegral) $ c_spiel_process_health sc fid_ptr

processQuiesce :: SpielContext
               -> Process
               -> IO ()
processQuiesce (SpielContext fsc) pc = withForeignPtr fsc $ \sc ->
  with (pc_fid pc) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce process: " ++ show rc)
      $ c_spiel_process_quiesce sc fid_ptr

processListServices :: SpielContext
                    -> Process
                    -> IO [RunningService]
processListServices (SpielContext fsc) pc = mask $ \restore ->
  withForeignPtr fsc $ \sc ->
    alloca $ \fid_ptr ->
      alloca $ \arr_ptr -> do
        poke fid_ptr (pc_fid pc)
        rc <- fmap fromIntegral . restore
              $ c_spiel_process_list_services sc fid_ptr arr_ptr
        if (rc < 0)
        then error $ "Cannot list process services: " ++ show rc
        else do
          elt <- peek arr_ptr
          services <- peekArray rc elt
          _ <- freeRunningServices elt
          return services

poolRepairStart :: SpielContext
                -> Pool
                -> IO ()
poolRepairStart (SpielContext fsc) pl = withForeignPtr fsc $ \sc ->
  with (pl_fid pl) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot start pool repair: " ++ show rc)
      $ c_spiel_pool_repair_start sc fid_ptr

poolRepairQuiesce :: SpielContext
                  -> Pool
                  -> IO ()
poolRepairQuiesce (SpielContext fsc) pl = withForeignPtr fsc $ \sc ->
  with (pl_fid pl) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce pool repair: " ++ show rc)
      $ c_spiel_pool_repair_quiesce sc fid_ptr

poolRebalanceStart :: SpielContext
                   -> Pool
                   -> IO ()
poolRebalanceStart (SpielContext fsc) pl = withForeignPtr fsc $ \sc ->
  with (pl_fid pl) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot start pool rebalance: " ++ show rc)
      $ c_spiel_pool_rebalance_start sc fid_ptr

poolRebalanceQuiesce :: SpielContext
                     -> Pool
                     -> IO ()
poolRebalanceQuiesce (SpielContext fsc) pl = withForeignPtr fsc $ \sc ->
  with (pl_fid pl) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce pool rebalance: " ++ show rc)
      $ c_spiel_pool_rebalance_quiesce sc fid_ptr
