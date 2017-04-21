{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData          #-}
{-# LANGUAGE TemplateHaskell     #-}
-- |
-- Module    : HA.Migrations
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Collection of persisted-state migrations.
module HA.Migrations
  ( migrateOrQuit
  , writeCurrentVersionFile
  ) where

import           Control.Applicative (liftA2, (<|>), Alternative(..))
import           Control.Distributed.Process
import           Control.Distributed.Process.Internal.Types
    (remoteTable, processNode)
import           Control.Distributed.Static (RemoteTable)
import qualified Control.Monad.Catch as C
import           Control.Monad.IO.Class (MonadIO)
import           Control.Monad.Reader (ask)
import           Data.Foldable (foldl')
import           Data.Maybe (listToMaybe)
import           Data.Monoid
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.Time.Clock
import           Data.Time.Format
import           Data.Version (parseVersion, versionBranch)
import           Filesystem.Path.CurrentOS (decodeString)
import           HA.Multimap
import qualified HA.RecoverySupervisor as RS
import           HA.Replicator.Log (replicasDir, storageDir)
import qualified HA.ResourceGraph as G
import           HA.ResourceGraph.GraphLike (toKeyValue)
import qualified HA.ResourceGraph.UGraph as U
import qualified HA.Resources as R
import qualified HA.Resources.Castor as Castor
import qualified HA.Resources.Castor.Old as CastorOld
import qualified HA.Resources.Mero as M0
import qualified HA.Services.SSPL.LL.Resources as SSPL
import qualified Shelly as Sh
import           System.Directory
    ( doesFileExist
    , doesDirectoryExist
    , createDirectoryIfMissing
    )
import           System.FilePath ((</>))
import           Text.ParserCombinators.ReadP
import           Text.Printf (printf)
import           Version (gitDescribe)

-- | @HalonVersion x y = version x.y@
data HalonVersion = HalonVersion
  { -- | @x in x.y@
    _hv_major :: !Int
    -- | @y in x.y@
  , _hv_minor :: !Int
  } deriving (Show, Eq, Ord)

pprHalonVersion :: HalonVersion -> String
pprHalonVersion (HalonVersion major minor) = printf "v%d.%d" major minor

data Migration = Migration
  { _m_versionFrom :: !HalonVersion
  , _m_versionTo :: !HalonVersion
  , _m_migration :: U.UGraph -> U.UGraph
  }

versionFile :: FilePath
versionFile = storageDir </> "version.txt"

-- | Write the current halon version to the version file. This is
-- needed when we don't have existing state but also after migration:
-- it's just always written out at start of RC, after graph creation.
writeCurrentVersionFile :: MonadIO m => m ()
writeCurrentVersionFile = liftIO $ writeFile versionFile gitDescribe

-- | Compare version of halon and persisted state and run migration if
-- necessary. If versions don't differ just read in graph normally. If
-- versions differ:
--
-- * Backup old state
--
-- * Retrieve existing data from multimap as 'U.UGraph'
--
-- * Find and run a migration
--
-- * Try loading the data as 'G.Graph'
--
-- * If it works then return as 'G.Graph' and let RC initialisation
--   sync it.
--
-- * If it doesn't then quit. Note we don't change the state on
--   disk in this case.
--
-- * Leave the backup around "just in case" though we have
--   already verified we can load the graph.
--
-- If any step fails, throws 'RS.ReallyDie'.
migrateOrQuit :: StoreChan -> Process G.Graph
migrateOrQuit mm = do
  haveData <- liftIO $
    liftA2 (&&) (doesFileExist versionFile) (doesDirectoryExist replicasDir)
  if not haveData
  -- No state that we know of, just create storageDir if needed.
   then do
    liftIO $ createDirectoryIfMissing True storageDir
    G.getGraph mm
   else getVersions versionFile >>= \case
     Nothing -> do
       C.throwM . RS.ReallyDie . T.pack $! Prelude.unlines
         [ "Error when parsing versions."
         , "Halon version: " <> gitDescribe
         , "State version file: " <> versionFile ]
     Just (Exact ver) -> do
       liftIO . putStrLn $ printf "Loading existing version %s data." ver
       G.getGraph mm
     Just (Numeric dataVer halonVer)
       | dataVer == halonVer -> do
           liftIO . putStrLn $ printf "Loading existing version %s data."
                                      (pprHalonVersion dataVer)
           G.getGraph mm
       | otherwise -> case buildMigration dataVer halonVer of
           Nothing -> do
             C.throwM . RS.ReallyDie . T.pack $
               printf "Can not find a migration path from %s to %s."
                      (pprHalonVersion dataVer)
                      (pprHalonVersion halonVer)
           Just m -> do
             t <- liftIO $
               formatTime defaultTimeLocale rfc822DateFormat <$> getCurrentTime
             let backupDir = storageDir <> "_" <> t
             Sh.shelly $ Sh.cp_r (decodeString storageDir)
                                 (decodeString backupDir)
             liftIO . putStrLn $ "Persistent state backed up to " <> backupDir
             rt <- fmap (remoteTable . processNode) ask
             storeVal@(mi, _) <- getStoreValue mm
             let ug = _m_migration m $! U.buildUGraph mm rt storeVal
             g <- return $! castGraph rt mi ug
             liftIO $ putStrLn "Persistent state migrated!"
             return g
  where
    castGraph :: RemoteTable -> MetaInfo -> U.UGraph -> G.Graph
    castGraph rt mi u = G.setChangeLog (U.getChangeLog u) $!
                        G.buildGraph mm rt (mi, toKeyValue $ U.getGraphValues u)

    verToHalonVer [(v, "")] = case versionBranch v of
      major : minor : _ -> Just $! HalonVersion major minor
      _ -> Nothing
    verToHalonVer _ = Nothing

    parseGitDescribe = fmap verToHalonVer . readP_to_S $ do
      v <- parseVersion
      skipSpaces
      eof
      return v

    getVersions :: MonadIO m => FilePath -> m (Maybe VersionMatch)
    getVersions vFile = liftIO $ do
      vtxt <- readFile vFile
      return $!
        if vtxt == gitDescribe
        then Just $! Exact vtxt
        else Numeric <$> parseGitDescribe vtxt <*> parseGitDescribe gitDescribe

data VersionMatch =
  Exact !String
  | Numeric !HalonVersion !HalonVersion
  deriving (Show, Eq)


-- | Compose two 'Migration's together if their versions line up.
mcomp :: Migration -> Migration -> Maybe Migration
mcomp (Migration fr' to' f') (Migration fr to'' f)
  -- Versions line up and increase.
  | to'' == fr', fr < to' = Just (Migration fr to' (f' . f))
  | otherwise = Nothing

migrations :: [Migration]
migrations = [teacakeToChelsea]

-- | Find a migration that takes us between the specified versions.
--
-- [perf]: Yes it's bad but it's total, can be updated any time and
-- never expect 'migrations' to be big.
buildMigration :: HalonVersion -- ^ Upgrading from
               -> HalonVersion -- ^ Upgrading to
               -> Maybe Migration
buildMigration from' to' = go migrations
  where
    isFinal m = _m_versionFrom m == from' && _m_versionTo m == to'

    go [] = Nothing
    go migs' = case filter isFinal migs' of
      -- We're not done, compose what we can and try again. Due to
      -- mcomp the list always gets smaller and doing it this way
      -- means we will always find a path if one exists.
      [] -> go [ m' | m <- migs', Just m' <- map (`mcomp` m) migs' ]
      final : _ -> Just final

teacakeVersion :: HalonVersion
teacakeVersion = HalonVersion 1 0

chelseaVersion :: HalonVersion
chelseaVersion = HalonVersion 1 1

data OldStorageDevice = OldStorageDevice
  { _osd_enclosure :: !(Maybe Castor.Enclosure)
  , _osd_sdev :: !CastorOld.StorageDevice
  , _osd_ids :: !(Set.Set CastorOld.DeviceIdentifier)
  , _osd_attrs :: !(Set.Set CastorOld.StorageDeviceAttr)
  } deriving (Show, Eq, Ord)

data NewStorageDevice dev = NewStorageDevice
  { -- | If the device is in a 'Castor.Slot', which one? If none, it's
    -- attached to 'R.Cluster' only.
    _nsd_slot :: !(Maybe Castor.Slot)
  , _nsd_dev :: !dev
  , _nsd_ids :: !(Set.Set Castor.DeviceIdentifier)
  , _nsd_oldDev :: !CastorOld.StorageDevice
  , _nsd_disk :: !(Maybe M0.Disk)
  , _nsd_replaced :: !Bool
  , _nsd_attrs :: !(Set.Set Castor.StorageDeviceAttr)
  , _nsd_removed :: !Bool
  } deriving (Show, Eq, Ord)

defaultNewStorageDevice :: Alternative m
                        => CastorOld.StorageDevice
                        -> NewStorageDevice (m Castor.StorageDevice)
defaultNewStorageDevice oldDev = NewStorageDevice
  { _nsd_slot = Nothing
  , _nsd_dev = empty
  , _nsd_ids = mempty
  , _nsd_oldDev = oldDev
  , _nsd_disk = Nothing
  , _nsd_replaced = False
  , _nsd_attrs = mempty
  , _nsd_removed = False
  }

writeNewStorageDevice :: NewStorageDevice Castor.StorageDevice
                      -> U.UGraph -> U.UGraph
writeNewStorageDevice NewStorageDevice{..} =
    connectCluster
  . connectSlot
  . connectIdentifiers
  . connectAttributes
  . collapseStorageDeviceStatus
  where
    -- All StorageDevices should be connected to Cluster element so
    -- even if we're temporarily removing them in hardware, we still
    -- can keep information about them.
    connectCluster = U.connect R.Cluster R.Has _nsd_dev

    -- Connect Slot out of inferred information. If the Disk is marked
    -- as replaced, give it the Replaced marker and do nothing else.
    -- If not, it must be in a Slot. Make the connection between the
    -- Slot and Enclosure, SDev, StorageDevice and LedControlState.
    connectSlot rg = maybe rg withSlot _nsd_slot
      where
        withSlot slot =
            U.connect (Castor.slotEnclosure slot) R.Has slot
          . connectStorageDevice
          . connectDisk
          . connectLed
          $ rg
          where
            -- Connect StorageDevice to slot unless it was marked as removed.
            connectStorageDevice rg'
              | not _nsd_removed = U.connect _nsd_dev R.Has slot rg'
              | otherwise = rg'

            -- If the StorageDevice has been marked as replaced
            -- through an identifier in the past, mark relevant Disk
            -- as Replaced.
            maybeMarkReplaced disk rg'
              | _nsd_replaced = U.connect disk Castor.Is M0.Replaced rg'
              | otherwise = rg'

            -- Connect SDev to Slot and mark associated Disk as
            -- Replaced if needed.
            connectDisk :: U.UGraph -> U.UGraph
            connectDisk rg' = maybe rg'
              (\disk -> let msdev :: Maybe M0.SDev
                            msdev = listToMaybe $ U.connectedFrom M0.IsOnHardware disk rg'
                        in maybeMarkReplaced disk
                           . U.connect disk M0.At _nsd_dev
                           $ maybe rg' (\sdev -> U.connect sdev M0.At slot rg') msdev
              ) _nsd_disk

            -- Led states are now connected to the slots directly
            -- rather that to drives.
            connectLed rg' = maybe rg' (\(led :: SSPL.LedControlState) -> U.connect slot R.Has led rg')
                                       (listToMaybe $ U.connectedTo _nsd_oldDev R.Has rg')

    -- Connect every device identifier to the new StorageDevice
    connectIdentifiers rg =
      foldl' (\g0 i -> U.connect _nsd_dev R.Has i g0) rg _nsd_ids

    -- Attach the update device to all the new attributes.
    connectAttributes rg =
      foldl' (\g0 attr -> U.connect _nsd_dev R.Has attr g0) rg _nsd_attrs

    -- Find all StorageDeviceStatus that exists in the old graph for
    -- the device and pick the first one as the authoritative one.
    collapseStorageDeviceStatus :: U.UGraph -> U.UGraph
    collapseStorageDeviceStatus rg =
      let oldStatus :: Maybe Castor.StorageDeviceStatus
          oldStatus = listToMaybe $ U.connectedTo _nsd_oldDev R.Has rg
                                 ++ U.connectedTo _nsd_oldDev Castor.Is rg
      in maybe rg (\st -> U.connect _nsd_dev Castor.Is st rg) oldStatus

teacakeToChelsea :: Migration
teacakeToChelsea = Migration teacakeVersion chelseaVersion $ \rg ->
  let storeDevs :: Set.Set (Maybe Castor.Enclosure, CastorOld.StorageDevice)
      storeDevs = Set.fromList $
        [ (Nothing, s) | h :: Castor.Host <- U.connectedTo R.Cluster R.Has rg
                       , s <- U.connectedTo h R.Has rg ]
        ++
        [ (Just enc, s) | r :: Castor.Rack <- U.connectedTo R.Cluster R.Has rg
                        , enc :: Castor.Enclosure <- U.connectedTo r R.Has rg
                        , s <- U.connectedTo enc R.Has rg ]
      stIds :: Set.Set OldStorageDevice
      stIds = Set.map (\(e, s) -> OldStorageDevice e s (ids s) (attrs s)) storeDevs
        where
          attrs s = Set.fromList $ U.connectedTo s R.Has rg
          ids s = Set.fromList $ U.connectedTo s R.Has rg ++ U.connectedTo s Castor.Is rg

      -- Apply updates resulting from old storage devs
      throughStoreDevs :: OldStorageDevice -> U.UGraph -> U.UGraph
      throughStoreDevs osd =

        let exInfo (CastorOld.DIPath v) = \x ->
              x { _nsd_ids = Set.insert (Castor.DIPath $ T.pack v) (_nsd_ids x) }
            exInfo (CastorOld.DIIndexInEnclosure v) = \x ->
              x { _nsd_slot = _nsd_slot x <|> maybe Nothing (\e -> Just $! Castor.Slot e v) (_osd_enclosure osd) }
            exInfo (CastorOld.DIWWN v) = \x ->
              x { _nsd_ids = Set.insert (Castor.DIWWN $ T.pack v) (_nsd_ids x) }
            exInfo (CastorOld.DIUUID v) = \x ->
              x { _nsd_ids = Set.insert (Castor.DIUUID $ T.pack v) (_nsd_ids x) }
            exInfo (CastorOld.DISerialNumber v) = \x ->
              x { _nsd_dev = _nsd_dev x <|> pure (Castor.StorageDevice $ T.pack v) }
            exInfo (CastorOld.DIRaidIdx v) = \x ->
              x { _nsd_ids = Set.insert (Castor.DIRaidIdx v) (_nsd_ids x) }
            exInfo (CastorOld.DIRaidDevice v) = \x ->
              x { _nsd_ids = Set.insert (Castor.DIRaidDevice $ T.pack v) (_nsd_ids x) }

            exAttr (CastorOld.SDResetAttempts v) = \x ->
              x { _nsd_attrs = Set.insert (Castor.SDResetAttempts v) (_nsd_attrs x) }
            exAttr (CastorOld.SDPowered v) = \x ->
              x { _nsd_attrs = Set.insert (Castor.SDPowered v) (_nsd_attrs x) }
            exAttr CastorOld.SDOnGoingReset = \x ->
              x { _nsd_attrs = Set.insert Castor.SDOnGoingReset (_nsd_attrs x) }
            exAttr CastorOld.SDRemovedAt = \x -> x { _nsd_removed = True }
            exAttr CastorOld.SDReplaced = \x -> x { _nsd_replaced = True }
            exAttr CastorOld.SDRemovedFromRAID = \x ->
              x { _nsd_attrs = Set.insert Castor.SDRemovedFromRAID (_nsd_attrs x) }

            extractedState :: NewStorageDevice (Maybe Castor.StorageDevice)
            extractedState =
                 (\acc -> foldl' (flip exAttr) acc (_osd_attrs osd))
               $ foldl' (flip exInfo) (defaultNewStorageDevice (_osd_sdev osd)) (_osd_ids osd)
        in case _nsd_dev extractedState of
          Just sdev -> writeNewStorageDevice (extractedState { _nsd_dev = sdev })
          Nothing -> id
  in foldl' (flip throughStoreDevs) rg stIds
