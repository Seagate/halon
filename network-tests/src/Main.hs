{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ForeignFunctionInterface #-}

-- This test runs two processes.
--
-- The first process connects to the second and then it is isolated.
-- Then the first process tries to send a message and it is expected to timeout.

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
import Data.Time
import Foreign.C.Types

import Network
import qualified Network.Socket as N

import System.Environment
import System.FilePath ((</>), takeDirectory)
import System.IO


getBuildPath :: IO FilePath
getBuildPath = fmap (takeDirectory . takeDirectory) getExecutablePath

foreign import ccall safe set_user_timeout :: CInt -> CUInt -> IO ()

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    ip <- getHostAddress
    argv <- getArgs
    s <- listenOn (PortNumber 9000)
    putStrLn "network started"

    prog <- getExecutablePath

    flip finally (sClose s) $ case argv of
     ["--slave1"] -> do
       -- N.setSocketOption s N.UserTimeout 1000
       set_user_timeout (N.fdSocket s) 1000
       (h, hn, port) <- accept s
       print (hn, port)
       m1 <- hGetLine h
       hPutStrLn h "ready"
       "go" <- hGetLine h
       (s1, ha1) <- N.accept s
       -- N.setSocketOption s1 N.UserTimeout 1000
       set_user_timeout (N.fdSocket s1) 1000
       h1 <- N.socketToHandle s1 ReadWriteMode
       hSetBuffering h1 LineBuffering

       hPutStrLn h "ready"
       "go" <- hGetLine h

       let trySome :: IO a -> IO (Either SomeException a)
           trySome = try
       r <- trySome $ do
         putStrLn "waiting timeout"
         hPutStrLn h1 "pong"
         hGetLine h1
       print r
       hPutStrLn h "over"

     ["--slave2"] -> do
       (h, hn, port) <- accept s
       print (hn, port)
       m0 <- hGetLine h

       hPutStrLn h "ready"
       "go" <- hGetLine h

       s0 <- N.socket N.AF_INET N.Stream N.defaultProtocol
       ha0 <- N.inet_addr m0
       N.connect s0 $ N.SockAddrInet 9000 ha0
       -- N.setSocketOption s0 N.UserTimeout 1000
       set_user_timeout (N.fdSocket s0) 1000
       h0 <- N.socketToHandle s0 ReadWriteMode
       hSetBuffering h0 LineBuffering

       hPutStrLn h "ready"
       "go" <- hGetLine h
       hPutStrLn h0 "ping"
       "finish" <- hGetLine h
       return ()

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
        Right "network started" <- sGetLine
        _ <- forkIO $ forever $ do
               Right line <- sGetLine
               putStrLn $ "1: " ++ line

        -- spawn the second slave
        sGetLine2 <- systemThereAsUser "dev" m1 $
          "DC_HOST_IP=" ++ m1 ++ " ./network-test --slave2 2>&1"
        Right "network started" <- sGetLine2
        _ <- forkIO $ forever $ do
               Right line <- sGetLine2
               putStrLn $ "2: " ++ line

        h0 <- connectTo m0 (PortNumber 9000)
        h1 <- connectTo m1 (PortNumber 9000)

        hPutStrLn h1 m0
        hPutStrLn h0 m1

        "ready" <- hGetLine h0
        "ready" <- hGetLine h1
        hPutStrLn h0 "go"
        hPutStrLn h1 "go"
        "ready" <- hGetLine h0
        "ready" <- hGetLine h1

        putStrLn $ "isolating " ++ show m0
        isolateHostsAsUser "root" [m0] ms

        hPutStrLn h0 "go"
        hPutStrLn h1 "go"

        putStrLn "Waiting for reply ..."
        "over" <- hGetLine h0
        hPutStrLn h1 "finish"

        rejoinHostsAsUser "root" [m0] ms

        putStrLn "SUCCESS!"
