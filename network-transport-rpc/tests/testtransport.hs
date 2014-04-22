
import Network.Transport.Tests.Auxiliary

import Network.Transport
import Network.Transport.RPC ( createTransport, defaultRPCParameters, rpcAddress
                             , RPCTransport(..) )
import Control.Concurrent
import Control.Monad
import Data.Map
import Control.Exception
import System.Environment
import qualified Data.ByteString.Char8 as B8

client :: Transport -> String -> IO ()
client transport serverAddr = do
  Right endpoint  <- newEndPoint transport

  let addr = EndPointAddress (B8.pack$ serverAddr++":10")
  x <- connect endpoint addr ReliableOrdered defaultConnectHints
  let conn = case x of
              Right conn' -> conn'
              Left err -> error$ "Error connecting: "++show err
  -- forM_ [1..5000::Int]$ \i -> do
  do Right () <- send conn [B8.pack "Hello world"]
     void$ receive endpoint
     -- when (mod i 100==0)$ print i
  close conn

  replicateM_ 2 $ receive endpoint


-- | Server that echoes messages straight back to the origin endpoint.
echoServer :: EndPoint -> MVar () -> IO ()
echoServer endpoint serverDone = go empty
  where
    go :: Map ConnectionId (MVar Connection) -> IO ()
    go cs = do
      event <- receive endpoint
      case event of
        ConnectionOpened cid rel addr -> do
          -- putStrLn$ "  New connection: ID "++show cid++", reliability: "++show rel++", address: "++ show addr
          connMVar <- newEmptyMVar
          _ <- forkIO $ do
            Right conn <- connect endpoint addr rel defaultConnectHints
            putMVar connMVar conn
          go (insert cid connMVar cs)
        Received cid payload -> do
          -- _ <- forkIO $ do
            conn <- readMVar (cs ! cid)
            Right () <- send conn payload
            return ()
            go cs
        ConnectionClosed cid -> do
          -- putStrLn$ "    Closed connection: ID "++show cid
          _ <- forkIO $ do
            conn <- readMVar (cs ! cid)
            close conn
            putMVar serverDone ()
          go (delete cid cs)
        EndPointClosed -> do
          -- putStrLn "Echo server exiting"
          putMVar serverDone ()
        _ -> putStrLn$ "unexpected event: "++show event

clientServer :: RPCTransport -> String -> IO ()
clientServer transport serverAddr = do
    serverDone      <- newEmptyMVar
    Right endpoint  <- newEndPoint (networkTransport transport)
    _ <- forkIO $ echoServer endpoint serverDone
    _ <- forkIO $ client (networkTransport transport) serverAddr
    -- putStrLn $ "Echo server started at " ++ show (address endpoint)
    readMVar serverDone

reservedAddress :: RPCTransport -> String -> IO ()
reservedAddress rpcTransport serverAddrs = do
    Right e0 <- newEndPoint $ networkTransport rpcTransport
    Right e1 <- newReservedEndPoint rpcTransport 4
    Right c <- connect e0 (EndPointAddress $ B8.pack $ serverAddrs ++ ":4")
                       ReliableOrdered defaultConnectHints
    send c [ B8.pack "ping" ]
    ConnectionOpened _ _ _ <- receive e1
    Received _ [bs] <- receive e1
    True <- return $ B8.unpack bs == "ping"
    close c
    ConnectionClosed _ <- receive e1
    closeEndPoint e1
    closeEndPoint e0
    return ()

reservedAddressOutOfRange :: RPCTransport -> String -> IO ()
reservedAddressOutOfRange rpcTransport serverAddrs = do
    Left (TransportError NewEndPointInsufficientResources
                         "EndPoint id not in the reserved range."
         )
        <- newReservedEndPoint rpcTransport 10
    return ()

reservedAddressInUse :: RPCTransport -> String -> IO ()
reservedAddressInUse rpcTransport serverAddrs = do
    Right e <- newReservedEndPoint rpcTransport 4
    Left (TransportError NewEndPointInsufficientResources
                         "EndPoint id is already in use."
         )
        <- newReservedEndPoint rpcTransport 4
    closeEndPoint e
    return ()

main :: IO ()
main = do
  [serverAddr]    <- getArgs
  bracket
    (createTransport "s1" (rpcAddress serverAddr) defaultRPCParameters)
    (closeTransport . networkTransport)
    $ \tr -> runTests
        [ ("ClientServer", clientServer tr serverAddr)
        , ("ReservedAddress", reservedAddress tr serverAddr)
        , ("ReservedAddressOutOfRange", reservedAddressOutOfRange tr serverAddr)
        , ("ReservedAddressInUse", reservedAddressInUse tr serverAddr)
        ]
        >> threadDelay 2000000
