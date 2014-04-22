-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This module defines operations to communicate out-of-band data.

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HA.Network.IdentifyRPC
    ( getAvailable
    , putAvailable
    , closeAvailable
    , IdentifyId
    , WrongTypeException(..)
    ) where

import Network.Transport.RPC ( RPCTransport, newReservedEndPoint )
import Network.Transport.RPC.RPCLite ( RPCAddress(..) )

import Control.Concurrent ( forkIOWithUnmask, killThread, ThreadId )
import Control.Distributed.Process.Serializable ( encodeFingerprint, fingerprint )
import Control.Monad ( void )
import Control.Exception ( bracket, mask_, finally, evaluate, Exception
                         , throwIO
                         )
import Data.Binary ( Binary, encode, decode )
import Data.ByteString ( ByteString )
import qualified Data.ByteString as ByteString
          ( concat, length, append, drop, isPrefixOf )
import Data.ByteString.Char8 ( pack )
import Data.ByteString.Lazy ( toChunks, fromStrict )
import Data.Typeable ( Typeable(..) )
import Data.Word ( Word32 )
import Network.Transport ( EndPoint(..), Event(..), connect, EndPointAddress(..)
                         , send, close, newEndPoint, Transport, Reliability(..)
                         , defaultConnectHints, TransportError(..)
                         , ConnectErrorCode(..), EventErrorCode(..)
                         )
import System.Timeout ( timeout )

-- | A wrapper abstracting away a 'ThreadId'.
newtype IdentifyId = IdentifyId ThreadId

-- | @putAvailable transport epId a@ creates a process which provides @a@
-- every time it is contacted on the endpoint with identifier @epId@.
--
-- epId must be an endpoint id in the reserved range of the transport.
-- See 'Network.Transport.RPC.newReservedEndPoint'.
--
putAvailable :: (Typeable a, Binary a) => RPCTransport -> Word32 -> a -> IO (Maybe IdentifyId)
putAvailable t epId a = mask_ $ do
  ee <- newReservedEndPoint t epId
  case ee of
    Left _ -> return Nothing
    Right e -> do
      tid <- forkIOWithUnmask $ \restore -> (`finally` closeEndPoint e) $ restore $ go e
      return $ Just $ IdentifyId tid
  where
    go e = do
      mepAddr <- fmap (fmap $ decode . fromStrict) $ receiveMessage e
      case mepAddr of
        Nothing -> return ()
        Just epAddr -> do
            bracket
              (connect e epAddr ReliableOrdered defaultConnectHints)
              (either (const $ return ()) close)
              $ \ec -> do
              case ec of
                Left _ -> return ()
                Right c -> void $ send c $ (encodeFingerprint $ fingerprint a)
                                         : toChunks (encode a)
            go e

-- | @getAvailable addr epId@ tries to fetch a value from the endpoint with
-- identifier @epId@ at the given RPC address.
--
-- If the remote peer does not respond, this function yields @Nothing@.
-- If the fetched value is not of the expected type, an exception of type
-- 'WrongTypeException' is thrown.
--
getAvailable :: forall a . (Typeable a, Binary a) => Transport -> RPCAddress
             -> Word32 -> IO (Maybe a)
getAvailable t (RPCAddress addr) epId =
  bracket
    (newEndPoint t)
    (either (const $ return ()) closeEndPoint)
    $ \ee ->
  case ee of
    Left err -> error (show err)
    Right e -> do
        ec <- connect e (EndPointAddress $
                             addr `ByteString.append` pack (':' : show epId)
                        )
                        ReliableOrdered
                        defaultConnectHints
        case ec of
          Left (TransportError ConnectTimeout _) -> return Nothing
          Left (TransportError ConnectNotFound _) -> return Nothing
          Left err -> error $ "getAvailable: connect: " ++ show err
          Right c -> do
              rc <- send c (toChunks $ encode $ address e)
              case rc of
                Right () -> return ()
                Left err -> error $ "getAvailable: send: " ++ show err
              close c
              -- discards connection opened event
              event <- timeout 5000000 $ do
                  void $ receive e
                  receive e
              case event of
                Just (Received _ msg) ->
                    let bs = ByteString.concat msg
                        efp = encodeFingerprint $ fingerprint (undefined :: a)
                     in if ByteString.isPrefixOf efp bs
                          then return $ Just $ decode $ fromStrict
                                    $ ByteString.drop (ByteString.length efp) bs
                          else throwIO $ WrongTypeException
                                 $ "getAvailable: the value obtained is not of"
                                 ++ " the expected type: "
                                 ++ show (typeOf (undefined :: a))
                Just (ErrorEvent (TransportError (EventConnectionLost _) _)) ->
                    return Nothing
                Nothing ->
                    return Nothing
                _ -> evaluate $ error $ "getAvailable: receive: " ++ show event

-- | Exceptions thrown when getAvailable gets a value of the wrong type
newtype WrongTypeException = WrongTypeException String
  deriving (Show, Typeable)

instance Exception WrongTypeException where

-- | Polls the endpoint queue until a message appears.
-- Discards all other events except 'EndPointClosed'.
--
-- Yields @Nothing@ if the endpoint is closed.
--
receiveMessage :: EndPoint -> IO (Maybe ByteString)
receiveMessage e = do
  event <- receive e
  case event of
    Received _ msg -> return $ Just $ ByteString.concat msg
    EndPointClosed -> return Nothing
    _ -> receiveMessage e

-- | Closes the process serving values.
closeAvailable :: IdentifyId -> IO ()
closeAvailable (IdentifyId tid) = killThread tid
