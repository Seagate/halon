--
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- This test starts halon on a single node and runs a mero test that notifies
-- of a state change.
--
{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

import Control.Distributed.Commands.Process
  ( systemLocal
  , spawnLocalNode
  , copyLog
  , expectLog
  , __remoteTable
  )

import Prelude hiding ((<$>))
import Control.Distributed.Process hiding (catch)
import Control.Monad.Catch (catch)
import Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , runProcess
  )

import Data.List (isInfixOf)

import Control.Applicative ((<$>))
import Control.Monad (when)
import Data.Maybe (catMaybes)
import System.Exit
import Network.Transport.TCP (createTransport, defaultTCPAddr
                                             , defaultTCPParameters)

import qualified Control.Exception as E (bracket, catch, SomeException)
import System.Directory (setCurrentDirectory, createDirectoryIfMissing)
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

    let testDir = takeDirectory buildPath </> "test" </> progName
    createDirectoryIfMissing True testDir

    argv <- getArgs
    prog <- getExecutablePath
    -- test if we have root privileges
    ((userid, _): _ ) <- reads <$> readProcess "id" ["-u"] ""
    when (userid /= (0 :: Int)) $ do
      -- Invoke again with root privileges
      putStrLn $ "Calling test with sudo ..."
      mld <- fmap ("LD_LIBRARY_PATH=" ++) <$> lookupEnv "LD_LIBRARY_PATH"
      mtl <- fmap ("DC_HOST_IP=" ++) <$> lookupEnv "DC_HOST_IP"
      mmr <- fmap ("M0_SRC_DIR=" ++) <$> lookupEnv "M0_SRC_DIR"
      callProcess "sudo" $ catMaybes [mld, mtl, mmr] ++ prog : argv
      exitSuccess

    setCurrentDirectory testDir
    putStrLn $ "Changed directory to: " ++ testDir

    let m0 = "0.0.0.0"
    Right nt <- createTransport (defaultTCPAddr m0 "4000") defaultTCPParameters
    n0 <- newLocalNode nt (__remoteTable initRemoteTable)
    let killHalond = E.catch (readProcess "pkill" [ "halond" ] "" >> return ())
                             (\e -> const (return ()) (e :: E.SomeException))

    E.bracket killHalond (const killHalond) $ const $ runProcess n0 $ do
      tmp0 <- liftIO $ mkdtemp $ testDir </> "tmp."
      tmp1 <- liftIO $ mkdtemp $ testDir </> "tmp."
      tmp2 <- liftIO $ mkdtemp $ testDir </> "tmp."
      let m0loc = m0 ++ ":9000"
          hctlloc = m0 ++ ":9002"
          ha_endpoint = "0@lo:12345:35:1"
          mero_endpoint = "0@lo:12345:35:2"

      let halonctl = "cd " ++ tmp0 ++ "; " ++ buildPath </> "halonctl/halonctl"
          halond = "cd " ++ tmp1 ++ "; " ++ buildPath </> "halond/halond"
          m0note = "cd " ++ tmp2 ++ "; $M0_SRC_DIR/ha/st/m0note"

      getSelfPid >>= copyLog (const True)

      say "Spawning halond ..."
      nid0 <- spawnLocalNode (halond ++ " -l " ++ m0loc ++ " 2>&1")

      say "Spawning tracking station ..."
      systemLocal (halonctl
                     ++ " -l " ++ hctlloc
                     ++ " -a " ++ m0loc
                     ++ " bootstrap station"
                     )
      expectLog [nid0] (isInfixOf "New replica started in legislature://0")

      say "Starting satellite node ..."
      systemLocal (halonctl
                     ++ " -l " ++ hctlloc
                     ++ " -a " ++ m0loc
                     ++ " bootstrap satellite"
                     ++ " -t " ++ m0loc)
      say "Started satellite nodes."
      expectLog [nid0] (isInfixOf $ "New node contacted: nid://" ++ m0loc)
      expectLog [nid0] (isInfixOf "Node succesfully joined the cluster.")

      say "Starting mero service ..."
      systemLocal (halonctl ++ " -l " ++ hctlloc ++ " -a " ++ m0loc ++
                        " service m0d start -t " ++ m0loc ++ " -l " ++
                        ha_endpoint ++ " -m " ++ mero_endpoint
                  )
      expectLog [nid0] (isInfixOf "Starting service m0d")

      say "Starting m0note ..."
      flip catch (\(_ :: E.SomeException) -> return ()) $
        systemLocal $ m0note ++ " -l " ++ mero_endpoint ++ " -a " ++ ha_endpoint
                             ++ " &> out.txt"
      expectLog [nid0] (isInfixOf "m0d: received state vector")
