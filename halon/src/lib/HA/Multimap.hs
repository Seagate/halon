-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
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
    ) where

import Prelude hiding ((<$>))
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

 deriving (Generic,Typeable)

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

-- | @getKeyValuePairs mmChan@ yields all the keys and values in the store.
--
-- @mmChan@ is the channel to the store.
--
getKeyValuePairs :: StoreChan -> Process [(Key,[Value])]
getKeyValuePairs (StoreChan mmpid rchan _) = do
    -- FIXME: Don't contact the local multimap but query the replicas directly
    self <- getSelfPid
    liftIO $ atomically $ writeTChan rchan self
    when schedulerIsEnabled $ usend mmpid ()
    x <- expect
    -- Decoding is forced to get any related errors at this point.
    let xs = decode x
    seq (length xs) $ return xs

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
