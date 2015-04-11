-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}

module Test.Run (runTests) where

import Prelude hiding ((<$>))
import Test.Tasty (TestTree, defaultMainWithIngredients)
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)

import Control.Applicative ((<$>))
import Network.Transport (Transport)
import System.Environment (lookupEnv, getArgs)
import System.IO (hSetBuffering, BufferMode(..), stdout, stderr)

#ifdef USE_RPC
import Test.Framework (testSuccess)
import Test.Tasty (testGroup)
import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Network.Transport.RPC as RPC

import Data.Maybe (catMaybes)
import System.Directory (createDirectoryIfMissing, setCurrentDirectory)
import System.FilePath (takeDirectory, (</>))
import System.Environment (getExecutablePath)
import System.Exit (exitSuccess)
import System.Process (readProcess, callProcess)
#else
import qualified HA.Network.Socket as TCP
import qualified Network.Socket as TCP
import qualified Network.Transport.TCP as TCP
#endif

#if USE_RPC
runTests :: (Transport -> IO TestTree) -> IO ()
#else
runTests :: (Transport -> TCP.TransportInternals -> IO TestTree) -> IO ()
#endif
runTests tests = do
    -- TODO: Remove threadDelay after RPC transport closes cleanly
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    argv <- getArgs
#if USE_RPC
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
#endif
    addr <- case argv of
            a0:_ -> return a0
            _    ->
#if USE_RPC
                    maybe (error "TEST_LISTEN environment variable is not set") id <$> lookupEnv "TEST_LISTEN"
#else
                    maybe "127.0.0.1:0" id <$> lookupEnv "TEST_LISTEN"
#endif
#ifdef USE_RPC
    rpcTransport <- RPC.createTransport "s1"
                                        (rpcAddress addr)
                                        RPC.defaultRPCParameters
    let transport = networkTransport rpcTransport
#else
    let TCP.SockAddrInet port hostaddr = TCP.decodeSocketAddress addr
    hostname <- TCP.inet_ntoa hostaddr
    (transport, internals) <- either (error . show) id <$>
        TCP.createTransportExposeInternals hostname (show port) TCP.defaultTCPParameters
#endif
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
#ifdef USE_RPC
     =<< (testGroup "uncleanRPCClose" <$> sequence
                                 [ tests transport
                                 , return (testSuccess "" $ threadDelay 2000000)
                                 ]
         )
#else
      =<< tests transport internals
#endif
