{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Control.Distributed.Commands.Process
  ( systemLocal
  , spawnLocalNode
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


import Control.Applicative ((<$>))
import Control.Monad (when, forM_, void)
import Data.Maybe (catMaybes)
import System.Exit
import Network.Transport.TCP (createTransport, defaultTCPParameters)

import qualified Control.Exception as E (bracket, bracket_, catch, SomeException)
import GHC.IO.Handle (hDuplicateTo, hDuplicate)
import System.Directory
import System.Environment
import System.IO
import System.FilePath ((</>), takeDirectory)
import System.Posix.Temp (mkdtemp)
import System.Process hiding (runProcess)
import System.Timeout
import System.SystemD.API
import Network.HostName

getBuildPath :: IO FilePath
getBuildPath = fmap (takeDirectory . takeDirectory) getExecutablePath

-- | @hRedirect hFrom hTo action@ redirects handle @hFrom@ to handle @hTo@
-- for the execution of @action@.
hRedirect :: Handle -> Handle -> IO a -> IO a
hRedirect hFrom hTo action = E.bracket
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

assertServiceRunning :: String -> Process ()
assertServiceRunning svs = do
  liftIO $ readProcessWithExitCode "systemctl" ["status", svs] "" >>= \case
    (ExitSuccess, _, _) -> return ()
    (c, _, _) -> fail $ "Service ‘" ++ svs ++ "’ is not running, " ++ show c

main :: IO ()
main =
  (>>= maybe (error "test timed out") return) $ timeout (120 * 1000000) $ do
  hSetBuffering stdout LineBuffering
  progName <- getProgName

  argv <- getArgs
  prog <- getExecutablePath
  tmpDir <- getTemporaryDirectory
  -- Creating @tmpDir </> "test"@ with the root user could interfere with other
  -- tests using the same folder.
  let testDir = tmpDir </> "test" </> progName
  createDirectoryIfMissing True testDir

  ((userid, _): _ ) <- reads <$> readProcess "id" ["-u"] ""
  when (userid /= (0 :: Int)) $ do
    -- Invoke again with root privileges
    putStrLn $ "Calling test with sudo ..."
    mld <- fmap ("LD_LIBRARY_PATH=" ++) <$> lookupEnv "LD_LIBRARY_PATH"
    mtl <- fmap ("DC_HOST_IP=" ++) <$> lookupEnv "DC_HOST_IP"
    mmr <- fmap ("MERO_ROOT=" ++) <$> lookupEnv "MERO_ROOT"
    tracing <- fmap ("HALON_TRACING=" ++) <$> lookupEnv "HALON_TRACING"
    units <- fmap (\s -> "SYSTEMD_UNIT_PATHS=" ++ s ++ ":") <$> lookupEnv "SYSTEMD_UNIT_PATHS"
    callProcess "sudo" $ catMaybes [mld, mtl, mmr, units, tracing] ++ prog : argv
    exitSuccess


  let fn = progName ++ ".stderr.log"

  putStrLn $ "Redirecting stderr to " ++ fn
  withFile fn WriteMode $ \fh -> hRedirect stderr fh $ do
    hSetBuffering stderr LineBuffering

    buildPath <- getBuildPath

    setCurrentDirectory testDir
    putStrLn $ "Changed directory to: " ++ testDir

    let m0 = "0.0.0.0"
    Right nt <- createTransport m0 "4000" defaultTCPParameters
    n0 <- newLocalNode nt (__remoteTable initRemoteTable)

    -- services which we are expecting to see started and should
    -- stop during cleanup
    let expectedServices = ["mero-kernel"]
        -- TODO m0d@ doesn't get cleaned because we need to either
        -- know the fid ahead of time or extract it
        m0dAtUnitFilePath = "/etc/systemd/system/m0d@.service"
    writeFile m0dAtUnitFilePath m0dAtUnitFile

    let killHalond = E.catch (readProcess "pkill" [ "halond" ] "" >> return ())
                             (\e -> const (return ()) (e :: E.SomeException))
        stopServices = do
          forM_ expectedServices stopService
          removeFile m0dAtUnitFilePath

    E.bracket_ killHalond (killHalond >> stopServices) $ runProcess n0 $ do
      tmp0 <- liftIO $ mkdtemp $ testDir </> "tmp."
      tmp1 <- liftIO $ mkdtemp $ testDir </> "tmp."
      tmp2 <- liftIO $ mkdtemp $ testDir </> "tmp."
      tmp3 <- liftIO $ mkdtemp $ testDir </> "tmp."
      let halonFacts = tmp0 </> "halon_facts.yaml"

      host <- liftIO getHostName
      say $ "Creating halon facts file with hostname "
         ++ host ++ " under " ++ halonFacts

      liftIO . writeFile halonFacts $ facts host


      let m0loc = m0 ++ ":9010"
          hctlloc = m0 ++ ":9001"

      let station = "cd " ++ tmp0 ++ "; " ++ buildPath </> "halonctl/halonctl"
          halond = "cd " ++ tmp1 ++ "; " ++ buildPath </> "halond/halond"
          satellite = "cd " ++ tmp2 ++ "; " ++ buildPath </> "halonctl/halonctl"
          cluster = "cd " ++ tmp3 ++ "; " ++ buildPath </> "halonctl/halonctl"

      self <- getSelfPid
      copyLog (const True) self

      say "Spawning halond ..."
      nid0 <- spawnLocalNode (halond ++ " -l " ++ m0loc ++ " > /tmp/halond1 2>&1")

      say "Spawning tracking station ..."
      systemLocal (station
                     ++ " -l " ++ hctlloc
                     ++ " -a " ++ m0loc
                     ++ " bootstrap station"
                     )
      expectLog [nid0] (isInfixOf "New replica started in legislature://0")

      say "Loading initial data"
      systemLocal (cluster
                     ++ " -l " ++ hctlloc
                     ++ " -a " ++ m0loc
                     ++ " cluster load"
                     ++ " -f " ++ halonFacts)

      expectLog [nid0] (isInfixOf "Loaded initial data")
      say "Loaded initial data, waiting for server bootstrap"


      say "Starting satellite node..."
      systemLocal (satellite
                     ++ " -l " ++ hctlloc
                     ++ " -a " ++ m0loc
                     ++ " bootstrap satellite"
                     ++ " -t " ++ m0loc)

      expectLog [nid0] (isInfixOf $ "New node contacted: nid://" ++ m0loc)
      say "Started satellite nodes."

      say "Waiting for server bootstrap"
      let p msg = isInfixOf "Starting m0d@" msg
                  || isInfixOf "Finished bootstrapping mero server" msg

      mfid <- matchIfAction [nid0] p $ \msg -> do
        case [ fid | 'm':'0':'d':'@':fid <- words msg ] of
          [] -> return Nothing
          fid:_ -> return $ Just fid

      -- expectLog [nid0] (isInfixOf "Finished bootstrapping mero server")
      case mfid of
        Nothing -> forM_ expectedServices assertServiceRunning
        Just fid -> do
          forM_ (("m0d@" ++ fid) : expectedServices) assertServiceRunning
          void . liftIO . stopService $ "m0d@" ++ fid

-- | Like 'expectLog' but can run a 'Process' callback on the message as well
matchIfAction :: [NodeId] -> (String -> Bool) -> (String -> Process a) -> Process a
matchIfAction nids p hook = receiveWait
  [ matchIf (\(_ :: String, pid, msg) -> elem (processNodeId pid) nids && p msg)
            (\(_, _, msg) -> hook msg)
  ]

m0dAtUnitFile :: String
m0dAtUnitFile = unlines $
  [ "[Unit]"
  , "Description=m0d@ dummy service, provided by halon"
  , "After=mero-kernel.service"
  , ""
  , "[Service]"
  , "EnvironmentFile=/etc/sysconf/m0d-%i"
  , "Type=oneshot"
  , "RemainAfterExit=yes"
  , "ExecStart=/bin/true"
  , ""
  , "[Install]"
  , "WantedBy=multi-user.target"
  ]

-- | Given hostname of the current machine, generate contents of halon
-- facts file for use in the test
facts :: String -> String
facts host = unlines $
  [ "id_racks_XXX0:"
  , "- rack_idx: 1"
  , "  rack_enclosures:"
  , "  - enc_idx_XXX0: 1"
  , "    enc_bmc_XXX0:"
  , "    - bmc_user: admin"
  , "      bmc_addr: bmc.enclosure1"
  , "      bmc_pass: admin"
  , "    enc_hosts_XXX0:"
  , "    - h_cpucount: 8"
  , "      h_fqdn_XXX0: " ++ host
  , "      h_memsize: 4096"
  , "      h_interfaces:"
  , "      - if_network: Data"
  , "        if_macAddress: '10-00-00-00-00'"
  , "        if_ipAddrs:"
  , "        - auto"
  , "    enc_id_XXX0: enclosure1"
  , "id_m0_servers_XXX0:"
  , "- m0h_processes:"
  , "  - m0p_services:"
  , "    - m0s_endpoints:"
  , "      - auto:12345:44:101"
  , "      m0s_params:"
  , "        tag: SPConfDBPath"
  , "        contents: /var/mero/confd"
  , "      m0s_type:"
  , "        tag: CST_CONFD"
  , "        contents: []"
  , "    m0p_mem_rss: 1"
  , "    m0p_mem_as: 1"
  , "    m0p_mem_memlock: 1"
  , "    m0p_cores:"
  , "    - 1"
  , "    m0p_mem_stack: 1"
  , "    m0p_endpoint: auto:12345:44:101"
  , "  - m0p_services:"
  , "    - m0s_endpoints:"
  , "      - auto:12345:41:201"
  , "      m0s_params:"
  , "        tag: SPUnused"
  , "        contents: []"
  , "      m0s_type:"
  , "        tag: CST_MDS"
  , "        contents: []"
  , "    m0p_mem_rss: 1"
  , "    m0p_mem_as: 1"
  , "    m0p_mem_memlock: 1"
  , "    m0p_cores:"
  , "    - 1"
  , "    m0p_mem_stack: 1"
  , "    m0p_endpoint: auto:12345:41:201"
  , "  m0h_devices: []"
  , "  m0h_fqdn: " ++ host
  , "id_m0_globals_XXX0:"
  , "  m0_max_rpc_msg_size: 65536"
  , "  m0_parity_units: 1"
  , "  m0_md_redundancy: 2"
  , "  m0_t1fs_mount: /mnt/mero"
  , "  m0_data_units: 2"
  , "  m0_be_segment_size: 536870912"
  , "  m0_failure_set_gen:"
  , "    tag: Dynamic"
  , "    contents: []"
  , "  m0_pool_width: 8"
  , "  m0_uuid: 096051ac-b79b-4045-a70b-1141ca4e4de1"
  , "  m0_min_rpc_recvq_len: 16"
  , "  m0_lnet_nid: auto"
  , "  m0_datadir: /var/mero"
  ]
