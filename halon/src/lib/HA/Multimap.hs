-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This is the Key-value API.
--
-- It allows to modify- and query the key-value store of the Replicator
-- component. It is intended to be used by the Recovery Coordinator.
-- Conceptually, the key-value store is a set of key-"set of values" pairs:
--
-- > store `in` Store = 2^(Key x 2^Value)
--

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
module HA.Multimap
    ( Key
    , Value
    , StoreUpdate(..)
    , StoreChan(..)
    , getKeyValuePairs
    , updateStore
    , MetaInfo(..)
    , getStoreValue
    , defaultMetaInfo
    ) where

import Control.Concurrent.STM.TChan
import Control.Distributed.Process
import Control.Distributed.Process.Scheduler (schedulerIsEnabled)
import Control.Monad (when)
import Control.Monad.STM

import Data.ByteString ( ByteString )
import Data.Binary ( Binary, decode )
import Data.Typeable ( Typeable )
import GHC.Generics ( Generic )

-- | Types of keys
type Key = ByteString
-- | Types of values
type Value = ByteString

-- | Update operations for the store
--
-- More formally, a value of type @StoreUpdate@ is a function on stores:
-- @Store -> Store@
--
data StoreUpdate =

    -- | Inserts key-value pairs in the store.
    -- If the key is already associated to the value, the pair is
    -- ignored.
    --
    -- More formally:
    --
    -- >  InsertMany xs store = normalize (xs `union` store)
    -- >    where
    -- >      normalize st = { (k,sets k st) | (k,_)<-st }
    -- >      sets k st = mconcat { s | (k’,s)<-st, k==k’ }
    --
    InsertMany [(Key,[Value])]

    -- | Deletes specific values from the store.
    -- If the value is not associated to the key, or the key is
    -- not in the store, the pair is ignored.
    --
    -- More formally:
    --
    -- >  DeleteValues xs store = { (k,s `difference` sets k xs) | (k,s)<-st }
    --
  | DeleteValues [(Key,[Value])]

    -- | Deletes keys and all its associated values from the store.
    -- If a key is not in the store, it is ignored.
    --
    -- More formally:
    --
    -- >  DeleteKeys xs store = { (k,s) | (k,s)<-store, k `notMember` xs }
    --
  | DeleteKeys [Key]
    -- | Sets the graph meta information, overwriting any old value
  | SetMetaInfo MetaInfo

 deriving (Generic, Typeable)

instance Show StoreUpdate where
  show (SetMetaInfo _) = "SetMetaInfo"
  show (DeleteKeys ks) = "DeleteKeys[" ++ show (length ks) ++ "]"
  show (DeleteValues vs) = "DeleteValues[" ++ show (length vs) ++ "]"
  show (InsertMany kvs) = "InsertMany[" ++ show (length kvs) ++ "]"

instance Binary StoreUpdate

-- | Channel to read and write the store.
data StoreChan =
    StoreChan ProcessId -- Multimap process pid. It is only used to signal to
                        -- the scheduler that messages are available in the
                        -- following TChans.
              (TChan ProcessId) -- Read requests. They carry the pid of the
                                -- requestor.
              (TChan ([StoreUpdate], Process ())) -- Update requests. They
                        -- carry the updates plus a callback to execute when
                        -- the update has been replicated.

-- | Replicated metainfo used by RG GC.
data MetaInfo = MetaInfo
  { -- | Graph disconnects since last major GC.
    _miSinceGC :: Int
    -- | Disconnect threshold after which we should perform major GC.
  , _miGCThreshold :: Int
    -- | List of root nodes that should be considered by the GC. These
    -- are later deserialised to @Res@ in RG module.
  , _miRootNodes :: [ByteString]
  } deriving (Generic, Typeable, Show)

instance Binary MetaInfo

-- | Default value for 'MetaInfo'.
defaultMetaInfo :: MetaInfo
defaultMetaInfo = MetaInfo 0 100 []

-- | @getStoreValue mmChan@ yields graph 'MetaInfo' along with all the
-- keys and values in the store.
--
-- @mmChan@ is the channel to the store.
getStoreValue :: StoreChan -> Process (MetaInfo, [(Key,[Value])])
getStoreValue (StoreChan mmpid rchan _) = do
    -- FIXME: Don't contact the local multimap but query the replicas directly
    self <- getSelfPid
    liftIO $ atomically $ writeTChan rchan self
    when schedulerIsEnabled $ usend mmpid ()
    (mi, x) <- expect
    -- Decoding is forced to get any related errors at this point.
    let xs = decode x
    length (_miRootNodes mi) `seq` length xs `seq` return (mi, xs)

-- | @getKeyValuePairs mmChan@ yields all the keys and values in the store.
--
-- @mmChan@ is the channel to the store.
--
getKeyValuePairs :: StoreChan -> Process [(Key,[Value])]
getKeyValuePairs = fmap snd . getStoreValue

-- | The type of @updateStore@. It updates the store with a batch of operations.
--
-- The update is asynchronous. The given callback is executed when the update
-- completes. Only fast calls that do not throw exceptions should be used there.
--
-- More formally: @updateStore xs store = foldr ($) store xs@
--
updateStore :: StoreChan -> [StoreUpdate] -> Process () -> Process ()
updateStore (StoreChan mmpid _ wchan) upds cb = do
    liftIO $ atomically $ writeTChan wchan (upds, cb)
    when schedulerIsEnabled $ usend mmpid ()
