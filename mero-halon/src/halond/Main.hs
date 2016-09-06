-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TemplateHaskell #-}
module Main (main) where

import Flags
import Version.Read

import HA.Network.RemoteTables (haRemoteTable)
import Mero.RemoteTables (meroRemoteTable)

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
import HA.Network.Transport (writeTransportGlobalIVar)
#else
import Network.Transport.TCP as TCP
#endif
import HA.RecoveryCoordinator.Definitions
import HA.Replicator.Log (replicasDir, storageDir)
import HA.Startup (startupHalonNode)
import Version (gitDescribe)

import Control.Distributed.Commands.Process (sendSelfNode)
import Control.Distributed.Process hiding (catch)
import Control.Distributed.Process.Closure ( mkStaticClosure )
import Control.Distributed.Process.Node

#ifdef USE_MERO
import Mero
import Mero.Environment
#endif
import Control.Monad (when)
import Data.Function (on)
import Data.Version (parseVersion, versionBranch)
import Text.ParserCombinators.ReadP
import System.FilePath ((</>))
import System.Directory
    ( getCurrentDirectory
    , doesFileExist
    , doesDirectoryExist
    , createDirectoryIfMissing
    )
import System.Environment
import System.Exit
import System.IO

printHeader :: String -> IO ()
printHeader listen = do
    cwd <- getCurrentDirectory
    hSetBuffering stdout LineBuffering
    putStrLn $ "This is halond/" ++ buildType ++ " listening on " ++ listen
    putStrLn $ "Working directory: " ++ show cwd
    versionString >>= putStrLn
    hFlush stdout
  where
#ifdef USE_RPC
    buildType = "RPC"
#else
    buildType = "TCP"
#endif

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

main :: IO ()
main = do
  config <- parseArgs <$> getArgs
  case mode config of
    Version -> versionString >>= putStrLn
    Help -> putStrLn helpString
    Run -> do
#ifdef USE_MERO
      withM0Deferred initializeFOPs deinitializeFOPs $ mdo
#endif
        -- TODO: Implement a mechanism to propagate env vars in distributed tests.
        -- Perhaps an env var like
        -- DC_PROPAGATE_ENV="HALON_TRACING DISTRIBUTED_PROCESS_TRACE_FILE"
        -- which enumerates the environment variables that must be propagated when
        -- spawning remote processes.
        whenTestIsDistributed $
          setEnvIfUnset "HALON_TRACING"
           "consensus-paxos replicated-log EQ EQ.producer MM RS RG call startup"
        checkStoredVersion
#ifdef USE_RPC
        rpcTransport <- RPC.createTransport "s1"
                                            (RPC.rpcAddress $ localEndpoint config)
                                            RPC.defaultRPCParameters
        writeTransportGlobalIVar rpcTransport
        let transport = RPC.networkTransport rpcTransport
#else
        let (hostname, _:port) = break (== ':') $ localEndpoint config
        transport <- either (error . show) id <$>
                     TCP.createTransport hostname port TCP.defaultTCPParameters
                       { tcpUserTimeout = Just 2000
                       , tcpNoDelay = True
                       , transportConnectTimeout = Just 2000000
                       }
#endif
        lnid <- newLocalNode transport myRemoteTable
        printHeader (localEndpoint config)
        runProcess lnid sendSelfNode
        runProcess lnid $ startupHalonNode rcClosure >> receiveWait []
  where
    rcClosure = $(mkStaticClosure 'recoveryCoordinator)

    whenTestIsDistributed action = do
      lookupEnv "DC_CALLER_PID" >>= maybe (return ()) (const action)

    setEnvIfUnset v x = lookupEnv v >>= maybe (setEnv v x) (const $ return ())

    checkStoredVersion = do
      let versionFile = storageDir </> "version.txt"
          parseGitDescribe = readP_to_S $ do
            v <- parseVersion
--          Uncomment when versionTag is removed from Data.Version.Version
--            optional $ char '-' >> munch1 isDigit >> char '-' >>
--                       munch1 isAlphaNum
            skipSpaces
            eof
            return v
      exists <- doesFileExist versionFile
      stateExists <- doesDirectoryExist replicasDir
      version <- case parseGitDescribe gitDescribe of
        [(version, "")] -> return version
        res -> do
          hPutStrLn stderr $ "Unexpected version string: " ++ show (gitDescribe, res)
          exitFailure
               
      -- We don't want to check the persisted state version if there is no
      -- persisted state.
      if exists && stateExists then do
        str <- readFile versionFile
        case parseGitDescribe str of
          [(fVersion, "")] ->
            when (versionBranch fVersion > versionBranch version
                  || ((/=) `on` (take 2 . versionBranch)) fVersion version) $ do
              hPutStrLn stderr "Version incompatibility of the persisted state."
              hPutStrLn stderr "The state was written with version"
              hPutStrLn stderr str
              hPutStrLn stderr $ "but halond is at version"
              hPutStrLn stderr gitDescribe
              exitFailure
          res -> do
            hPutStrLn stderr $ "Error when parsing " ++ show versionFile ++ ": "
                               ++ show res
            exitFailure
      else do
        createDirectoryIfMissing True storageDir
      writeFile versionFile gitDescribe
