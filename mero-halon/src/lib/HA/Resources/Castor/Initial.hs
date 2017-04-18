{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData        #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE ViewPatterns      #-}
-- |
-- Module    : HA.Resources.Castor.Initial
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Initial resource load for Castor cluster.
-- This module should be imported qualified.

module HA.Resources.Castor.Initial where

import           Control.Monad (forM)
import           Data.Data
import           Data.Either (partitionEithers)
import qualified Data.HashMap.Lazy as M
import qualified Data.HashMap.Strict as HM
import           Data.Hashable (Hashable)
import qualified Data.Hashable as H
import           Data.List (find, intercalate, nub)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as T (toStrict)
import           Data.Word (Word32, Word64)
import qualified Data.Yaml as Y
import           GHC.Generics (Generic)
import qualified HA.Aeson as A
import           HA.Resources.TH
import           HA.SafeCopy
import           Mero.ConfC (ServiceParams, ServiceType)
import           SSPL.Bindings.Instances () -- HashMap
import qualified Text.EDE as EDE

-- | Halon-specific settings for the 'Host'.
data HalonSettings = HalonSettings
  { _hs_address :: String
  -- ^ Address on which Halon should listen on, including port. e.g.
  -- @10.0.2.15:9000@.
  , _hs_roles :: [RoleSpec]
  -- ^ List of halon roles for this host. Valid values are determined
  -- by the halon roles files passed to 'parseInitialData'.
  } deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable HalonSettings

-- | JSON parser options for 'HalonSettings'.
halonSettingsOptions :: A.Options
halonSettingsOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_hs_" :: String)) }

instance A.FromJSON HalonSettings where
  parseJSON = A.genericParseJSON halonSettingsOptions

instance A.ToJSON HalonSettings where
  toJSON = A.genericToJSON halonSettingsOptions

-- | Information about a mero host.
data Host = Host
  { h_fqdn :: !T.Text
  -- ^ Fully-qualified domain name.
  , h_halon :: !(Maybe HalonSettings)
  -- ^ Halon settings, if any. Note that if unset, the node is ignored
  -- during @hctl bootstrap cluster@ command. This does not imply that
  -- the host is not loaded as part of the initial data.
} deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable Host
instance A.FromJSON Host
instance A.ToJSON Host

-- | Information about @BMC@ interface, used to commands to the
-- hardware.
data BMC = BMC
  { bmc_addr :: String
  -- ^ Address of the interface.
  , bmc_user :: String
  -- ^ Username
  , bmc_pass :: String
  -- ^ Password
} deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable BMC
instance A.FromJSON BMC
instance A.ToJSON BMC

-- | Information about enclosures.
data Enclosure = Enclosure
  { enc_idx :: Int
  -- ^ Enclosure index
  , enc_id :: String
  -- ^ Enclosure name
  , enc_bmc :: [BMC]
  -- ^ List of 'BMC' interfaces.
  , enc_hosts :: [Host]
  -- ^ List of 'Host's in the enclosure.
} deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable Enclosure
instance A.FromJSON Enclosure
instance A.ToJSON Enclosure

-- | Rack information
data Rack = Rack
  { rack_idx :: Int
  -- ^ Rack index
  , rack_enclosures :: [Enclosure]
  -- ^ List of 'Enclosure's in the index.
  } deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable Rack
instance A.FromJSON Rack
instance A.ToJSON Rack


-- | Failure set schemes. Define how failure sets are determined.
--
-- TODO: Link to some doc here.
data FailureSetScheme =
    Preloaded Word32 Word32 Word32
  | Formulaic [[Word32]]
  deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable FailureSetScheme
instance A.FromJSON FailureSetScheme
instance A.ToJSON FailureSetScheme

-- | Halon config for a host
data HalonRole = HalonRole
  { _hc_name :: RoleName
  -- ^ Role name
  , _hc_h_bootstrap_station :: Bool
  -- ^ Does this role make the host a tracking station?
  , _hc_h_services :: [String]
  -- ^ Commands starting the services for this role. For example, a
  -- role for the CMU that requires @halon:SSPL@ and @halon:SSPL-HL@
  -- could define its services as follows:
  --
  -- @
  -- - "sspl-hl start -u sspluser -p sspl4ever"
  -- - "sspl start -u sspluser -p sspl4ever"
  -- @
  } deriving (Show, Eq, Data, Ord, Generic, Typeable)

instance Hashable HalonRole

-- | Options for the 'HalonRole' JSON parser.
halonConfigOptions :: A.Options
halonConfigOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_hc_" :: String)) }

instance A.FromJSON HalonRole where
  parseJSON = A.genericParseJSON halonConfigOptions

instance A.ToJSON HalonRole where
  toJSON = A.genericToJSON halonConfigOptions

-- | Facts about the cluster.
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

instance Hashable M0Globals
instance A.FromJSON M0Globals
instance A.ToJSON M0Globals

-- | Devices attached to a 'M0Host'
data M0Device = M0Device {
    m0d_wwn :: String -- ^ World Wide Name of the device
  , m0d_serial :: String -- ^ Serial number of the device
  , m0d_bsize :: Word32 -- ^ Block size
  , m0d_size :: Word64 -- ^ Size of disk (in MB)
  , m0d_path :: String -- ^ Path to the device (e.g. /dev/disk...)
  , m0d_slot :: Int -- ^ Slot within the enclosure the device is in
} deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable M0Device
instance A.FromJSON M0Device
instance A.ToJSON M0Device

-- | Represents an aggregation of three Mero concepts, which we don't
-- necessarily need for the castor implementation - nodes,
-- controllers, and processes.
data M0Host = M0Host
  { m0h_fqdn :: !T.Text
  -- ^ Fully qualified domain name of host this server is running on
  , m0h_processes :: ![M0Process]
  -- ^ Processes that should run on the host.
  , m0h_devices :: ![M0Device]
  -- ^ Information about devices attached to the host.
} deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable M0Host
instance A.FromJSON M0Host
instance A.ToJSON M0Host

data M0ProcessType =
    PLM0t1fs -- ^ Process lives as part of m0t1fs in kernel space
  | PLClovis String Bool -- ^ Process lives as part of a Clovis client, with
                         --   given name. If the second parameter is set to
                         --   'True', then the process is independently
                         --   controlled and should not be started/stopped
                         --   by Halon.
  | PLM0d Word64  -- ^ Process runs in m0d at the given boot level.
                  --   Currently 0 = confd, 1 = other
  | PLHalon  -- ^ Process lives inside Halon program space.
  deriving (Eq, Data, Show, Typeable, Generic)
instance Hashable M0ProcessType
instance A.FromJSON M0ProcessType
instance A.ToJSON M0ProcessType

-- | Mero process environment. Values of this type become additional Environment
--   variables in the sysconfig file for this process.
data M0ProcessEnv =
    -- | A simple value, passed directly to the file.
    M0PEnvValue String
    -- | A unique range within the node. Each process shall be given a unique
    --   value within this range for the given environment key.
  | M0PEnvRange Int Int
  deriving (Eq, Data, Show, Typeable, Generic)
instance Hashable M0ProcessEnv
instance A.FromJSON M0ProcessEnv
instance A.ToJSON M0ProcessEnv

-- | Information about mero process on the host
data M0Process = M0Process
  { m0p_endpoint :: String
  -- ^ Endpoint the process should listen on
  , m0p_mem_as :: Word64
  , m0p_mem_rss :: Word64
  , m0p_mem_stack :: Word64
  , m0p_mem_memlock :: Word64
  , m0p_cores :: [Word64]
  -- ^ Treated as a bitmap of length (@no_cpu@) indicating which CPUs to use
  , m0p_services :: [M0Service]
  -- ^ List of services this process should run.
  , m0p_boot_level :: M0ProcessType
  -- ^ Type of process, governing how it should run.
  , m0p_environment :: Maybe [(String, M0ProcessEnv)]
  -- ^ Process environment - additional
} deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable M0Process
instance A.FromJSON M0Process
instance A.ToJSON M0Process

-- | Information about a service
data M0Service = M0Service {
    m0s_type :: ServiceType -- ^ e.g. ioservice, haservice
  , m0s_endpoints :: [String]
  -- ^ Listen endpoints for the service itself.
  , m0s_params :: ServiceParams
  , m0s_pathfilter :: Maybe String -- ^ For IOS, filter on disk WWN
} deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable M0Service
instance A.FromJSON M0Service
instance A.ToJSON M0Service


-- | Parsed initial data that halon buids its initial knowledge base
-- about the cluster from.
data InitialData = InitialData {
    id_racks :: [Rack]
  , id_m0_servers :: [M0Host]
  , id_m0_globals :: M0Globals
} deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable InitialData
instance A.FromJSON InitialData
instance A.ToJSON InitialData

-- | Handy synonym for role names
type RoleName = String

-- | Specification for mero roles. Mero roles are user-defined (or
-- provider defined). This determines which role to look-up and reify
-- as well as any overrides to the environment.
data RoleSpec = RoleSpec
  { _rolespec_name :: RoleName
  -- ^ Role name. Valid values depend on the mero roles passed to
  -- 'parseInitialData'.
  , _rolespec_overrides :: Maybe Y.Object
  -- ^ Any user-provided environment for this role. If present, this
  -- environment is unified (with precedence) with default environment
  -- (rest of the facts) in call to 'EDE.render': this allows the user
  -- to override values from the rest of the facts in case we want to
  -- tweak an existing role.
  } deriving (Eq, Data, Generic, Show, Typeable)

-- | Options for 'RoleSpec' JSON parser.
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

{-
-- TODO: We lose overrides here but we don't care about these in first
-- place. We should do something like we have with 'UnexpandedHost' if
-- we do care about it persisting through serialisation. This is
-- short-term for purposes of bootstrap cluster command.
instance Binary RoleSpec where
  put (RoleSpec a _) = B.put a
  get = RoleSpec <$> B.get <*> pure Nothing
-}

-- | A single parsed mero role, ready to be used for building
-- 'InitialData'.
data Role = Role
  { _role_name :: RoleName
  , _role_content :: [M0Process]
  } deriving (Eq, Data, Generic, Show, Typeable)

-- | Options for the 'Role' JSON parser.
roleJSONOptions :: A.Options
roleJSONOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_role_" :: String)) }

instance A.FromJSON Role where
  parseJSON = A.genericParseJSON roleJSONOptions

instance A.ToJSON Role where
  toJSON = A.genericToJSON roleJSONOptions

-- | Parse a halon_facts file into a structure indicating roles for
-- each given host.
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
  { _uhost_m0h_fqdn :: !T.Text
  , _uhost_m0h_roles :: ![RoleSpec]
  , _uhost_m0h_devices :: ![M0Device]
  } deriving (Eq, Data, Generic, Show, Typeable)

-- | Options for 'UnexpandedHost' JSON parser.
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

-- | Expand a role from the given template and env.
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

-- | Entry point into 'InitialData' parsing.
parseInitialData :: FilePath -- ^ Halon facts
                 -> FilePath -- ^ Role map file
                 -> FilePath -- ^ Halon role map file
                 -> IO (Either Y.ParseException (InitialData, EDE.Template))

parseInitialData facts maps halonMaps = Y.decodeFileEither facts >>= \case
  Left err -> return $ Left err
  Right initialWithRoles -> EDE.eitherResult <$> EDE.parseFile halonMaps >>= \case
    Left err -> return $ mkExc err
    Right obj -> resolveRoles initialWithRoles maps >>= \case
      Left err -> return $ Left err
      Right initialD -> return $ case validateData initialD of
        Left err -> Left $ Y.AesonException err
        Right initialD' -> Right (initialD', obj)
  where
    validateData :: InitialData -> Either String InitialData
    validateData idata =
      let encs = [ (r, rack_enclosures r) | r <- id_racks idata ]
          ns = enc_id <$> (encs >>= snd)

          check True _ = return idata
          check False m = Left m
      in check ( all (\(fmap enc_idx -> idx)
                        -> (length (nub idx) == length idx)
                        )
                      (snd <$> encs)
                )
               "Enclosures with non-unique enc_idx exist inside a rack."
         >> check (null ns || any (not . null) ns)
                  "Enclosure without enc_id specified."
         >> check (length ns == length (nub ns))
                  "Enclosures with non-unique enc_id exist."

