import Control.Concurrent
import Control.Exception
import Control.Monad
import qualified Data.ByteString.Char8 as B8
import Network.Transport.RPC.RPCLite
import System.Environment

main :: IO ()
main = do
  args <- getArgs
  if length args>0 then mainServer else mainClient

mainClient :: IO ()
mainClient = flip catch (\e -> print (e::SomeException))$ do
    initRPC
    ce <- createClientEndpoint$ rpcAddress "0@lo:12345:34:1"
    putStrLn "created client endpoint"

    se <- listen "s1" (rpcAddress "0@lo:12345:34:2")$ ListenCallbacks 
              { receive_callback = \it _ ->  putStr "server: " >> unsafeGetFragments it >>= print >> return True
              }
    putStrLn "listening ..."

    c <- connect ce (rpcAddress "0@lo:12345:34:4") 1 3
    putStrLn "client connected"

    sendBlocking c [B8.pack "hello"] 3
    putStrLn "client sent message"

    send c [B8.pack "hello"] 3$ (\st -> putStrLn$ "client received reply: "++" "++show st)
    putStrLn "client sent message"

    threadDelay 1000000

    disconnect c 3
    putStrLn "disconnected ... (press enter)"
    void getLine

    destroyClientEndpoint ce

    stopListening se
    putStrLn "stopped listening"
    finalizeRPC

mainServer :: IO ()
mainServer = flip catch (\e -> print (e::SomeException))$ do
    initRPC
    ce <- createClientEndpoint$ rpcAddress "0@lo:12345:34:3"
    putStrLn "created client endpoint"

    se <- listen "s2" (rpcAddress "0@lo:12345:34:4")$ ListenCallbacks 
              { receive_callback = \it _ ->  putStr "server: " >> unsafeGetFragments it >>= print >> return True
              }
    putStrLn "listening ... (press enter)"
    void getLine

    c <- connect ce (rpcAddress "0@lo:12345:34:2") 1 3
    putStrLn "client connected"

    sendBlocking c [B8.pack "hello"] 3
    putStrLn "client sent message"

    send c [B8.pack "hello"] 3$ (\st -> putStrLn$ "client received reply: "++" "++show st)
    putStrLn "client sent message"

    _ <- forkIO$ disconnect c 3

    threadDelay 1000000

    putStrLn "disconnected ... (press enter)"
    void getLine

    destroyClientEndpoint ce

    stopListening se
    putStrLn "stopped listening"
    finalizeRPC
