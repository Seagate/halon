-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
{-# LANGUAGE TemplateHaskell #-}
import Network.Transport.RPC ( createTransport, rpcAddress, defaultRPCParameters
                             , RPCTransport(..)
                             )
import Control.Distributed.Process
import Control.Distributed.Process.Node
import System.Environment
import System.IO

main :: IO ()
main = do
  [pfx,serverAddr] <- getArgs
  transport <- fmap networkTransport $
                    createTransport pfx (rpcAddress serverAddr)
                                    defaultRPCParameters
  n <- newLocalNode transport initRemoteTable
  runProcess n $ do
    self <- getSelfPid
    register "pingServer" self
    liftIO $ hPutStrLn stderr "ready" >> hFlush stdout
    let go =
          receiveWait
            [ match $ \s -> case s of
                              "terminate" -> return ()
                              _ -> go
            , match $ \pid -> send pid "pong" >> go
            ]
    go
    liftIO $ putStrLn "server done!"
