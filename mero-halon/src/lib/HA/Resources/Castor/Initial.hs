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
import           HA.Aeson (FromJSON, ToJSON, (.:), (.=))
import qualified HA.Aeson as A
import           HA.Resources.TH
import           HA.SafeCopy
import           Mero.ConfC (ServiceType)
import           Mero.Lnet
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

instance FromJSON HalonSettings where
  parseJSON = A.genericParseJSON halonSettingsOptions

instance ToJSON HalonSettings where
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
instance FromJSON Host
instance ToJSON Host

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
instance FromJSON BMC
instance ToJSON BMC

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
instance FromJSON Enclosure
instance ToJSON Enclosure

-- | Rack information
data Rack = Rack
  { rack_idx :: Int                -- ^ Rack index.
  , rack_enclosures :: [Enclosure] -- ^ List of 'Enclosure's in the index.
  } deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable Rack
instance FromJSON Rack
instance ToJSON Rack

-- | Site information
data Site = Site
  { site_idx :: Int      -- ^ Site index.
  , site_racks :: [Rack] -- ^ List of 'Rack's in the index.
  } deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable Site
instance FromJSON Site
instance ToJSON Site

-- | Failure set schemes. Define how failure sets are determined.
--
-- TODO: Link to some doc here.
data FailureSetScheme =
    Preloaded Word32 Word32 Word32
  | Formulaic [[Word32]]
  deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable FailureSetScheme
instance FromJSON FailureSetScheme
instance ToJSON FailureSetScheme

