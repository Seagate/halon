{-# LANGUAGE CPP           #-}
{-# LANGUAGE TupleSections #-}
-- |
-- Copyright: (C) 2015 Seagate Technology LLC and/or its Affiliates.
--

module Test.Transport
  ( AbstractTransport(..)
  , mkTCPTransport
  , mkInMemoryTransport
  , mkRPCTransport
  , mkControlledTransport
  ) where

import Network.Transport
import Control.Concurrent (threadDelay, forkIO)
import Control.Concurrent.MVar
import Control.Exception
import qualified Network.Socket as N (close)
import qualified Network.Transport.TCP as TCP
import qualified Network.Transport.InMemory as InMemory
import qualified Network.Transport.Controlled as Controlled
#ifdef USE_RPC
import Helper.Environment
import Test.Framework (testSuccess)
import Test.Tasty (testGroup)
import Control.Monad (when)
import qualified Network.Transport.RPC as RPC

import Data.Maybe (catMaybes)
import System.Directory (createDirectoryIfMissing, setCurrentDirectory)
import System.FilePath (takeDirectory, (</>))
import System.Environment (getExecutablePath)
import System.Exit (exitSuccess)
import System.Process (readProcess, callProcess)
#endif

data AbstractTransport = AbstractTransport
  { getTransport :: Transport
  , breakConnection :: EndPointAddress -> EndPointAddress -> IO ()
  , closeAbstractTransport :: IO ()
  }

mkControlledTransport :: AbstractTransport -> IO (Transport,Controlled.Controlled)
mkControlledTransport transport = Controlled.createTransport (getTransport transport)
                                                             (breakConnection transport)

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

mkRPCTransport :: [String] -> IO AbstractTransport
#ifndef USE_RPC
mkRPCTransport _ = error "RPC transport is not enabled."
#else
mkRPCTransport argv = do
    prog <- getExecutablePath
    -- test if we have root privileges
    ((userid, _): _ ) <- reads <$> readProcess "id" ["-u"] ""
    when (userid /= (0 :: Int)) $ do
      -- change directory so mero files are produced under the dist folder
      let testDir = takeDirectory (takeDirectory $ takeDirectory prog)
                  </> "test"
      createDirectoryIfMissing True testDir
      setCurrentDirectory testDir
      putStrLn $ "Changed directory to: " ++ testDir
      -- Invoke again with root privileges
      putStrLn $ "Calling test with sudo ..."
      mld <- fmap ("LD_LIBRARY_PATH=" ++) <$> lookupEnv "LD_LIBRARY_PATH"
      mtl <- fmap ("TEST_LISTEN=" ++) . fromMaybe "127.0.0.1:0" <$>
        lookupEnv "TEST_LISTEN"
      callProcess "sudo" $ catMaybes [mld, mtl] ++ prog : argv
      exitSuccess
    addr <- getTestListen
    rpcTransport <- RPC.createTransport "s1"
                                        (RPC.rpcAddress addr)
                                        RPC.defaultRPCParameters
    let transport = RPC.networkTransport rpcTransport
    return (AbstractTransport transport (error "not implemented") (threadDelay 2000000 >> closeTransport transport))
#endif
