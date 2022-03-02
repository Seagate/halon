-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
import Network.Transport
import Network.Transport.RPC ( createTransport, defaultRPCParameters, rpcAddress
                             , RPCTransport(..)
                             )
import Control.Concurrent
import Data.Map
import Control.Exception
import System.Environment

-- | Server that echoes messages straight back to the origin endpoint.
echoServer :: EndPoint -> MVar () -> IO ()
echoServer endpoint serverDone = go empty
  where
    go :: Map ConnectionId (MVar Connection) -> IO ()
    go cs = do
      event <- receive endpoint
      case event of
        ConnectionOpened cid rel addr -> do
          putStrLn$ "  New connection: ID "++show cid++", reliability: "++show rel++", address: "++ show addr
          connMVar <- newEmptyMVar
          _ <- forkIO $ do
            Right conn <- connect endpoint addr rel defaultConnectHints
            putMVar connMVar conn
          go (insert cid connMVar cs)
        Received cid payload -> do
         -- _ <- forkIO $ do -- the send call needs to evaluate before the close call
            conn <- readMVar (cs ! cid)
            Right () <- send conn payload
            -- return ()
            go cs
        ConnectionClosed cid -> do
          putStrLn$ "    Closed connection: ID "++show cid
          _ <- forkIO $ do
            conn <- readMVar (cs ! cid)
            close conn
          go (delete cid cs)
        EndPointClosed -> do
          putStrLn "Echo server exiting"
          putMVar serverDone ()
        _ -> putStrLn$ "unexpected event: "++show event

onCtrlC :: IO a -> IO () -> IO a
p `onCtrlC` q = catchJust isUserInterrupt p (const $ q >> p `onCtrlC` q)
  where
    isUserInterrupt :: AsyncException -> Maybe ()
    isUserInterrupt UserInterrupt = Just ()
    isUserInterrupt _             = Nothing

main :: IO ()
main = do
  [serverAddr]    <- getArgs
  serverDone      <- newEmptyMVar
  transport <- fmap networkTransport $
                    createTransport "s2" (rpcAddress serverAddr)
                                    defaultRPCParameters
  Right endpoint  <- newEndPoint transport
  _ <- forkIO $ echoServer endpoint serverDone
  putStrLn $ "Echo server started at " ++ show (address endpoint)
  readMVar serverDone `onCtrlC` closeTransport transport

