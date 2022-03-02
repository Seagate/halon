{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE RecordWildCards #-}
-- |
-- Copyright : (C) 2013-2018 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
module Main (main) where

import           Control.Applicative ((<|>), some)
import           Control.Distributed.Process hiding (bracket)
import           Control.Distributed.Process.Closure (sdictUnit, returnCP)
import           Control.Distributed.Process.Node
  ( initRemoteTable
  , newLocalNode
  , closeLocalNode
  , runProcess
  )
import           Control.Monad (unless)
import           Control.Monad.Catch (bracket)
import           Data.Char (isAlphaNum, isPunctuation)
import           Data.List (isInfixOf, isPrefixOf)
import           Data.Maybe (fromMaybe)
import           Data.Monoid (Last(..), (<>))
import           Data.Traversable (forM)
import           HA.Network.RemoteTables (haRemoteTable)
import qualified Handler.Halon as Halon
import qualified Handler.Mero as Mero
import qualified Handler.Debug as Debug
import           Lookup (conjureRemoteNodeId)
import           Mero.RemoteTables (meroRemoteTable)
import           Network.Transport (closeTransport)
import           Network.Transport.TCP
  ( TCPParameters(..)
  , createTransport
  , defaultTCPAddr
  , defaultTCPParameters
  )
import qualified Options.Applicative as O
import           Options.Applicative.Extras (command', withFullDesc)
import           System.Directory (doesFileExist)
import           System.Environment (getProgName, getArgs)
import           System.IO
  ( BufferMode(LineBuffering)
  , hSetBuffering
  , stderr
  , stdout
  )
import qualified System.Log.Handler.Syslog as L
import qualified System.Log.Logger as L
import           System.Process (readProcess)
import           Version.Read (versionString)

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

initLogging :: String -> IO ()
initLogging progName = do
  s <- L.openlog progName [L.PID] L.USER L.INFO
  L.updateGlobalLogger L.rootLoggerName (L.setLevel L.INFO . L.setHandlers [s])

logArgs :: String -> [String] -> IO ()
logArgs progName args = do
  -- `hctl mero status` command is called too often. It would flood the log.
  let noisy = ["mero", "status"] `isInfixOf` args
  unless noisy . L.infoM progName $ "args=" ++ show args

main :: IO ()
main = do
  prog <- getProgName
  initLogging prog
  getArgs >>= logArgs prog
  options <- getOpts
  case options of
    Version  -> putStrLn ("This is " ++ prog) >> versionString >>= putStrLn
    Run opts -> run opts

data Opts = Version | Run Options

data Options = Options
  { optTheirAddress :: ![String] -- ^ Addresses of halond nodes to control.
  , optOurAddress   :: !String
  , optCommand      :: !Command
  }

data Command
  = Mero Mero.Options
  | Halon Halon.Options
  | Debug Debug.Options

type SystemOptions = Last (String, String)

getOpts :: IO Opts
getOpts = do
    prog <- getProgName
    hostname <- readProcess "hostname" [] ""
    defaults <- let sysconfig = "/etc/sysconfig/halond"
                in doesFileExist sysconfig >>= \case
        True  -> mconcat . fmap toSystemOptions . lines <$> readFile sysconfig
        False -> return mempty
    let parser = parseVersion <|> (Run <$> parseOptions hostname defaults)
    O.execParser $ withFullDesc prog parser "Control nodes (halond instances)."
  where
    toSystemOptions line
      | "HALOND_LISTEN" `isPrefixOf` line =
            Last . Just . breakAt ':' . snd $ breakAt '=' line
      | otherwise = Last Nothing

    parseVersion :: O.Parser Opts
    parseVersion = O.flag' Version $ O.long "version"
                                  <> O.help "Show version information and exit."

    parseOptions :: String -> SystemOptions -> O.Parser Options
    parseOptions hostname (Last mhp) = Options
        <$> (maybe some (\(h, p) -> \x -> some x <|> pure [h ++ ":" ++ p]) mhp $
             O.strOption $ O.metavar "ADDRESSES"
                        <> O.short 'a'
                        <> O.long "address"
                        <> O.help "Addresses of nodes to control.")
        <*> (O.strOption $ O.metavar "ADDRESS"
                        <> O.short 'l'
                        <> O.long "listen"
                        <> O.value (listenAddr $ maybe hostname fst mhp)
                        <> O.help "Address halonctl binds to.")
        <*> (O.hsubparser $ (command' "halon" (Halon <$> Halon.parser)
                             "Halon commands.")
                         <> (command' "mero" (Mero <$> Mero.parser)
                             "Mero commands.")
                         <> (command' "debug" (Debug <$> Debug.parser)
                             "Commands for troubleshooting."))

    listenAddr :: String -> String
    listenAddr = (++ ":0") . filter (\c -> isAlphaNum c || isPunctuation c)

breakAt :: Eq a => a -> [a] -> ([a], [a])
breakAt x = fmap tail . break (== x)

run :: Options -> IO ()
run Options{..} =
  let (hostname, port) = breakAt ':' optOurAddress in
  bracket (either (error . show) id <$>
               createTransport (defaultTCPAddr hostname port)
               defaultTCPParameters { tcpUserTimeout = Just 2000
                                    , tcpNoDelay = True
                                    , transportConnectTimeout = Just 2000000
                                    }
          ) closeTransport $ \transport ->
  bracket (newLocalNode transport myRemoteTable) closeLocalNode $ \lnid -> do
  let rnids = map conjureRemoteNodeId optTheirAddress
  runProcess lnid $ do
    -- Default buffering mode may result in gibberish in systemd logs.
    liftIO $ hSetBuffering stdout LineBuffering
    liftIO $ hSetBuffering stderr LineBuffering
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
          Debug opts -> Debug.run rnids opts
      else do
        say "Failed to connect to controlled nodes: "
        liftIO $ mapM_ putStrLn $ concat replies
        _ <- receiveTimeout 1000000 [] -- XXX: give a time to output logs
        return ()
  return ()
