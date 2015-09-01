--
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This test exhibits starting a simple cluster over two nodes and controlling
-- it with `halonctl`.
--
-- We start two instances of `halond` on a single machine. We then boostrap a
-- sattelite on each of these nodes, and a tracking station on one of them.
-- Finally, we contact the tracking station to request that the Dummy service be
-- started on the satellite node.
--
{-# LANGUAGE CPP #-}

import Control.Distributed.Commands.Process
  ( systemLocal
  , spawnLocalNode
  , redirectLogsHere
  , copyLog
  , expectLog
  , __remoteTable
  )

import Prelude hiding ((<$>))
import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , runProcess
  )

import Data.List (isInfixOf)

#ifdef USE_RPC
import Control.Applicative ((<$>))
import Control.Monad (when)
import Data.Maybe (catMaybes)
import Network.Transport.RPC
  ( createTransport
  , defaultRPCParameters
  , rpcAddress
  , RPCTransport(..)
  )
import System.Exit
#else
import Network.Transport.TCP (createTransport, defaultTCPParameters)
#endif

import qualified Control.Exception as E (bracket, catch, SomeException)
import System.Directory (setCurrentDirectory, createDirectoryIfMissing, getTemporaryDirectory)
import System.Environment
import System.IO
import System.FilePath ((</>), takeDirectory)
import System.Posix.Temp (mkdtemp)
import System.Process hiding (runProcess)
import System.Timeout


getBuildPath :: IO FilePath
getBuildPath = fmap (takeDirectory . takeDirectory) getExecutablePath

main :: IO ()
main =
  (>>= maybe (error "test timed out") return) $ timeout (120 * 1000000) $ do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering

    buildPath <- getBuildPath
    progName <- getProgName

    tmpDir <- getTemporaryDirectory
    let testDir = tmpDir </> "test" </> progName
    createDirectoryIfMissing True testDir

#ifdef USE_RPC
    argv <- getArgs
    prog <- getExecutablePath
    -- test if we have root privileges
    ((userid, _): _ ) <- reads <$> readProcess "id" ["-u"] ""
    when (userid /= (0 :: Int)) $ do
      -- Invoke again with root privileges
      putStrLn $ "Calling test with sudo ..."
      mld <- fmap ("LD_LIBRARY_PATH=" ++) <$> lookupEnv "LD_LIBRARY_PATH"
      mtl <- fmap ("DC_HOST_IP=" ++) <$> lookupEnv "DC_HOST_IP"
      callProcess "sudo" $ catMaybes [mld, mtl] ++ prog : argv
      exitSuccess
#endif

    setCurrentDirectory testDir
    putStrLn $ "Changed directory to: " ++ testDir

#ifdef USE_RPC
    let m0 = "0@lo:12345:34"
    nt <- fmap networkTransport $
           createTransport "s1" (rpcAddress $ m0 ++ ":100") defaultRPCParameters
#else
    let m0 = "0.0.0.0"
    Right nt <- createTransport m0 "4000" defaultTCPParameters
#endif
    n0 <- newLocalNode nt (__remoteTable initRemoteTable)
    let killHalond = E.catch (readProcess "pkill" [ "halond" ] "" >> return ())
                             (\e -> const (return ()) (e :: E.SomeException))

    E.bracket killHalond (const killHalond) $ const $ runProcess n0 $ do
      tmp0 <- liftIO $ mkdtemp $ testDir </> "tmp."
      tmp1 <- liftIO $ mkdtemp $ testDir </> "tmp."
      tmp2 <- liftIO $ mkdtemp $ testDir </> "tmp."
#ifdef USE_RPC
      let m0loc = m0 ++ ":900"
          m1loc = m0 ++ ":901"
          hctlloc = m0 ++ ":902"
#else
      let m0loc = m0 ++ ":9000"
          m1loc = m0 ++ ":9001"
          hctlloc = m0 ++ ":9002"
#endif

      let halonctl = "cd " ++ tmp0 ++ "; " ++ buildPath </> "halonctl/halonctl"
          halond1 = "cd " ++ tmp1 ++ "; " ++ buildPath </> "halond/halond"
          halond2 = "cd " ++ tmp2 ++ "; " ++ buildPath </> "halond/halond"

      getSelfPid >>= copyLog (const True)

      say "Spawning halond ..."
      nid0 <- spawnLocalNode (halond1 ++ " -l " ++ m0loc ++ " 2>&1")
      nid1 <- spawnLocalNode (halond2 ++ " -l " ++ m1loc ++ " 2>&1")
      say $ "Redirecting logs from " ++ show nid0 ++ " ..."
      redirectLogsHere nid0
      say $ "Redirecting logs from " ++ show nid1 ++ " ..."
      redirectLogsHere nid1

      say "Spawning tracking station ..."
      systemLocal (halonctl
                     ++ " -l " ++ hctlloc
                     ++ " -a " ++ m0loc
                     ++ " bootstrap station"
                     )
      expectLog [nid0] (isInfixOf "New replica started in legislature://0")

      say "Starting satellite nodes ..."
      systemLocal (halonctl
                     ++ " -l " ++ hctlloc
                     ++ " -a " ++ m0loc
                     ++ " -a " ++ m1loc
                     ++ " bootstrap satellite"
                     ++ " -t " ++ m0loc)
      say "Started satellite nodes."
      expectLog [nid0] (isInfixOf $ "New node contacted: nid://" ++ m0loc)
      expectLog [nid0] (isInfixOf $ "New node contacted: nid://" ++ m1loc)
      expectLog [nid0, nid1] (isInfixOf "Node succesfully joined the cluster.")

      say "Starting dummy service ..."
      systemLocal (halonctl ++ " -l " ++ hctlloc ++ " -a " ++ m1loc ++
                        " service dummy start -t " ++ m0loc)
      expectLog [nid1] (isInfixOf "Starting service dummy")
      expectLog [nid1] (isInfixOf "Hello World!")
