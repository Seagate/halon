{-# LANGUAGE CApiFFI #-}
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
module Mero.Conf.Internal
  ( -- * Initialization
    initConfC
  , finalizeConfC
  , withConfC
    -- * HA Session interface
    -- $ha-session
  , withHASession
  , initHASession
  , finiHASession
    -- * Fetching operations
  , Dir(..)
  , Iterator(..)
  , WithClose
  , withClose
  , openRoot
  , rootFid
  , getChild
  , ConfObj(..)
  , ConfObjUnion(..)
  , RelationFid
  ) where

#include "confc_helpers.h"
#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

import Mero.Conf.Fid
import Mero.Conf.Obj

import Network.RPC.RPCLite

import Control.Exception ( Exception, throwIO, bracket_, bracket )
import Control.Monad ( when )
import Data.ByteString ( useAsCString )
import Data.Typeable ( Typeable )
import Foreign.C.String ( CString )
import Foreign.C.Types ( CInt(..) )
import Foreign.Marshal.Alloc ( alloca, malloc, free )
import Foreign.Marshal.Utils ( with )
import Foreign.Ptr ( Ptr, nullPtr, castPtr )
import Foreign.Storable ( Storable(..) )


-- * Initialization

-- | Call 'Network.Transport.RPC.RPCLite.initRPC' before calling 'initConfC'.
-- Or otherwise, create a 'Network.Transport.RPC.RPCTransport' instance before
-- calling 'initConfC'.
--
initConfC :: IO ()
initConfC = confc_init >>= check_rc "initConfC"

foreign import capi unsafe "confc_helpers.h confc_init"
  confc_init :: IO CInt

-- | Call 'Network.Transport.RPC.RPCLite.finalizeRPC' after calling
-- 'finalizeConfC'. Or otherwise, close the 'Network.Transport.RPC.RPCTransport'
-- instance after calling 'finalizeConfC'.
--
finalizeConfC :: IO ()
finalizeConfC = confc_finalize

foreign import capi unsafe "confc_helpers.h confc_finalize"
  confc_finalize :: IO ()

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

-- | @openRoot rpcMachine confdRPCAddress fid@ gets the root of the
-- configuration tree which can be found at the given confd RPC address with the
-- given file identifier.
--
-- The @rpcMachine@ is the machine used to establish the connection with confd.
--
openRoot :: RPCMachine -> RPCAddress -> Fid -> IO (WithClose ConfObj)
openRoot (RPCMachine pm) (RPCAddress addr) fid = alloca $ \ppc ->
  with fid $ \pfid ->
  useAsCString addr$ \cconfd_addr -> do
    confc_create ppc pfid cconfd_addr pm >>= check_rc "getProfile"
    pc <- peek ppc
    fmap (,confc_destroy pc) $ #{peek struct m0_confc, cc_root} pc >>= getConfObj

data {-# CTYPE "conf/confc.h" "struct m0_confc" #-} ConfCV

foreign import capi "confc_helpers.h confc_create"
  confc_create :: Ptr (Ptr ConfCV) -> Ptr Fid -> CString
               -> Ptr RPCMachineV -> IO CInt

foreign import capi "confc_helpers.h confc_destroy"
  confc_destroy :: Ptr ConfCV -> IO ()

-- | Root of the configuration tree. Defined in conf/obj.h
foreign import capi "&M0_CONF_ROOT_FID" rootFid :: Ptr Fid

--------------------------------------------------------------------------------
-- Generic Configuration
--------------------------------------------------------------------------------

data {-# CTYPE "conf/obj.h" "struct m0_conf_obj_type" #-} ObjType

foreign import capi unsafe  "&M0_CONF_DIR_TYPE"
                             m0_CONF_DIR_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_ROOT_TYPE"
                             m0_CONF_ROOT_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_PROFILE_TYPE"
                             m0_CONF_PROFILE_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_FILESYSTEM_TYPE"
                             m0_CONF_FILESYSTEM_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_POOL_TYPE"
                             m0_CONF_POOL_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_PVER_TYPE"
                             m0_CONF_PVER_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_OBJV_TYPE"
                             m0_CONF_OBJV_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_NODE_TYPE"
                             m0_CONF_NODE_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_PROCESS_TYPE"
                             m0_CONF_PROCESS_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_SERVICE_TYPE"
                             m0_CONF_SERVICE_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_SDEV_TYPE"
                             m0_CONF_SDEV_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_RACK_TYPE"
                             m0_CONF_RACK_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_ENCLOSURE_TYPE"
                             m0_CONF_ENCLOSURE_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_CONTROLLER_TYPE"
                             m0_CONF_CONTROLLER_TYPE :: Ptr ObjType
foreign import capi unsafe  "&M0_CONF_DISK_TYPE"
                             m0_CONF_DISK_TYPE :: Ptr ObjType

-- | Get the object type for a configuration object.
foreign import ccall unsafe "conf/obj.h m0_conf_obj_type"
  m0_conf_obj_type :: Ptr Obj -> IO (Ptr ObjType)

-- | Data type to wrap around casted configuration data.
--
-- Configuration object types listed here were derived from \"conf/obj.h\" mero
-- source code.
--
data ConfObjUnion
    = CDr Dir
    | CRo Root
    | CPf Profile
    | CF Filesystem
    | CPl Pool
    | CPv PVer
    | CO ObjV
    | CN Node
    | CPr Process
    | CS Service
    | CSd Sdev
    | CRa Rack
    | CE Enclosure
    | CC Controller
    | CDsk Disk
    | COUnknown (Ptr ())
  deriving (Show)

getConfObj :: Ptr Obj -> IO ConfObj
getConfObj po = do
  fid <- #{peek struct m0_conf_obj, co_id} po
  ot <- m0_conf_obj_type po
  ou <- if | ot == m0_CONF_DIR_TYPE        -> fmap CDr $ getDir po
           | ot == m0_CONF_ROOT_TYPE       -> fmap CRo $ getRoot po
           | ot == m0_CONF_PROFILE_TYPE    -> fmap CPf $ getProfile po
           | ot == m0_CONF_FILESYSTEM_TYPE -> fmap CF $ getFilesystem po
           | ot == m0_CONF_POOL_TYPE       -> fmap CPl $ getPool po
           | ot == m0_CONF_PVER_TYPE       -> fmap CPv $ getPVer po
           | ot == m0_CONF_OBJV_TYPE       -> fmap CO $ getObjV po
           | ot == m0_CONF_NODE_TYPE       -> fmap CN $ getNode po
           | ot == m0_CONF_PROCESS_TYPE    -> fmap CPr $ getProcess po
           | ot == m0_CONF_SERVICE_TYPE    -> fmap CS $ getService po
           | ot == m0_CONF_SDEV_TYPE       -> fmap CSd $ getSdev po
           | ot == m0_CONF_RACK_TYPE       -> fmap CRa $ getRack po
           | ot == m0_CONF_ENCLOSURE_TYPE  -> fmap CE $ getEnclosure po
           | ot == m0_CONF_CONTROLLER_TYPE -> fmap CC $ getController po
           | ot == m0_CONF_DISK_TYPE       -> fmap CDsk $ getDisk po
           | otherwise -> return $ COUnknown $ castPtr ot
  return ConfObj
      { co_id = fid
      , co_union = ou
      }

-- | Slimmed down representation of @m0_conf_obj@ object from confc.
data ConfObj = ConfObj
  { co_id :: Fid
    -- ^ Object identifier.
    --
    -- This value is unique among the object of given @co_type@ in internal C
    -- structure.
    --
  , co_union :: ConfObjUnion
    -- ^ Haskell side representation data of casted configuration object.
  }

-- | Representation of @m0_conf_dir@.
data Dir = Dir
    { cd_iterator :: IO (WithClose Iterator)
    }

instance Show Dir where
  show _ = "Directory"

-- | Iterator used in 'Dir' objects to traverse the contained elements.
data Iterator = Iterator
    { ci_next :: IO (Maybe ConfObj) -- ^ Call repeteadly to get all objects until
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
                -- pointer. On each call, the pointed ConfObject is closed and
                -- reopened. When no more calls to m0_confc_readdir_sync
                -- remain, the ppi pointer has to be closed manually.
                rc <- m0_confc_readdir_sync po ppi
                if rc>0 then peek ppi >>= fmap Just . getConfObj
                  else check_rc "m0_confc_readdir_sync" rc >> return Nothing
            }
        , peek ppi >>= \p -> when (p/=nullPtr) (close p) >> free ppi
        )
  }

foreign import capi "conf/confc.h m0_confc_readdir_sync"
  m0_confc_readdir_sync :: Ptr Obj -> Ptr (Ptr Obj) -> IO CInt

-- * Low level operations

getChild :: Ptr Obj -> RelationFid -> IO (WithClose ConfObj)
getChild po fid = open_sync po fid >>= \pc -> fmap (,close pc) $ getConfObj pc

-- | Relation FIDs.
type RelationFid = Ptr Fid

open_sync :: Ptr Obj -> RelationFid -> IO (Ptr Obj)
open_sync po fid = alloca $ \ppc ->
  confc_open_sync ppc po fid >>= check_rc "open_sync" >> peek ppc

foreign import capi "confc_helpers.h confc_open_sync"
  confc_open_sync :: Ptr (Ptr Obj) -> Ptr Obj -> RelationFid -> IO CInt

close :: Ptr Obj -> IO ()
close = m0_confc_close

foreign import capi "conf/confc.h m0_confc_close"
  m0_confc_close :: Ptr Obj -> IO ()

--------------------------------------------------------------------------------
-- Utility
--------------------------------------------------------------------------------

-- | Type of exceptions that ConfC can produce.
data ConfCException = ConfCException String Int
  deriving (Show,Typeable)

instance Exception ConfCException

check_rc :: String -> CInt -> IO ()
check_rc _ 0 = return ()
check_rc msg i = throwIO $ ConfCException msg $ fromIntegral i

--------------------------------------------------------------------------------
-- HASession interface
--------------------------------------------------------------------------------

-- $ha-session
-- HASession is a special session that could be used by confc and spiel libraries
-- in order to get information about current active confd and RM services from
-- HA service. Rconfc queries this information on startup using HASession.
-- HA Session should implement FOMs for the following FOPs:
--
--  * M0_HA_NOTE_GET
--  * M0_HA_ENTRYPOINT
--
-- for further information refer to the mero sources /ha\/note_fops.h/, /spiel\/spiel.h/.

foreign import ccall "<ha/note.h> m0_ha_state_init"
  c_ha_state_init :: Ptr SessionV -> IO CInt

foreign import ccall "<ha/note.h> m0_ha_state_fini"
  c_ha_state_fini :: IO ()

-- | Initialize connection from with the given 'RPCMachine' to the service at
-- 'RPCAddress', that implements HA Session interface. Newly created connection
-- is returned. For additional information see @ha_state_init@ in mero sources.
initHASession :: RPCMachine -> RPCAddress -> IO Connection
initHASession rpcm addr = do
  conn <- connect_rpc_machine rpcm addr 2
  Session s <- getConnectionSession conn
  rc <- c_ha_state_init s
  when (rc /= 0) $ error "failed to initialize ha_state"
  return conn

-- | Finalize connection and unmark current connection from beign an HA session.
-- If connection that is not a HA Session is passed then implementation is undefined.
-- For additional information see @ha_state_fini@ in mero.
finiHASession :: Connection -> IO ()
finiHASession conn = do
  c_ha_state_fini
  disconnect conn 0

-- | Convenient wrapper for 'initHASession' and 'finiHASession'.
withHASession :: ServerEndpoint -> RPCAddress -> IO a -> IO a
withHASession sep addr f =
   bracket (connect_se sep addr 2)
           (`disconnect` 2)
     $ \conn -> do
        bracket_ (do Session s <- getConnectionSession conn
                     rc <- c_ha_state_init s
                     when (rc /= 0) $ error "failed to initialize ha_state")
                 c_ha_state_fini
                 f
