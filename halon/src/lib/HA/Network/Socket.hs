-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Support functions for Internet socket addresses, as used by TCP.

-- XXX These functions should really be part of "Network.Socket".

module HA.Network.Socket
  ( SockAddr(..)
  , HostAddress
  , PortNumber(..)
  , socketAddressHost
  , socketAddressPort
  , decodeSocketAddress
  , encodeSocketAddress
  ) where

import Network.Socket (SockAddr(..), HostAddress, PortNumber(..), inet_addr)

import Data.Char (isDigit)
import System.IO.Unsafe (unsafePerformIO)

socketAddressHost :: SockAddr -> HostAddress
socketAddressHost (SockAddrInet _ host) = host
socketAddressHost _ = error "socketAddressHost: socket address format not supported."

socketAddressPort :: SockAddr -> PortNumber
socketAddressPort (SockAddrInet port _) = port
socketAddressPort (SockAddrInet6 port _ _ _) = port
socketAddressPort _ = error "socketAddressPort: socket address does not have a port."

-- | Read a socket address. Raises an exception on malformed inputs.
decodeSocketAddress :: String -> SockAddr
decodeSocketAddress sockstr = check $ break (== ':') sockstr
  where
    check (host,':':port) | not (null port), all isDigit port =
        -- XXX 'unsafePerformIO' might be a bit scary, but this is exactly how
        -- it is used in the 'network' package.
        SockAddrInet (toEnum $ read port) (unsafePerformIO $ inet_addr host)
    check _ = error $ "decodeSocketAddress: \
                      \Malformed or unsupported socket address: " ++ sockstr

-- | Show a socket address.
encodeSocketAddress :: SockAddr -> String
encodeSocketAddress = show
