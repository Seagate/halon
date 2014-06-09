--
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This program tests the "Network.Transport.Identify" module.

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

import HA.Network.IdentifyRPC ( getAvailable, putAvailable
                              , WrongTypeException(..)
                              )

import Network.Transport.RPC ( RPCTransport(..), rpcAddress, createTransport
                             , defaultRPCParameters
                             )

import Control.Concurrent ( newEmptyMVar, takeMVar, forkIO, putMVar )
import Control.Exception ( try )
import Control.Monad ( forM, void )
import Data.Binary ( Binary )
import Data.List ( isPrefixOf )
import Data.Time ( getCurrentTime, NominalDiffTime, diffUTCTime )
import Data.Typeable ( Typeable )
import System.Environment ( getArgs )

newtype Hello = Hello String
  deriving (Typeable,Binary,Eq)

main :: IO ()
main = do
  [nid] <- getArgs
  -- we don't close the transport to prevent Mero from crashing
  tr <- createTransport "s1" (rpcAddress $ nid ++ ":12345:34:2")
                             defaultRPCParameters
  _ <- putAvailable tr 0 (Hello "World!")
  normal nid tr
  wrongEndpointId nid tr
  wrongType nid tr
  peerDown tr
  parallelPeerDown tr

normal :: String -> RPCTransport -> IO ()
normal nid tr = do
  mh <- getAvailable (networkTransport tr) (rpcAddress $ nid ++ ":12345:34:2") 0
  printResult "identify" $ mh==Just (Hello "World!")

printResult :: String -> Bool -> IO ()
printResult name test = do
  putStr $ name ++ ": "
  if test
    then putStrLn "Ok"
    else putStrLn "Failed"

wrongEndpointId :: String -> RPCTransport -> IO ()
wrongEndpointId nid tr = do
  mh <- getAvailable (networkTransport tr) (rpcAddress $ nid ++ ":12345:34:2") 1
  printResult "wrongEndpointId" $ mh == (Nothing :: Maybe Hello)

peerDown :: RPCTransport -> IO ()
peerDown tr = do
  (mh,t) <- time $ getAvailable (networkTransport tr)
                                (rpcAddress "10.155.91.90@o2ib:12345:34:2")
                                1
  printResult ("peerDown (" ++ show t ++ ")") $ mh == (Nothing :: Maybe Hello)

time :: IO a -> IO (a,NominalDiffTime)
time action = do
  t0 <- getCurrentTime
  a <- action
  tf <- getCurrentTime
  return (a,diffUTCTime tf t0)

parallelPeerDown :: RPCTransport -> IO ()
parallelPeerDown tr = do
  let unknownAddresses =
        [ "10.155.91.90@o2ib:12345:34:2"
        , "10.155.91.91@o2ib:12345:34:2"
        ]
  (mh,t) <- time $
    (forM unknownAddresses $ \addr -> newEmptyMVar >>= \mv -> do
       void $ forkIO $
         getAvailable (networkTransport tr) (rpcAddress addr) 1
         >>= putMVar mv
       return mv
    )
    >>= mapM takeMVar
  printResult ("parallelPeerDown (" ++ show t ++")")
              $ mh `isPrefixOf` (repeat Nothing :: [Maybe Hello])

wrongType :: String -> RPCTransport -> IO ()
wrongType nid tr =
    try (getAvailable (networkTransport tr)
                      (rpcAddress $ nid ++ ":12345:34:2")
                      0
        )
    >>=
    printResult "wrongType" . either (\(WrongTypeException _) -> True)
                                     (\a -> const False (a :: Maybe String))
