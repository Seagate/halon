--
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This program tests the notification interface from the HA side.
-- Call as: ./testhastate local_rpc_address dummy_mero_rpc_address

import HA.Resources.Mero (UUID(..), ConfType(..), ConfObjectState(..))
import Mero.Notification.HAState
                    ( initHAState, finiHAState
                    , notify, Note(..)
                    , doneGet, updateNVecRef
                    , NVec
                    )

import Network.Transport.RPC.RPCLite
  ( rpcAddress, ListenCallbacks(..), listen, stopListening, getFragments
  , initRPCAt, finalizeRPC, sendBlocking, disconnect, connect_se
  )

import Control.Concurrent ( forkIO )
import Control.Concurrent.MVar ( newEmptyMVar, takeMVar, putMVar, MVar )
import Control.Exception ( bracket, bracket_, try, SomeException )
import Control.Monad ( when, void )
import Data.ByteString ( ByteString )
import Data.Char ( isSpace )
import qualified Data.ByteString as B ( concat, unpack )
import Data.Word ( Word8 )
import Foreign.Marshal.Alloc ( alloca )
import Foreign.Marshal.Array ( pokeArray )
import Foreign.Ptr ( castPtr )
import Foreign.Storable ( Storable(peek) )
import System.Environment ( getArgs, getEnv )
import System.Exit ( exitFailure )
import System.FilePath ( (</>), normalise, pathSeparator )


main :: IO ()
main =
  getDbDir >>= \dbDir ->
  (newEmptyMVar :: IO (MVar [ByteString])) >>= \mv ->
  (newEmptyMVar :: IO (MVar NVec)) >>= \mv' ->
  getArgs >>= \[ localAddress , meroAddress ] ->
  bracket_ (initRPCAt dbDir) finalizeRPC $
  bracket (listen (dbDir </> "s2") (rpcAddress localAddress)$ ListenCallbacks
              { receive_callback = \it _ ->
                  getFragments it >>= putMVar mv >> return True
              }
          )
          stopListening $ \se ->
  bracket_ (initHAState (\nvecr -> void $ forkIO $ do
                           updateNVecRef nvecr
                             [ Note (UUID 0 1) M0_CO_NODE M0_NC_ACTIVE ]
                           doneGet nvecr 0
                         )
                         (\nvecs -> do
                               putMVar mv' nvecs
                               return 0
                         )
           ) finiHAState $ do

    c <- connect_se se (rpcAddress meroAddress) 1 5
    sendBlocking c [] 5
    -- check output of m0_ha_state_get
    takeMVar mv >>= \bss ->
      when ([[1]] /= map B.unpack bss) $ do
        putStrLn $ "m0_ha_state_get yielded bad result: "
                   ++ show (map B.unpack bss)
        exitFailure
    -- check output of m0_ha_state_set
    -- comparing with known note values written in "hastate/dummy_mero.c".
    takeMVar mv' >>= \ns -> do
        let expectedNotes = case ns of
                [n1,n2] | n1 == Note (UUID 1 2) M0_CO_NODE M0_NC_OFFLINE &&
                          n2 == Note (UUID 3 4) M0_CO_NIC M0_NC_RECOVERING
                          -> True
                _         -> False
        when (not expectedNotes) $ do
            putStrLn $ "m0_ha_state_set got unexpected result"
            exitFailure
    root_id <- str2id "prof-10000000000"
    notify se (rpcAddress meroAddress)
           [ Note root_id M0_CO_PROFILE M0_NC_UNKNOWN ] 5
    oid <- str2id "ios-100000000000"
    notify se (rpcAddress meroAddress) [ Note oid M0_CO_SERVICE M0_NC_ACTIVE ] 5
    sendBlocking c [] 5
    disconnect c 5
    -- check output of m0_ha_state_accept
    takeMVar mv >>= \bss ->
      when (any (fromIntegral (fromEnum M0_NC_ACTIVE)/=)
                $ take 4 $ drop 3 $ B.unpack (B.concat bss)
           ) $ do
        putStrLn $ "m0_ha_state_accept produced a bad result"
                   ++ show (B.unpack (B.concat bss))
        exitFailure

str2id :: String -> IO UUID
str2id s = alloca $ \p -> do
    pokeArray (castPtr p) (map (fromIntegral . fromEnum) $ take 16 s :: [Word8])
    peek p

getDbDir :: IO FilePath
getDbDir = do
  ntrDbDir <- try (getEnv "NTR_DB_DIR") :: IO (Either SomeException FilePath)
  return $ case ntrDbDir of
      Right dir | not (null (filter (not . isSpace) dir)) ->
          normalise (dir ++ [pathSeparator])
      _        -> ""
