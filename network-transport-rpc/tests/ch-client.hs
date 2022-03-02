-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
{-# LANGUAGE TemplateHaskell #-}
import Network.Transport
import Network.Transport.RPC ( createTransport, rpcAddress, defaultRPCParameters
                             , RPCTransport(..)
                             )
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Internal.Types
import Control.Distributed.Process.Closure
import System.Environment
import qualified Data.ByteString.Char8 as B8
import DoSomething


main :: IO ()
main = do
  [serverAddr, remoteServerAddr] <- getArgs
  transport <- fmap networkTransport $
                    createTransport "s1" (rpcAddress serverAddr)
                                    defaultRPCParameters
  n <- newLocalNode transport (__remoteTable initRemoteTable)
  runProcess n $ do
    say "calling ..."
    call $(functionTDict 'doSomething) (NodeId $ EndPointAddress $ B8.pack remoteServerAddr) $
         $(mkClosure 'doSomething) True
    say "done."
