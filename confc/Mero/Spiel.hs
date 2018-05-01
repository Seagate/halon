{-# LANGUAGE LambdaCase #-}
-- |
-- Copyright : (C) 2018 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the spiel interface.
--

module Mero.Spiel
  ( module Mero.Spiel.Context
  , SpielTransaction
  , addRoot
  , addProfile
  , addFilesystem
  , addNode
  , addProcess
  , addService
  , addDevice
  , addRack
  , addEnclosure
  , addController
  , addDisk
  , addPool
  , addPVerActual
  , addPVerFormulaic
  , addRackV
  , addEnclosureV
  , addControllerV
  , addDiskV
  , poolVersionDone
  , closeTransaction
  , commitTransactionForced
  , deviceAttach
  , deviceDetach
  , filesystemStatsFetch
  , openLocalTransaction
  , openTransaction
  , poolRepairStart
  , poolRepairContinue
  , poolRepairQuiesce
  , poolRepairStatus
  , poolRepairAbort
  , poolRebalanceStart
  , poolRebalanceContinue
  , poolRebalanceQuiesce
  , poolRebalanceStatus
  , poolRebalanceAbort
  , rconfStart
  , rconfStop
  , setCmdProfile
  , txToBS
  , txValidateTransactionCache
  ) where

import Mero.ConfC (Bitmap, Fid, PDClustAttr, withBitmap)
import Mero.Spiel.Context
import Mero.Spiel.Internal

import Control.Exception (bracket, mask)

import Data.ByteString (ByteString, packCString)
import Data.Word (Word32, Word64)

import Foreign.C.Error (Errno(..), eOK, eBUSY, eNOENT)
import Foreign.C.String (newCString, withCString, peekCString)
import Foreign.C.Types (CUInt(..), CSize)
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Marshal.Alloc (alloca, free)
import Foreign.Marshal.Array (peekArray, withArray0, withArrayLen)
import Foreign.Marshal.Error (throwIf_)
import Foreign.Marshal.Utils (fillBytes, maybeWith, with, withMany)
import Foreign.Ptr (nullPtr)
import Foreign.Storable (peek, poke)

-- | Start rconfc server associated with spiel context.
rconfStart :: IO ()
rconfStart =
  throwIfNonZero_ (\rc -> "Cannot start spiel command interface: " ++ show rc)
    $ c_spiel >>= \sc -> c_spiel_rconfc_start sc nullPtr

-- | Stop rconfc server associated with spiel context.
rconfStop :: IO ()
rconfStop = c_spiel >>= c_spiel_rconfc_stop

---------------------------------------------------------------
-- Configuration management                                  --
---------------------------------------------------------------

newtype SpielTransaction = SpielTransaction (ForeignPtr SpielTransactionV)

openTransaction :: IO SpielTransaction
openTransaction = do
  sc <- c_spiel
  st <- mallocForeignPtrBytes m0_spiel_tx_size
  withForeignPtr st $ \ptr -> c_spiel_tx_open sc ptr
  return $ SpielTransaction st

closeTransaction :: SpielTransaction
                 -> IO ()
closeTransaction (SpielTransaction ptr) = withForeignPtr ptr c_spiel_tx_close

commitTransactionForced :: SpielTransaction
                        -> Bool
                        -> Word64 -- ^ Version number
                        -> IO (Either String ())
commitTransactionForced tx@(SpielTransaction ptr) forced ver =
  txValidateTransactionCache tx >>= \case
    Nothing -> do
      throwIfNonZero_ (\rc -> "Cannot commmit Spiel transaction: " ++ show rc)
        $ withForeignPtr ptr $ \c_ptr -> alloca $ \q_ptr -> do
          c_spiel_tx_commit_forced c_ptr forced ver q_ptr
      return $ Right ()
    Just err -> return $ Left err

txToBS :: SpielTransaction
       -> Word64
       -> IO ByteString
txToBS (SpielTransaction ptr) verno = withForeignPtr ptr $ \c_ptr -> do
  valid <- Errno . negate <$> c_spiel_tx_validate c_ptr
  case valid of
    x | x == eOK -> alloca $ \c_str_ptr -> do
          throwIfNonZero_ (\rc -> "Cannot dump Spiel transaction: " ++ show rc)
            $ c_spiel_tx_to_str c_ptr verno c_str_ptr
          cs <- peek c_str_ptr
          bs <- packCString cs
          c_spiel_tx_str_free cs
          return bs
    x | x == eBUSY -> error "Not all objects are ready."
    x | x == eNOENT -> error "Not all objects have a parent."
    Errno x -> error $ "Unknown error return: " ++ show x

-- | Open transaction that doesn't require communication with conf or rms service.
-- Such transaction can be run in non privileged mode without prior creation of
-- the spiel context. However it's illegal to commit such transactions and that
-- could lead to undefined behaviour, use should only verify or dump such transactions.
openLocalTransaction :: IO SpielTransaction
openLocalTransaction = do
  sc <- mallocForeignPtrBytes m0_spiel_size
  st <- mallocForeignPtrBytes m0_spiel_tx_size
  withForeignPtr sc
    $ \sc_ptr -> withForeignPtr st
    $ \ptr -> do
       fillBytes sc_ptr 0 m0_spiel_size
       c_spiel_tx_open sc_ptr ptr
  return $ SpielTransaction st

txValidateTransactionCache :: SpielTransaction
                           -> IO (Maybe String)
txValidateTransactionCache (SpielTransaction ftx) = withForeignPtr ftx $ \tx -> do
  let buflen = 128 :: CSize
  res <- c_confc_validate_cache_of_tx tx buflen
  if res == nullPtr
    then return Nothing
    else do
      str <- peekCString res
      free res
      return $ Just str

-- XXX-MULTIPOOLS: DELETEME?
setCmdProfile :: Maybe String
              -> IO ()
setCmdProfile ms =
  throwIfNonZero_ (\rc -> "Cannot set cmd profile: " ++ show rc) $ do
    sc <- c_spiel
    case ms of
      Nothing -> c_spiel_cmd_profile_set sc nullPtr
      Just s  -> withCString s $ \cs ->
        c_spiel_cmd_profile_set sc cs

addRoot :: SpielTransaction
        -> Fid -> Fid -> Fid -> Word32 -> [String] -> IO ()
addRoot _ _ _ _ _ _ = putStrLn "XXX Mero.Spiel.addRoot: IMPLEMENTME"

addProfile :: SpielTransaction
           -> Fid
           -> IO ()
addProfile (SpielTransaction fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot add profile: " ++ show rc)
      $ c_spiel_profile_add sc fid_ptr

addFilesystem :: SpielTransaction
              -> Fid
              -> Fid
              -> Word32
              -> Fid
              -> Fid
              -> Fid -- ^ imeta_pver
              -> [String]
              -> IO ()
addFilesystem (SpielTransaction fsc) fid profile mdRedundancy
                                     rootFid mdfid imeta params =
  withForeignPtr fsc $ \sc ->
    withMany with [fid, profile, rootFid, mdfid, imeta]
      $ \[fid_ptr, prof_ptr, root_ptr, md_ptr, imeta_ptr] ->
        bracket
          (mapM newCString params)
          (mapM_ free)
          (\eps_arr -> withArray0 nullPtr eps_arr $ \c_eps -> do
            throwIfNonZero_ (\rc -> "Cannot add filesystem: " ++ show rc)
              $ c_spiel_filesystem_add sc fid_ptr prof_ptr
                                       (CUInt mdRedundancy)
                                       root_ptr
                                       md_ptr
                                       imeta_ptr
                                       c_eps
          )

addNode :: SpielTransaction
        -> Fid
        -> Fid -- ^ Filesystem
        -> Word32
        -> Word32
        -> Word64
        -> Word64
        -> Fid
        -> IO ()
addNode (SpielTransaction fsc) fid fsFid memsize cpuNo lastState flags poolFid =
  withForeignPtr fsc $ \sc ->
    withMany with [fid, fsFid, poolFid] $ \[fid_ptr, fs_ptr, pool_ptr] ->
      throwIfNonZero_ (\rc -> "Cannot add node: " ++ show rc)
        $ c_spiel_node_add sc fid_ptr fs_ptr memsize
                           cpuNo lastState flags pool_ptr

addProcess :: SpielTransaction
           -> Fid
           -> Fid -- ^ Node
           -> Bitmap
           -> Word64 -- ^ memlimit_as
           -> Word64 -- ^ memlimit_rss
           -> Word64 -- ^ memlimit_stack
           -> Word64 -- ^ memlimit_memlock
           -> String -- ^ Process endpoint
           -> IO ()
addProcess (SpielTransaction fsc) fid nodeFid bitmap memlimit_as memlimit_rss
            memlimit_stack memlimit_memlock endpoint =
  withForeignPtr fsc $ \sc ->
    withMany with [fid, nodeFid] $ \[fid_ptr, fs_ptr] ->
      withBitmap bitmap $ \bm_ptr ->
        withCString endpoint $ \c_ep ->
          throwIfNonZero_ (\rc -> "Cannot add process: " ++ show rc)
            $ c_spiel_process_add sc fid_ptr fs_ptr bm_ptr memlimit_as
                                  memlimit_rss memlimit_stack memlimit_memlock
                                  c_ep

addService :: SpielTransaction
           -> Fid
           -> Fid -- ^ Process
           -> ServiceInfo
           -> IO ()
addService (SpielTransaction fsc) fid processFid serviceInfo =
  withForeignPtr fsc $ \sc ->
    withMany with [fid, processFid] $ \[fid_ptr, fs_ptr] ->
      with serviceInfo $ \sm_ptr ->
        throwIfNonZero_ (\rc -> "Cannot add service: " ++ show rc)
          $ c_spiel_service_add sc fid_ptr fs_ptr sm_ptr

addDevice :: SpielTransaction
          -> Fid
          -> Fid -- ^ Service
          -> Maybe Fid -- ^ Disk
          -> Word32 -- ^ Device index
          -> StorageDeviceInterfaceType
          -> StorageDeviceMediaType
          -> Word32 -- ^ block size in bytes
          -> Word64 -- ^ size in bytes
          -> Word64 -- ^ last known state (bitmask of m0_cfg_state_bit)
          -> Word64 -- ^ different flags (bitmask of m0_cfg_flag_bit)
          -> String -- ^ device filename
          -> IO ()
addDevice (SpielTransaction fsc) fid parentFid mdiskFid devIdx ifType medType
            bsize size lastState flags filename =
  withForeignPtr fsc $ \sc ->
    maybeWith with (mdiskFid) $ \disk_ptr ->
      withMany with [fid, parentFid] $ \[fid_ptr, fs_ptr] ->
        withCString filename $ \ c_filename ->
          throwIfNonZero_ (\rc -> "Cannot add device: " ++ show rc)
            $ c_spiel_device_add sc fid_ptr fs_ptr disk_ptr
                                  devIdx
                                  (fromIntegral . fromEnum $ ifType)
                                  (fromIntegral . fromEnum $ medType)
                                  bsize size lastState flags
                                  c_filename

addRack :: SpielTransaction
        -> Fid
        -> Fid
        -> IO ()
addRack (SpielTransaction fsc) fid fsFid = withForeignPtr fsc $ \sc ->
  withMany with [fid, fsFid] $ \[fid_ptr, fs_ptr] ->
    throwIfNonZero_ (\rc -> "Cannot add rack: " ++ show rc)
      $ c_spiel_rack_add sc fid_ptr fs_ptr

addEnclosure :: SpielTransaction
             -> Fid
             -> Fid
             -> IO ()
addEnclosure (SpielTransaction fsc) fid fsFid = withForeignPtr fsc $ \sc ->
  withMany with [fid, fsFid] $ \[fid_ptr, fs_ptr] ->
    throwIfNonZero_ (\rc -> "Cannot add enclosure: " ++ show rc)
      $ c_spiel_enclosure_add sc fid_ptr fs_ptr

addController :: SpielTransaction
              -> Fid
              -> Fid -- ^ Parent enclodure
              -> Fid -- ^ Node fid
              -> IO ()
addController (SpielTransaction fsc) fid fsFid nodeFid = withForeignPtr fsc $ \sc ->
  withMany with [fid, fsFid, nodeFid] $ \[fid_ptr, fs_ptr, node_ptr] ->
    throwIfNonZero_ (\rc -> "Cannot add controller: " ++ show rc)
      $ c_spiel_controller_add sc fid_ptr fs_ptr node_ptr

addDisk :: SpielTransaction
        -> Fid
        -> Fid
        -> IO ()
addDisk (SpielTransaction fsc) fid fsFid = withForeignPtr fsc $ \sc ->
  withMany with [fid, fsFid] $ \[fid_ptr, fs_ptr] ->
    throwIfNonZero_ (\rc -> "Cannot add disk: " ++ show rc)
      $ c_spiel_disk_add sc fid_ptr fs_ptr

addPool :: SpielTransaction
        -> Fid
        -> Fid
        -> Word32
        -> IO ()
addPool (SpielTransaction fsc) fid fsFid order = withForeignPtr fsc $ \sc ->
  withMany with [fid, fsFid] $ \[fid_ptr, fs_ptr] ->
    throwIfNonZero_ (\rc -> "Cannot add pool: " ++ show rc)
      $ c_spiel_pool_add sc fid_ptr fs_ptr order

addPVerActual :: SpielTransaction
              -> Fid
              -> Fid -- ^ Parent pool
              -> PDClustAttr -- ^ attributes specific to layout type
              -> [Word32] -- ^ Number of failures in each failure domain.
              -> IO ()
addPVerActual (SpielTransaction fsc) fid parent attrs failures =
  withForeignPtr fsc $ \sc ->
    withMany with [fid, parent] $ \[fid_ptr, fs_ptr] ->
      with attrs $ \c_attrs ->
        withArrayLen failures $ \fail_len fail_ptr ->
          throwIfNonZero_ (\rc -> "Cannot add pool version: " ++ show rc)
            $ c_spiel_pver_actual_add sc fid_ptr fs_ptr c_attrs fail_ptr (fromIntegral fail_len)

addPVerFormulaic :: SpielTransaction
                 -> Fid
                 -> Fid -- ^ Parent pool
                 -> Word32   -- ^ Index
                 -> Fid      -- ^ base
                 -> [Word32] -- ^ Number of simulated failures in each failure domain.
                 -> IO ()
addPVerFormulaic (SpielTransaction fsc) fid parent idx base allowance =
  withForeignPtr fsc $ \sc ->
    withMany with [fid, parent, base] $ \[fid_ptr, parent_ptr, base_ptr] ->
      withArrayLen allowance $ \allow_len allow_ptr ->
          throwIfNonZero_ (\rc -> "Cannot add pool version: " ++ show rc)
            $ c_spiel_pver_formulaic_add sc fid_ptr parent_ptr idx base_ptr allow_ptr (fromIntegral allow_len)

addRackV :: SpielTransaction
         -> Fid
         -> Fid -- ^ Parent pool version
         -> Fid -- ^ Real rack
         -> IO ()
addRackV (SpielTransaction fsc) fid fsFid rack = withForeignPtr fsc $ \sc ->
  withMany with [fid, fsFid, rack] $ \[fid_ptr, fs_ptr, rack_ptr] ->
    throwIfNonZero_ (\rc -> "Cannot add rack version: " ++ show rc)
      $ c_spiel_rack_v_add sc fid_ptr fs_ptr rack_ptr

addEnclosureV :: SpielTransaction
              -> Fid
              -> Fid -- ^ Parent rack version
              -> Fid -- ^ Real enclosure
              -> IO ()
addEnclosureV (SpielTransaction fsc) fid fsFid enclosure = withForeignPtr fsc $ \sc ->
  withMany with [fid, fsFid, enclosure] $ \[fid_ptr, fs_ptr, enclosure_ptr] ->
    throwIfNonZero_ (\rc -> "Cannot add enclosure version: " ++ show rc)
      $ c_spiel_enclosure_v_add sc fid_ptr fs_ptr enclosure_ptr

addControllerV :: SpielTransaction
               -> Fid
               -> Fid -- ^ Parent enclosure version
               -> Fid -- ^ Real controller
               -> IO ()
addControllerV (SpielTransaction fsc) fid fsFid controller = withForeignPtr fsc $ \sc ->
  withMany with [fid, fsFid, controller] $ \[fid_ptr, fs_ptr, controller_ptr] ->
    throwIfNonZero_ (\rc -> "Cannot add controller version: " ++ show rc)
      $ c_spiel_controller_v_add sc fid_ptr fs_ptr controller_ptr

addDiskV :: SpielTransaction
         -> Fid
         -> Fid -- ^ Parent controller version
         -> Fid -- ^ Real disk
         -> IO ()
addDiskV (SpielTransaction fsc) fid fsFid disk = withForeignPtr fsc $ \sc ->
  withMany with [fid, fsFid, disk] $ \[fid_ptr, fs_ptr, disk_ptr] ->
    throwIfNonZero_ (\rc -> "Cannot add disk version: " ++ show rc)
      $ c_spiel_disk_v_add sc fid_ptr fs_ptr disk_ptr

poolVersionDone :: SpielTransaction
                -> Fid
                -> IO ()
poolVersionDone (SpielTransaction fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot finish pool: " ++ show rc)
      $ c_spiel_pool_version_done sc fid_ptr

deviceAttach :: Fid  -- ^ Disk
             -> IO ()
deviceAttach fid =
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot attach device: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_device_attach sc fid_ptr

deviceDetach :: Fid -- ^ Disk
             -> IO ()
deviceDetach fid =
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot detach device: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_device_detach sc fid_ptr

poolRepairStart :: Fid -- ^ Pool Fid
                -> IO ()
poolRepairStart fid =
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot start pool repair: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_pool_repair_start sc fid_ptr

poolRepairContinue :: Fid -- ^ Pool Fid
                   -> IO ()
poolRepairContinue fid =
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot continue pool repair: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_pool_repair_continue sc fid_ptr

poolRepairQuiesce :: Fid -- ^ Pool Fid
                  -> IO ()
poolRepairQuiesce fid =
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce pool repair: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_pool_repair_quiesce sc fid_ptr

poolRepairAbort :: Fid
                -> IO ()
poolRepairAbort fid =
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot abort pool repair: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_pool_repair_abort sc fid_ptr

poolRepairStatus :: Fid
                 -> IO [SnsStatus]
poolRepairStatus fid = mask $ \restore ->
    with fid $ \fid_ptr ->
      alloca $ \arr_ptr -> do
        sc <- c_spiel
        poke fid_ptr fid
        rc <- fmap fromIntegral . restore
              $ c_spiel_pool_repair_status sc fid_ptr arr_ptr
        if rc < 0
        then error $ "Cannot retrieve pool repair status: " ++ show rc
        else do
          elt <- peek arr_ptr
          x <- peekArray rc elt
          free elt
          return x

poolRebalanceStart :: Fid -- ^ Pool Fid
                   -> IO ()
poolRebalanceStart fid =
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot start pool rebalance: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_pool_rebalance_start sc fid_ptr

poolRebalanceContinue :: Fid -- ^ Pool Fid
                     -> IO ()
poolRebalanceContinue fid =
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot continue pool rebalance: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_pool_rebalance_continue sc fid_ptr

poolRebalanceQuiesce :: Fid -- ^ Pool Fid
                     -> IO ()
poolRebalanceQuiesce fid =
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce pool rebalance: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_pool_rebalance_quiesce sc fid_ptr

poolRebalanceAbort :: Fid
                   -> IO ()
poolRebalanceAbort fid =
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot abort pool rebalance: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_pool_rebalance_abort sc fid_ptr

poolRebalanceStatus :: Fid
                    -> IO [SnsStatus]
poolRebalanceStatus fid = mask $ \restore ->
    with fid $ \fid_ptr ->
      alloca $ \arr_ptr -> do
        sc <- c_spiel
        poke fid_ptr fid
        rc <- fmap fromIntegral . restore
                $ c_spiel_pool_rebalance_status sc fid_ptr arr_ptr
        if rc < 0
        then error $ "Cannot retrieve pool rebalance status: " ++ show rc
        else do
          elt <- peek arr_ptr
          peekArray rc elt

filesystemStatsFetch :: Fid -> IO FSStats
filesystemStatsFetch fid =
  with fid $ \fid_ptr ->
    alloca $ \stats -> do
      throwIfNonZero_ (\rc -> "Cannot fetch filesystem stats: " ++ show rc)
        $ (c_spiel >>= \sc -> c_spiel_filesystem_stats_fetch sc fid_ptr stats)
      peek stats

---------------------------------------------------------------
-- Utility                                                   --
---------------------------------------------------------------

throwIfNonZero_ :: (Eq a, Num a) => (a -> String) -> IO a -> IO ()
throwIfNonZero_ = throwIf_ (/= 0)
