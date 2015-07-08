-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the spiel interface.
--

module Mero.Spiel where

import Mero.ConfC ( Fid )
import Mero.Spiel.Internal

import Network.RPC.RPCLite
  ( RPCMachine )

import Control.Exception
  ( bracket
  , mask
  )

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
  ( throwIfNeg )
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
      -> String -- ^ Configuration profile
      -> IO SpielContext
start rpcmach eps profile = withCAString profile $ \c_profile -> do
  let reqh = rm_reqh rpcmach
  bracket
    (mapM newCString eps)
    (mapM_ free)
    (\eps_arr -> withArray eps_arr $ \c_eps -> do
      sc <- mallocForeignPtrBytes m0_spiel_size
      throwIfNonZero_ (\rc -> "Cannot initialize Spiel context: " ++ show rc)
                      $ withForeignPtr sc
                        $ \ptr -> c_spiel_start ptr reqh c_eps c_profile
      return $ SpielContext sc
    )

-- | Close a Spiel context
stop :: SpielContext
     -> IO ()
stop (SpielContext ptr) = withForeignPtr ptr c_spiel_stop

---------------------------------------------------------------
-- Command interface                                         --
---------------------------------------------------------------

serviceInit :: SpielContext
            -> Fid
            -> IO ()
serviceInit (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot initialise service: " ++ show rc)
      $ c_spiel_service_init sc fid_ptr

serviceStart :: SpielContext
             -> Fid
             -> IO ()
serviceStart (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot start service: " ++ show rc)
      $ c_spiel_service_start sc fid_ptr

serviceStop :: SpielContext
            -> Fid
            -> IO ()
serviceStop (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot stop service: " ++ show rc)
      $ c_spiel_service_stop sc fid_ptr

serviceHealth :: SpielContext
              -> Fid
              -> IO ServiceHealth
serviceHealth (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    fmap ServiceHealth
      $ throwIfNeg (\rc -> "Cannot query service health: " ++ show rc)
        $ fmap (fromIntegral) $ c_spiel_service_health sc fid_ptr

serviceQuiesce :: SpielContext
               -> Fid
               -> IO ()
serviceQuiesce (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce service: " ++ show rc)
      $ c_spiel_service_quiesce sc fid_ptr

deviceAttach :: SpielContext
             -> Fid
             -> IO ()
deviceAttach (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot attach device: " ++ show rc)
      $ c_spiel_device_attach sc fid_ptr

deviceDetach :: SpielContext
             -> Fid
             -> IO ()
deviceDetach (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot detach device: " ++ show rc)
      $ c_spiel_device_detach sc fid_ptr

deviceFormat :: SpielContext
            -> Fid
            -> IO ()
deviceFormat (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot format device: " ++ show rc)
      $ c_spiel_device_format sc fid_ptr

processStop :: SpielContext
            -> Fid
            -> IO ()
processStop (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot stop process: " ++ show rc)
      $ c_spiel_process_stop sc fid_ptr

processReconfig :: SpielContext
                -> Fid
                -> IO ()
processReconfig (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot reconfigure process: " ++ show rc)
      $ c_spiel_process_reconfig sc fid_ptr

processHealth :: SpielContext
              -> Fid
              -> IO ServiceHealth
processHealth (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    fmap ServiceHealth
      $ throwIfNeg (\rc -> "Cannot query process health: " ++ show rc)
        $ fmap (fromIntegral) $ c_spiel_process_health sc fid_ptr

processQuiesce :: SpielContext
               -> Fid
               -> IO ()
processQuiesce (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce process: " ++ show rc)
      $ c_spiel_process_quiesce sc fid_ptr

processListServices :: SpielContext
                    -> Fid
                    -> IO [RunningService]
processListServices (SpielContext fsc) fid = mask $ \restore ->
  withForeignPtr fsc $ \sc ->
    alloca $ \fid_ptr ->
      alloca $ \arr_ptr -> do
        poke fid_ptr fid
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
                -> Fid
                -> IO ()
poolRepairStart (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot start pool repair: " ++ show rc)
      $ c_spiel_pool_repair_start sc fid_ptr

poolRepairQuiesce :: SpielContext
                  -> Fid
                  -> IO ()
poolRepairQuiesce (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce pool repair: " ++ show rc)
      $ c_spiel_pool_repair_quiesce sc fid_ptr

poolRebalanceStart :: SpielContext
                   -> Fid
                   -> IO ()
poolRebalanceStart (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot start pool rebalance: " ++ show rc)
      $ c_spiel_pool_rebalance_start sc fid_ptr

poolRebalanceQuiesce :: SpielContext
                     -> Fid
                     -> IO ()
poolRebalanceQuiesce (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce pool rebalance: " ++ show rc)
      $ c_spiel_pool_rebalance_quiesce sc fid_ptr
