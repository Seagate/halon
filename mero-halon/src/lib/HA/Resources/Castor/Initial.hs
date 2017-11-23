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
import           Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import           Data.Bifunctor (first)
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
import           Text.Printf (printf)
import qualified HA.Aeson as A
import           HA.Resources.TH
import           HA.SafeCopy (base, deriveSafeCopy)
import           Mero.ConfC (PDClustAttr, ServiceParams, ServiceType)
import           Mero.Lnet (Endpoint)
import           SSPL.Bindings.Instances () -- HashMap
import qualified Text.EDE as EDE

-- | Parsed initial data that Halon buids its initial knowledge base
-- about the cluster from.
data InitialData = InitialData
  { _id_profiles :: [Profile]
  , _id_racks :: [Rack]
  , _id_nodes :: [Node]
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable InitialData

initialDataOptions :: A.Options
initialDataOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_id_" :: String)) }

instance A.FromJSON InitialData where
    parseJSON = A.genericParseJSON initialDataOptions

instance A.ToJSON InitialData where
    toJSON = A.genericToJSON initialDataOptions

data Profile = Profile
  { prof_id :: T.Text
  , prof_md_redundancy :: Word32
  , prof_pools :: [Pool]
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable Profile
instance A.FromJSON Profile
instance A.ToJSON Profile

-- | Information about Mero pool.
data Pool = Pool
  { pool_id :: T.Text -- ^ Unique name of pool.
  , pool_pdclust_attr :: PDClustAttr -- ^ Parity de-clustering attributes.
  , pool_vers_gen :: PoolVersGen -- ^ Pool version generator settings.
  , pool_ver_policy :: Word32 -- ^ Policy to be used for pool version selection.
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable Pool
instance A.FromJSON Pool
instance A.ToJSON Pool

-- | Defines how pool versions are generated.
data PoolVersGen =
    Preloaded Word32 Word32 Word32
  | Formulaic [[Word32]]
  deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable PoolVersGen
instance A.FromJSON PoolVersGen
instance A.ToJSON PoolVersGen

data Rack = Rack {
    rack_idx :: Integer
  , rack_enclosures :: [Enclosure]
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable Rack
instance A.FromJSON Rack
instance A.ToJSON Rack

data Enclosure = Enclosure
  { enc_idx :: Int
  , enc_id :: T.Text
  , enc_bmc :: [BMC]
  , enc_controllers :: [Controller]
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable Enclosure
instance A.FromJSON Enclosure
instance A.ToJSON Enclosure

-- | Information about Baseboard Management Controller interface,
-- used to send commands to the hardware.
--
-- See <https://en.wikipedia.org/wiki/Intelligent_Platform_Management_Interface>.
data BMC = BMC
  { bmc_addr :: String -- ^ Address of the interface.
  , bmc_user :: String -- ^ Username.
  , bmc_pass :: String -- ^ Password.
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable BMC
instance A.FromJSON BMC
instance A.ToJSON BMC

-- | Controller information.
data Controller = Controller
  { c_fqdn :: T.Text -- ^ Fully-qualified domain name.
  , c_memsize :: Word32 -- ^ Memory size in MB.
  , c_cpucount :: Word32 -- ^ Number of processors.
  , c_disks :: [Disk] -- ^ Disks attached to this controller.
  , c_halon :: Maybe HalonSettings -- XXX Why 'Maybe'?
  -- ^ Halon settings, if any.  Note that if unset, the node is ignored
  -- during @hctl bootstrap cluster@ command. This does not imply that
  -- the controller is not loaded as part of the initial data.
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable Controller
instance A.FromJSON Controller
instance A.ToJSON Controller

-- | Disk information.
data Disk = Disk
  { d_wwn :: T.Text -- ^ World Wide Name.
  , d_serial :: T.Text -- ^ Serial number.
  , d_bsize :: Word32 -- ^ Block size in bytes.
  , d_size :: Word64 -- ^ Size in bytes.
  , d_path :: T.Text -- ^ File name in host OS (e.g. "/dev/disk/...").
  , d_slot :: Int -- ^ Slot within the enclosure the disk is in.
  , d_pool :: T.Text -- ^ Name of the pool this disk belongs to.
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable Disk
instance A.FromJSON Disk
instance A.ToJSON Disk

data Node = Node
  { n_fqdn :: T.Text -- ^ Fully qualified domain name.
  , n_processes :: [Process] -- ^ Processes that should run on this node.
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable Node
instance A.FromJSON Node
instance A.ToJSON Node

-- | Information about Mero process.
data Process = Process
  { p_endpoint :: Endpoint
  -- ^ Endpoint the process should listen on.
  , p_mem_as :: Word64
  , p_mem_rss :: Word64
  , p_mem_stack :: Word64
  , p_mem_memlock :: Word64
  , p_cores :: [Word64]
  -- ^ Treated as a bitmap of length (@no_cpu@) indicating which CPUs to use.
  , p_services :: [Service]
  -- ^ List of services this process should run.
  , p_boot_level :: ProcessType
  -- ^ Type of process, governing how it should run.
  , p_environment :: Maybe [(String, ProcessEnv)]
  -- ^ Process environment - additional.
  , p_multiplicity :: Maybe Int
  -- ^ Process multiplicity - how many instances of this process
  -- should be started?
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable Process
instance A.FromJSON Process
instance A.ToJSON Process

data ProcessType =
    PTM0t1fs -- ^ Process lives as part of m0t1fs in kernel space.
  | PTClovis String Bool -- ^ Process lives as part of a Clovis client, with
                         -- given name. If the second parameter is set to
                         -- 'True', then the process is independently
                         -- controlled and should not be started/stopped
                         -- by Halon.
  | PTM0d Word64 -- ^ Process runs in m0d at the given boot level.
                 -- Currently 0 = confd, 1 = other.
  | PTHalon  -- ^ Process lives inside Halon program space.
  deriving (Data, Eq, Show, Typeable, Generic)

instance Hashable ProcessType
instance A.FromJSON ProcessType
instance A.ToJSON ProcessType

-- | Mero process environment.
--
-- Values of this type become additional environment variables in the
-- sysconfig file for this process.
data ProcessEnv =
    -- | A simple value, passed directly to the file.
    PEnvValue String
    -- | A unique range within the node.  Each process shall be given
    -- a unique value within this range for the given environment key.
  | PEnvRange Int Int
  deriving (Data, Eq, Show, Typeable, Generic)

instance Hashable ProcessEnv
instance A.FromJSON ProcessEnv
instance A.ToJSON ProcessEnv

-- | Information about a service.
data Service = Service
  { s_type :: ServiceType -- ^ E.g. IOS, HA service.
  , s_endpoints :: [Endpoint] -- ^ Listen endpoints for the service itself.
  , s_params :: ServiceParams
  , s_pathfilter :: Maybe String -- ^ For IOS, filter on disk WWN.
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable Service
instance A.FromJSON Service
instance A.ToJSON Service

-- | Halon-specific settings for the 'Controller'.
data HalonSettings = HalonSettings
  { halon_address :: String
  -- ^ Address on which Halon should listen on, including port
  -- (e.g. "10.0.2.15:9000").
  , halon_roles :: [RoleSpec]
  -- ^ List of halon roles for this controller.  Valid values are
  -- determined by the halon roles file passed to 'parseInitialData'.
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable HalonSettings
instance A.FromJSON HalonSettings
instance A.ToJSON HalonSettings

----------------------------------------------------------------------
-- Roles and their expansion
----------------------------------------------------------------------

-- | Handy synonym for role names.
type RoleName = String

-- | Specification for Mero or Halon role. Determines which role to
-- look-up and reify as well as any overrides to the environment.
-- Roles are user-defined (or provider defined).
data RoleSpec = RoleSpec
  { r_name :: RoleName
  -- ^ Role name. Valid values depend on the mero roles passed to
  -- 'parseInitialData'.
  , r_overrides :: Maybe Y.Object
  -- ^ Any user-provided environment for this role. If present, this
  -- environment is unified (with precedence) with default environment
  -- (rest of the facts) in call to 'EDE.render': this allows the user
  -- to override values from the rest of the facts in case we want to
  -- tweak an existing role.
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable RoleSpec where
  hashWithSalt s (RoleSpec a v) =
    s `H.hashWithSalt` a `H.hashWithSalt` fmap HM.toList v

instance A.FromJSON RoleSpec
instance A.ToJSON RoleSpec

-- | A single parsed mero role, ready to be used for building 'InitialData'.
data MeroRole = MeroRole
  { mr_name :: RoleName
  , mr_content :: [Process]
  } deriving (Data, Eq, Generic, Show, Typeable)

instance A.FromJSON MeroRole
instance A.ToJSON MeroRole

-- | Halon config for a host
data HalonRole = HalonRole
  { hr_name :: RoleName
  -- ^ Role name
  , hr_bootstrap_station :: Bool
  -- ^ Does this role make the host a tracking station?
  , hr_services :: [T.Text]
  -- ^ Commands starting the services for this role. For example, a
  -- role for the CMU that requires @halon:SSPL@ and @halon:SSPL-HL@
  -- could define its services as follows:
  --
  -- @
  -- - "sspl-hl start -u sspluser -p sspl4ever"
  -- - "sspl start -u sspluser -p sspl4ever"
  -- @
  } deriving (Show, Data, Eq, Ord, Generic, Typeable)

-- instance Hashable HalonRole
instance A.FromJSON HalonRole
instance A.ToJSON HalonRole

-- | Parse a halon_facts file into a structure indicating roles for
-- each given controller.
data InitialWithRoles = InitialWithRoles
  { _rolesinit_id_profiles :: [Profile]
  , _rolesinit_id_racks :: [Rack]
  , _rolesinit_id_nodes :: [(UnexpandedNode, Y.Object)]
    -- ^ The list of unexpanded host as well as the full object that
    -- the host was parsed out from, used as environment given during
    -- template expansion.
  } deriving (Data, Eq, Generic, Show, Typeable)

instance A.FromJSON InitialWithRoles where
  parseJSON (A.Object v) = InitialWithRoles <$>
                           v A..: "profiles" <*>
                           v A..: "racks" <*>
                           parseNodes
    where
      parseNodes :: A.Parser [(UnexpandedNode, Y.Object)]
      parseNodes = do
        objs <- v A..: "nodes"
        forM objs $ \obj -> (, obj) <$> A.parseJSON (A.Object obj)

  parseJSON invalid = A.typeMismatch "InitialWithRoles" invalid

instance A.ToJSON InitialWithRoles where
  toJSON InitialWithRoles{..} = A.object
    [ "profiles" A..= _rolesinit_id_profiles
    , "racks" A..= _rolesinit_id_racks
    -- Dump out the full object into the file rather than our parsed
    -- and trimmed structure. This means we won't lose any information
    -- with @fromJSON . toJSON@.
    , "nodes" A..= map snd _rolesinit_id_nodes
    ]

-- | "nodes" section of halon_facts.
--
-- XXX: Perhaps we shouldn't have this structure or part of this
-- structure and simply use 'Y.Object'. That will allow us to easily
-- let the user specify any fields they want, including the ones we
-- don't have present and use them in their roles, without updating
-- the source here.
data UnexpandedNode = UnexpandedNode
  { _unode_n_fqdn :: T.Text
  , _unode_n_mero_roles :: [RoleSpec]
  } deriving (Data, Eq, Generic, Show, Typeable)

unexpandedNodeJSONOptions :: A.Options
unexpandedNodeJSONOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_unode_" :: String)) }

instance A.FromJSON UnexpandedNode where
  parseJSON = A.genericParseJSON unexpandedHostJSONOptions

instance A.ToJSON UnexpandedNode where
  toJSON = A.genericToJSON unexpandedHostJSONOptions

-- | Having parsed the facts file, expand the roles for each node to
-- provide full 'InitialData'.
resolveMeroRoles :: InitialWithRoles -- ^ Parsed contents of halon_facts.
                 -> EDE.Template -- ^ Parsed Mero roles template.
                 -> Either Y.ParseException InitialData
resolveMeroRoles InitialWithRoles{..} template =
    case partitionEithers enodes of
        ([], nodes) ->
            Right $ InitialData { _id_profiles = _rolesinit_id_profiles
                                , _id_racks = _rolesinit_id_racks
                                , _id_nodes = nodes
                                }
        (errs, _) -> Left . mkException func . intercalate ", " $ concat errs
  where
    func = "resolveMeroRoles"

    enodes :: [Either [String] Node]
    enodes = map (\(unode, env) -> mkNode env unode) _rolesinit_id_nodes

    -- | Expand a node.
    mkNode :: Y.Object -> UnexpandedNode -> Either [String] Node
    mkNode env unode =
        let eprocs :: [Either String [Process]]
            eprocs = roleToProcesses env `map` _unode_n_mero_roles unode
        in case partitionEithers eprocs of
            ([], procs) -> Right $ Node { n_fqdn = _unode_n_fqdn unode
                                        , n_processes = concat procs
                                        }
            (errs, _) -> Left errs

    -- | Find a list of processes corresponding to the given role.
    roleToProcesses :: Y.Object -> RoleSpec -> Either String [Process]
    roleToProcesses env role =
        mkRole template env role (findProcesses $ r_name role)

    -- | Find a role among the others by its name and return the list
    -- of this role's processes.
    findProcesses :: RoleName -> [MeroRole] -> Either String [Process]
    findProcesses rname roles = maybeToEither errMsg (mr_content <$> findRole)
      where
        findRole = find ((rname ==) . mr_name) roles
        errMsg = printf "%s.findProcesses: Role \"%s\" not found\
                        \ in Mero mapping file" func rname

-- | Expand a role from the given template and env.
mkRole :: A.FromJSON a
       => EDE.Template -- ^ Role template.
       -> Y.Object -- ^ Surrounding env.
       -> RoleSpec -- ^ Role to expand.
       -> (a -> Either String b) -- ^ Role post-process.
       -> Either String b
mkRole template env role pp = do
    let env' = maybe env (`M.union` env) (r_overrides role)
    roleText <- T.toStrict <$> EDE.eitherResult (EDE.render template env')
    role' <- first (++ "\n" ++ T.unpack roleText)
        (Y.decodeEither $ T.encodeUtf8 roleText)
    pp role'

-- | Expand all given 'RoleSpec's into 'HalonRole's.
mkHalonRoles :: EDE.Template -- ^ Role template.
             -> [RoleSpec] -- ^ Roles to expand.
             -> Either String [HalonRole]
mkHalonRoles template roles =
    fmap (nub . concat) . forM roles $ \role ->
        mkRole template mempty role (findHalonRole $ r_name role)
  where
    findHalonRole :: RoleName -> [HalonRole] -> Either String [HalonRole]
    findHalonRole rname halonRoles = maybeToEither errMsg ((:[]) <$> findRole)
      where
        findRole = find ((rname ==) . hr_name) halonRoles
        errMsg = printf "mkHalonRoles.findHalonRole: Role \"%s\" not found\
                        \ in Halon mapping file" rname

----------------------------------------------------------------------
-- parseInitialData
----------------------------------------------------------------------

mkException :: String -> String -> Y.ParseException
mkException funcName msg = Y.AesonException (funcName ++ ": " ++ msg)

-- | Entry point into 'InitialData' parsing.
parseInitialData :: FilePath -- ^ Halon facts.
                 -> FilePath -- ^ Mero role map file.
                 -> FilePath -- ^ Halon role map file.
                 -> IO (Either Y.ParseException (InitialData, EDE.Template))
parseInitialData facts meroRoles halonRoles = runExceptT parse
  where
    parse :: ExceptT Y.ParseException IO (InitialData, EDE.Template)
    parse = do
        initialWithRoles <- ExceptT (Y.decodeFileEither facts)
        m0roles <- parseFile meroRoles
        h0roles <- parseFile halonRoles
        initialData <-
            ExceptT . pure $ resolveMeroRoles initialWithRoles m0roles
        {- XXX RESTOREME
        ExceptT . pure $ validateInitialData initialData
        -}
        -- XXX Can we process 'h0roles' here and return only 'initialData'?
        pure (initialData, h0roles)

    parseFile :: FilePath -> ExceptT Y.ParseException IO EDE.Template
    parseFile = ExceptT . (first mkExc <$>) . EDE.eitherParseFile

    mkExc = mkException "parseInitialData"
-- XXX ---------------------------------------------------------------

-- | Halon-specific settings for the 'Host'.
data HalonSettings_XXX0 = HalonSettings_XXX0
  { _hs_address_XXX0 :: String
  -- ^ Address on which Halon should listen on, including port. e.g.
  -- @10.0.2.15:9000@.
  , _hs_roles_XXX0 :: [RoleSpec_XXX0]
  -- ^ List of halon roles for this host. Valid values are determined
  -- by the halon roles files passed to 'parseInitialData'.
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable HalonSettings_XXX0

-- | JSON parser options for 'HalonSettings'.
halonSettingsOptions_XXX0 :: A.Options
halonSettingsOptions_XXX0 = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_hs_" :: String)) }

instance A.FromJSON HalonSettings_XXX0 where
  parseJSON = A.genericParseJSON halonSettingsOptions_XXX0

instance A.ToJSON HalonSettings_XXX0 where
  toJSON = A.genericToJSON halonSettingsOptions_XXX0

-- | Information about a mero host.
data Host_XXX0 = Host_XXX0
  { h_fqdn_XXX0 :: !T.Text
  -- ^ Fully-qualified domain name.
  , h_halon_XXX0 :: !(Maybe HalonSettings_XXX0)
  -- ^ Halon settings, if any. Note that if unset, the node is ignored
  -- during @hctl bootstrap cluster@ command. This does not imply that
  -- the host is not loaded as part of the initial data.
} deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable Host_XXX0
instance A.FromJSON Host_XXX0
instance A.ToJSON Host_XXX0

-- | Information about enclosures.
data Enclosure_XXX0 = Enclosure_XXX0
  { enc_idx_XXX0 :: Int
  -- ^ Enclosure index
  , enc_id_XXX0 :: String
  -- ^ Enclosure name
  , enc_bmc_XXX0 :: [BMC]
  -- ^ List of 'BMC' interfaces.
  , enc_hosts_XXX0 :: [Host_XXX0]
  -- ^ List of 'Host_XXX0's in the enclosure.
} deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable Enclosure_XXX0
instance A.FromJSON Enclosure_XXX0
instance A.ToJSON Enclosure_XXX0

-- | Rack information
data Rack_XXX0 = Rack_XXX0
  { rack_idx_XXX0 :: Int
  -- ^ Rack index
  , rack_enclosures_XXX0 :: [Enclosure_XXX0]
  -- ^ List of 'Enclosure_XXX0's in the index.
  } deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable Rack_XXX0
instance A.FromJSON Rack_XXX0
instance A.ToJSON Rack_XXX0

-- | Halon config for a host
data HalonRole_XXX0 = HalonRole_XXX0
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
  } deriving (Show, Data, Eq, Ord, Generic, Typeable)

halonConfigOptions :: A.Options
halonConfigOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_hc_" :: String)) }

instance A.FromJSON HalonRole_XXX0 where
  parseJSON = A.genericParseJSON halonConfigOptions

instance A.ToJSON HalonRole_XXX0 where
  toJSON = A.genericToJSON halonConfigOptions

-- | Facts about the cluster.
data M0Globals_XXX0 = M0Globals_XXX0 {
    m0_data_units_XXX0 :: Word32 -- ^ As in genders
  , m0_parity_units_XXX0 :: Word32  -- ^ As in genders
  , m0_md_redundancy_XXX0 :: Word32 -- ^ Metadata redundancy count
  , m0_failure_set_gen_XXX0 :: PoolVersGen
  , m0_be_ios_seg_size_XXX0 :: Maybe Word64
  , m0_be_log_size_XXX0 :: Maybe Word64
  , m0_be_seg_size_XXX0 :: Maybe Word64
  , m0_be_tx_payload_size_max_XXX0 :: Maybe Word64
  , m0_be_tx_reg_nr_max_XXX0 :: Maybe Word32
  , m0_be_tx_reg_size_max_XXX0 :: Maybe Word32
  , m0_be_txgr_freeze_timeout_max_XXX0 :: Maybe Word64
  , m0_be_txgr_freeze_timeout_min_XXX0 :: Maybe Word64
  , m0_be_txgr_payload_size_max_XXX0 :: Maybe Word64
  , m0_be_txgr_reg_nr_max_XXX0 :: Maybe Word64
  , m0_be_txgr_reg_size_max_XXX0 :: Maybe Word64
  , m0_be_txgr_tx_nr_max_XXX0 :: Maybe Word32
  , m0_block_size_XXX0 :: Maybe Word32
  , m0_min_rpc_recvq_len_XXX0 :: Maybe Word32
} deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable M0Globals_XXX0
instance A.FromJSON M0Globals_XXX0
instance A.ToJSON M0Globals_XXX0

-- | Devices attached to a 'M0Host'
data M0Device_XXX0 = M0Device_XXX0 {
    m0d_wwn_XXX0 :: String -- ^ World Wide Name of the device
  , m0d_serial_XXX0 :: String -- ^ Serial number of the device
  , m0d_bsize_XXX0 :: Word32 -- ^ Block size
  , m0d_size_XXX0 :: Word64 -- ^ Size of disk (in MB)
  , m0d_path_XXX0 :: String -- ^ Path to the device (e.g. /dev/disk...)
  , m0d_slot_XXX0 :: Int -- ^ Slot within the enclosure the device is in
} deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable M0Device_XXX0
instance A.FromJSON M0Device_XXX0
instance A.ToJSON M0Device_XXX0

-- | Represents an aggregation of three Mero concepts, which we don't
-- necessarily need for the castor implementation - nodes,
-- controllers, and processes.
data M0Host_XXX0 = M0Host_XXX0
  { m0h_fqdn_XXX0 :: !T.Text
  -- ^ Fully qualified domain name of host this server is running on
  , m0h_processes_XXX0 :: ![M0Process_XXX0]
  -- ^ Processes that should run on the host.
  , m0h_devices_XXX0 :: ![M0Device_XXX0]
  -- ^ Information about devices attached to the host.
} deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable M0Host_XXX0
instance A.FromJSON M0Host_XXX0
instance A.ToJSON M0Host_XXX0

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
  deriving (Data, Eq, Show, Typeable, Generic)
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
  deriving (Data, Eq, Show, Typeable, Generic)
instance Hashable M0ProcessEnv
instance A.FromJSON M0ProcessEnv
instance A.ToJSON M0ProcessEnv

-- | Information about mero process on the host
data M0Process_XXX0 = M0Process_XXX0
  { m0p_endpoint_XXX0 :: Endpoint
  -- ^ Endpoint the process should listen on
  , m0p_mem_as_XXX0 :: Word64
  , m0p_mem_rss_XXX0 :: Word64
  , m0p_mem_stack_XXX0 :: Word64
  , m0p_mem_memlock_XXX0 :: Word64
  , m0p_cores_XXX0 :: [Word64]
  -- ^ Treated as a bitmap of length (@no_cpu@) indicating which CPUs to use
  , m0p_services_XXX0 :: [M0Service_XXX0]
  -- ^ List of services this process should run.
  , m0p_boot_level_XXX0 :: M0ProcessType
  -- ^ Type of process, governing how it should run.
  , m0p_environment_XXX0 :: Maybe [(String, M0ProcessEnv)]
  -- ^ Process environment - additional
  , m0p_multiplicity_XXX0 :: Maybe Int
  -- ^ Process multiplicity - how many instances of this process should be started?
} deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable M0Process_XXX0
instance A.FromJSON M0Process_XXX0
instance A.ToJSON M0Process_XXX0

-- | Information about a service
data M0Service_XXX0 = M0Service_XXX0 {
    m0s_type_XXX0 :: ServiceType -- ^ e.g. ioservice, haservice
  , m0s_endpoints_XXX0 :: [Endpoint]
  -- ^ Listen endpoints for the service itself.
  , m0s_params_XXX0 :: ServiceParams
  , m0s_pathfilter_XXX0 :: Maybe String -- ^ For IOS, filter on disk WWN
} deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable M0Service_XXX0
instance A.FromJSON M0Service_XXX0
instance A.ToJSON M0Service_XXX0

data InitialData_XXX0 = InitialData_XXX0 {
    id_racks_XXX0 :: [Rack_XXX0]
  , id_m0_servers_XXX0 :: [M0Host_XXX0]
  , id_m0_globals_XXX0 :: M0Globals_XXX0
} deriving (Data, Eq, Generic, Show, Typeable)

instance Hashable InitialData_XXX0
instance A.FromJSON InitialData_XXX0
instance A.ToJSON InitialData_XXX0

-- | Specification for Mero or Halon role. Determines which role to
-- look-up and reify as well as any overrides to the environment.
-- Roles are user-defined (or provider defined).
data RoleSpec_XXX0 = RoleSpec_XXX0
  { _rolespec_name_XXX0 :: RoleName
  -- ^ Role name. Valid values depend on the mero roles passed to
  -- 'parseInitialData'.
  , _rolespec_overrides_XXX0 :: Maybe Y.Object
  -- ^ Any user-provided environment for this role. If present, this
  -- environment is unified (with precedence) with default environment
  -- (rest of the facts) in call to 'EDE.render': this allows the user
  -- to override values from the rest of the facts in case we want to
  -- tweak an existing role.
  } deriving (Data, Eq, Generic, Show, Typeable)

-- | Options for 'RoleSpec' JSON parser.
rolespecJSONOptions :: A.Options
rolespecJSONOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_rolespec_" :: String))
  , A.omitNothingFields = True
  }

instance A.FromJSON RoleSpec_XXX0 where
  parseJSON = A.genericParseJSON rolespecJSONOptions

instance A.ToJSON RoleSpec_XXX0 where
  toJSON = A.genericToJSON rolespecJSONOptions

instance Hashable RoleSpec_XXX0 where
  hashWithSalt s (RoleSpec_XXX0 a v) = s `H.hashWithSalt` a `H.hashWithSalt` fmap HM.toList v

-- | A single parsed mero role, ready to be used for building
-- 'InitialData'.
data Role_XXX0 = Role_XXX0
  { _role_name :: RoleName
  , _role_content :: [M0Process_XXX0]
  } deriving (Data, Eq, Generic, Show, Typeable)

roleJSONOptions :: A.Options
roleJSONOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_role_" :: String)) }

instance A.FromJSON Role_XXX0 where
  parseJSON = A.genericParseJSON roleJSONOptions

instance A.ToJSON Role_XXX0 where
  toJSON = A.genericToJSON roleJSONOptions

-- | Parse a halon_facts file into a structure indicating roles for
-- each given host.
data InitialWithRoles_XXX0 = InitialWithRoles_XXX0
  { _rolesinit_id_racks_XXX0 :: [Rack_XXX0]
  , _rolesinit_id_m0_servers_XXX0 :: [(UnexpandedHost_XXX0, Y.Object)]
    -- ^ The list of unexpanded host as well as the full object that
    -- the host was parsed out from, used as environment given during
    -- template expansion.
  , _rolesinit_id_m0_globals_XXX0 :: M0Globals_XXX0
  } deriving (Data, Eq, Generic, Show, Typeable)

instance A.FromJSON InitialWithRoles_XXX0 where
  parseJSON (A.Object v) = InitialWithRoles_XXX0 <$>
                           v A..: "id_racks_XXX0" <*>
                           parseServers <*>
                           v A..: "id_m0_globals_XXX0"
    where
      parseServers :: A.Parser [(UnexpandedHost_XXX0, Y.Object)]
      parseServers = do
        objs <- v A..: "id_m0_servers_XXX0"
        forM objs $ \obj -> (,obj) <$> A.parseJSON (A.Object obj)

  parseJSON invalid = A.typeMismatch "InitialWithRoles_XXX0" invalid

instance A.ToJSON InitialWithRoles_XXX0 where
  toJSON InitialWithRoles_XXX0{..} = A.object
    [ "id_racks_XXX0" A..= _rolesinit_id_racks_XXX0
    -- Dump out the full object into the file rather than our parsed
    -- and trimmed structure. This means we won't lose any information
    -- with @fromJSON . toJSON@
    , "id_m0_servers_XXX0" A..= map snd _rolesinit_id_m0_servers_XXX0
    , "id_m0_globals_XXX0" A..= _rolesinit_id_m0_globals_XXX0
    ]

-- | Hosts section of halon_facts
--
-- XXX: Perhaps we shouldn't have this structure or part of this
-- structure and simply use 'Y.Object'. That will allow us to easily
-- let the user specify any fields they want, including the ones we
-- don't have present and use them in their roles, without updating
-- the source here.
data UnexpandedHost_XXX0 = UnexpandedHost_XXX0
  { _uhost_m0h_fqdn_XXX0 :: !T.Text
  , _uhost_m0h_roles_XXX0 :: ![RoleSpec_XXX0]
  , _uhost_m0h_devices_XXX0 :: ![M0Device_XXX0]
  } deriving (Data, Eq, Generic, Show, Typeable)

unexpandedHostJSONOptions :: A.Options
unexpandedHostJSONOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_uhost_" :: String)) }

instance A.FromJSON UnexpandedHost_XXX0 where
  parseJSON = A.genericParseJSON unexpandedHostJSONOptions

instance A.ToJSON UnexpandedHost_XXX0 where
  toJSON = A.genericToJSON unexpandedHostJSONOptions

-- | Having parsed the facts file, expand the roles for each host to
-- provide full 'InitialData'.
resolveMeroRoles_XXX0 :: InitialWithRoles_XXX0 -- ^ Parsed contents of halon_facts.
                 -> EDE.Template -- ^ Parsed Mero roles template.
                 -> Either Y.ParseException InitialData_XXX0
resolveMeroRoles_XXX0 InitialWithRoles_XXX0{..} template =
    case partitionEithers ehosts of
        ([], hosts) ->
            Right $ InitialData_XXX0 { id_racks_XXX0 = _rolesinit_id_racks_XXX0
                                , id_m0_servers_XXX0 = hosts
                                , id_m0_globals_XXX0 = _rolesinit_id_m0_globals_XXX0
                                }
        (errs, _) -> Left . mkException func . intercalate ", " $ concat errs
  where
    func = "resolveMeroRoles_XXX0"

    ehosts :: [Either [String] M0Host_XXX0]
    ehosts = map (\(uhost, env) -> mkHost env uhost) _rolesinit_id_m0_servers_XXX0

    -- | Expand a host.
    mkHost :: Y.Object -> UnexpandedHost_XXX0 -> Either [String] M0Host_XXX0
    mkHost env uhost =
        let eprocs :: [Either String [M0Process_XXX0]]
            eprocs = roleToProcesses env `map` _uhost_m0h_roles_XXX0 uhost
        in case partitionEithers eprocs of
            ([], procs) ->
                Right $ M0Host_XXX0 { m0h_fqdn_XXX0 = _uhost_m0h_fqdn_XXX0 uhost
                               , m0h_processes_XXX0 = concat procs
                               , m0h_devices_XXX0 = _uhost_m0h_devices_XXX0 uhost
                               }
            (errs, _) -> Left errs

    -- | Find a list of processes corresponding to the given role.
    roleToProcesses :: Y.Object -> RoleSpec_XXX0 -> Either String [M0Process_XXX0]
    roleToProcesses env role =
        mkRole_XXX0 template env role (findProcesses $ _rolespec_name_XXX0 role)

    -- | Find a role among the others by its name and return the list
    -- of this role's processes.
    findProcesses :: RoleName -> [Role_XXX0] -> Either String [M0Process_XXX0]
    findProcesses rname roles =
        maybeToEither errMsg (_role_content <$> findRole)
      where
        findRole = find ((rname ==) . _role_name) roles
        errMsg = printf "%s.findProcesses: Role \"%s\" not found\
                        \ in Mero mapping file" func rname

-- | Expand a role from the given template and env.
mkRole_XXX0 :: A.FromJSON a
       => EDE.Template -- ^ Role template.
       -> Y.Object -- ^ Surrounding env.
       -> RoleSpec_XXX0 -- ^ Role to expand.
       -> (a -> Either String b) -- ^ Role post-process.
       -> Either String b
mkRole_XXX0 template env role pp = do
  let env' = maybe env (`M.union` env) (_rolespec_overrides_XXX0 role)
  roleText <- T.toStrict <$> EDE.eitherResult (EDE.render template env')
  role' <- first (++ "\n" ++ T.unpack roleText)
    (Y.decodeEither $ T.encodeUtf8 roleText)
  pp role'

-- | Expand all given 'RoleSpec's into 'HalonRole's.
mkHalonRoles_XXX0 :: EDE.Template -- ^ Role template.
             -> [RoleSpec_XXX0] -- ^ Roles to expand.
             -> Either String [HalonRole_XXX0]
mkHalonRoles_XXX0 template roles =
  fmap (nub . concat) . forM roles $ \role ->
    mkRole_XXX0 template mempty role (findHalonRole $ _rolespec_name_XXX0 role)
  where
    findHalonRole :: RoleName -> [HalonRole_XXX0] -> Either String [HalonRole_XXX0]
    findHalonRole rname halonRoles = maybeToEither errMsg ((:[]) <$> findRole)
      where
        findRole = find ((rname ==) . _hc_name) halonRoles
        errMsg = printf "mkHalonRoles_XXX0.findHalonRole: Role \"%s\" not found\
                        \ in Halon mapping file" rname

-- | Entry point into 'InitialData' parsing.
parseInitialData_XXX0 :: FilePath -- ^ Halon facts.
                 -> FilePath -- ^ Role map file.
                 -> FilePath -- ^ Halon role map file.
                 -> IO (Either Y.ParseException (InitialData_XXX0, EDE.Template))
parseInitialData_XXX0 facts meroRoles halonRoles = runExceptT parse
  where
    parse :: ExceptT Y.ParseException IO (InitialData_XXX0, EDE.Template)
    parse = do
        initialWithRoles <- ExceptT (Y.decodeFileEither facts)
        m0roles <- parseFile meroRoles
        h0roles <- parseFile halonRoles
        initialData <-
            ExceptT . pure $ resolveMeroRoles_XXX0 initialWithRoles m0roles
        ExceptT . pure $ validateInitialData_XXX0 initialData
        pure (initialData, h0roles)

    parseFile :: FilePath -> ExceptT Y.ParseException IO EDE.Template
    parseFile = ExceptT . (first mkExc <$>) . EDE.eitherParseFile

    mkExc = mkException "parseInitialData_XXX0"

validateInitialData_XXX0 :: InitialData_XXX0 -> Either Y.ParseException ()
validateInitialData_XXX0 idata = do
    check (allUnique $ map rack_idx_XXX0 $ id_racks_XXX0 idata)
        "Racks with non-unique rack_idx exist"
    check (all (\(fmap enc_idx_XXX0 -> idxs) -> allUnique idxs) enclsPerRack)
        "Enclosures with non-unique enc_idx exist inside a rack"
    check (all (not . null) enclIds) "Enclosure without enc_id specified"
    check (length enclIds == length (nub enclIds))
        "Enclosures with non-unique enc_id exist"
  where
    check cond msg =
        if cond then Right () else Left (mkException "validateInitialData_XXX0" msg)
    allUnique xs = length (nub xs) == length xs
    enclsPerRack = [rack_enclosures_XXX0 rack | rack <- id_racks_XXX0 idata]
    enclIds = enc_id_XXX0 <$> concat enclsPerRack

-- | Given a 'Maybe', convert it to an 'Either', providing a suitable
-- value for the 'Left' should the value be 'Nothing'.
maybeToEither :: e -> Maybe a -> Either e a
maybeToEither _ (Just a) = Right a
maybeToEither e Nothing = Left e

deriveSafeCopy 0 'base ''InitialData
deriveSafeCopy 0 'base ''Profile
storageIndex           ''Profile "229722d0-8317-48c4-a278-3c45cb992f2b"
deriveSafeCopy 0 'base ''Pool
storageIndex           ''Pool "ff3bef0e-25d0-49d3-96ae-7e9dd5bb7864"
deriveSafeCopy 0 'base ''PoolVersGen
storageIndex           ''PoolVersGen "3ad171f9-2691-4554-bef7-e6997d2698f1"
deriveSafeCopy 0 'base ''Rack
storageIndex           ''Rack "a4551891-4903-4778-8e96-b492389f6dc7"
deriveSafeCopy 0 'base ''Enclosure
storageIndex           ''Enclosure "ecc47908-646a-4457-8b84-b7712ff10c32"
deriveSafeCopy 0 'base ''BMC
storageIndex           ''BMC "22641893-9206-48ab-b4be-b2846acf5843"
deriveSafeCopy 0 'base ''Controller
storageIndex           ''Controller "7744280c-f12b-4798-a334-7ad572bc2924"
deriveSafeCopy 0 'base ''Disk
storageIndex           ''Disk "1dfdbc1d-0f1d-4dcc-bfdb-f1cdadc8db47"
deriveSafeCopy 0 'base ''Node
storageIndex           ''Node "53297999-5acc-4339-8b4c-3a3bcc10d6a9"
deriveSafeCopy 0 'base ''Process
deriveSafeCopy 0 'base ''ProcessType
deriveSafeCopy 0 'base ''ProcessEnv
deriveSafeCopy 0 'base ''Service
deriveSafeCopy 0 'base ''HalonSettings
deriveSafeCopy 0 'base ''RoleSpec
storageIndex           ''RoleSpec "d86682e1-d839-496f-9613-1037d42b10e5"
-- XXX ---------------------------------------------------------------
deriveSafeCopy 0 'base ''M0Device_XXX0
storageIndex           ''M0Device_XXX0 "cf6ea1f5-1d1c-4807-915e-5df1396fc764"
deriveSafeCopy 0 'base ''M0Globals_XXX0
storageIndex           ''M0Globals_XXX0 "4978783e-e7ff-48fe-ab83-85759d822622"
deriveSafeCopy 0 'base ''M0Host_XXX0
deriveSafeCopy 0 'base ''M0ProcessEnv
deriveSafeCopy 0 'base ''M0ProcessType
deriveSafeCopy 0 'base ''M0Process_XXX0
deriveSafeCopy 0 'base ''M0Service_XXX0
deriveSafeCopy 0 'base ''Enclosure_XXX0
deriveSafeCopy 0 'base ''HalonSettings_XXX0
deriveSafeCopy 0 'base ''Host_XXX0
deriveSafeCopy 0 'base ''InitialData_XXX0
deriveSafeCopy 0 'base ''Rack_XXX0
storageIndex           ''Rack_XXX0 "fe43cf82-adcd-40b5-bf74-134902424229"
deriveSafeCopy 0 'base ''RoleSpec_XXX0
storageIndex           ''RoleSpec_XXX0 "495818cc-ec20-4159-ab91-37fe449af3e0"
