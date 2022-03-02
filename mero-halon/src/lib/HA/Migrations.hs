{-# LANGUAGE LambdaCase #-}
-- |
-- Module    : HA.Migrations
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Collection of persisted-state migrations.
module HA.Migrations
  ( migrateOrQuit
  , writeCurrentVersionFile
  ) where

import           Control.Applicative (liftA2)
import           Control.Distributed.Process
import           Control.Distributed.Process.Internal.Types
    (remoteTable, processNode)
import           Control.Distributed.Static (RemoteTable)
import qualified Control.Monad.Catch as C
import           Control.Monad.IO.Class (MonadIO)
import           Control.Monad.Reader (ask)
import           Data.Monoid
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
mcomp (Migration fr' to' f') (Migration fr to f)
  -- Versions line up and increase.
  | to == fr', fr < to' = Just (Migration fr to' (f' . f))
  | otherwise = Nothing

migrations :: [Migration]
migrations = []

-- | Find a migration that takes us between the specified versions.
--
-- [perf]: Yes it's bad but it's total, can be updated any time and
-- never expect migrations to be big.
buildMigration :: HalonVersion -- ^ Upgrading from
               -> HalonVersion -- ^ Upgrading to
               -> Maybe Migration
buildMigration from to = go migrations
  where
    isFinal m = _m_versionFrom m == from && _m_versionTo m == to

    go [] = Nothing
    go migs' = case filter isFinal migs' of
      -- We're not done, compose what we can and try again. Due to
      -- mcomp the list always gets smaller and doing it this way
      -- means we will always find a path if one exists.
      [] -> go $ [ m' | m <- migs', Just m' <- map (`mcomp` m) migs' ]
      final : _ -> Just final
