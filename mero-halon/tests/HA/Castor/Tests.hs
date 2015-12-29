{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
module HA.Castor.Tests (tests, initialData, initialDataAddr) where

import Control.Distributed.Process
  ( Process
  , RemoteTable
  , liftIO
  , getSelfNode
  , say
  , unClosure
  )
import Control.Distributed.Process.Internal.Types (nullProcessId)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Monad (forM_, join)

import Data.List (sort, unfoldr, isPrefixOf, findIndex)
import qualified Data.Set as Set

import Network.Transport (Transport)
import Network.CEP
  ( Buffer
  , PhaseM
  , emptyFifoBuffer
  , liftProcess
  )
import Network.CEP.Testing (runPhase, runPhaseGet)

import HA.Multimap
import HA.Multimap.Implementation (Multimap, fromList)
import HA.Multimap.Process (startMultimap)
#ifdef USE_MERO
import HA.RecoveryCoordinator.Actions.Mero
#endif
import HA.RecoveryCoordinator.Mero
import HA.Replicator (RGroup(..))
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock (MC_RG)
#else
import HA.Replicator.Log (MC_RG)
#endif
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import HA.ResourceGraph hiding (__remoteTable)


import RemoteTables (remoteTable)
import TestRunner

import Test.Framework
import System.IO
import System.Mem
import GHC.Stats

import Helper.InitialData
import Helper.Environment (systemHostname)
import Helper.RC

mmSDict :: SerializableDict Multimap
mmSDict = SerializableDict

remotable
  [ 'mmSDict ]

myRemoteTable :: RemoteTable
myRemoteTable = HA.Castor.Tests.__remoteTable remoteTable

rGroupTest :: Transport -> (StoreChan -> Process ()) -> IO ()
rGroupTest transport p =
  withLocalNode transport myRemoteTable $ \lnid2 ->
  withLocalNode transport myRemoteTable $ \lnid3 ->
  tryRunProcessLocal transport myRemoteTable $ do
    nid <- getSelfNode
    rGroup <- newRGroup $(mkStatic 'mmSDict) 30 1000000
                [nid, localNodeId lnid2, localNodeId lnid3] (fromList [])
                >>= unClosure
                >>= (`asTypeOf` return (undefined :: MC_RG Multimap))
    (_, mmchan) <- startMultimap rGroup id
    p mmchan

tests :: String -> Transport -> [TestTree]
tests host transport = map (localOption (mkTimeout $ 10*60*1000000))
  [ testSuccess "failure-sets" $ testFailureSets transport
  , testSuccess "initial-data-doesn't-error" $ loadInitialData host transport
  , testSuccess "large-data" $ largeInitialData host transport
  ]

fsSize :: FailureSet -> Int
fsSize (FailureSet a _) = Set.size a

testFailureSets :: Transport -> IO ()
testFailureSets transport = rGroupTest transport $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    (ls', _) <- run ls $ do
      mapM_ goRack (CI.id_racks initialData)
      filesystem <- initialiseConfInRG
      loadMeroGlobals (CI.id_m0_globals initialData)
      loadMeroServers filesystem (CI.id_m0_servers initialData)
    -- 8 disks, tolerating one disk failure at a time
    failureSets <- runGet ls' $ generateFailureSets 1 0 0
    say $ show failureSets
    assertMsg "Number of failure sets (100)" $ length failureSets == 9
    assertMsg "Smallest failure set is empty (100)"
      $ fsSize (head failureSets) == 0

    -- 8 disks, two failures at a time
    failureSets2 <- runGet ls' $ generateFailureSets 2 0 0
    assertMsg "Number of failure sets (200)" $ length failureSets2 == 37
    assertMsg "Smallest failure set is empty (200)"
      $ fsSize (head failureSets2) == 0
    assertMsg "Next smallest failure set has one disk (200)"
      $ fsSize (failureSets2 !! 1) == 1

loadInitialData :: String -> Transport -> IO ()
loadInitialData host transport = rGroupTest transport $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    (ls', _) <- run ls $ do
      -- TODO: the interface address is hard-coded here: currently we
      -- don't use it so it doesn't impact us but in the future we
      -- should also take it as a parameter to the test, just like the
      -- host
      mapM_ goRack (CI.id_racks (initialDataAddr host "192.0.2.2" 8))
      filesystem <- initialiseConfInRG
      loadMeroGlobals (CI.id_m0_globals initialData)
      loadMeroServers filesystem (CI.id_m0_servers initialData)
      rg <- getLocalGraph
      failureSets <- generateFailureSets 2 2 1
      let pvers = failureSetToPoolVersion rg filesystem <$> failureSets
      createPoolVersions filesystem pvers
    -- Verify that everything is set up correctly
    bmc <- runGet ls' $ findBMCAddress myHost
    assertMsg "Get BMC Address." $ bmc == Just host
    hosts <- runGet ls' $ findHosts ".*"
    assertMsg "Find correct hosts." $ hosts == [myHost]
    hostAttrs <- runGet ls' $ findHostAttrs myHost
    assertMsg "Host attributes"
      $ sort hostAttrs == sort [HA_MEMSIZE_MB 4096, HA_CPU_COUNT 8]
    (Just fs) <- runGet ls' getFilesystem
    let pool = M0.Pool (M0.f_mdpool_fid fs)
    assertMsg "MDPool is stored in RG"
      $ memberResource pool (lsGraph ls')
    mdpool <- runGet ls' $ lookupConfObjByFid (M0.f_mdpool_fid fs)
    assertMsg "MDPool is findable by Fid"
      $ mdpool == Just pool
    -- We have 8 disks in only a single enclosure. Thus, each disk should
    -- be in 29 pool versions (1 with 0 failures, 7 with 1 failure, 21 with
    -- 2 failures)

    let g = lsGraph ls'
        racks = connectedTo fs M0.IsParentOf g :: [M0.Rack]
        encls = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Enclosure]) racks
        ctrls = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Controller]) encls
        disks = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Disk]) ctrls

        sdevs = join $ fmap (\r -> connectedTo r Has g :: [StorageDevice]) hosts
        disksByHost = join $ fmap (\r -> connectedFrom M0.At r g :: [M0.Disk]) sdevs

        disk1 = head disks
        dvers1 = connectedTo disk1 M0.IsRealOf g :: [M0.DiskV]


    assertMsg "Number of racks" $ length racks == 1
    assertMsg "Number of enclosures" $ length encls == 1
    assertMsg "Number of controllers" $ length ctrls == 1
    assertMsg "Number of storage devices" $ length sdevs == 8
    assertMsg "Number of disks (reached by host)" $ length disksByHost == 8
    assertMsg "Number of disks" $ length disks == 8
    assertMsg "Number of disk versions" $ length dvers1 == 29


  where
    myHost = Host systemHostname