-- | Halon config for a host
data HalonRole = HalonRole
  { _hc_name :: RoleName
  -- ^ Role name.
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

-- | Options for the 'HalonRole' JSON parser.
halonConfigOptions :: A.Options
halonConfigOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_hc_" :: String)) }

instance FromJSON HalonRole where
  parseJSON = A.genericParseJSON halonConfigOptions

instance ToJSON HalonRole where
  toJSON = A.genericToJSON halonConfigOptions

-- | Facts about the cluster.
data M0Globals = M0Globals
  { m0_data_units :: Word32 -- ^ As in genders
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
instance FromJSON M0Globals
instance ToJSON M0Globals

-- | Devices attached to a 'M0Host'
data M0Device = M0Device
  { m0d_wwn :: String -- ^ World Wide Name of the device
  , m0d_serial :: String -- ^ Serial number of the device
  , m0d_bsize :: Word32 -- ^ Block size
  , m0d_size :: Word64 -- ^ Size of disk (in MB)
  , m0d_path :: String -- ^ Path to the device (e.g. /dev/disk...)
  , m0d_slot :: Int -- ^ Slot within the enclosure the device is in
  } deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable M0Device
instance FromJSON M0Device
instance ToJSON M0Device

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
instance FromJSON M0Host
instance ToJSON M0Host

data ProcessOwnership
  = Managed      -- ^ Process is started/monitored/stopped by Halon.
  | Independent  -- ^ Process is not controlled by Halon.
  deriving (Eq, Data, Show, Generic)
instance Hashable ProcessOwnership
instance FromJSON ProcessOwnership
instance ToJSON ProcessOwnership

data M0ProcessType
  = PLM0t1fs -- ^ Process lives as part of m0t1fs in kernel space.
  | PLClovis String ProcessOwnership -- ^ Process lives as part of a
                                     --   Clovis client, with given name.
  | PLM0d Word64  -- ^ Process runs in m0d at the given boot level.
                  --   Currently 0 = confd, 1 = other.
  | PLHalon  -- ^ Process lives inside Halon program space.
  deriving (Eq, Data, Show, Typeable, Generic)
instance Hashable M0ProcessType
instance FromJSON M0ProcessType
instance ToJSON M0ProcessType

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
instance FromJSON M0ProcessEnv
instance ToJSON M0ProcessEnv

-- | Information about mero process on the host
data M0Process = M0Process
  { m0p_endpoint :: Endpoint
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
  , m0p_multiplicity :: Maybe Int
  -- ^ Process multiplicity - how many instances of this process should be started?
  } deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable M0Process
instance FromJSON M0Process
instance ToJSON M0Process

-- | Information about a service
data M0Service = M0Service
  { m0s_type :: ServiceType        -- ^ E.g. ioservice, haservice.
  , m0s_endpoints :: [Endpoint]    -- ^ Listen endpoints for the service itself.
  , m0s_pathfilter :: Maybe String -- ^ For IOS, filter on disk WWN.
  } deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable M0Service
instance FromJSON M0Service
instance ToJSON M0Service

data M0Pool = M0Pool
  { pool_id :: T.Text
  , pool_device_refs :: [M0DeviceRef]
  } deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable M0Pool
instance FromJSON M0Pool
instance ToJSON M0Pool

-- | Reference to M0Device: a combination of any number of device
-- attributes (from given subset), which uniquely identifies a device.
--
-- We cannot use WWN as a unique identifier, because it's not set for
-- some types of devices (e.g., loop devices).
data M0DeviceRef = M0DeviceRef
  { dr_wwn :: Maybe T.Text
  , dr_serial :: Maybe T.Text
  , dr_path :: Maybe T.Text
  } deriving (Eq, Data, Generic, Show, Typeable)

-- XXX BUGS: If name of optional field is misspelled in facts.yaml,
-- the parsing will succeed nevertheless!
--
-- E.g. (note that `dr_wwn` is misspelled here)
--     > Y.decode "rd_wwn: \"0x5000c50078000157\"" :: Maybe M0DeviceRef
--     Just (M0DeviceRef Nothing Nothing Nothing)
--
-- This problem can be solved by using yaml-combinators package;
-- see https://ro-che.info/articles/2015-07-26-better-yaml-parsing

instance Hashable M0DeviceRef
instance FromJSON M0DeviceRef
instance ToJSON M0DeviceRef

data M0Profile = M0Profile
  { prof_id :: T.Text
  , prof_pools :: [T.Text]
  } deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable M0Profile
instance FromJSON M0Profile
instance ToJSON M0Profile

-- | Parsed initial data that halon buids its initial knowledge base
-- about the cluster from.
data InitialData = InitialData
  { id_sites :: [Site]
  , id_m0_servers :: [M0Host]
  , id_m0_globals :: M0Globals
  , id_pools :: [M0Pool]
  , id_profiles :: [M0Profile]
  } deriving (Eq, Data, Generic, Show, Typeable)

instance Hashable InitialData
instance FromJSON InitialData
instance ToJSON InitialData

-- | Handy synonym for role names
type RoleName = String

-- | Specification for Mero or Halon role. Determines which role to
-- look-up and reify as well as any overrides to the environment.
-- Roles are user-defined (or provider defined).
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

instance FromJSON RoleSpec where
  parseJSON = A.genericParseJSON rolespecJSONOptions

instance ToJSON RoleSpec where
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
data MeroRole = MeroRole
  { _role_name :: RoleName
  , _role_content :: [M0Process]
  } deriving (Eq, Data, Generic, Show, Typeable)

-- | Options for the 'Role' JSON parser.
roleJSONOptions :: A.Options
roleJSONOptions = A.defaultOptions
  { A.fieldLabelModifier = drop (length ("_role_" :: String)) }

instance FromJSON MeroRole where
  parseJSON = A.genericParseJSON roleJSONOptions

instance ToJSON MeroRole where
  toJSON = A.genericToJSON roleJSONOptions

-- | Parse a halon_facts file into a structure indicating roles for
-- each given host.
data InitialWithRoles = InitialWithRoles
  { _rolesinit_id_sites :: [Site]
  , _rolesinit_id_m0_servers :: [(UnexpandedHost, Y.Object)]
    -- ^ The list of unexpanded host as well as the full object that
    -- the host was parsed out from, used as environment given during
    -- template expansion.
  , _rolesinit_id_m0_globals :: M0Globals
  , _rolesinit_id_pools :: [M0Pool]
  , _rolesinit_id_profiles :: [M0Profile]
  } deriving (Eq, Data, Generic, Show, Typeable)

instance FromJSON InitialWithRoles where
  parseJSON (A.Object v) =
      InitialWithRoles <$> v .: "id_sites"
                       <*> parseServers
                       <*> v .: "id_m0_globals"
                       <*> v .: "id_pools"
                       <*> v .: "id_profiles"
    where
      parseServers :: A.Parser [(UnexpandedHost, Y.Object)]
      parseServers = do
        objs <- v .: "id_m0_servers"
        forM objs $ \obj -> (,obj) <$> A.parseJSON (A.Object obj)

  parseJSON invalid = A.typeMismatch "InitialWithRoles" invalid

instance ToJSON InitialWithRoles where
  toJSON InitialWithRoles{..} = A.object
    [ "id_sites" .= _rolesinit_id_sites
    -- Dump out the full object into the file rather than our parsed
    -- and trimmed structure. This means we won't lose any information
    -- with @fromJSON . toJSON@
    , "id_m0_servers" .= map snd _rolesinit_id_m0_servers
    , "id_m0_globals" .= _rolesinit_id_m0_globals
    , "id_pools" .= _rolesinit_id_pools
    , "id_profiles" .= _rolesinit_id_profiles
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

instance FromJSON UnexpandedHost where
  parseJSON = A.genericParseJSON unexpandedHostJSONOptions

instance ToJSON UnexpandedHost where
  toJSON = A.genericToJSON unexpandedHostJSONOptions

mkException :: String -> String -> Y.ParseException
mkException funcName msg = Y.AesonException (funcName ++ ": " ++ msg)

-- | Having parsed the facts file, expand the roles for each host to
-- provide full 'InitialData'.
resolveMeroRoles :: InitialWithRoles -- ^ Parsed contents of halon_facts.
                 -> EDE.Template -- ^ Parsed Mero roles template.
                 -> Either Y.ParseException InitialData
resolveMeroRoles InitialWithRoles{..} template =
    case partitionEithers ehosts of
        ([], hosts) ->
            Right $ InitialData { id_sites = _rolesinit_id_sites
                                , id_m0_servers = hosts
                                , id_m0_globals = _rolesinit_id_m0_globals
                                , id_pools = _rolesinit_id_pools
                                , id_profiles = _rolesinit_id_profiles
                                }
        (errs, _) -> Left . mkException "resolveMeroRoles" . intercalate ", "
            $ concat errs
  where
    ehosts :: [Either [String] M0Host]
    ehosts = map (\(uhost, env) -> mkHost env uhost) _rolesinit_id_m0_servers

    -- | Expand a host.
    mkHost :: Y.Object -> UnexpandedHost -> Either [String] M0Host
    mkHost env uhost =
        let eprocs :: [Either String [M0Process]]
            eprocs = roleToProcesses env `map` _uhost_m0h_roles uhost
        in case partitionEithers eprocs of
            ([], procs) ->
                Right $ M0Host { m0h_fqdn = _uhost_m0h_fqdn uhost
                               , m0h_processes = concat procs
                               , m0h_devices = _uhost_m0h_devices uhost
                               }
            (errs, _) -> Left errs

    -- | Find a list of processes corresponding to the given role.
    roleToProcesses :: Y.Object -> RoleSpec -> Either String [M0Process]
    roleToProcesses env role =
        mkRole template env role (
            (_role_content <$>) . findMeroRole (_rolespec_name role) )

    findMeroRole :: RoleName -> [MeroRole] -> Either String MeroRole
    findMeroRole name =
        let err = "No such role in Mero mapping file: " ++ show name
        in maybeToEither err . findRole name

    findRole :: RoleName -> [MeroRole] -> Maybe MeroRole
    findRole name = find ((name ==) . _role_name)

-- | Expand all given 'RoleSpec's into 'HalonRole's.
mkHalonRoles :: EDE.Template -- ^ Role template.
             -> [RoleSpec] -- ^ Roles to expand.
             -> Either String [HalonRole]
mkHalonRoles template roles =
    fmap nub . forM roles $ \role ->
        mkRole template mempty role (findHalonRole $ _rolespec_name role)
  where
    findHalonRole :: RoleName -> [HalonRole] -> Either String HalonRole
    findHalonRole name =
        let err = "No such role in Halon mapping file: " ++ show name
        in maybeToEither err . findRole name

    findRole :: RoleName -> [HalonRole] -> Maybe HalonRole
    findRole name = find ((name ==) . _hc_name)

-- | Expand a role from the given template and env.
mkRole :: FromJSON a
       => EDE.Template -- ^ Role template.
       -> Y.Object -- ^ Surrounding environment.
       -> RoleSpec -- ^ Role to expand.
       -> (a -> Either String b) -- ^ Role post-process.
       -> Either String b
mkRole template env role pp = do
    let env' = maybe env (`M.union` env) (_rolespec_overrides role)
    roleText <- T.toStrict <$> EDE.eitherResult (EDE.render template env')
    role' <- first (++ "\n" ++ T.unpack roleText)
        (Y.decodeEither $ T.encodeUtf8 roleText)
    pp role'

-- | Entry point into 'InitialData' parsing.
parseInitialData :: FilePath -- ^ Halon facts.
                 -> FilePath -- ^ Mero role map file.
                 -> FilePath -- ^ Halon role map file.
                 -> IO (Either Y.ParseException (InitialData, EDE.Template))
parseInitialData facts meroRoles halonRoles = runExceptT $ do
    initialWithRoles <- ExceptT (Y.decodeFileEither facts)
    m0roles <- parseFile meroRoles
    h0roles <- parseFile halonRoles
    initialData <- ExceptT . pure $ resolveMeroRoles initialWithRoles m0roles
    ExceptT . pure $ validateInitialData initialData
    pure (initialData, h0roles)
  where
    parseFile :: FilePath -> ExceptT Y.ParseException IO EDE.Template
    parseFile = let mkExc = mkException "parseInitialData"
                in ExceptT . fmap (first mkExc) . EDE.eitherParseFile

validateInitialData :: InitialData -> Either Y.ParseException ()
validateInitialData InitialData{..} = do
    check "Sites with non-unique rack_idx exist"
        (unique . map site_idx $ id_sites)
    check "Racks with non-unique rack_idx exist inside a site" $
        all (unique . map rack_idx) racksPerSite
    check "Enclosures with non-unique enc_idx exist inside a rack" $
        all (unique . map enc_idx) enclsPerRack
    check "Enclosure without enc_id specified" $ all (not . null) enclIds
    check "Enclosures with non-unique enc_id exist" (unique enclIds)
  where
    check msg cond = if cond
                     then Right ()
                     else Left (mkException "validateInitialData" msg)

    unique :: Eq a => [a] -> Bool
    unique xs = length (nub xs) == length xs

    racksPerSite :: [[Rack]]
    racksPerSite = site_racks <$> id_sites

    enclsPerRack :: [[Enclosure]]
    enclsPerRack = [ rack_enclosures rack
                   | site <- id_sites
                   , rack <- site_racks site
                   ]
    enclIds = enc_id <$> concat enclsPerRack

-- | Given a 'Maybe', convert it to an 'Either', providing a suitable
-- value for the 'Left' should the value be 'Nothing'.
maybeToEither :: e -> Maybe a -> Either e a
maybeToEither _ (Just a) = Right a
maybeToEither e Nothing = Left e

deriveSafeCopy 0 'base ''FailureSetScheme
storageIndex           ''FailureSetScheme "3ad171f9-2691-4554-bef7-e6997d2698f1"
deriveSafeCopy 0 'base ''M0Device
storageIndex           ''M0Device "cf6ea1f5-1d1c-4807-915e-5df1396fc764"
deriveSafeCopy 0 'base ''M0Globals
storageIndex           ''M0Globals "4978783e-e7ff-48fe-ab83-85759d822622"
deriveSafeCopy 0 'base ''M0Pool
deriveSafeCopy 0 'base ''M0DeviceRef
deriveSafeCopy 0 'base ''M0Profile
deriveSafeCopy 0 'base ''M0Host
deriveSafeCopy 0 'base ''M0ProcessEnv
deriveSafeCopy 0 'base ''ProcessOwnership
deriveSafeCopy 0 'base ''M0ProcessType
deriveSafeCopy 0 'base ''M0Process
deriveSafeCopy 0 'base ''M0Service
deriveSafeCopy 0 'base ''BMC
storageIndex           ''BMC "22641893-9206-48ab-b4be-b2846acf5843"
deriveSafeCopy 0 'base ''Enclosure
deriveSafeCopy 0 'base ''HalonSettings
deriveSafeCopy 0 'base ''Host
deriveSafeCopy 0 'base ''InitialData
deriveSafeCopy 0 'base ''Site
storageIndex           ''Site "4fb5befd-eb37-4f8f-b507-8aff14e774c9"
deriveSafeCopy 0 'base ''Rack
storageIndex           ''Rack "fe43cf82-adcd-40b5-bf74-134902424229"
deriveSafeCopy 0 'base ''RoleSpec
storageIndex           ''RoleSpec "495818cc-ec20-4159-ab91-37fe449af3e0"
