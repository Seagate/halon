{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Status
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module Handler.Mero.Status
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
import           Control.Monad
import qualified Data.ByteString.Lazy.Char8 as BSL
import           Data.Foldable
import           Data.List (intercalate)
import           Data.List.Split (chunksOf)
import           Data.Monoid ((<>))
import qualified Data.Text as T
import qualified HA.Aeson
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import           HA.Resources.Castor (Host(..))
import qualified HA.Resources.Mero as M0
import           Handler.Mero.Helpers
import           Mero.ConfC (fidToStr)
import           Mero.Lnet (encodeEndpoint)
import           Mero.Spiel (FSStats(..))
import qualified Options.Applicative as Opt
import           Text.Printf (printf)

data Options = Options
  { _statusOptJSON :: Bool
  , _statusOptDevices :: Bool
  , _statusTimeout :: Int
  } deriving (Eq, Show)

parser :: Opt.Parser Options
parser = Options
  <$> Opt.switch
       ( Opt.long "json"
       <> Opt.help "Output in json format."
       )
  <*> Opt.switch
        ( Opt.long "show-devices"
       <> Opt.short 'd'
       <> Opt.help "Also show failed devices and their status. Devices are always shown in the JSON format.")
  <*> Opt.option Opt.auto
        ( Opt.metavar "TIMEOUT(s)"
       <> Opt.long "timeout"
       <> Opt.help "How long to wait for status, in seconds"
       <> Opt.value 10
       <> Opt.showDefault )

run :: [NodeId] -> Options -> Process ()
run nids (Options m d t) = clusterCommand nids (Just t) ClusterStatusRequest out
  where
    out = liftIO . case m of
      True -> jsonReport
      False -> prettyReport d

jsonReport :: ReportClusterState -> IO ()
jsonReport = BSL.putStrLn . HA.Aeson.encode

prettyReport :: Bool -> ReportClusterState -> IO ()
prettyReport showDevices (ReportClusterState status sns info' mstats hosts) = do
  putStrLn $ "Cluster is " ++ maybe "N/A" M0.prettyStatus status
  case info' of
    Nothing -> putStrLn "cluster information is not available, load initial data.."
    Just (M0.Profile_XXX3 pfid, M0.Filesystem_XXX3 ffid _ _)  -> do
      putStrLn   "  cluster info:"
      putStrLn $ "    profile:    " ++ fidToStr pfid
      putStrLn $ "    filesystem: " ++ fidToStr ffid
      forM_ mstats $ \stats -> do
        putStrLn "    Filesystem stats:"
        let fss = M0._fs_stats stats
        let entries =
              [ ("      Total space:    ", showGrouped $ _fss_total_disk fss)
              , ("      Free space:     ", showGrouped $ _fss_free_disk fss)
              , ("      Total segments: ", showGrouped $ _fss_total_seg fss)
              , ("      Free segments:  ", showGrouped $ _fss_free_seg fss)
              ]
        let width = maximum $ map (\(_, val) -> length val) entries
        forM_ entries $ \(label, val) -> do
          putStrLn $ label ++ printf ("%" ++ show width ++ "s") val
      unless (null sns) $ do
         putStrLn "    sns operations:"
         forM_ sns $ \(M0.Pool_XXX3 pool_fid, s) -> do
           putStrLn $ "      pool:" ++ fidToStr pool_fid ++ " => " ++ show (M0.prsType s)
           putStrLn $ "      uuid:" ++ show (M0.prsRepairUUID s)
           forM_ (M0.prsPri s) $ \i -> do
             putStrLn $ "      time of start: " ++ show (M0.priTimeOfSnsStart i)
             forM_ (M0.priStateUpdates i) $ \(M0.SDev{d_fid=sdev_fid,d_path=sdev_path},_) -> do
               putStrLn $ "          " ++ fidToStr sdev_fid ++ " -> " ++ sdev_path
      putStrLn "\nHosts:"
      forM_ hosts $ \(Host qfdn, ReportClusterHost m0fid st ps) -> do
         let (nst,extSt) = M0.displayNodeState st
         printf node_pattern nst (showNodeFid m0fid) qfdn
         for_ extSt $ printf node_pattern_ext (""::String)
         forM_ ps $ \( M0.Process{r_fid=rfid, r_endpoint=endpoint}
                     , ReportClusterProcess ptype proc_st srvs) -> do
           let (pst,proc_extSt) = M0.displayProcessState proc_st
           printf proc_pattern pst
                               (fidToStr rfid)
                               (T.unpack . encodeEndpoint $ endpoint)
                               ptype
           for_ proc_extSt $ printf proc_pattern_ext (""::String)
           for_ srvs $ \(ReportClusterService sst (M0.Service fid' t' _) sdevs) -> do
             let (serv_st,serv_extSt) = M0.displayServiceState sst
             printf serv_pattern serv_st
                                 (fidToStr fid')
                                 (show t')
             for_ serv_extSt $ printf serv_pattern_ext (""::String)
             when (showDevices && (not . null) sdevs) $ do
               putStrLn "    Devices:"
               forM_ sdevs $ \(M0.SDev{d_fid=sdev_fid,d_path=sdev_path}, sdev_st, mslot, msdev) -> do
                 let (sd_st,sdev_extSt) = M0.displaySDevState sdev_st
                 printf sdev_pattern sd_st
                                     (fidToStr sdev_fid)
                                     (maybe "No StorageDevice" show msdev)
                                     (sdev_path)
                 for_ sdev_extSt $ printf sdev_pattern_ext (""::String)
                 for_ mslot $ printf sdev_patterni (""::String) . show
   where
     showNodeFid Nothing = ""
     showNodeFid (Just (M0.Node fid)) = show fid

     -- E.g. showGrouped 1234567 ==> "1,234,567"
     showGrouped = reverse . intercalate "," . chunksOf 3 . reverse . show

     node_pattern  = "  [%9s] %-24s  %s\n"
     node_pattern_ext  = "  %13s Extended state: %s\n"

     proc_pattern  = "  [%9s] %-24s    %s %s\n"
     proc_pattern_ext  = "  %13s Extended state: %s\n"

     serv_pattern  = "  [%9s] %-24s      %s\n"
     serv_pattern_ext  = "  %13s Extended state: %s\n"

     sdev_pattern  = "  [%9s] %-24s        %s %s\n"
     sdev_pattern_ext  = "  %13s Extended state: %s\n"
     sdev_patterni = "  %13s %s\n"
