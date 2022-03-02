-- |
-- Module: HA.Storage
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
--
-- Service that holds non-persistent key value storage,
-- and provide simple API for working with it. This service is
-- intended to be used locally, thus all highlevel commands do
-- not provide notion of monitoring.
--
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE MonoLocalBinds #-}

module HA.Storage
  ( -- * Highlevel API
    -- ** Initialization
    runStorage
    -- ** Storage Access
  , get
  , put
  , delete
    -- * Lowlevel API
  , name
  , Put(..)
  , Get(..)
  , Delete(..)
  , Reply(..)
  , StorageError(..)
  ) where

import HA.Debug
import Control.Distributed.Process
import Control.Distributed.Process.Serializable

import Control.Exception (Exception)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.Binary (Binary)
import qualified Data.Trie as Trie
import Data.Typeable (Typeable)
import GHC.Generics

-- | Request to put value inside storage. If there was already
-- value associated with key, that message is overriden.
data Put = Put ByteString Message deriving (Generic, Typeable)
instance Binary Put

-- | Request to read message from storage.
data Get = Get ByteString ProcessId deriving (Generic, Typeable)
instance Binary Get

-- | Request to delete message from storage.
data Delete = Delete ByteString deriving (Generic, Typeable)
instance Binary Delete

-- | Reply to get request
data Reply = Reply ByteString (Maybe Message) deriving (Generic, Typeable)
instance Binary Reply

data StorageError
      = KeyTypeMithmatch  -- ^ Value was found but have different type.
      | KeyNotFound       -- ^ Key was not found in storage.
      deriving (Eq,Show)
instance Exception StorageError

name :: String
name = "HA.Storage"

-- | Get value from storage, this function makes no attempt to monitor
-- Storage, thus will never exit if Storage will die.
get :: Serializable a => String -> Process (Either StorageError a)
get keyName = do
    self <- getSelfPid
    nsend name (Get key self)
    mmsg <- receiveWait
      [ matchIf (\(Reply k _  ) -> k == key)
                (\(Reply _ msg) -> return msg)
      ]
    case mmsg of
      Nothing -> return $ Left KeyNotFound
      Just msg -> maybe (Left KeyTypeMithmatch) Right  <$> unwrapMessage msg
  where
    key = BS.pack keyName

-- | Put value into storage, if value is already there it will be
-- updated to the new one, even types differ.
put :: Serializable a => String -> a -> Process ()
put keyName v = nsend name (Put (BS.pack keyName) (wrapMessage v))

-- | Remove key from storage.
delete :: String -> Process ()
delete = nsend name . Delete . BS.pack

-- | Start a storage process
runStorage :: Process ProcessId
runStorage = do
    labelProcess "ha:storage"
    pid <- spawnLocal mainloop
    prepare pid
    return pid
  where
    prepare pid = do
      mpid <- whereis name
      case mpid of
        Nothing -> register name pid
        Just _  -> do
          say "Could not start storage, as previous storage exists."
          error "Storage: takeover procedure is not yet implemented."

mainloop :: Process ()
mainloop = go Trie.empty
  where
    go t = do
      s <- receiveWait
            [ match $ \(Put k msg)   ->
                return $! Trie.insert k msg t
            , match $ \(Get k them) -> do
                usend them (Reply k (Trie.lookup k t))
                return t
            , match $ \(Delete k)  ->
                return $! Trie.delete k t
            ]
      go s
