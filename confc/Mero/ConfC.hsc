{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ForeignFunctionInterface #-}
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

import Network.Transport.RPC.RPCLite ( RPCAddress(..), RPCMachine(..)
                                     , RPCMachineV
                                     )

import Control.Exception ( Exception, throwIO, bracket_, bracket )
import Control.Monad ( when )
import Data.ByteString ( useAsCString )
import Data.Typeable ( Typeable )
import Data.Word ( Word32, Word64 )
import Foreign.C.String ( withCString, CString, peekCString )
import Foreign.C.Types ( CInt(..) )
import Foreign.Marshal.Alloc ( alloca, malloc, free )
import Foreign.Marshal.Array ( advancePtr )
import Foreign.Ptr ( Ptr, nullPtr )
import Foreign.Storable ( Storable(..) )
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

-- | @getRoot rpcMachine confdRPCAddress name@ gets the root of the
-- configuration tree which can be found at the given confd RPC address with the
-- given name.
--
-- The @rpcMachine@ is the machine used to establish the connection with confd.
--
getRoot :: RPCMachine -> RPCAddress -> String -> IO (WithClose CObj)
getRoot (RPCMachine pm) (RPCAddress addr) name = alloca $ \ppc ->
  withCString name$ \cname ->
  useAsCString addr$ \cconfd_addr -> do
    confc_create ppc cname cconfd_addr pm >>= check_rc "getProfile"
    pc <- peek ppc
    fmap (,confc_destroy pc) $ #{peek struct m0_confc, cc_root} pc >>= getCObj

data ConfCV

foreign import ccall confc_create :: Ptr (Ptr ConfCV) -> CString -> CString
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
foreign import ccall "m0_conf_obj_type" c_conf_obj_type :: Ptr Obj -> IO CInt

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
    | COUnknown Int

getCObj :: Ptr Obj -> IO CObj
getCObj po = do
  id_c <- #{peek struct m0_conf_obj, co_id.f_container} po
  id_k <- #{peek struct m0_conf_obj, co_id.f_key} po
  ot <- c_conf_obj_type po
  ou <- case ot :: CInt of
          #{const CONF_PROFILE_TYPE} -> fmap CP $ getProfile po
          #{const CONF_FILESYSTEM_TYPE} -> fmap CF $ getFilesystem po
          #{const CONF_SERVICE_TYPE} -> fmap CS $ getService po
          #{const CONF_NODE_TYPE} -> fmap CN $ getNode po
          #{const CONF_DIR_TYPE} -> fmap CD $ getDir po
          #{const CONF_NIC_TYPE} -> fmap NI $ getNic po
          #{const CONF_SDEV_TYPE} -> fmap SD $ getSdev po
          _ -> return $ COUnknown $ fromIntegral ot
  return CObj
      { co_id = Fid { f_container = id_c, f_key = id_k }
      , co_union = ou
      }

-- | Representation of @m0_conf_profile@.
data Profile = Profile
    { cp_filesystem :: IO (WithClose CObj)
    }

getProfile :: Ptr Obj -> IO Profile
getProfile po = return Profile
    { cp_filesystem = getChild po "filesystem"
    }

getChild :: Ptr Obj -> String -> IO (WithClose CObj)
getChild po name = open_sync po name >>= \pc -> fmap (,close pc) $ getCObj pc

-- | Representation of @m0_fid@.
data Fid = Fid { f_container :: Word64, f_key :: Word64 }

-- | Representation of @m0_conf_filesystem@.
data Filesystem = Filesystem
    { cf_rootfid  :: Fid
    , cf_params   :: [String]
    , cf_services :: IO (WithClose CObj)
    }

getFilesystem :: Ptr Obj -> IO Filesystem
getFilesystem pc = do
  pfs <- confc_cast_filesystem pc
  c <- #{peek struct m0_conf_filesystem, cf_rootfid.f_container} pfs
  k <- #{peek struct m0_conf_filesystem, cf_rootfid.f_key} pfs
  params <- #{peek struct m0_conf_filesystem, cf_params} pfs >>= peekStringArray
  return Filesystem
           { cf_rootfid = Fid { f_container = c, f_key = k }
           , cf_params = params
           , cf_services = getChild pc "services"
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
           , cs_node = getChild po "node"
           }

foreign import ccall unsafe confc_cast_service :: Ptr Obj
                                               -> IO (Ptr Service)

instance Enum ServiceType where

  toEnum #{const M0_CST_MDS} = CST_MDS
  toEnum #{const M0_CST_IOS} = CST_IOS
  toEnum #{const M0_CST_MGS} = CST_MGS
  toEnum #{const M0_CST_RMS} = CST_RMS
  toEnum #{const M0_CST_SS}  = CST_SS
  toEnum i                   = CST_UNKNOWN i

  fromEnum CST_MDS         = #{const M0_CST_MDS}
  fromEnum CST_IOS         = #{const M0_CST_IOS}
  fromEnum CST_MGS         = #{const M0_CST_MGS}
  fromEnum CST_RMS         = #{const M0_CST_RMS}
  fromEnum CST_SS          = #{const M0_CST_SS}
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
           , cn_nics = getChild po "nics"
           , cn_sdevs = getChild po "sdevs"
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
    , sd_partitions :: IO (WithClose CObj)
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
           , sd_partitions = getChild po "partitions"
           }

foreign import ccall unsafe confc_cast_sdev :: Ptr Obj
                                            -> IO (Ptr Service)

-- * Low level operations

data Obj

open_sync :: Ptr Obj -> String -> IO (Ptr Obj)
open_sync po name = alloca $ \ppc ->
  withCString name $ \cname ->
    confc_open_sync ppc po cname >>= check_rc  "open_sync" >> peek ppc

foreign import ccall confc_open_sync :: Ptr (Ptr Obj) -> Ptr Obj -> CString
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
