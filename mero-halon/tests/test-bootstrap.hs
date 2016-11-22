--
-- Copyright : (C) 2016 Seagate Technology Limited.
--
-- In this program we test bootstrap as follows:
--
-- * Run `st/bootstrap.sh -s -c cluster_start` from Mero sources
-- * Run `hctl cluster status` and verify that no services are FAILED, OFFLINE
--   or STARTING.
-- * Do `dd if=/dev/zero of=/mnt/m0t1fs/0:1006001 bs=512K count=10` and check
--   successful completion
-- * Run `hctl cluster stop`
-- * Run `hctl cluster status` and verify that all Mero services are stopped.
-- * Run `st/bootstrap.sh -s -c cluster_stop`
--

{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

import HA.RecoveryCoordinator.Castor.Cluster.Events
import HA.Resources.Mero
import Helper.Environment
import Mero.ConfC

import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Aeson
import qualified Data.ByteString.Lazy as BSL (empty)
import qualified Data.ByteString.Lazy.Char8 as BSL (hPutStrLn)
import GHC.IO.Handle (hDuplicateTo, hDuplicate)
-- import GHC.Stack
import Language.Haskell.TH
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO
import System.Process
import qualified System.Process.ByteString.Lazy as BSL


-- Absolute path of the source code of the current module.
absSrcPath :: String
absSrcPath =
    $(litE . StringL =<< runIO getCurrentDirectory)
    </> $(litE . StringL . loc_filename =<< location)

-- | @hRedirect hFrom hTo action@ redirects handle @hFrom@ to handle @hTo@
-- for the execution of @action@.
hRedirect :: Handle -> Handle -> IO a -> IO a
hRedirect hFrom hTo action = bracket
    (do hFlush hFrom
        h' <- hDuplicate hFrom
        hDuplicateTo hTo hFrom
        return h'
    )
    (\h' -> do
      hDuplicateTo h' hFrom
      hClose h'
    )
    (const action)

main :: IO ()
main = withMeroRoot $ \mero_root -> do
  hSetBuffering stdout LineBuffering
  progName <- getProgName
  let fn = progName ++ ".log"
  putStrLn $ "Redirecting stdout and stderr to " ++ fn
  withFile fn WriteMode $ \fh -> hRedirect stdout fh $ hRedirect stderr fh $ do
    hSetBuffering stderr LineBuffering
    hSetBuffering stdout LineBuffering

    (ip, _) <- getTestListenSplit
    setEnv "IP" ip
    let halon_sources = takeDirectory $ takeDirectory $ takeDirectory absSrcPath
    setEnv "HALON_SOURCES" halon_sources
    buildDir <- takeDirectory . takeDirectory <$> getExecutablePath
    setEnv "HALOND" $ buildDir </> "halond/halond"
    setEnv "HALONCTL" $ buildDir </> "halonctl/halonctl"
    bracket_ (callCommand $ "cd " ++ show mero_root ++ "; "
                  ++ mero_root </> "st/bootstrap.sh -s -c cluster_start")
             (callCommand $ "cd " ++ show mero_root ++ "; "
                  ++ mero_root </> "st/bootstrap.sh -s -c cluster_stop") $ do

      BSL.readProcessWithExitCode (buildDir </> "halonctl/halonctl")
        [ "-l", ip ++ ":9010", "-a", ip ++ ":9000"
        , "cluster", "status", "--json"
        ]
        BSL.empty >>= checkStatus (`elem` [PSOnline, PSUnknown])
                                  "Got a bad status after starting the cluster."
      putStrLn "Calling dd ..."
      callProcess "sudo"
        ["dd", "if=/dev/zero", "of=/mnt/m0t1fs/0:1006001", "bs=1K", "count=10"]

      callProcess (buildDir </> "halonctl/halonctl")
        ["-l", ip ++ ":9010", "-a", ip ++ ":9000", "cluster", "stop"]

      putStrLn "Waiting 180 seconds ..."
      threadDelay (180 * 1000000)
      BSL.readProcessWithExitCode (buildDir </> "halonctl/halonctl")
        [ "-l", ip ++ ":9010", "-a", ip ++ ":9000"
        , "cluster", "status", "--json"
        ]
        BSL.empty >>= checkStatus (`elem` [PSOffline, PSUnknown])
                                  "Got a bad status after stoping the cluster."
  putStrLn "SUCCESS!"
  where
    checkStatus validProcState msg (rc, st, _) = do
      let parseStatus = join $
            (`fmap` Data.Aeson.eitherDecode st) $
              \cs ->
                let valid = all validProcState
                      [ crpState proc'
                      | (_, host) <- csrHosts cs
                      , (_, proc') <- crnProcesses host
                        -- filter halon process from checks
                      , all (/= CST_HA) $ map (s_type . fst) $ crpServices proc'
                      ]
                 in if valid then Right ()
                    else Left "Some process state is not valid."
          checkResult = if rc == ExitSuccess then parseStatus else Left (show rc)
      case checkResult of
        Left str -> do
          hPutStrLn stderr $ msg ++ ": " ++ str
          BSL.hPutStrLn stderr st
          exitFailure
        Right () -> return ()