deriveSafeCopy 0 'base ''FailureSetScheme
storageIndex           ''FailureSetScheme "3ad171f9-2691-4554-bef7-e6997d2698f1"
deriveSafeCopy 0 'base ''M0Device
storageIndex           ''M0Device "cf6ea1f5-1d1c-4807-915e-5df1396fc764"
deriveSafeCopy 0 'base ''M0Globals
storageIndex           ''M0Globals "4978783e-e7ff-48fe-ab83-85759d822622"
deriveSafeCopy 0 'base ''M0Host
deriveSafeCopy 0 'base ''M0ProcessEnv
deriveSafeCopy 0 'base ''M0ProcessType
deriveSafeCopy 0 'base ''M0Process
deriveSafeCopy 0 'base ''M0Service
deriveSafeCopy 0 'base ''BMC
storageIndex           ''BMC "22641893-9206-48ab-b4be-b2846acf5843"
deriveSafeCopy 0 'base ''Enclosure
deriveSafeCopy 0 'base ''HalonSettings
deriveSafeCopy 0 'base ''Host
deriveSafeCopy 0 'base ''InitialData
deriveSafeCopy 0 'base ''Rack
storageIndex           ''Rack "fe43cf82-adcd-40b5-bf74-134902424229"
deriveSafeCopy 0 'base ''RoleSpec
storageIndex           ''RoleSpec "495818cc-ec20-4159-ab91-37fe449af3e0"
