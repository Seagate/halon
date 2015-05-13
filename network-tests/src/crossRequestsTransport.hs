{-# LANGUAGE RecordWildCards #-}
import Control.Distributed.Commands.IPTables
import Control.Distributed.Commands
import Control.Distributed.Commands.Management (withHostNames)
import Control.Distributed.Commands.Providers
  ( getHostAddress
  , getProvider
  )

import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Binary (encode, decode)
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Time

import Network.Transport.TCP
import Network.Transport

import System.Environment
import System.FilePath ((</>), takeDirectory)
import System.IO


getBuildPath :: IO FilePath
getBuildPath = fmap (takeDirectory . takeDirectory) getExecutablePath

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    ip <- getHostAddress
    argv <- getArgs
    Right nt <- createTransport ip "4000"
                  defaultTCPParameters { tcpUserTimeout = if argv == ["--slave5"] then Nothing else Just 500, transportConnectTimeout = Just 1000000 }
    Right ep <- newEndPoint nt

    prog <- getExecutablePath

    case argv of
     ["--slave1"] -> do
       print $ endPointAddressToByteString $ address ep
       hFlush stdout
       flip finally (putStrLn "terminated") $ do
         ConnectionOpened _ _ addr <- receive ep
         Right c0 <- connect ep addr ReliableOrdered
                                     (ConnectHints (Just 2000000))
         putStrLn $ "connected to " ++ show addr
         forever $ do
           receive ep >>= print
           send c0 []

     ["--slave2"] -> do
       print $ endPointAddressToByteString $ address ep
       hFlush stdout
       ConnectionOpened _ _ master <- receive ep
       Received _ [addr] <- receive ep

       Right c0 <- connect ep (EndPointAddress addr) ReliableOrdered
                                          (ConnectHints (Just 2000000))
       Right c <- connect ep master ReliableOrdered defaultConnectHints

       ConnectionOpened _ _ addr' <- receive ep
       putStrLn $ "connected to " ++ show addr'
       Received _ [] <- receive ep
       let trySome :: IO a -> IO (Either SomeException a)
           trySome = try
       ex <- trySome $ do
         Right () <- send c0 []
         receive ep

       send c [ toStrict $ encode $ show ex ]


       Received _ [] <- receive ep

       ex <- trySome $ do
         putStrLn "reconnecting"
         Right c1 <- connect ep (EndPointAddress addr) ReliableOrdered
                                (ConnectHints (Just 2000000))
         putStrLn "resending"
         Right () <- send c1 []
         receive ep

       send c [ toStrict $ encode $ show ex ]

       close c

     _ -> do
      cp <- getProvider
      buildPath <- getBuildPath
      withHostNames cp 2 $  \ms@[m0, m1] -> do

        putStrLn "Copying binary ..."
        scp (LocalPath prog) (RemotePath (Just "dev") m0 "network-test")
        scp (LocalPath prog) (RemotePath (Just "dev") m1 "network-test")

        putStrLn "Spawning slaves ..."
        -- spawn the first slave
        sGetLine <- systemThereAsUser "dev" m0 $ "DC_HOST_IP=" ++ m0 ++
                                                 " ./network-test --slave1 2>&1"
        Right line <- sGetLine
        ep1' <- case reads line of
                (bs, _) : _ -> return $ EndPointAddress bs
                _           -> error "Cannot read slave1 endpoint address. "
        _ <- forkIO $ forever $ do
               Right line <- sGetLine
               putStrLn $ "1: " ++ line


        -- spawn the second slave
        sGetLine2 <- systemThereAsUser "dev" m1 $
          "DC_HOST_IP=" ++ m1 ++ " ./network-test --slave2 2>&1"
        Right line2 <- sGetLine2
        ep2' <- case reads line2 of
                (bs, _) : _ -> return $ EndPointAddress bs
                _           -> error "Cannot read slave2 endpoint address. "
        _ <- forkIO $ forever $ do
               Right line <- sGetLine2
               putStrLn $ "2: " ++ line

        putStrLn $ "connecting to " ++ show ep2'
        Right c2 <- connect ep ep2' ReliableOrdered defaultConnectHints { connectTimeout = Just 1000000 }
        send c2 [ endPointAddressToByteString ep1']
        ConnectionOpened _ _ _ <- receive ep

        putStrLn $ "isolating " ++ show m0
        isolateHostsAsUser "root" [m0] ms

        send c2 []

        putStrLn "Waiting for reply ..."
        Received _ [resp] <- receive ep
        putStrLn $ decode $ fromStrict resp

        rejoinHostsAsUser "root" [m0] ms

        send c2 []

        putStrLn "Waiting for reply after rejoining ..."
        Received _ [resp2] <- receive ep
        putStrLn $ decode $ fromStrict resp2


