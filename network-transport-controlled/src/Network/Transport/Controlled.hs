-- |
-- Module Network.Transport.Controlled
-- Copyright: (C) 2015 Seagate Technology LLC and/or its Affiliates.
--
-- Network transport controlled is a transport wrapper that
-- allow control connection properties between nodes. This
-- transport should only be using for testing.
--
--
module Network.Transport.Controlled
  ( createTransport
  , silenceBetween
  , unsilence
  , Controlled
  ) where

import Network.Transport
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import Control.Concurrent.MVar

data Controlled = Controlled (Transport)
                             (MVar (Map EndPointAddress [EndPointAddress]))
                             (EndPointAddress -> EndPointAddress -> IO ())

-- | Create transport wrapper.
-- This function creates a Transport wrapper and additional 'Controlled'
-- structure that could be used to change connection properties of the hosts.
--
createTransport :: Transport -- ^ Underlying transport
                -> (EndPointAddress -> EndPointAddress -> IO ())
                -- ^ Internal connection break procedure, see "silenceBetween"
                -> IO (Transport, Controlled)
createTransport transport break = do
    c <- Controlled transport <$> newMVar Map.empty <*> pure break
    return (Transport
      { newEndPoint = apiNewEndPoint c
      , closeTransport = closeTransport transport
      }, c)

-- | Tear down communication between two nodes, once connection is teared down
-- all further calls to 'send' will return 'TransportError SendFailed ..'
-- and all connections will return 'TransportError ConnectFailed ..'.
-- This function calls 'connection break function' that were provided during 'createTransport'
-- call, this function may explicitly tear down connections, or force underlaying transport
-- backend send additional messages, for example 'EventConnectionLost' depending
-- on required semantics.
silenceBetween :: Controlled -> EndPointAddress -> EndPointAddress -> IO ()
silenceBetween (Controlled t mBrokenLinks break) a b = do
   modifyMVar_ mBrokenLinks $ \m -> do
     break a b
     return $ Map.alter (Just . (a:) . fromMaybe []) b (Map.alter (Just . (b:) . fromMaybe []) a m)

-- | Remove persistent breakage between nodes, this means that any following
-- call to 'connect' will succeed. Semantics of the call to 'send' depends on
-- 'break' function that was passed to 'createTransport', if it closed underlying
-- connection then 'send' will fail, otherwise following 'send' will succeed.
unsilence :: Controlled -> EndPointAddress -> EndPointAddress -> IO ()
unsilence (Controlled t mBrokenLinks _) a b = do
   modifyMVar_ mBrokenLinks $ \m -> do
     return $ Map.alter (Just . filter (/=a) . fromMaybe []) b
                        (Map.alter (Just . filter (/=b) . fromMaybe []) a m)

apiNewEndPoint :: Controlled -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)
apiNewEndPoint c@(Controlled transport brokenLinks _) = fmap wrapEndPoint <$> newEndPoint transport where
  wrapEndPoint (EndPoint receive' address' connect' _ _ closeEndPoint') =
        EndPoint { receive  = receive'
                 , address  = address'
                 , connect  = wrapConnect c connect'
                 , closeEndPoint  = closeEndPoint'
                 , newMulticastGroup     = return $ Left $ newMulticastGroupError
                 , resolveMulticastGroup = return . Left . const resolveMulticastGroupError
                 }
       where
         newMulticastGroupError =
           TransportError NewMulticastGroupUnsupported "Multicast not supported"
         resolveMulticastGroupError =
           TransportError ResolveMulticastGroupUnsupported "Multicast not supported"
         wrapConnect c f = \theirAddress rel hints -> withMVar brokenLinks $ \m ->
           case elem theirAddress <$> Map.lookup address' m of
             Just True -> return (Left $ TransportError ConnectFailed "EndPoint not found")
             _ -> fmap (wrapConnection c address' theirAddress) <$> f theirAddress rel hints
  wrapConnection (Controlled _ b _) ourAddress theirAddress (Connection send' close') =
    Connection { send = \d -> do
                          m <- readMVar b
                          if theirAddress /= ourAddress
                             then case elem theirAddress <$> Map.lookup ourAddress m of
                                    Just True -> return (Left (TransportError SendFailed "silence"))
                                    _         -> send' d
                             else send' d
               , close = close'
               }
