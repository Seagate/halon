-- |
-- Copyright: (C) 2015 Seagate Technology Limited.
--
module Transport
  ( AbstractTransport(..)
  , mkTCPTransport
  , mkInMemoryTransport
  ) where

import Network.Transport
import Control.Concurrent (threadDelay)
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
  Right (transport, internals) <- TCP.createTransportExposeInternals "127.0.0.1" "0" TCP.defaultTCPParameters
  let closeConnection here there = do
        TCP.socketBetween internals here there >>= N.close
        TCP.socketBetween internals there here >>= N.close
        threadDelay 1000000
  return (AbstractTransport transport closeConnection (closeTransport transport))

mkInMemoryTransport :: IO AbstractTransport
mkInMemoryTransport = do
  (transport, internals) <- InMemory.createTransportExposeInternals
  let closeConnection here there =
        InMemory.breakConnection internals here there "user error"
  return (AbstractTransport transport closeConnection (closeTransport transport))
