{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData      #-}
-- |
-- Module    : Handler.Mero.Status
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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
import qualified HA.Resources.Castor as Castor
import qualified HA.Resources.Mero as M0
import           Handler.Mero.Helpers
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
      False -> prettyReport d nids

jsonReport :: ReportClusterState -> IO ()
jsonReport = BSL.putStrLn . HA.Aeson.encode

prettyReport :: Bool -> [NodeId] -> ReportClusterState -> IO ()
prettyReport showDevices nids ReportClusterState{..} = do
  putStrLn $ "Cluster disposition: " ++ maybe "N/A" (show . M0._mcs_disposition) csrStatus
  case csrProfile of
    Nothing -> putStrLn "Cluster information is not available, load initial data first."
    Just prof -> do
      putStrLn   "  cluster info:"
      forM_ csrSnsPools $ \(pool, M0.PoolId poolId) ->
        putStrLn $ printf "    SNS pool:   %s \"%s\"" (fidStr pool) poolId
      forM_ csrDixPool $ \pool ->
        putStrLn $ "    DIX pool:   " ++ fidStr pool
      putStrLn $ "    profile:    " ++ fidStr prof
      forM_ csrStats $ \stats -> do
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
      unless (null csrSNS) $ do
         putStrLn "    SNS operations:"
         forM_ csrSNS $ \(pool, prs) -> do
           putStrLn $ "      pool: " ++ fidStr pool ++ " => " ++ show (M0.prsType prs)
           putStrLn $ "      uuid: " ++ show (M0.prsRepairUUID prs)
           forM_ (M0.prsPri prs) $ \i -> do
             putStrLn $ "      time of start: " ++ show (M0.priTimeOfSnsStart i)
             forM_ (M0.priStateUpdates i) $ \(M0.SDev{d_fid=sdev_fid,d_path=sdev_path},_) -> do
               putStrLn $ "          " ++ show sdev_fid ++ " -> " ++ sdev_path
      putStrLn "\nHosts:"
      forM_ csrHosts $ \( Castor.Host qfdn
                        , ReportClusterHost mnode st mnid isRC ps ) -> do
         let (nst, extSt) = M0.displayNodeState st
         printf node_pattern nst (maybe "" fidStr mnode) qfdn
         for_ extSt $ printf pattern_ext
         forM_ ps $ \( M0.Process{r_fid=rfid, r_endpoint=endpoint}
                     , ReportClusterProcess ptype proc_st srvs ) -> do
           let (pst, proc_extSt) = M0.displayProcessState proc_st
               tsTag | ptype /= "halon"          = "" :: String
                     | isRC                      = " (RC)"
                     | mnid `elem` map Just nids = " (TS)"
                     | otherwise                 = ""
           printf proc_pattern pst
                               (show rfid)
                               (T.unpack . encodeEndpoint $ endpoint)
                               ptype
                               tsTag
           for_ proc_extSt $ printf pattern_ext
           for_ srvs $ \(ReportClusterService sst svc sdevs) -> do
             let (serv_st, serv_extSt) = M0.displayServiceState sst
                 rmTag | Just svc == csrPrincipalRM = " (principal)"
                       | otherwise                  = "" :: String
             printf serv_pattern serv_st (fidStr svc) (show $ M0.s_type svc) rmTag
             for_ serv_extSt $ printf pattern_ext
             when (showDevices && (not . null) sdevs) $ do
               putStrLn "    Devices:"
               forM_ sdevs $ \( M0.SDev { d_fid = sdev_fid, d_path = sdev_path }
                              , sdev_st
                              , mslot
                              , msdev ) -> do
                 let (sd_st, sdev_extSt) = M0.displaySDevState sdev_st
                 printf sdev_pattern sd_st
                                     (show sdev_fid)
                                     (maybe "No StorageDevice" show msdev)
                                     sdev_path
                 for_ sdev_extSt $ printf pattern_ext
                 for_ mslot $ printf sdev_patterni . show
   where
     fidStr :: M0.ConfObj a => a -> String
     fidStr = show . M0.fid

     -- E.g. showGrouped 1234567 ==> "1,234,567"
     showGrouped = reverse . intercalate "," . chunksOf 3 . reverse . show

     indentation = replicate 16 ' '
     pattern_ext = indentation ++ "Extended state: %s\n"
     node_pattern  = "  [%9s] %-24s  %s\n"
     proc_pattern  = "  [%9s] %-24s    %s %s%s\n"
     serv_pattern  = "  [%9s] %-24s      %s%s\n"
     sdev_pattern  = "  [%9s] %-24s        %s %s\n"
     sdev_patterni = indentation ++ "%s\n"
