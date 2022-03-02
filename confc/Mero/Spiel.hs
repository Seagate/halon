{-# LANGUAGE LambdaCase #-}

-- |
-- Copyright : (C) 2015-2018 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Bindings to the spiel interface.
--

module Mero.Spiel
  ( module Mero.Spiel.Context
  , SpielTransaction
  , addRoot

  , addNode
  , addProcess
  , addService
  , addDevice

  , addSite
  , addRack
  , addEnclosure
  , addController
  , addDrive

  , addPool
  , addPVerActual
  , addPVerFormulaic
  , addSiteV
  , addRackV
  , addEnclosureV
  , addControllerV
  , addDriveV
  , poolVersionDone

  , addProfile
  , addProfilePool

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
  , nodeDirectRebalanceStart
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
import Foreign.C.Types (CInt, CSize)
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Marshal.Alloc (alloca, free)
import Foreign.Marshal.Array (peekArray, withArray0, withArrayLen)
import Foreign.Marshal.Error (throwIf_)
import Foreign.Marshal.Utils (fillBytes, maybeWith, with, withMany)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek, poke)

-- | Start rconfc server associated with spiel context.
rconfStart :: IO ()
rconfStart =
    throwIfNonZero_ (\rc -> "Cannot start spiel command interface: " ++ show rc)
      $ c_spiel >>= \sc -> c_spiel_rconfc_start sc nullPtr

-- | Stop rconfc server associated with spiel context.
rconfStop :: IO ()
rconfStop = c_spiel >>= c_spiel_rconfc_stop

----------------------------------------------------------------------
-- Configuration management

newtype SpielTransaction = SpielTransaction (ForeignPtr SpielTransactionV)

openTransaction :: IO SpielTransaction
openTransaction = do
    sc <- c_spiel
    ftx <- mallocForeignPtrBytes m0_spiel_tx_size
    withForeignPtr ftx $ \tx -> c_spiel_tx_open sc tx
    pure (SpielTransaction ftx)

closeTransaction :: SpielTransaction -> IO ()
closeTransaction (SpielTransaction ftx) = withForeignPtr ftx c_spiel_tx_close

commitTransactionForced :: SpielTransaction
                        -> Bool
                        -> Word64
                        -> IO (Either String ())
commitTransactionForced tx@(SpielTransaction ftx) forced verno =
    txValidateTransactionCache tx >>= \case
        Nothing -> do
            throwIfNonZero_ (\rc -> "Cannot commmit Spiel transaction: "
                                    ++ show rc)
              $ withForeignPtr ftx $ \tx_ptr -> alloca $ \rquorum_ptr ->
                    c_spiel_tx_commit_forced tx_ptr forced verno rquorum_ptr
            pure $ Right ()
        Just err -> pure $ Left err

txToBS :: SpielTransaction -> Word64 -> IO ByteString
txToBS (SpielTransaction ftx) verno = withForeignPtr ftx $ \tx_ptr -> do
    valid <- Errno . negate <$> c_spiel_tx_validate tx_ptr
    case valid of
        x | x == eOK -> alloca $ \cstr_ptr -> do
            throwIfNonZero_ (\rc -> "Cannot dump Spiel transaction: "
                                    ++ show rc)
              $ c_spiel_tx_to_str tx_ptr verno cstr_ptr
            cs <- peek cstr_ptr
            bs <- packCString cs
            c_spiel_tx_str_free cs
            pure bs
        x | x == eBUSY  -> error "Not all objects are ready"
        x | x == eNOENT -> error "Not all objects have a parent"
        Errno x -> error $ "Unknown error: " ++ show x

-- | Open transaction that doesn't require communication with confd or rms
-- service.
--
-- Such transaction can be run in non privileged mode without prior creation
-- of the spiel context.  However it's illegal to commit such transactions
-- and that could lead to undefined behaviour, use should only verify or
-- dump such transactions.
openLocalTransaction :: IO SpielTransaction
openLocalTransaction = do
    sc <- mallocForeignPtrBytes m0_spiel_size
    ftx <- mallocForeignPtrBytes m0_spiel_tx_size
    withForeignPtr sc
      $ \sc_ptr -> withForeignPtr ftx
      $ \tx_ptr -> do
         fillBytes sc_ptr 0 m0_spiel_size
         c_spiel_tx_open sc_ptr tx_ptr
    pure (SpielTransaction ftx)

txValidateTransactionCache :: SpielTransaction -> IO (Maybe String)
txValidateTransactionCache (SpielTransaction ftx) =
    withForeignPtr ftx $ \tx -> do
        let buflen = 192 :: CSize
        err <- c_confc_validate_cache_of_tx tx buflen
        if err == nullPtr
        then pure Nothing
        else do
            str <- peekCString err
            free err
            pure (Just str)

-- XXX-MULTIPOOLS: DELETEME?
setCmdProfile :: Maybe String -> IO ()
setCmdProfile mstr =
    throwIfNonZero_ (\rc -> "Cannot set cmd profile: " ++ show rc) $ do
        sc <- c_spiel
        case mstr of
            Nothing  -> c_spiel_cmd_profile_set sc nullPtr
            Just str -> withCString str $ \cstr ->
                c_spiel_cmd_profile_set sc cstr

addRoot :: SpielTransaction
        -> Fid
        -> Fid
        -> Fid
        -> Word32
        -> [String]
        -> IO ()
addRoot (SpielTransaction ftx) rootfid mdpool imeta mdRedundancy params =
    withForeignPtr ftx $ \tx ->
        withMany with [rootfid, mdpool, imeta]
          $ \[rootfid_ptr, mdpool_ptr, imeta_ptr] ->
            bracket
                (mapM newCString params)
                (mapM_ free)
                (\cstrs -> withArray0 nullPtr cstrs $ \cstr_ptr ->
                    throwIfNonZero_ (\rc -> "Cannot add root: " ++ show rc)
                      $ c_spiel_root_add tx
                                         rootfid_ptr
                                         mdpool_ptr
                                         imeta_ptr
                                         mdRedundancy
                                         cstr_ptr
                )

addNode :: SpielTransaction
        -> Fid
        -> Word32
        -> Word32
        -> Word64
        -> Word64
        -> IO ()
addNode (SpielTransaction ftx) fid memsize nrCpu lastState flags =
    withForeignPtr ftx $ \tx ->
        with fid $ \fid_ptr ->
            throwIfNonZero_ (\rc -> "Cannot add node: " ++ show rc)
              $ c_spiel_node_add tx fid_ptr memsize nrCpu lastState flags

addProcess :: SpielTransaction
           -> Fid
           -> Fid
           -> Bitmap
           -> Word64
           -> Word64
           -> Word64
           -> Word64
           -> String
           -> IO ()
addProcess (SpielTransaction ftx) fid parent cores memlimit_as memlimit_rss
            memlimit_stack memlimit_memlock endpoint =
    withForeignPtr ftx $ \tx ->
        withMany with [fid, parent] $ \[fid_ptr, parent_ptr] ->
            withBitmap cores $ \cores_ptr ->
                withCString endpoint $ \c_endpoint ->
                    throwIfNonZero_ (\rc -> "Cannot add process: " ++ show rc)
                      $ c_spiel_process_add tx
                                            fid_ptr
                                            parent_ptr
                                            cores_ptr
                                            memlimit_as
                                            memlimit_rss
                                            memlimit_stack
                                            memlimit_memlock
                                            c_endpoint

addService :: SpielTransaction -> Fid -> Fid -> ServiceInfo -> IO ()
addService (SpielTransaction ftx) fid parent si =
    withForeignPtr ftx $ \tx ->
        withMany with [fid, parent] $ \[fid_ptr, parent_ptr] ->
            with si $ \si_ptr ->
                throwIfNonZero_ (\rc -> "Cannot add service: " ++ show rc)
                  $ c_spiel_service_add tx fid_ptr parent_ptr si_ptr

addDevice :: SpielTransaction
          -> Fid
          -> Fid
          -> Maybe Fid
          -> Word32
          -> StorageDeviceInterfaceType
          -> StorageDeviceMediaType
          -> Word32
          -> Word64
          -> Word64
          -> Word64
          -> String
          -> IO ()
addDevice (SpielTransaction ftx) fid parent mdrive devIdx iface media
            bsize size lastState flags filename =
    withForeignPtr ftx $ \tx ->
        maybeWith with mdrive $ \drive_ptr ->
            withMany with [fid, parent] $ \[fid_ptr, parent_ptr] ->
                withCString filename $ \ c_filename ->
                    throwIfNonZero_ (\rc -> "Cannot add device: " ++ show rc)
                      $ c_spiel_device_add tx
                                           fid_ptr
                                           parent_ptr
                                           drive_ptr
                                           devIdx
                                           (fromIntegral $ fromEnum iface)
                                           (fromIntegral $ fromEnum media)
                                           bsize size lastState flags
                                           c_filename

addSite :: SpielTransaction -> Fid -> IO ()
addSite (SpielTransaction ftx) fid =
    withForeignPtr ftx $ \tx ->
        with fid $ \fid_ptr ->
            throwIfNonZero_ (\rc -> "Cannot add site: " ++ show rc)
              $ c_spiel_site_add tx fid_ptr

addRack :: SpielTransaction
        -> Fid
        -> Fid -- ^ parent
        -> IO ()
addRack = addObj "rack" c_spiel_rack_add

addEnclosure :: SpielTransaction
             -> Fid
             -> Fid -- ^ parent
             -> IO ()
addEnclosure = addObj "enclosure" c_spiel_enclosure_add

addController :: SpielTransaction
              -> Fid
              -> Fid -- ^ parent
              -> Fid -- ^ node
              -> IO ()
addController = addObjR "controller" c_spiel_controller_add

addDrive :: SpielTransaction
         -> Fid
         -> Fid -- ^ parent
         -> IO ()
addDrive = addObj "drive" c_spiel_drive_add

addPool :: SpielTransaction -> Fid -> Word32 -> IO ()
addPool (SpielTransaction ftx) fid pverPolicy =
    withForeignPtr ftx $ \tx ->
        with fid $ \fid_ptr ->
            throwIfNonZero_ (\rc -> "Cannot add pool: " ++ show rc)
              $ c_spiel_pool_add tx fid_ptr pverPolicy

addPVerActual :: SpielTransaction
              -> Fid
              -> Fid
              -> PDClustAttr
              -> [Word32]
              -> IO ()
addPVerActual (SpielTransaction ftx) fid parent attrs tolerance =
    withForeignPtr ftx $ \tx ->
        withMany with [fid, parent] $ \[fid_ptr, parent_ptr] ->
            with attrs $ \attrs_ptr ->
                withArrayLen tolerance $ \tolerance_len tolerance_ptr ->
                    throwIfNonZero_ (\rc -> "Cannot add pver: " ++ show rc)
                      $ c_spiel_pver_actual_add tx
                                            fid_ptr
                                            parent_ptr
                                            attrs_ptr
                                            tolerance_ptr
                                            (fromIntegral tolerance_len)

addPVerFormulaic :: SpielTransaction
                 -> Fid
                 -> Fid
                 -> Word32
                 -> Fid
                 -> [Word32]
                 -> IO ()
addPVerFormulaic (SpielTransaction ftx) fid parent idx base allowance =
    withForeignPtr ftx $ \tx ->
        withMany with [fid, parent, base] $ \[fid_ptr, parent_ptr, base_ptr] ->
            withArrayLen allowance $ \allowance_len allowance_ptr ->
                throwIfNonZero_ (\rc -> "Cannot add pver_f: " ++ show rc)
                  $ c_spiel_pver_formulaic_add tx
                                               fid_ptr
                                               parent_ptr
                                               idx
                                               base_ptr
                                               allowance_ptr
                                               (fromIntegral allowance_len)

addSiteV :: SpielTransaction
         -> Fid
         -> Fid -- ^ parent
         -> Fid -- ^ real
         -> IO ()
addSiteV = addObjR "site-v" c_spiel_site_v_add

addRackV :: SpielTransaction
         -> Fid
         -> Fid -- ^ parent
         -> Fid -- ^ real
         -> IO ()
addRackV = addObjR "rack-v" c_spiel_rack_v_add

addEnclosureV :: SpielTransaction
              -> Fid
              -> Fid -- ^ parent
              -> Fid -- ^ real
              -> IO ()
addEnclosureV = addObjR "enclosure-v" c_spiel_enclosure_v_add

addControllerV :: SpielTransaction
               -> Fid
               -> Fid -- ^ parent
               -> Fid -- ^ real
               -> IO ()
addControllerV = addObjR "controller-v" c_spiel_controller_v_add

addDriveV :: SpielTransaction
          -> Fid
          -> Fid -- ^ parent
          -> Fid -- ^ real
          -> IO ()
addDriveV = addObjR "drive-v" c_spiel_drive_v_add

poolVersionDone :: SpielTransaction -> Fid -> IO ()
poolVersionDone (SpielTransaction ftx) fid =
    withForeignPtr ftx $ \tx ->
        with fid $ \fid_ptr ->
            throwIfNonZero_ (\rc -> "Cannot finish pool: " ++ show rc)
              $ c_spiel_pool_version_done tx fid_ptr

addProfile :: SpielTransaction -> Fid -> IO ()
addProfile (SpielTransaction ftx) fid =
    withForeignPtr ftx $ \tx ->
        with fid $ \fid_ptr ->
            throwIfNonZero_ (\rc -> "Cannot add profile: " ++ show rc)
              $ c_spiel_profile_add tx fid_ptr

addProfilePool :: SpielTransaction
               -> Fid -- ^ profile
               -> Fid -- ^ pool
               -> IO ()
addProfilePool = addObj "pool to profile" c_spiel_profile_pool_add

----------------------------------------------------------------------
-- Command interface

deviceAttach :: Fid -> IO ()
deviceAttach = command "attach device" c_spiel_device_attach

deviceDetach :: Fid -> IO ()
deviceDetach = command "detach device" c_spiel_device_detach

poolRepairStart :: Fid -> IO ()
poolRepairStart = command "start pool repair" c_spiel_pool_repair_start

nodeDirectRebalanceStart :: Fid -> IO ()
nodeDirectRebalanceStart = command "start node direct rebalance" c_spiel_node_direct_rebalance_start

poolRepairContinue :: Fid -> IO ()
poolRepairContinue = command "continue pool repair" c_spiel_pool_repair_continue

poolRepairQuiesce :: Fid -> IO ()
poolRepairQuiesce = command "quiesce pool repair" c_spiel_pool_repair_quiesce

poolRepairAbort :: Fid -> IO ()
poolRepairAbort = command "abort pool repair" c_spiel_pool_repair_abort

poolRepairStatus :: Fid -> IO [SnsStatus]
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
                pure x

poolRebalanceStart :: Fid -> IO ()
poolRebalanceStart =
    command "start pool rebalance" c_spiel_pool_rebalance_start

poolRebalanceContinue :: Fid -> IO ()
poolRebalanceContinue =
    command "continue pool rebalance" c_spiel_pool_rebalance_continue

poolRebalanceQuiesce :: Fid -> IO ()
poolRebalanceQuiesce =
    command "quiesce pool rebalance" c_spiel_pool_rebalance_quiesce

poolRebalanceAbort :: Fid -> IO ()
poolRebalanceAbort =
    command "abort pool rebalance" c_spiel_pool_rebalance_abort

poolRebalanceStatus :: Fid -> IO [SnsStatus]
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
                -- XXX Why is this piece asymmetrical to 'poolRepairStatus'?

filesystemStatsFetch :: IO FSStats
filesystemStatsFetch =
    alloca $ \stats -> do
        throwIfNonZero_ (\rc -> "Cannot fetch filesystem stats: " ++ show rc)
          $ (c_spiel >>= \sc -> c_spiel_filesystem_stats_fetch sc stats)
        peek stats

----------------------------------------------------------------------
-- Helper functions

addObj :: String
       -> (Ptr SpielTransactionV -> Ptr Fid -> Ptr Fid -> IO CInt)
       -> SpielTransaction
       -> Fid
       -> Fid
       -> IO ()
addObj name act (SpielTransaction ftx) fid parent =
    withForeignPtr ftx $ \tx ->
        withMany with [fid, parent] $ \[fid_ptr, parent_ptr] ->
            throwIfNonZero_ (\rc -> "Cannot add " ++ name ++ ": " ++ show rc)
              $ act tx fid_ptr parent_ptr

addObjR :: String
        -> (Ptr SpielTransactionV -> Ptr Fid -> Ptr Fid -> Ptr Fid -> IO CInt)
        -> SpielTransaction
        -> Fid
        -> Fid
        -> Fid
        -> IO ()
addObjR name act (SpielTransaction ftx) fid parent ref =
    withForeignPtr ftx $ \tx ->
        withMany with [fid, parent, ref] $ \[fid_ptr, parent_ptr, ref_ptr] ->
            throwIfNonZero_ (\rc -> "Cannot add " ++ name ++ ": " ++ show rc)
              $ act tx fid_ptr parent_ptr ref_ptr

command :: String
        -> (Ptr SpielContextV -> Ptr Fid -> IO CInt)
        -> Fid
        -> IO ()
command desc act fid =
    with fid $ \fid_ptr ->
        throwIfNonZero_ (\rc -> "Cannot " ++ desc ++ ": " ++ show rc)
          $ c_spiel >>= \sc -> act sc fid_ptr

throwIfNonZero_ :: (Eq a, Num a) => (a -> String) -> IO a -> IO ()
throwIfNonZero_ = throwIf_ (/= 0)
