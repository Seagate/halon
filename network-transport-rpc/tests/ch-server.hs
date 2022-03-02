-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
import Network.Transport.RPC ( createTransport, defaultRPCParameters, rpcAddress
                             , RPCTransport(..)
                             )
import Control.Distributed.Process
import Control.Distributed.Process.Node
import System.IO
import System.Environment
import DoSomething(__remoteTable)

main :: IO ()
main = do
  [serverAddr]    <- getArgs
  transport <- fmap networkTransport $
                    createTransport "s2" (rpcAddress serverAddr)
                                    defaultRPCParameters
  n <- newLocalNode transport (__remoteTable initRemoteTable)
  runProcess n $ do
    liftIO $ putStrLn "ready"
    liftIO $ hFlush stdout
    receiveWait []

