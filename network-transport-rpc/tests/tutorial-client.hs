-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
import Network.Transport
import Network.Transport.RPC ( createTransport, rpcAddress, defaultRPCParameters
                             , RPCTransport(..)
                             )
import System.Environment
import Control.Concurrent
import Control.Monad
import qualified Data.ByteString.Char8 as B8

main :: IO ()
main = do
  [serverAddr, remoteServerAddr] <- getArgs
  transport <- fmap networkTransport $
                    createTransport "s1" (rpcAddress serverAddr)
                                    defaultRPCParameters
  Right endpoint  <- newEndPoint transport

  let addr = EndPointAddress (B8.pack remoteServerAddr)
  x <- connect endpoint addr ReliableOrdered defaultConnectHints
  let conn = case x of
              Right conn' -> conn'
              Left err -> error$ "Error connecting: "++show err
  Right () <- send conn [B8.pack "Hello world"]
  close conn

  replicateM_ 3 $ receive endpoint >>= print

  threadDelay 1000000
  closeTransport transport
