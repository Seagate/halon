{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
--
-- Entry point for halon-st.
module Main where

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Node
                   (initRemoteTable, newLocalNode, runProcess)
import           Data.List (intercalate)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromMaybe)
import           Data.Monoid ((<>))
import           Data.Traversable
import           HA.Network.RemoteTables (haRemoteTable)
import qualified HA.ST.ClusterRunning
import           HA.ST.Common
import           Mero.RemoteTables (meroRemoteTable)
import           Network.BSD (getHostName, HostName)
import           Network.Transport.TCP as TCP
import qualified Options.Applicative as Opt
import           System.Environment (getProgName)
import           System.Exit
import           System.IO (stderr, hPutStrLn)
import qualified Test.Tasty as T
import qualified Test.Tasty.HUnit as T
import qualified Test.Tasty.Runners as T

-- | List of tests to expose to the user. Add new tests here.
tests :: [HASTTest]
tests =
  [ HA.ST.ClusterRunning.test
  ]

-- | Look-up map for 'tests'.
testMap :: Map.Map String HASTTest
testMap = Map.fromList $ map (\v -> (_st_name v, v)) tests

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

main :: IO ()
main = do
  pname <- getProgName
  guessedHostname <- getHostName

  -- optparse-applicative #53
  let mkDefaultTS a = if null $ _sta_trackers a
                      then a { _sta_trackers = tsDefault guessedHostname }
                      else a

  STArgs{..} <- fmap mkDefaultTS . Opt.execParser $
    Opt.info (Opt.helper <*> opts guessedHostname)
      ( Opt.header pname
       <> Opt.progDesc "Run halon-st tests."
       <> Opt.fullDesc
      )

  let (hostname, _:port) = break (== ':') _sta_listen
  transport <- either (error . show) id <$>
               TCP.createTransport hostname port
               defaultTCPParameters { tcpUserTimeout = Just 2000
                                    , tcpNoDelay = True
                                    , transportConnectTimeout = Just 2000000
                                    }
  let conjureRemoteNodeId addr = let (h, _:p) = break (== ':') addr
                                 in NodeId $ TCP.encodeEndPointAddress h p 0
  lnid <- newLocalNode transport myRemoteTable
  let rnids = fmap conjureRemoteNodeId _sta_trackers
  runProcess lnid $ do
    replies <- forM rnids $ \nid -> do
      (_, mref) <- spawnMonitor nid (returnCP sdictUnit ())
      let mkErrorMsg msg = "Error connecting to " ++ show nid ++ ": " ++ msg
      fromMaybe [mkErrorMsg "connect timeout"] <$> receiveTimeout 5000000
        [ matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
                  (\(ProcessMonitorNotification _ _ dr) -> do
                      return $ case dr of
                        DiedException e -> [mkErrorMsg $ "got exception (" ++ e ++ ")."]
                        DiedDisconnect -> [mkErrorMsg  "node disconnected."]
                        DiedNodeDown -> [mkErrorMsg "node is down."]
                        _ -> []
                  )
        ]
    self <- getSelfPid
    promulgateEQ rnids $ RequestRCInfo self
    expectTimeout _sta_eq_timeout  >>= \case
      Nothing -> liftIO $ do
        hPutStrLn stderr "Waited too long for reply from RC"
        exitFailure
      Just ans -> do
        let ta = TestArgs { _ta_eq_nids = rnids
                          , _ta_eq_pid = _rci_eq_pid ans
                          , _ta_rc_pid = _rci_rc_pid ans }
        if null $ concat replies
          then liftIO $ runTest ta _sta_test
          else do
            say "Failed to connect to controlled nodes: "
            liftIO $ mapM_ (hPutStrLn stderr) $ concat replies
            _ <- receiveTimeout 1000000 [] -- XXX: give a time to output logs
            return ()
  return ()

tsDefault :: HostName -> [String]
tsDefault = return . (++ ":9000")

listenDefault :: HostName -> String
listenDefault = (++ ":9002")

runTest :: TestArgs -> HASTTest -> IO ()
runTest args t = case T.tryIngredients T.defaultIngredients mempty (toTree args t) of
  Nothing -> do
    hPutStrLn stderr "Tasty test framework complained that it couldn't run."
    exitFailure
  Just act -> act >>= \case
    True -> exitSuccess
    False -> exitFailure

toTree :: TestArgs -> HASTTest -> T.TestTree
toTree args t = T.testCase (_st_name t) $ _st_action t args >>= \case
  Nothing -> return ()
  Just err -> T.assertFailure err

opts :: HostName -> Opt.Parser STArgs
opts hostname = STArgs
   <$> ( Opt.argument stParser $
            Opt.metavar "TESTNAME"
         <> Opt.help ("Test name. One of " ++ show (Map.keys testMap))
       )
   <*> ( Opt.strOption $
           Opt.metavar "ADDRESS"
        <> Opt.long "listen"
        <> Opt.short 'l'
        <> Opt.value (listenDefault hostname)
        <> Opt.help "Address halonctl binds to."
        <> Opt.showDefaultWith id
       )
   <*> ( Opt.many . Opt.strOption $
            Opt.short 't'
         <> Opt.long "trackers"
         <> Opt.help ("Addresses of tracking station nodes. (default: "
                      ++ show (tsDefault hostname) ++ ")")
         <> Opt.metavar "ADDRESS"
       )
   <*> Opt.option Opt.auto
      ( Opt.metavar "TIMEOUT (μs)"
        <> Opt.long "eqt-timeout"
        <> Opt.value 1000000
        <> Opt.help ("Time to wait from a reply from the EQT when" ++
                     " querying the location of an EQ.")
        <> Opt.showDefault
      )

stParser :: Opt.ReadM HASTTest
stParser = Opt.eitherReader $ \s -> case Map.lookup s testMap of
  Nothing -> Left $ "Can't find test " ++ show s
  Just t -> Right t

showList :: [String] -> String
showList xs = '[' : intercalate "," xs ++ "]"
