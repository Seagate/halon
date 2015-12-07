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

import Network.RPC.RPCLite
  ( RPCMachine )

import Control.Exception
  ( bracket
  , mask
  )

import Data.IORef
import qualified Data.Map.Strict as Map
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
  )
import Foreign.C.Types
  ( CUInt(..) )
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
import Foreign.Marshal.Error (throwIfNeg)
import Foreign.Marshal.Utils
  ( fillBytes
  , with
  , withMany
  )
import Foreign.Ptr
  ( nullPtr )
import Foreign.Storable
  ( peek
  , poke
  )

import System.IO.Unsafe (unsafePerformIO)

newtype SpielContext = SpielContext (ForeignPtr SpielContextV)

-- | Open a Spiel context
start :: RPCMachine -- ^ Request handler
      -> [String] -- ^ Confd endpoints
      -> String -- ^ Network endpoint of Resource Manager service.
      -> IO SpielContext
start rpcmach eps rm_ep = withCString rm_ep $ \c_rm_ep -> do
  let reqh = rm_reqh rpcmach
  bracket
    (mapM newCString eps)
    (mapM_ free)
    (\eps_arr -> withArray0 nullPtr eps_arr $ \c_eps -> do
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
withSpiel rpcmach eps rm_ep = bracket (start rpcmach eps rm_ep) stop

---------------------------------------------------------------
-- Configuration management                                  --
---------------------------------------------------------------

newtype SpielTransaction = SpielTransaction (ForeignPtr SpielTransactionV)

openTransactionContext :: SpielContext
                      -> IO (SpielTransaction)
openTransactionContext (SpielContext fsc) = withForeignPtr fsc $ \sc -> do
  st <- mallocForeignPtrBytes m0_spiel_tx_size
  withForeignPtr st $ \ptr -> c_spiel_tx_open sc ptr
  return $ SpielTransaction st

openTransaction :: IO SpielTransaction
openTransaction = do
  sc <- mallocForeignPtrBytes m0_spiel_size
  st <- mallocForeignPtrBytes m0_spiel_tx_size
  withForeignPtr sc
    $ \sc_ptr -> withForeignPtr st
      $ \ptr -> do
        fillBytes sc_ptr 0 m0_spiel_size
        c_spiel_tx_open sc_ptr ptr
  return $ SpielTransaction st

closeTransaction :: SpielTransaction
                 -> IO ()
closeTransaction (SpielTransaction ptr) = withForeignPtr ptr c_spiel_tx_close

commitTransaction :: SpielTransaction
                  -> IO ()
commitTransaction (SpielTransaction ptr) =
  throwIfNonZero_ (\rc -> "Cannot commit Spiel transaction: " ++ show rc)
                  $ withForeignPtr ptr c_spiel_tx_commit

commitTransactionForced :: SpielTransaction
                        -> Bool
                        -> Word64 -- ^ Version number
                        -> Word32 -- ^ Quorum
                        -> IO ()
commitTransactionForced (SpielTransaction ptr) forced ver quorum =
  throwIfNonZero_ (\rc -> "Cannot commmit Spiel transaction: " ++ show rc)
    $ withForeignPtr ptr $ \c_ptr -> alloca $ \q_ptr -> do
      poke q_ptr quorum
      c_spiel_tx_commit_forced c_ptr forced ver q_ptr

withTransaction :: SpielContext
                -> (SpielTransaction -> IO a)
                -> IO a
withTransaction sc f = bracket
  (openTransactionContext sc)
  (closeTransaction)
  (\t -> f t >>= \x -> commitTransaction t >> return x)

dumpTransaction :: SpielTransaction
                -> FilePath
                -> IO ()
dumpTransaction (SpielTransaction ptr) fp = withForeignPtr ptr $ \c_ptr -> do
  valid <- Errno . negate <$> c_spiel_tx_validate c_ptr
  case valid of
    x | x == eOK -> throwIfNonZero_ (\rc -> "Cannot dump Spiel transaction: " ++ show rc)
      $ withCString fp $ \c_fp -> c_spiel_tx_dump c_ptr c_fp
    x | x == eBUSY -> error "Not all objects are ready."
    x | x == eNOENT -> error "Not all objects have a parent."
    (Errno x) -> error $ "Unknown error return: " ++ show x

setCmdProfile :: SpielContext
              -> Maybe String
              -> IO ()
setCmdProfile (SpielContext sc) ms =
  throwIfNonZero_ (\rc -> "Cannot set cmd profile: " ++ show rc) $
    withForeignPtr sc $ \sc_ptr -> case ms of
      Nothing -> c_spiel_cmd_profile_set sc_ptr nullPtr
      Just s  -> withCString s $ \cs ->
        c_spiel_cmd_profile_set sc_ptr cs


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
              -> [String]
              -> IO ()
addFilesystem (SpielTransaction fsc) fid profile mdRedundancy
                                     rootFid mdfid params =
  withForeignPtr fsc $ \sc ->
    withMany with [fid, profile, rootFid, mdfid]
      $ \[fid_ptr, prof_ptr, root_ptr, md_ptr] ->
        bracket
          (mapM newCString params)
          (mapM_ free)
          (\eps_arr -> withArray0 nullPtr eps_arr $ \c_eps -> do
            throwIfNonZero_ (\rc -> "Cannot add filesystem: " ++ show rc)
              $ c_spiel_filesystem_add sc fid_ptr prof_ptr
                                       (CUInt mdRedundancy)
                                       root_ptr
                                       md_ptr
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
          -> Fid -- ^ Disk
          -> StorageDeviceInterfaceType
          -> StorageDeviceMediaType
          -> Word32 -- ^ block size in bytes
          -> Word64 -- ^ size in bytes
          -> Word64 -- ^ last known state (bitmask of m0_cfg_state_bit)
          -> Word64 -- ^ different flags (bitmask of m0_cfg_flag_bit)
          -> String -- ^ device filename
          -> IO ()
addDevice (SpielTransaction fsc) fid parentFid diskFid ifType medType
            bsize size lastState flags filename =
  withForeignPtr fsc $ \sc ->
    withMany with [fid, parentFid, diskFid] $ \[fid_ptr, fs_ptr, disk_ptr] ->
      withCString filename $ \ c_filename ->
        throwIfNonZero_ (\rc -> "Cannot add device: " ++ show rc)
          $ c_spiel_device_add sc fid_ptr fs_ptr disk_ptr
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

addPVer :: SpielTransaction
        -> Fid
        -> Fid -- ^ Parent pool
        -> [Word32] -- ^ Number of failures in each failure domain.
        -> PDClustAttr -- ^ attributes specific to layout type
        -> IO ()
addPVer (SpielTransaction fsc) fid parent failures attrs =
  withForeignPtr fsc $ \sc ->
    withMany with [fid, parent] $ \[fid_ptr, fs_ptr] ->
      withArrayLen failures $ \fail_nr fail_ptr ->
        with attrs $ \c_attrs ->
          throwIfNonZero_ (\rc -> "Cannot add pool version: " ++ show rc)
            $ c_spiel_pool_version_add sc fid_ptr fs_ptr fail_ptr
                                       (fromIntegral fail_nr) c_attrs

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

-- Temporary workaround for MERO-1094
{-# NOINLINE sdevDiskMap #-}
sdevDiskMap :: IORef (Map.Map Fid Fid)
sdevDiskMap = unsafePerformIO $ newIORef $ Map.empty

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
    writeIORef sdevDiskMap Map.empty -- YUCK
    splice t p o
    fs <- children o :: IO [Filesystem]
    mapM_ (spliceTree t (cp_fid o)) fs

instance Spliceable Filesystem where
  splice t p fs = addFilesystem t (cf_fid fs) p
                                  (cf_redundancy fs) (cf_rootfid fs)
                                  (cf_mdpool fs) (cf_params fs)
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
  splice t p o = addPool t (pl_fid o) p (pl_order o)
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
  splice t p o = addPVer t (pv_fid o) p (pv_failures o) (pv_attr o)
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
                                                         (cs_u o)
  spliceTree t p o = do
    splice t p o
    kids <- children o :: IO [Sdev]
    mapM_ (spliceTree t (cs_fid o)) kids

instance Spliceable Sdev where
  splice t p o = do
    mdisk <- fmap (Map.lookup (sd_fid o)) $ readIORef sdevDiskMap
    case mdisk of
      Just disk ->
        addDevice t (sd_fid o) p disk
               (toEnum . fromIntegral $ sd_iface o)
               (toEnum . fromIntegral $ sd_media o)
               (sd_bsize o) (sd_size o)
               (sd_last_state o) (sd_flags o)
               (sd_filename o)
      Nothing -> error "Problem building reverse map needed until MERO-1094"
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
  spliceTree t p o = do
    modifyIORef' sdevDiskMap $ Map.insert (ck_dev o) (ck_fid o)
    splice t p o

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
             -> Fid  -- ^ Disk
             -> IO ()
deviceAttach (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot attach device: " ++ show rc)
      $ c_spiel_device_attach sc fid_ptr

deviceDetach :: SpielContext
             -> Fid -- ^ Disk
             -> IO ()
deviceDetach (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
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
        if rc < 0
        then error $ "Cannot list process services: " ++ show rc
        else do
          elt <- peek arr_ptr
          services <- peekArray rc elt
          -- _ <- freeRunningServices elt
          return services

poolRepairStart :: SpielContext
                -> Fid -- ^ Pool Fid
                -> IO ()
poolRepairStart (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot start pool repair: " ++ show rc)
      $ c_spiel_pool_repair_start sc fid_ptr

poolRepairQuiesce :: SpielContext
                  -> Fid -- ^ Pool Fid
                  -> IO ()
poolRepairQuiesce (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce pool repair: " ++ show rc)
      $ c_spiel_pool_repair_quiesce sc fid_ptr

poolRebalanceStart :: SpielContext
                   -> Fid -- ^ Pool Fid
                   -> IO ()
poolRebalanceStart (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot start pool rebalance: " ++ show rc)
      $ c_spiel_pool_rebalance_start sc fid_ptr

poolRebalanceQuiesce :: SpielContext
                     -> Fid -- ^ Pool Fid
                     -> IO ()
poolRebalanceQuiesce (SpielContext fsc) fid = withForeignPtr fsc $ \sc ->
  with fid $ \fid_ptr ->
    throwIfNonZero_ (\rc -> "Cannot quiesce pool rebalance: " ++ show rc)
      $ c_spiel_pool_rebalance_quiesce sc fid_ptr
