-- |
-- Copyright: (C) 2015 Seagate Technology Limited.
--
{-# LANGUAGE CPP #-}
module Test.Transport
  ( AbstractTransport(..)
  , mkTCPTransport
  , mkInMemoryTransport
  , mkRPCTransport
  ) where

import Network.Transport
import Control.Concurrent (threadDelay)
import qualified Network.Socket as N (close)
import qualified Network.Transport.TCP as TCP
import qualified Network.Transport.InMemory as InMemory
#ifdef USE_RPC
import Test.Framework (testSuccess)
import Test.Tasty (testGroup)
import Control.Concurrent (threadDelay)
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
      mtl <- fmap ("TEST_LISTEN=" ++) <$> lookupEnv "TEST_LISTEN"
      callProcess "sudo" $ catMaybes [mld, mtl] ++ prog : argv
      exitSuccess
    addr <- case argv of
            a0:_ -> return a0
            _    ->
                    maybe (error "TEST_LISTEN environment variable is not set") id <$> lookupEnv "TEST_LISTEN"
    rpcTransport <- RPC.createTransport "s1"
                                        (RPC.rpcAddress addr)
                                        RPC.defaultRPCParameters
    let transport = RPC.networkTransport rpcTransport
    return (AbstractTransport transport (error "not implemented") (threadDelay 2000000 >> closeTransport transport))
#endif