printMem :: IO ()
printMem = do
  performGC
  readFile "/proc/self/status" >>=
    hPutStr stderr . unlines . filter (\x -> any (`isPrefixOf` x) ["VmHWM", "VmRSS"])
                   . lines
  stats <- getGCStats
  hPutStrLn stderr $ "In use according to GC stats: " ++
    show (currentBytesUsed stats `div` (1024 * 1024)) ++ " MB"
  hPutStrLn stderr $ "HWM according the GC stats: " ++
    show (maxBytesUsed stats `div` (1024 * 1024)) ++ " MB"
  hPutStrLn stderr ""

largeInitialData :: String -> Transport -> IO ()
largeInitialData host transport = let
    numDisks = 300
    initD = (initialDataAddr host "192.0.2.2" numDisks)
    myHost = Host systemHostname
  in
    rGroupTest transport $ \pid -> do
      me <- getSelfNode
      ls <- emptyLoopState pid (nullProcessId me)
      (ls', _) <- run ls $ do
        rg <- getLocalGraph
        -- TODO: the interface address is hard-coded here: currently we
        -- don't use it so it doesn't impact us but in the future we
        -- should also take it as a parameter to the test, just like the
        -- host
        mapM_ goRack (CI.id_racks initD)
        filesystem <- initialiseConfInRG
        loadMeroGlobals (CI.id_m0_globals initD)
        loadMeroServers filesystem (CI.id_m0_servers initD)
        failureSets <- generateFailureSets 1 0 0
        let chunks = flip unfoldr failureSets $ \xs ->
              case xs of
                [] -> Nothing
                _  -> case findIndex (>2000) $ scanl1 (+) $
                             map ((numDisks -) . fsSize) xs of
                  -- put all sets in one chunk
                  Nothing -> Just (xs, [])
                  -- ensure at most one set is in the chunk
                  -- TODO: split failure sets which are too big.
                  Just i -> Just $ splitAt (max 1 i) xs
        liftProcess $ liftIO $ hPutStrLn stderr $ "have " ++ show (length chunks) ++
                      " chunks for " ++ show (length failureSets) ++ " failure sets."
        forM_ (zip [0..] chunks) $ \(i, chunk) -> do
          let pvers = failureSetToPoolVersion rg filesystem <$> chunk
          createPoolVersions filesystem pvers
          liftProcess $ liftIO $ hPutStrLn stderr $ "submitting chunk " ++ show (i :: Int)
          syncGraph (return ())

      -- Verify that everything is set up correctly
      bmc <- runGet ls' $ findBMCAddress myHost
      assertMsg "Get BMC Address." $ bmc == Just host
      hosts <- runGet ls' $ findHosts ".*"
      assertMsg "Find correct hosts." $ hosts == [myHost]
      hostAttrs <- runGet ls' $ findHostAttrs myHost
      assertMsg "Host attributes"
        $ sort hostAttrs == sort [HA_MEMSIZE_MB 4096, HA_CPU_COUNT 8]
      (Just fs) <- runGet ls' getFilesystem
      let pool = M0.Pool (M0.f_mdpool_fid fs)
      assertMsg "MDPool is stored in RG"
        $ memberResource pool (lsGraph ls')
      mdpool <- runGet ls' $ lookupConfObjByFid (M0.f_mdpool_fid fs)
      assertMsg "MDPool is findable by Fid"
        $ mdpool == Just pool

      liftIO printMem
      -- let g = lsGraph ls'
      g <- getGraph pid
      let racks = connectedTo fs M0.IsParentOf g :: [M0.Rack]
          encls = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Enclosure]) racks
          ctrls = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Controller]) encls
          disks = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Disk]) ctrls

          sdevs = join $ fmap (\r -> connectedTo r Has g :: [StorageDevice]) hosts
          disksByHost = join $ fmap (\r -> connectedFrom M0.At r g :: [M0.Disk]) sdevs

      liftIO printMem
      assertMsg "Number of racks" $ length racks == 1
      assertMsg "Number of enclosures" $ length encls == 1
      assertMsg "Number of controllers" $ length ctrls == 1
      assertMsg "Number of storage devices" $ length sdevs == numDisks
      assertMsg "Number of disks (reached by host)" $ length disksByHost == numDisks
      assertMsg "Number of disks" $ length disks == numDisks

