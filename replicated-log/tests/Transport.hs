{-# LANGUAGE TupleSections #-}
-- |
-- Copyright: (C) 2015 Seagate Technology LLC and/or its Affiliates.
--
module Transport
  ( AbstractTransport(..)
  , mkTCPTransport
  , mkInMemoryTransport
  ) where

import Network.Transport
import Control.Concurrent (threadDelay, forkIO)
import Control.Concurrent.MVar
import Control.Exception
import qualified Network.Socket as N (close)
import qualified Network.Transport.TCP as TCP
import qualified Network.Transport.InMemory as InMemory

data AbstractTransport = AbstractTransport
  { getTransport :: Transport
  , breakConnection :: EndPointAddress -> EndPointAddress -> IO ()
  , closeAbstractTransport :: IO ()
  }

mkTCPTransport :: IO AbstractTransport
mkTCPTransport = do
    Right (transport, internals) <- TCP.createTransportExposeInternals
                   (TCP.defaultTCPAddr "127.0.0.1" "0") TCP.defaultTCPParameters
    let -- XXX: Could use enclosed-exceptions here. Note that the worker
        -- is not killed in case of an exception.
        ignoreSyncExceptions action = do
          mv <- newEmptyMVar
          _ <- forkIO $ action `finally` putMVar mv ()
          takeMVar mv
        closeConnection here there = do
          ignoreSyncExceptions $
            TCP.socketBetween internals here there >>= N.close
          ignoreSyncExceptions $
            TCP.socketBetween internals there here >>= N.close
          threadDelay 1000000
    return (AbstractTransport transport closeConnection (closeTransport transport))

mkInMemoryTransport :: IO AbstractTransport
mkInMemoryTransport = do
  (transport, internals) <- InMemory.createTransportExposeInternals
  let closeConnection here there =
        InMemory.breakConnection internals here there "user error"
  return (AbstractTransport transport closeConnection (closeTransport transport))
