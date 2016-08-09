{-# LANGUAGE CPP                        #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TupleSections              #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Initial resource load for Castor cluster.
-- This module should be imported qualified.

module HA.Resources.Castor.Initial where

#ifdef USE_MERO
import Mero.ConfC (ServiceParams, ServiceType)
import Control.Monad (forM)
#endif

import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A
import Data.Binary (Binary)
import qualified Data.Binary as B
import Data.Data
import Data.Hashable (Hashable)

import qualified Data.Hashable as H
import qualified Data.HashMap.Strict as HM

import Data.Word
  ( Word32
#ifdef USE_MERO
  , Word64
#endif
  )

import GHC.Generics (Generic)

#ifdef USE_MERO
import           Data.Either (partitionEithers)
import qualified Data.HashMap.Lazy as M
import           Data.List (find, intercalate, nub)
import qualified Text.EDE as EDE
import qualified Data.Text as T (unpack)
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as T (toStrict)

#endif
import qualified Data.Yaml as Y

data Network = Data | Management | Local
  deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Network
instance Hashable Network
instance A.FromJSON Network
instance A.ToJSON Network

data Interface = Interface {
    if_macAddress :: String
  , if_network :: Network
  , if_ipAddrs :: [String]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Interface
instance Hashable Interface
instance A.FromJSON Interface
instance A.ToJSON Interface

data HalonSettings = HalonSettings
  { _hs_address :: String
  , _hs_roles :: [RoleSpec]
  } deriving (Eq, Data, Generic, Show, Typeable)

instance Binary HalonSettings
instance Hashable HalonSettings

halonSettingsOptions :: A.Options
halonSettingsOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_hs_" :: String)) }

instance A.FromJSON HalonSettings where
  parseJSON = A.genericParseJSON halonSettingsOptions

instance A.ToJSON HalonSettings where
  toJSON = A.genericToJSON halonSettingsOptions

data Host = Host {
    h_fqdn :: String
  , h_interfaces :: [Interface]
  , h_memsize :: Word32 -- ^ Memory in MB
  , h_cpucount :: Word32 -- ^ Number of CPUs
  , h_halon :: Maybe HalonSettings
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Host
instance Hashable Host
instance A.FromJSON Host
instance A.ToJSON Host

data BMC = BMC {
    bmc_addr :: String
  , bmc_user :: String
  , bmc_pass :: String
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary BMC
instance Hashable BMC
instance A.FromJSON BMC
instance A.ToJSON BMC

data Enclosure = Enclosure {
    enc_idx :: Int
  , enc_id :: String
  , enc_bmc :: [BMC]
  , enc_hosts :: [Host]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Enclosure
instance Hashable Enclosure
instance A.FromJSON Enclosure
instance A.ToJSON Enclosure

data Rack = Rack {
    rack_idx :: Int
  , rack_enclosures :: [Enclosure]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary Rack
instance Hashable Rack
instance A.FromJSON Rack
instance A.ToJSON Rack

#ifdef USE_MERO

data FailureSetScheme =
    Preloaded Word32 Word32 Word32
  | Dynamic
  | Formulaic [[Word32]]
  deriving (Eq, Data, Generic, Show, Typeable)

instance Binary FailureSetScheme
instance Hashable FailureSetScheme
instance A.FromJSON FailureSetScheme
instance A.ToJSON FailureSetScheme

-- | Halon config for a host
data HalonRole = HalonRole
  { _hc_name :: String -- ^ Role name
  , _hc_h_bootstrap_station :: Bool
  , _hc_h_services :: [String]
    -- ^ List of strings starting appropriate services
  } deriving (Show, Eq, Data, Ord, Generic, Typeable)

instance Binary HalonRole
instance Hashable HalonRole

halonConfigOptions :: A.Options
halonConfigOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_hc_" :: String)) }

instance A.FromJSON HalonRole where
  parseJSON = A.genericParseJSON halonConfigOptions

instance A.ToJSON HalonRole where
  toJSON = A.genericToJSON halonConfigOptions

data M0Globals = M0Globals {
    m0_data_units :: Word32 -- ^ As in genders
  , m0_parity_units :: Word32  -- ^ As in genders
  , m0_md_redundancy :: Word32 -- ^ Metadata redundancy count
  , m0_failure_set_gen :: FailureSetScheme
  , m0_be_ios_seg_size :: Maybe Word64
  , m0_be_log_size :: Maybe Word64
  , m0_be_seg_size :: Maybe Word64
  , m0_be_tx_payload_size_max :: Maybe Word64
  , m0_be_tx_reg_nr_max :: Maybe Word32
  , m0_be_tx_reg_size_max :: Maybe Word32
  , m0_be_txgr_freeze_timeout_max :: Maybe Word64
  , m0_be_txgr_freeze_timeout_min :: Maybe Word64
  , m0_be_txgr_payload_size_max :: Maybe Word64
  , m0_be_txgr_reg_nr_max :: Maybe Word64
  , m0_be_txgr_reg_size_max :: Maybe Word64
  , m0_be_txgr_tx_nr_max :: Maybe Word32
  , m0_block_size :: Maybe Word32
  , m0_min_rpc_recvq_len :: Maybe Word32
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Globals
instance Hashable M0Globals
instance A.FromJSON M0Globals
instance A.ToJSON M0Globals

data M0Device = M0Device {
    m0d_wwn :: String
  , m0d_serial :: String
  , m0d_bsize :: Word32 -- ^ Block size
  , m0d_size :: Word64 -- ^ Size of disk (in MB)
  , m0d_path :: String -- ^ Path to the device (e.g. /dev/disk...)
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Device
instance Hashable M0Device
instance A.FromJSON M0Device
instance A.ToJSON M0Device

-- | Represents an aggregation of three Mero concepts, which we don't
--   necessarily need for the castor implementation - nodes, controllers, and
--   processes.
data M0Host = M0Host {
    m0h_fqdn :: String -- ^ FQDN of host this server is running on
  , m0h_processes :: [M0Process]
  , m0h_devices :: [M0Device]
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Host
instance Hashable M0Host
instance A.FromJSON M0Host
instance A.ToJSON M0Host

data M0Process = M0Process {
    m0p_endpoint :: String
  , m0p_mem_as :: Word64
  , m0p_mem_rss :: Word64
  , m0p_mem_stack :: Word64
  , m0p_mem_memlock :: Word64
  , m0p_cores :: [Word64]
    -- ^ Treated as a bitmap of length (no_cpu) indicating which CPUs to use
  , m0p_services :: [M0Service]
  , m0p_boot_level :: Word64
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Process
instance Hashable M0Process
instance A.FromJSON M0Process
instance A.ToJSON M0Process

data M0Service = M0Service {
    m0s_type :: ServiceType -- ^ e.g. ioservice, haservice
  , m0s_endpoints :: [String]
  , m0s_params :: ServiceParams
  , m0s_pathfilter :: Maybe String -- ^ For IOS, filter on disk WWN
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary M0Service
instance Hashable M0Service
instance A.FromJSON M0Service
instance A.ToJSON M0Service

#endif

data InitialData = InitialData {
    id_racks :: [Rack]
#ifdef USE_MERO
  , id_m0_servers :: [M0Host]
  , id_m0_globals :: M0Globals
#endif
} deriving (Eq, Data, Generic, Show, Typeable)

instance Binary InitialData
instance Hashable InitialData
instance A.FromJSON InitialData
instance A.ToJSON InitialData

-- | Handy synonym for role names
type RoleName = String

-- | Used as list of roles in halon_facts: the user can optionally
-- give a map overriding the environment in which the template file is
-- expanded.
data RoleSpec = RoleSpec
  { _rolespec_name :: RoleName
  , _rolespec_overrides :: Maybe Y.Object
  } deriving (Eq, Data, Generic, Show, Typeable)

rolespecJSONOptions :: A.Options
rolespecJSONOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_rolespec_" :: String))
  , A.omitNothingFields = True
  }

instance A.FromJSON RoleSpec where
  parseJSON = A.genericParseJSON rolespecJSONOptions

instance A.ToJSON RoleSpec where
  toJSON = A.genericToJSON rolespecJSONOptions

instance Hashable RoleSpec where
  hashWithSalt s (RoleSpec a v) = s `H.hashWithSalt` a `H.hashWithSalt` fmap HM.toList v

-- TODO: We lose overrides here but we don't care about these in first
-- place. We should do something like we have with 'UnexpandedHost' if
-- we do care about it persisting through serialisation. This is
-- short-term for purposes of bootstrap cluster command.
instance Binary RoleSpec where
  put (RoleSpec a _) = B.put a
  get = RoleSpec <$> B.get <*> pure Nothing

#ifdef USE_MERO

-- | A single parsed role, ready to be used for building 'InitialData'
data Role = Role
  { _role_name :: RoleName
  , _role_content :: [M0Process]
  } deriving (Eq, Data, Generic, Show, Typeable)

roleJSONOptions :: A.Options
roleJSONOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_role_" :: String)) }

instance A.FromJSON Role where
  parseJSON = A.genericParseJSON roleJSONOptions

instance A.ToJSON Role where
  toJSON = A.genericToJSON roleJSONOptions

-- | Parse a halon_facts file into a structure indicating roles for
-- each given host
data InitialWithRoles = InitialWithRoles
  { _rolesinit_id_racks :: [Rack]
  , _rolesinit_id_m0_servers :: [(UnexpandedHost, Y.Object)]
    -- ^ The list of unexpanded host as well as the full object that
    -- the host was parsed out from, used as environment given during
    -- template expansion.
  , _rolesinit_id_m0_globals :: M0Globals
  } deriving (Eq, Data, Generic, Show, Typeable)

instance A.FromJSON InitialWithRoles where
  parseJSON (A.Object v) = InitialWithRoles <$>
                           v A..: "id_racks" <*>
                           parseServers <*>
                           v A..: "id_m0_globals"

    where
      parseServers :: A.Parser [(UnexpandedHost, Y.Object)]
      parseServers = do
        objs <- v A..: "id_m0_servers"
        forM objs $ \obj -> (,obj) <$> A.parseJSON (A.Object obj)

  parseJSON invalid = A.typeMismatch "InitialWithRoles" invalid


instance A.ToJSON InitialWithRoles where
  toJSON InitialWithRoles{..} = A.object
    [ "id_racks" A..= _rolesinit_id_racks
    -- Dump out the full object into the file rather than our parsed
    -- and trimmed structure. This means we won't lose any information
    -- with @fromJSON . toJSON@
    , "id_m0_servers" A..= map snd _rolesinit_id_m0_servers
    , "id_m0_globals" A..= _rolesinit_id_m0_globals
    ]


-- | Hosts section of halon_facts
--
-- XXX: Perhaps we shouldn't have this structure or part of this
-- structure and simply use 'Y.Object'. That will allow us to easily
-- let the user specify any fields they want, including the ones we
-- don't have present and use them in their roles, without updating
-- the source here.
data UnexpandedHost = UnexpandedHost
  { _uhost_m0h_fqdn :: String
  , _uhost_m0h_roles :: [RoleSpec]
  , _uhost_m0h_devices :: [M0Device]
  } deriving (Eq, Data, Generic, Show, Typeable)

unexpandedHostJSONOptions :: A.Options
unexpandedHostJSONOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_uhost_" :: String)) }

instance A.FromJSON UnexpandedHost where
  parseJSON = A.genericParseJSON unexpandedHostJSONOptions

instance A.ToJSON UnexpandedHost where
  toJSON = A.genericToJSON unexpandedHostJSONOptions

-- | Having parsed the facts file, expand the roles for each host to
-- provide full 'InitialData'.
resolveRoles :: InitialWithRoles -- ^ Parsed contents of halon_facts
             -> FilePath -- ^ Role map file
             -> IO (Either Y.ParseException InitialData)
resolveRoles InitialWithRoles{..} cf = EDE.eitherResult <$> EDE.parseFile cf >>= \case
  Left err -> return $ mkExc err
  Right template ->
    let procRoles uh env = mkProc template env <$> _uhost_m0h_roles uh
        allHosts :: [Either [String] M0Host]
        allHosts = flip map _rolesinit_id_m0_servers $ \(uh, env) ->
                     case partitionEithers $ procRoles uh env of
                       ([], procs) -> Right $ mkHost uh (concat procs)
                       (errs, _) -> Left errs
    in case partitionEithers allHosts of
      ([], hosts) -> return $ Right $
        InitialData { id_racks = _rolesinit_id_racks
                    , id_m0_servers = hosts
                    , id_m0_globals = _rolesinit_id_m0_globals
                    }
      (errs, _) -> return . mkExc . intercalate ", " $ concat errs
  where
    mkProc :: EDE.Template -> Y.Object -> RoleSpec -> Either String [M0Process]
    mkProc template env role =
      mkRole template env role $ findRoleProcess (_rolespec_name role)

    mkHost :: UnexpandedHost -> [M0Process] -> M0Host
    mkHost uh procs = M0Host { m0h_fqdn = _uhost_m0h_fqdn uh
                             , m0h_processes = procs
                             , m0h_devices = _uhost_m0h_devices uh
                             }
    findRoleProcess :: RoleName -> [Role] -> Either String [M0Process]
    findRoleProcess rn roles = case find (\r -> _role_name r == rn) roles of
      Nothing ->
        Left $ "resolveRoles: role " ++ show rn ++ " not found in map file"
      Just r -> Right $ _role_content r

-- | Helper for exception creation
mkExc :: String -> Either Y.ParseException a
mkExc = Left . Y.AesonException . ("resolveRoles: " ++)

mkRole :: A.FromJSON a
       => EDE.Template -- ^ Role template
       -> Y.Object -- ^ Surrounding env
       -> RoleSpec -- ^ Role to expand
       -> (a -> Either String b) -- ^ Role post-process
       -> Either String b
mkRole template env role f = case EDE.eitherResult $ EDE.render template env' of
  Left err -> Left $ err
  Right roleText -> case Y.decodeEither . T.encodeUtf8 $ T.toStrict roleText of
    Left err -> Left $ err ++ "\n" ++ T.unpack (T.toStrict (roleText))
    Right roles -> f roles
  where
    env' = maybe env (`M.union` env) (_rolespec_overrides role)

-- | Expand all given 'RoleSpec's into 'HalonRole's.
mkHalonRoles :: EDE.Template -- ^ Role template
             -> [RoleSpec] -- ^ Roles to expand
             -> Either String [HalonRole]
mkHalonRoles template roles =
  fmap (nub . concat) . forM roles $ \role ->
    mkRole template mempty role (findRole role)
  where
    findRole :: RoleSpec -> [HalonRole] -> Either String [HalonRole]
    findRole role xs = case find ((_rolespec_name role ==) . _hc_name) xs of
      Nothing -> Left $ "No matching role "
                      ++ show role
                      ++ " found in mapping file."
      Just a -> Right [a]
#endif

-- | Entry point into 'InitialData' parsing.
parseInitialData :: FilePath -- ^ Halon facts
                 -> FilePath -- ^ Role map file
                 -> FilePath -- ^ Halon role map file
#ifdef USE_MERO
                 -> IO (Either Y.ParseException (InitialData, EDE.Template))
#else
                 -> IO (Either Y.ParseException (InitialData, ()))
#endif
#ifdef USE_MERO
parseInitialData facts maps halonMaps = Y.decodeFileEither facts >>= \case
  Left err -> return $ Left err
  Right initialWithRoles -> EDE.eitherResult <$> EDE.parseFile halonMaps >>= \case
    Left err -> return $ mkExc err
    Right obj -> do
      initialD <- resolveRoles initialWithRoles maps
      return $ (,) <$> initialD <*> pure obj
#else
parseInitialData facts _ _ = fmap (\x -> (x, ())) <$> Y.decodeFileEither facts
#endif