run :: forall g. g
    -> PhaseM g Int ()
    -> Process (g, [(Buffer, Int)])
run ls = runPhase ls (0 :: Int) emptyFifoBuffer

runGet :: forall g a. g -> PhaseM g (Maybe a) a -> Process a
runGet = runPhaseGet

goRack :: forall l. CI.Rack
       -> PhaseM LoopState l ()
goRack (CI.Rack{..}) = let rack = Rack rack_idx in do
  registerRack rack
  mapM_ (goEnc rack) rack_enclosures
goEnc :: forall l. Rack
      -> CI.Enclosure
      -> PhaseM LoopState l ()
goEnc rack (CI.Enclosure{..}) = let
    enclosure = Enclosure enc_id
  in do
    registerEnclosure rack enclosure
    mapM_ (registerBMC enclosure) enc_bmc
    mapM_ (goHost enclosure) enc_hosts
goHost :: forall l. Enclosure
       -> CI.Host
       -> PhaseM LoopState l ()
goHost enc (CI.Host{..}) = let
    host = Host h_fqdn
    mem = fromIntegral h_memsize
    cpucount = fromIntegral h_cpucount
    attrs = [HA_MEMSIZE_MB mem, HA_CPU_COUNT cpucount]
  in do
    registerHost host
    locateHostInEnclosure host enc
    mapM_ (setHostAttr host) attrs
    mapM_ (registerInterface host) h_interfaces
