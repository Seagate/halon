{-# LANGUAGE LambdaCase #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the spiel interface.
--

module Mero.Spiel
  ( module Mero.Spiel
  , module Mero.Spiel.Context
  ) where

import Mero.ConfC
import Mero.Spiel.Context
import Mero.Spiel.Internal

import Control.Exception
  ( bracket
  , bracket_
  , mask
  )

import Data.ByteString (ByteString, packCString)
import Data.Word ( Word32, Word64 )

import Foreign.C.Error
  ( Errno(..)
  , eOK
  , eBUSY
  , eNOENT
  )
import Foreign.C.String
  ( newCString
  , withCString
  , peekCString
  )
import Foreign.C.Types
  ( CUInt(..)
  , CSize(..)
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
  , withArray0
  , withArrayLen
  )
import Foreign.Marshal.Error (throwIfNeg, throwIf_)
import Foreign.Marshal.Utils
  ( fillBytes
  , with
  , withMany
  , maybeWith
  , maybePeek
  )
import Foreign.Ptr
  ( nullPtr )
import Foreign.Storable
  ( peek
  , poke
  )

-- | Start rconfc server associated with spiel context.
rconfStart :: IO ()
rconfStart =
  throwIfNonZero_ (\rc -> "Cannot start spiel command interface: " ++ show rc)
    $ c_spiel >>= \sc -> c_spiel_rconfc_start sc nullPtr

-- | Stop rconfc server associated with spiel context.
rconfStop :: IO ()
rconfStop = c_spiel >>= c_spiel_rconfc_stop

-------------------------------------------------------------------------------
-- Backcompatibility functions
-------------------------------------------------------------------------------

-- | Helper function to run actions with rconfc setup.
withRConf :: IO a       -- ^ Action to undertake with configuration manager
          -> IO a
withRConf = bracket_ rconfStart rconfStop

---------------------------------------------------------------
-- Configuration management                                  --
---------------------------------------------------------------

newtype SpielTransaction = SpielTransaction (ForeignPtr SpielTransactionV)

openTransaction :: IO (SpielTransaction)
openTransaction = do
  sc <- c_spiel
  st <- mallocForeignPtrBytes m0_spiel_tx_size
  withForeignPtr st $ \ptr -> c_spiel_tx_open sc ptr
  return $ SpielTransaction st

closeTransaction :: SpielTransaction
                 -> IO ()
closeTransaction (SpielTransaction ptr) = withForeignPtr ptr c_spiel_tx_close

commitTransaction :: SpielTransaction
                  -> IO (Maybe String)
commitTransaction tx@(SpielTransaction ptr) =
  txValidateTransactionCache tx >>= \case
    Nothing -> do
      throwIfNonZero_ (\rc -> "Cannot commit Spiel transaction: " ++ show rc)
        $ withForeignPtr ptr c_spiel_tx_commit
      return Nothing
    Just err -> return $ Just err

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

withTransaction :: (SpielTransaction -> IO a)
                -> IO a
withTransaction f = bracket
    openTransaction
    closeTransaction
    (\t -> f t >>= \x -> commitTransaction t >> return x)

txToBS :: SpielTransaction
       -> Word64
       -> IO ByteString
txToBS (SpielTransaction ptr) verno = withForeignPtr ptr $ \c_ptr -> do
  valid <- Errno . negate <$> c_spiel_tx_validate c_ptr
  case valid of
    x | x == eOK -> alloca $ \c_str_ptr -> do
          _ <- throwIf_ (/= 0) (\rc -> "Cannot dump Spiel transaction: " ++ show rc) (c_spiel_tx_to_str c_ptr verno c_str_ptr)
          cs <- peek c_str_ptr
          bs <- packCString cs
          c_spiel_tx_str_free cs
          return bs
    x | x == eBUSY -> error "Not all objects are ready."
    x | x == eNOENT -> error "Not all objects have a parent."
    (Errno x) -> error $ "Unknown error return: " ++ show x

dumpTransaction :: SpielTransaction
                -> Word64 -- ^ Version number
                -> FilePath -- ^ File to dump to
                -> IO ()
dumpTransaction (SpielTransaction ptr) verno fp = withForeignPtr ptr $ \c_ptr -> do
  valid <- Errno . negate <$> c_spiel_tx_validate c_ptr
  case valid of
    x | x == eOK -> throwIfNonZero_ (\rc -> "Cannot dump Spiel transaction: " ++ show rc)
      $ withCString fp $ \c_fp -> c_spiel_tx_dump c_ptr verno c_fp
    x | x == eBUSY -> error "Not all objects are ready."
    x | x == eNOENT -> error "Not all objects have a parent."
    (Errno x) -> error $ "Unknown error return: " ++ show x

-- | Dump transaction to file, this call is required to be running in m0thread,
-- but it's possible to run it without setting rpc server, creating confd connection,
-- or spiel context. Usafe of 'commitTransaction' functions will lead to undefined
-- behavior.
withTransactionDump :: FilePath -> Word64 -> (SpielTransaction -> IO a) -> IO a
withTransactionDump fp verno transaction = bracket
  openLocalTransaction
  closeTransaction
  $ \t -> transaction t >>= \x -> dumpTransaction t verno fp >> return x

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

addPool :: SpielTransaction
        -> Fid
        -> Fid
        -> Word32
        -> IO ()
addPool (SpielTransaction fsc) fid fsFid order = withForeignPtr fsc $ \sc ->
  withMany with [fid, fsFid] $ \[fid_ptr, fs_ptr] ->
    throwIfNonZero_ (\rc -> "Cannot add pool: " ++ show rc)
      $ c_spiel_pool_add sc fid_ptr fs_ptr order

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

addDisk :: SpielTransaction
        -> Fid
        -> Fid
        -> IO ()
addDisk (SpielTransaction fsc) fid fsFid = withForeignPtr fsc $ \sc ->
  withMany with [fid, fsFid] $ \[fid_ptr, fs_ptr] ->
    throwIfNonZero_ (\rc -> "Cannot add disk: " ++ show rc)
      $ c_spiel_disk_add sc fid_ptr fs_ptr

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

deleteElement :: SpielTransaction
              -> Fid
              -> IO ()
deleteElement (SpielTransaction fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot delete element: " ++ show rc)
      $ c_spiel_element_del sc fid_ptr

---------------------------------------------------------------
-- Splicing configuration trees                              --
---------------------------------------------------------------

-- | A type providing an instance of Splicable may be spliced into a
--   configuration database, given an open Spiel Transaction.
class Spliceable a where

  -- | Splice just this object into the configuration database.
  splice :: SpielTransaction
         -> Fid -- ^ Parent fid to splice entity as a child of
         -> a  -- ^ Entity to splice
         -> IO ()

  -- | Splice this object and any children into the configuration
  --   database. The implementation is responsible for determining
  --   how children may be accessed.
  spliceTree :: SpielTransaction
             -> Fid -- ^ Parent fid to splice the subtree onto
             -> a -- ^ Root of the subtree to splice
             -> IO ()

instance Spliceable Profile where
  splice t _ o = addProfile t (cp_fid o)
  spliceTree t p o = do
    splice t p o
    fs <- children o :: IO [Filesystem]
    mapM_ (spliceTree t (cp_fid o)) fs

-- XXX-MULTIPOOLS: use Root instead
instance Spliceable Filesystem where
  splice t p fs = addFilesystem t (cf_fid fs) p
                                  (cf_redundancy fs) (cf_rootfid fs)
                                  (cf_mdpool fs) (cf_imeta_pver fs)
                                  (cf_params fs)
  spliceTree t p fs = do
    splice t p fs
    nodes <- children fs :: IO [Node]
    pools <- children fs :: IO [Pool]
    racks <- children fs :: IO [Rack]
    mapM_ (spliceTree t (cf_fid fs)) racks
    mapM_ (spliceTree t (cf_fid fs)) nodes
    mapM_ (spliceTree t (cf_fid fs)) pools

instance Spliceable Node where
  splice t p n = addNode t (cn_fid n) p (cn_memsize n) (cn_nr_cpu n)
                           (cn_last_state n) (cn_flags n) (cn_pool_fid n)
  spliceTree t p n = do
    splice t p n
    procs <- children n :: IO [Process]
    mapM_ (spliceTree t (cn_fid n)) procs

instance Spliceable Pool where
  splice t p o = addPool t (pl_fid o) p (pl_pver_policy o)
  spliceTree t p o = do
    splice t p o
    kids <- children o :: IO [PVer]
    mapM_ (spliceTree t (pl_fid o)) kids

instance Spliceable Rack where
  splice t p o = addRack t (cr_fid o) p
  spliceTree t p o = do
    splice t p o
    kids <- children o :: IO [Enclosure]
    mapM_ (spliceTree t (cr_fid o)) kids

instance Spliceable PVer where
  splice t p o = case pv_type o of
    s@PVerSubtree{}   -> addPVerActual t (pv_fid o) p (pvs_attr s) (pvs_tolerance s)
    s@PVerFormulaic{} -> addPVerFormulaic t (pv_fid o) p (pvf_id s) (pvf_base s) (pvf_allowance s)
  spliceTree t p o = do
    splice t p o
    kids <- children o :: IO [RackV]
    mapM_ (spliceTree t (pv_fid o)) kids
    poolVersionDone t (pv_fid o)

instance Spliceable RackV where
  splice t p o = let (RackV v) = o in addRackV t (cv_fid v) p (cv_real v)
  spliceTree t p o = do
    let (RackV v) = o
    splice t p o
    kids <- children o :: IO [EnclV]
    mapM_ (spliceTree t (cv_fid v)) kids

instance Spliceable EnclV where
  splice t p o = let (EnclV v) = o in addEnclosureV t (cv_fid v) p (cv_real v)
  spliceTree t p o = do
    let (EnclV v) = o
    splice t p o
    kids <- children o :: IO [CtrlV]
    mapM_ (spliceTree t (cv_fid v)) kids

instance Spliceable CtrlV where
  splice t p o = let (CtrlV v) = o in addControllerV t (cv_fid v) p (cv_real v)
  spliceTree t p o = do
    let (CtrlV v) = o
    splice t p o
    kids <- children o :: IO [DiskV]
    mapM_ (spliceTree t (cv_fid v)) kids

instance Spliceable DiskV where
  splice t p o = let (DiskV v) = o in addDiskV t (cv_fid v) p (cv_real v)
  spliceTree = splice

instance Spliceable Process where
  splice t p o = addProcess t (pc_fid o) p (pc_cores o) (pc_memlimit_as o)
                              (pc_memlimit_rss o) (pc_memlimit_stack o)
                              (pc_memlimit_memlock o) (pc_endpoint o)
  spliceTree t p o = do
    splice t p o
    kids <- children o :: IO [Service]
    mapM_ (spliceTree t (pc_fid o)) kids

instance Spliceable Service where
  splice t p o = addService t (cs_fid o) p $ ServiceInfo (cs_type o)
                                                         (cs_endpoints o)
  spliceTree t p o = do
    splice t p o
    kids <- children o :: IO [Sdev]
    mapM_ (spliceTree t (cs_fid o)) kids

instance Spliceable Sdev where
  splice t p o = do
     msd <- maybePeek peek (sd_disk o)
     addDevice t (sd_fid o) p msd (sd_dev_idx o)
               (toEnum . fromIntegral $ sd_iface o)
               (toEnum . fromIntegral $ sd_media o)
               (sd_bsize o) (sd_size o)
               (sd_last_state o) (sd_flags o)
               (sd_filename o)
  spliceTree = splice

instance Spliceable Enclosure where
  splice t p o = addEnclosure t (ce_fid o) p
  spliceTree t p o = do
    splice t p o
    kids <- children o :: IO [Controller]
    mapM_ (spliceTree t (ce_fid o)) kids

instance Spliceable Controller where
  splice t p o = addController t (cc_fid o) p (cc_node_fid o)
  spliceTree t p o = do
    splice t p o
    kids <- children o :: IO [Disk]
    mapM_ (spliceTree t (cc_fid o)) kids

instance Spliceable Disk where
  splice t p o = addDisk t (ck_fid o) p
  spliceTree t p o = splice t p o

---------------------------------------------------------------
-- Command interface                                         --
---------------------------------------------------------------

serviceInit :: Service
            -> IO ()
serviceInit cs =
  with (cs_fid cs) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot initialise service: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_service_init sc fid_ptr

serviceStart :: Service
             -> IO ()
serviceStart cs =
  with (cs_fid cs) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot start service: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_service_start sc fid_ptr

serviceStop :: Service
            -> IO ()
serviceStop cs =
  with (cs_fid cs) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot stop service: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_service_stop sc fid_ptr

serviceHealth :: Service
              -> IO ServiceHealth
serviceHealth cs =
  with (cs_fid cs) $ \fid_ptr ->
    fmap ServiceHealth
      $ throwIfNeg (\rc -> "Cannot query service health: " ++ show rc)
        $ fmap (fromIntegral) $ c_spiel >>= \sc -> c_spiel_service_health sc fid_ptr

serviceQuiesce :: Service
               -> IO ()
serviceQuiesce cs =
  with (cs_fid cs) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce service: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_service_quiesce sc fid_ptr

deviceAttach :: Fid  -- ^ Disk
             -> IO ()
deviceAttach  fid =
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot attach device: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_device_attach sc fid_ptr

deviceDetach :: Fid -- ^ Disk
             -> IO ()
deviceDetach fid =
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot detach device: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_device_detach sc fid_ptr

deviceFormat :: Disk
             -> IO ()
deviceFormat ck =
  with (ck_fid ck) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot format device: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_device_format sc fid_ptr

processStop :: Process
            -> IO ()
processStop pc =
  with (pc_fid pc) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot stop process: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_process_stop sc fid_ptr

processReconfig :: Process
                -> IO ()
processReconfig pc =
  with (pc_fid pc) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot reconfigure process: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_process_reconfig sc fid_ptr

processHealth :: Process
              -> IO ServiceHealth
processHealth pc =
  with (pc_fid pc) $ \fid_ptr ->
    fmap ServiceHealth
      $ throwIfNeg (\rc -> "Cannot query process health: " ++ show rc)
        $ fmap (fromIntegral) $ c_spiel >>= \sc -> c_spiel_process_health sc fid_ptr

processQuiesce :: Process
               -> IO ()
processQuiesce pc =
  with (pc_fid pc) $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce process: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_process_quiesce sc fid_ptr

processListServices :: Process
                    -> IO [RunningService]
processListServices pc = mask $ \restore ->
    alloca $ \fid_ptr ->
      alloca $ \arr_ptr -> do
        sc <- c_spiel
        poke fid_ptr (pc_fid pc)
        rc <- fmap fromIntegral . restore
              $ c_spiel_process_list_services sc fid_ptr arr_ptr
        if rc < 0
        then error $ "Cannot list process services: " ++ show rc
        else do
          elt <- peek arr_ptr
          services <- peekArray rc elt
          -- _ <- freeRunningServices elt
          return services

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

-- XXX-MULTIPOOLS: Change it to site/pool stats?
filesystemStatsFetch :: Fid
                     -> IO FSStats
filesystemStatsFetch fid = with fid $ \fid_ptr -> do
  alloca $ \stats -> do
    rc <- c_spiel >>= \sc -> c_spiel_filesystem_stats_fetch sc fid_ptr stats
    if rc < 0
    then error $ "Cannot fetch filesystem stats: " ++ show rc
    else peek stats
