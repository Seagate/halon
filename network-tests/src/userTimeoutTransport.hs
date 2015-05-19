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
import System.Exit
import System.FilePath ((</>), takeDirectory)
import System.IO
import System.Timeout


retry :: Int -> IO a -> IO a
retry t action = catch (timeout t action)
                       (\e -> const (fmap Just again) (e :: SomeException))
                 >>= maybe again return
  where
    again = threadDelay t >> retry t action

getBuildPath :: IO FilePath
getBuildPath = fmap (takeDirectory . takeDirectory) getExecutablePath

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    ip <- getHostAddress
    argv <- getArgs
    Right nt <- createTransport ip "4000"
                  defaultTCPParameters { tcpUserTimeout = Just 1000, transportConnectTimeout = Just 1000000 }
    Right ep <- newEndPoint nt

    prog <- getExecutablePath

    case argv of
     ["--slave1"] -> do
       print $ endPointAddressToByteString $ address ep
       hFlush stdout
       flip finally (putStrLn "terminated") $ do
         putStrLn "waiting connection"
         ConnectionOpened _ _ addr <- receive ep
         Right c0 <- connect ep addr ReliableOrdered (ConnectHints (Just 2000000))
         putStrLn "connected"
         receive ep >>= print
         putStrLn "testing old connection"
         send c0 [] >>= print
         receive ep >>= print
         putStrLn "reconnecting"
         c1 <- retry 1000000 $ do
                 r <- connect ep addr ReliableOrdered (ConnectHints (Just 2000000))
                 print $ fmap (const ()) r
                 Right c1 <- return r
                 return c1
         receive ep >>= print
         receive ep >>= print
         send c1 [] >>= print
         close c1
         putStrLn "done"

     ["--slave2"] -> do
       print $ endPointAddressToByteString $ address ep
       hFlush stdout
       ConnectionOpened _ _ master <- receive ep
       Received _ [addr] <- receive ep

       Right c0 <- connect ep (EndPointAddress addr) ReliableOrdered
                                          (ConnectHints (Just 2000000))
       ConnectionOpened _ _ _addr <- receive ep
       putStrLn $ "connected to " ++ show addr
       Right c <- connect ep master ReliableOrdered defaultConnectHints

       Received _ [] <- receive ep
       t0 <- getCurrentTime
       let trySome :: IO a -> IO (Either SomeException a)
           trySome = try
       putStrLn "testing ..."
       ex <- trySome $ do
         Right () <- send c0 []
         receive ep

       tf <- getCurrentTime

       send c [ toStrict $ encode $ show
                  ( round (diffUTCTime tf t0 * 1000000)
                  , ex
                  )
              ]


       Received _ [] <- receive ep
       Right () <- send c []

       t0 <- getCurrentTime
       ex <- trySome $ do
         putStrLn "reconnecting"
         c1 <- retry 1000000 $ do
                 r <- connect ep (EndPointAddress addr) ReliableOrdered
                                 (ConnectHints (Just 2000000))
                 print $ fmap (const ()) r
                 Right c1 <- return r
                 return c1
         putStrLn "resending"
         Right () <- send c1 []
         ConnectionOpened _ _ _ <- receive ep
         receive ep >>= print
       tf <- getCurrentTime

       putStrLn "done"
       send c [ toStrict $ encode $ show
                  ( round (diffUTCTime tf t0 * 1000000)
                  , ex
                  )
              ]

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
               eLine <- sGetLine
               case eLine of
                 Right line -> putStrLn $ "1: " ++ line
                 Left ExitSuccess -> return ()
                 Left ec -> exitWith ec


        -- spawn the second slave
        sGetLine2 <- systemThereAsUser "dev" m1 $
          "DC_HOST_IP=" ++ m1 ++ " ./network-test --slave2 2>&1"
        Right line2 <- sGetLine2
        ep2' <- case reads line2 of
                (bs, _) : _ -> return $ EndPointAddress bs
                _           -> error "Cannot read slave2 endpoint address. "
        _ <- forkIO $ forever $ do
               eLine <- sGetLine2
               case eLine of
                 Right line -> putStrLn $ "2: " ++ line
                 Left ExitSuccess -> return ()
                 Left ec -> exitWith ec

        putStrLn $ "connecting to " ++ show ep2'
        Right c2 <- connect ep ep2' ReliableOrdered defaultConnectHints { connectTimeout = Just 1000000 }
        putStrLn "receiving ..."
        send c2 [ endPointAddressToByteString ep1']
        ConnectionOpened _ _ _ <- receive ep

        putStrLn $ "isolating " ++ show m0
        isolateHostsAsUser "root" [m0] ms

        send c2 []

        putStrLn "Waiting for reply ..."
        Received _ [resp] <- receive ep
        putStrLn "time (us)"
        putStrLn $ decode $ fromStrict resp

        rejoinHostsAsUser "root" [m0] ms

        send c2 []
        Received _ [] <- receive ep
        Right c1 <- connect ep ep1' ReliableOrdered defaultConnectHints { connectTimeout = Just 1000000 }
        send c1 []

        putStrLn "Waiting for reply after rejoining ..."
        Received _ [resp2] <- receive ep
        putStrLn "time (us)"
        putStrLn $ decode $ fromStrict resp2
