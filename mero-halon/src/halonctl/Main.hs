{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
module Main (main) where

import           Control.Distributed.Process hiding (bracket)
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , closeLocalNode
  , runProcess
  )
import           Control.Monad.Catch
import           Data.Char
import           Data.List
import           Data.Maybe (fromMaybe)
import           Data.Monoid
import           Data.Traversable
import           HA.Network.RemoteTables (haRemoteTable)
import qualified Handler.Halon as Halon
import qualified Handler.Mero as Mero
import           Lookup
import           Mero.RemoteTables (meroRemoteTable)
import           Network.Transport (closeTransport)
import           Network.Transport.TCP as TCP
import           Options.Applicative
import qualified Options.Applicative as O
import qualified Options.Applicative.Extras as O
import           System.Directory
import           System.Environment (getProgName)
import           System.Process (readProcess)
import           Version.Read


printHeader :: IO ()
printHeader = putStrLn "This is halonctl/TCP"

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

main :: IO ()
main = getOptions >>= maybe version run
  where
    version = do
      printHeader
      versionString >>= putStrLn


data Options = Options
    { optTheirAddress :: ![String] -- ^ Addresses of halond nodes to control.
    , optOurAddress   :: !String
    , optCommand      :: !Command
    }
  deriving (Show, Eq)

data Command =
      Mero Mero.Options
    | Halon Halon.Options
  deriving (Show, Eq)

newtype SystemOptions = SystemOptions (Last (String, String))

instance Monoid SystemOptions where
  mempty = SystemOptions mempty
  SystemOptions a1 `mappend` SystemOptions a2 = SystemOptions (a1 <> a2)

getOptions :: IO (Maybe Options)
getOptions = do
    self <- getProgName

    hostname <- readProcess "hostname" [] ""
    defaults <- doesFileExist sysconfig >>= \case
      True -> mconcat . fmap toSystemOptions . lines <$> readFile sysconfig
      False -> return mempty
    O.execParser $
      O.withFullDesc self (parseOptions hostname defaults)
        "Control nodes (halond instances)."
  where
    parseOptions :: String -> SystemOptions -> O.Parser (Maybe Options)
    parseOptions h o = O.flag' Nothing (O.long "version" <> O.hidden) O.<|> (Just <$> normalOptions h o)
    normalOptions hostname (SystemOptions la) = Options
        <$> (maybe O.some  (\(h,p) -> \x -> O.some x <|> pure [h++":"++p]) (getLast la) $
               O.strOption $ O.metavar "ADDRESSES" <>
                 O.long "address" <>
                 O.short 'a' <>
                 O.help "Addresses of nodes to control.")
        <*> (O.strOption $ O.metavar "ADDRESS" <>
               O.long "listen" <>
               O.short 'l' <>
               O.value (maybe (listenAddr hostname)
                              (listenAddr . fst) $ getLast la) <>
               O.help "Address halonctl binds to.")
        <*> (O.subparser $
                (O.command "halon" $ Halon <$> O.withDesc Halon.parser "Halon commands.")
             <> (O.command "mero" $ Mero <$> O.withDesc Mero.parser "Mero commands."))
    listenAddr :: String -> String
    listenAddr h = trim $ h ++ ":0"
    toSystemOptions line
      | "HALOND_LISTEN" `isPrefixOf` line = SystemOptions $ Last . Just $ extractIp (tail . snd $ span (/='=') line)
      | otherwise = SystemOptions $ Last Nothing
    extractIp = fmap tail . span (/= ':')
    sysconfig :: String
    sysconfig = "/etc/sysconfig/halond"

    trim = filter (liftA2 (||) isAlphaNum isPunctuation)

run :: Options -> IO ()
run (Options { .. }) =
  let (hostname, _:port) = break (== ':') optOurAddress in
  bracket (either (error . show) id <$>
               TCP.createTransport hostname port
               defaultTCPParameters { tcpUserTimeout = Just 2000
                                    , tcpNoDelay = True
                                    , transportConnectTimeout = Just 2000000
                                    }
          ) closeTransport $ \transport ->
  bracket (newLocalNode transport myRemoteTable) closeLocalNode $ \lnid -> do
  let rnids = fmap conjureRemoteNodeId optTheirAddress
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

    if null $ concat replies
      then case optCommand of
          Mero opts -> Mero.mero rnids opts
          Halon opts -> Halon.halon rnids opts
      else do
        say "Failed to connect to controlled nodes: "
        liftIO $ mapM_ putStrLn $ concat replies
        _ <- receiveTimeout 1000000 [] -- XXX: give a time to output logs
        return ()
  return ()
