-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Support functions for Internet socket addresses, as used by TCP.

-- XXX These functions should really be part of "Network.Socket".

module HA.Network.Socket
  ( SockAddr(..)
  , HostAddress
  , PortNumber(..)
  , socketAddressHost
  , socketAddressPort
  , socketAddressHostName
  , socketAddressServiceName
  , decodeSocketAddress
  , encodeSocketAddress
  ) where

import Network.Socket
  ( HostAddress
  , HostName
  , NameInfoFlag(..)
  , PortNumber(..)
  , ServiceName
  , SockAddr(..)
  , getNameInfo
  , inet_addr
  )

import Prelude hiding ((<$>))
import Control.Applicative ((<$>))
import Data.Char (isDigit)
import System.IO.Unsafe (unsafePerformIO)

socketAddressHost :: SockAddr -> HostAddress
socketAddressHost (SockAddrInet _ host) = host
socketAddressHost _ = error "socketAddressHost: socket address format not supported."

socketAddressPort :: SockAddr -> PortNumber
socketAddressPort (SockAddrInet port _) = port
socketAddressPort (SockAddrInet6 port _ _ _) = port
socketAddressPort _ = error "socketAddressPort: socket address does not have a port."

socketAddressHostName :: SockAddr -> HostName
-- No lookup, so referentially transparent, hence unsafePerformIO.
socketAddressHostName sa = unsafePerformIO $ do
    maybe (error "socketAddressHost: impossible") id . fst <$>
      getNameInfo [NI_NUMERICHOST, NI_NUMERICSERV] True True sa

socketAddressServiceName :: SockAddr -> ServiceName
socketAddressServiceName sa = unsafePerformIO $ do
    maybe (error "socketAddressHost: impossible") id . snd <$>
      getNameInfo [NI_NUMERICHOST, NI_NUMERICSERV] True True sa

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
