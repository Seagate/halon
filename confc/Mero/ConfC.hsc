{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TupleSections #-}
-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the confc client library. confc allows programs to
-- get data from the Mero confd service.
--
-- The configuration data are organized in a tree. Fetching the children
-- of a node involve IO operations which consume resources that must be
-- released explicitly. Whenever an operation requires subsequently
-- releasing resources the close operation is provided together with the
-- result of the operation (see 'WithClose').
--
module Mero.ConfC
  ( -- * Initialization
    initConfC
  , finalizeConfC
  , withConfC
    -- * Fetching operations
  , WithClose
  , withClose
  , getRoot
  , Profile(..)
  , CObj(..)
  , CObjUnion(..)
  , Filesystem(..)
  , Fid(..)
  , Dir(..)
  , Iterator(..)
  , Service(..)
  , Node(..)
  , Nic(..)
  , Sdev(..)
  ) where

#include "confc_helpers.h"
#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

import Network.RPC.RPCLite
  ( RPCAddress(..)
  , RPCMachine(..)
  , RPCMachineV
  )

import Control.Exception ( Exception, throwIO, bracket_, bracket )
import Control.Monad ( when, liftM2 )
import Data.Binary (Binary)
import Data.ByteString ( useAsCString )
import Data.Hashable (Hashable)
import Data.Typeable ( Typeable )
import Data.Word ( Word32, Word64 )
import Foreign.C.String ( CString, peekCString )
import Foreign.C.Types ( CInt(..) )
import Foreign.Marshal.Alloc ( alloca, malloc, free )
import Foreign.Marshal.Array ( advancePtr )
import Foreign.Marshal.Utils ( with )
import Foreign.Ptr ( Ptr, nullPtr, castPtr )
import Foreign.Storable ( Storable(..) )
import GHC.Generics ( Generic )
import System.IO.Unsafe ( unsafePerformIO )


-- * Initialization

-- | Call 'Network.Transport.RPC.RPCLite.initRPC' before calling 'initConfC'.
-- Or otherwise, create a 'Network.Transport.RPC.RPCTransport' instance before
-- calling 'initConfC'.
--
initConfC :: IO ()
initConfC = confc_init >>= check_rc "initConfC"

foreign import ccall unsafe confc_init :: IO CInt

-- | Call 'Network.Transport.RPC.RPCLite.finalizeRPC' after calling
-- 'finalizeConfC'. Or otherwise, close the 'Network.Transport.RPC.RPCTransport'
-- instance after calling 'finalizeConfC'.
--
finalizeConfC :: IO ()
finalizeConfC = confc_finalize

foreign import ccall unsafe confc_finalize :: IO ()

-- | Wraps an IO action with calls to 'initConfC' and 'finalizeConfC'.
withConfC :: IO a -> IO a
withConfC = bracket_ initConfC finalizeConfC


-- * Fetching operations

-- | Type of values attached with a close operation.
--
-- Given a value @(a,close)@, call @close@ when @a@ is no longer used.
-- Otherwise, resources would leak.
--
-- In the definitions that follow, operations which take resources yield
-- results of type @WithClose a@ so they can be released.
--
type WithClose a = (a,IO ())

-- | Ensures resources of a @WithClose a@ are released after an IO action.
withClose :: IO (WithClose a) -> (a -> IO b) -> IO b
withClose wc = bracket wc snd . (.fst)

-- | @getRoot rpcMachine confdRPCAddress fid@ gets the root of the
-- configuration tree which can be found at the given confd RPC address with the
-- given file identifier.
--
-- The @rpcMachine@ is the machine used to establish the connection with confd.
--
getRoot :: RPCMachine -> RPCAddress -> Fid -> IO (WithClose CObj)
getRoot (RPCMachine pm) (RPCAddress addr) fid = alloca $ \ppc ->
  with fid $ \pfid ->
  useAsCString addr$ \cconfd_addr -> do
    confc_create ppc pfid cconfd_addr pm >>= check_rc "getProfile"
    pc <- peek ppc
    fmap (,confc_destroy pc) $ #{peek struct m0_confc, cc_root} pc >>= getCObj

data ConfCV

foreign import ccall confc_create :: Ptr (Ptr ConfCV) -> Ptr Fid -> CString
                                  -> Ptr RPCMachineV -> IO CInt

foreign import ccall confc_destroy :: Ptr ConfCV -> IO ()

-- | Slimmed down representation of @m0_conf_obj@ object from confc.
data CObj = CObj
  { co_id :: Fid
    -- ^ Object identifier.
    --
    -- This value is unique among the object of given @co_type@ in internal C
    -- structure.
    --
  , co_union :: CObjUnion
    -- ^ Haskell side representation data of casted configuration object.
  }

-- | Get the object type for a configuration object.
foreign import ccall unsafe m0_conf_obj_type :: Ptr Obj -> IO (Ptr ObjType)

data ObjType

-- | Data type to wrap around casted configuration data.
--
-- Configuration object types listed here were derived from \"conf/obj.h\" mero
-- source code.
--
data CObjUnion
    = CP Profile
    | CF Filesystem
    | CD Dir
    | CS Service
    | CN Node
    | NI Nic
    | SD Sdev
    | COUnknown (Ptr ())

getCObj :: Ptr Obj -> IO CObj
getCObj po = do
  fid <- #{peek struct m0_conf_obj, co_id} po
  ot <- m0_conf_obj_type po
  ou <- if | ot == m0_CONF_PROFILE_TYPE    -> fmap CP $ getProfile po
           | ot == m0_CONF_FILESYSTEM_TYPE -> fmap CF $ getFilesystem po
           | ot == m0_CONF_SERVICE_TYPE    -> fmap CS $ getService po
           | ot == m0_CONF_NODE_TYPE       -> fmap CN $ getNode po
           | ot == m0_CONF_DIR_TYPE        -> fmap CD $ getDir po
           | ot == m0_CONF_NIC_TYPE        -> fmap NI $ getNic po
           | ot == m0_CONF_SDEV_TYPE       -> fmap SD $ getSdev po
           | otherwise -> return $ COUnknown $ castPtr ot
  return CObj
      { co_id = fid
      , co_union = ou
      }

foreign import ccall unsafe  "&M0_CONF_PROFILE_TYPE"
                             m0_CONF_PROFILE_TYPE :: Ptr ObjType
foreign import ccall unsafe  "&M0_CONF_FILESYSTEM_TYPE"
                             m0_CONF_FILESYSTEM_TYPE :: Ptr ObjType
foreign import ccall unsafe  "&M0_CONF_SERVICE_TYPE"
                             m0_CONF_SERVICE_TYPE :: Ptr ObjType
foreign import ccall unsafe  "&M0_CONF_NODE_TYPE"
                             m0_CONF_NODE_TYPE :: Ptr ObjType
foreign import ccall unsafe  "&M0_CONF_DIR_TYPE"
                             m0_CONF_DIR_TYPE :: Ptr ObjType
foreign import ccall unsafe  "&M0_CONF_NIC_TYPE"
                             m0_CONF_NIC_TYPE :: Ptr ObjType
foreign import ccall unsafe  "&M0_CONF_SDEV_TYPE"
                             m0_CONF_SDEV_TYPE :: Ptr ObjType

-- | Representation of @m0_conf_profile@.
data Profile = Profile
    { cp_filesystem :: IO (WithClose CObj)
    }

getProfile :: Ptr Obj -> IO Profile
getProfile po = return Profile
    { cp_filesystem = getChild po m0_FS_FID
    }

getChild :: Ptr Obj -> RelationFid -> IO (WithClose CObj)
getChild po fid = open_sync po fid >>= \pc -> fmap (,close pc) $ getCObj pc

-- | Representation of @struct m0_fid@. It is an identifier for objects in
-- confc.
data Fid = Fid { f_container :: {-# UNPACK #-} !Word64
               , f_key       :: {-# UNPACK #-} !Word64
               }
  deriving (Eq, Show, Typeable, Generic)

instance Binary Fid
instance Hashable Fid

instance Storable Fid where
  sizeOf    _           = #{size struct m0_fid}
  alignment _           = #{alignment struct m0_fid}
  peek      p           = liftM2 Fid
                            (#{peek struct m0_fid, f_container} p)
                            (#{peek struct m0_fid, f_key} p)
  poke      p (Fid c k) = do #{poke struct m0_fid, f_container} p c
                             #{poke struct m0_fid, f_key} p k

-- | Representation of @m0_conf_filesystem@.
data Filesystem = Filesystem
    { cf_rootfid  :: Fid
    , cf_params   :: [String]
    , cf_services :: IO (WithClose CObj)
    }

getFilesystem :: Ptr Obj -> IO Filesystem
getFilesystem pc = do
  pfs <- confc_cast_filesystem pc
  fid <- #{peek struct m0_conf_filesystem, cf_rootfid} pfs
  params <- #{peek struct m0_conf_filesystem, cf_params} pfs >>= peekStringArray
  return Filesystem
           { cf_rootfid = fid
           , cf_params = params
           , cf_services = getChild pc m0_SERVICE_FID
           }

foreign import ccall unsafe confc_cast_filesystem :: Ptr Obj
                                                  -> IO (Ptr Filesystem)

peekStringArray :: Ptr CString -> IO [String]
peekStringArray p = mapM peekCString
                  $ takeWhile (/=nullPtr)
                  $ map (unsafePerformIO . peek)
                  $ iterate (`advancePtr` 1) p

-- | Representation of @m0_conf_dir@.
data Dir = Dir
    { cd_iterator :: IO (WithClose Iterator)
    }

-- | Iterator used in 'Dir' objects to traverse the contained elements.
data Iterator = Iterator
    { ci_next :: IO (Maybe CObj) -- ^ Call repeteadly to get all objects until
                                 -- it yields Nothing.
    }

getDir :: Ptr Obj -> IO Dir
getDir po = return Dir
  { cd_iterator = do
      ppi <- malloc
      poke ppi nullPtr
      return
        ( Iterator
            { ci_next = do
                -- m0_confc_readdir_sync requires passing always the same ppi
                -- pointer. On each call, the pointed cobject is closed and
                -- reopened. When no more calls to m0_confc_readdir_sync
                -- remain, the ppi pointer has to be closed manually.
                rc <- m0_confc_readdir_sync po ppi
                if rc>0 then peek ppi >>= fmap Just . getCObj
                  else check_rc "m0_confc_readdir_sync" rc >> return Nothing
            }
        , peek ppi >>= \p -> when (p/=nullPtr) (close p) >> free ppi
        )
  }

foreign import ccall m0_confc_readdir_sync :: Ptr Obj -> Ptr (Ptr Obj)
                                           -> IO CInt

-- | Representation of `m0_conf_service_type`.
data ServiceType
    = CST_MDS
    | CST_IOS
    | CST_MGS
    | CST_RMS
    | CST_SS
    | CST_HA
    | CST_UNKNOWN Int
  deriving (Show,Read,Ord,Eq)

-- | Representation of `m0_conf_service`.
data Service = Service
    { cs_type      :: ServiceType
    , cs_endpoints :: [String]
    , cs_node      :: IO (WithClose CObj)
    }

getService :: Ptr Obj -> IO Service
getService po = do
  ps <- confc_cast_service po
  stype <- #{peek struct m0_conf_service, cs_type} ps
  endpoints <- #{peek struct m0_conf_service, cs_endpoints} ps
                    >>= peekStringArray
  return Service
           { cs_type = toEnum $ fromIntegral (stype :: CInt)
           , cs_endpoints = endpoints
           , cs_node = getChild po m0_NODE_FID
           }

foreign import ccall unsafe confc_cast_service :: Ptr Obj
                                               -> IO (Ptr Service)

instance Enum ServiceType where

  toEnum #{const M0_CST_MDS} = CST_MDS
  toEnum #{const M0_CST_IOS} = CST_IOS
  toEnum #{const M0_CST_MGS} = CST_MGS
  toEnum #{const M0_CST_RMS} = CST_RMS
  toEnum #{const M0_CST_SS}  = CST_SS
  toEnum #{const M0_CST_HA}  = CST_HA
  toEnum i                   = CST_UNKNOWN i

  fromEnum CST_MDS         = #{const M0_CST_MDS}
  fromEnum CST_IOS         = #{const M0_CST_IOS}
  fromEnum CST_MGS         = #{const M0_CST_MGS}
  fromEnum CST_RMS         = #{const M0_CST_RMS}
  fromEnum CST_SS          = #{const M0_CST_SS}
  fromEnum CST_HA          = #{const M0_CST_HA}
  fromEnum (CST_UNKNOWN i) = i

-- | Represetation of `m0_conf_node`.
data Node = Node
    { cn_memsize    :: Word32
    , cn_nr_cpu     :: Word32
    , cn_last_state :: Word64
    , cn_flags      :: Word64
    , cn_pool_id    :: Word64
    , cn_nics       :: IO (WithClose CObj)
    , cn_sdevs      :: IO (WithClose CObj)
    }

getNode :: Ptr Obj -> IO Node
getNode po = do
  pn <- confc_cast_node po
  memsize <- #{peek struct m0_conf_node, cn_memsize} pn
  nr_cpu <- #{peek struct m0_conf_node, cn_nr_cpu} pn
  last_state <- #{peek struct m0_conf_node, cn_last_state} pn
  flags <- #{peek struct m0_conf_node, cn_flags} pn
  pool_id <- #{peek struct m0_conf_node, cn_pool_id} pn
  return Node
           { cn_memsize = memsize
           , cn_nr_cpu = nr_cpu
           , cn_last_state = last_state
           , cn_flags = flags
           , cn_pool_id = pool_id
           , cn_nics = getChild po m0_NICS_FID
           , cn_sdevs = getChild po m0_SDEVS_FID
           }

foreign import ccall unsafe confc_cast_node :: Ptr Obj
                                            -> IO (Ptr Service)

-- | Represetation of `m0_conf_nic`.
data Nic = Nic
    { ni_iface      :: Word32
    , ni_mtu        :: Word32
    , ni_speed      :: Word64
    , ni_filename   :: String
    , ni_last_state :: Word64
    }

getNic :: Ptr Obj -> IO Nic
getNic po = do
  pn <- confc_cast_nic po
  iface <- #{peek struct m0_conf_nic, ni_iface} pn
  mtu <- #{peek struct m0_conf_nic, ni_mtu} pn
  speed <- #{peek struct m0_conf_nic, ni_speed} pn
  filename <- #{peek struct m0_conf_nic, ni_filename} pn >>= peekCString
  last_state <- #{peek struct m0_conf_nic, ni_last_state} pn
  return Nic
           { ni_iface = iface
           , ni_mtu = mtu
           , ni_speed = speed
           , ni_filename = filename
           , ni_last_state = last_state
           }

foreign import ccall unsafe confc_cast_nic :: Ptr Obj
                                           -> IO (Ptr Service)

-- | Representation of `m0_conf_sdev`.
data Sdev = Sdev
    { sd_iface      :: Word32
    , sd_media      :: Word32
    , sd_size       :: Word64
    , sd_last_state :: Word64
    , sd_flags      :: Word64
    , sd_filename   :: String
    }

getSdev :: Ptr Obj -> IO Sdev
getSdev po = do
  ps <- confc_cast_sdev po
  iface <- #{peek struct m0_conf_sdev, sd_iface} ps
  media <- #{peek struct m0_conf_sdev, sd_media} ps
  size <- #{peek struct m0_conf_sdev, sd_size} ps
  last_state <- #{peek struct m0_conf_sdev, sd_last_state} ps
  flags <- #{peek struct m0_conf_sdev, sd_flags} ps
  filename <- #{peek struct m0_conf_sdev, sd_filename} ps >>= peekCString
  return Sdev
           { sd_iface = iface
           , sd_media = media
           , sd_size = size
           , sd_last_state = last_state
           , sd_flags = flags
           , sd_filename = filename
           }

foreign import ccall unsafe confc_cast_sdev :: Ptr Obj
                                            -> IO (Ptr Service)

-- * Low level operations

data Obj

-- | Relation FIDs.
type RelationFid = Ptr Fid

foreign import ccall unsafe "&M0_CONF_PROFILE_FILESYSTEM_FID"
                            m0_FS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_FILESYSTEM_SERVICES_FID"
                            m0_SERVICE_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_SERVICE_NODE_FID"
                            m0_NODE_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_NODE_NICS_FID"
                            m0_NICS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_NODE_SDEVS_FID"
                            m0_SDEVS_FID :: RelationFid

open_sync :: Ptr Obj -> RelationFid -> IO (Ptr Obj)
open_sync po fid = alloca $ \ppc ->
  confc_open_sync ppc po fid >>= check_rc  "open_sync" >> peek ppc

foreign import ccall confc_open_sync :: Ptr (Ptr Obj) -> Ptr Obj -> RelationFid
                                     -> IO CInt

close :: Ptr Obj -> IO ()
close = m0_confc_close

foreign import ccall m0_confc_close :: Ptr Obj -> IO ()

-- | Type of exceptions that ConfC can produce.
data ConfCException = ConfCException String Int
  deriving (Show,Typeable)

instance Exception ConfCException

check_rc :: String -> CInt -> IO ()
check_rc _ 0 = return ()
check_rc msg i = throwIO $ ConfCException msg $ fromIntegral i
