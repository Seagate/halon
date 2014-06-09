module HA.Network.IdentifyTCP
       ( IdentifyId
       , getAvailable
       , putAvailable
       , closeAvailable) where

import Control.Concurrent.MVar
import Control.Exception (try)
import Control.Monad (forever)
import Control.Applicative ((<$>))
import Control.Concurrent (forkIO, killThread, myThreadId, ThreadId)
import Data.Binary (encode, decode, Binary)
import System.IO (hClose)
import qualified Data.ByteString.Lazy as B
import Network
import Network.Socket (close)
import Data.Word (Word32)
import System.Timeout ( timeout )


-- | A wrapper abstracting away a 'ThreadId'.
--
-- We include a socket for technical reasons. In GHC, handlers installed using
-- 'finally' don't seem to be executed upon receiving a 'killThread' signal, so
-- we have to close the socket from the source thread.
data IdentifyId = IdentifyId ThreadId Socket

-- | Creates a process serving the given value at the given port.
--
-- The value can be obtained multiple times from remote processes by
-- using 'getAvailable'.
putAvailable :: Binary a => Int -> a -> IO (Maybe IdentifyId)
putAvailable port ident =
  do putStrLn $ "IdentifyTCP.putAvailable has started at " ++ show port
     msuccess <- newEmptyMVar
     _ <- forkIO (bind msuccess)
     takeMVar msuccess
  where value = B.concat [encodedLength,encoded]
           where
             encoded = encode ident
             encodedLength = encode (fromIntegral (B.length encoded) :: Word32)
        bind msuccess =
           do msock <- try (listenOn (PortNumber (toEnum port))) :: IO (Either IOError Socket)
              tid <- myThreadId
              either (const $ putMVar msuccess Nothing)
                     (\sock -> do putMVar msuccess $ Just $ IdentifyId tid sock
                                  forever $ do (h,_,_) <- accept sock
                                               forkIO $ do B.hPut h value
                                                           hClose h)
                     msock

-- | Fetches the value offered by a process at the given host and port.
--
-- Returns @Nothing@ if the attempt timeouts.
--
-- The behavior of this function is undefined if the type of the expected
-- value does not match the type of the provided value on the remote process.
getAvailable :: Binary a => HostName -> Int -> IO (Maybe a)
getAvailable host port =
   either (const Nothing) (fmap decode)
      <$> (try (timeout 5000000 doConnect)
               :: IO (Either IOError (Maybe B.ByteString)))
     where doConnect =
              do putStrLn $ "IdentifyTCP.getAvailable has started at " ++ show port
                 h <- connectTo host (PortNumber (toEnum port))
                 len <- decode <$> B.hGet h (fromEnum $ B.length (encode (0 :: Word32))) :: IO Word32
                 val <- B.hGet h (fromEnum len)
                 hClose h
                 if fromIntegral (B.length val) == len
                    then return val
                    else return B.empty

-- | Closes the process serving values.
closeAvailable :: IdentifyId -> IO ()
closeAvailable (IdentifyId tid sock) = do
    close sock
    killThread tid
