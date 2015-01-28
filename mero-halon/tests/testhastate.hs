--
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This program tests the notification interface from the HA side.
-- Call as: ./testhastate local_rpc_address dummy_mero_rpc_address

import HA.Resources.Mero (ConfObjectState(..))
import Mero.ConfC (Fid(..))
import Mero.Notification.HAState
                    ( initHAState, finiHAState
                    , notify, Note(..)
                    , doneGet, updateNVecRef
                    , NVec
                    )

import Network.RPC.RPCLite
  ( rpcAddress, ListenCallbacks(..), listen, stopListening, getFragments
  , initRPCAt, finalizeRPC, sendBlocking, disconnect, connect_se
  )

import Control.Applicative ((<$>))
import Control.Concurrent ( forkIO )
import Control.Concurrent.MVar ( newEmptyMVar, takeMVar, putMVar, MVar )
import Control.Exception ( bracket, bracket_, try, SomeException )
import Control.Monad ( when, void )
import Data.Bits ( (.|.), shiftL )
import Data.ByteString ( ByteString )
import Data.Char ( isSpace )
import qualified Data.ByteString as B ( concat, unpack )
import Data.List (isInfixOf, delete)
import Data.Maybe (maybeToList)
import System.Directory
    ( getCurrentDirectory
    , setCurrentDirectory
    , createDirectoryIfMissing
    )
import System.Environment ( getArgs, getEnv, getExecutablePath, lookupEnv )
import System.Exit ( exitFailure, exitSuccess )
import System.FilePath ( (</>), normalise, pathSeparator, takeDirectory )
import System.Process (readProcess, callProcess, callCommand)

main :: IO ()
main =
  -- find the LNET NID
  (take 1 . lines <$> readProcess "sudo" ["lctl", "list_nids"] "")
  >>= \[testNid] ->
  let dummyMeroAddress = testNid ++ ":12345:34:2"
      confdAddress = testNid ++ ":12345:34:1001"
      halonAddress = testNid ++ ":12345:34:3"
  in
  (do
    prog <- getExecutablePath
    args <- getArgs
    when (notElem "--noscript" args) $ do
      meroHalonTopDir <- getCurrentDirectory
      -- change directory so mero files are produced under the dist folder
      let testDir = takeDirectory (takeDirectory $ takeDirectory prog)
                  </> "test"
      createDirectoryIfMissing True testDir
      setCurrentDirectory testDir
      putStrLn $ "Changed directory to: " ++ testDir
      -- build the dummy mero
      callProcess "make" ["-C", meroHalonTopDir </> "hastate", "dummy_mero"]
      -- remove the output of a previous dummy mero
      callProcess "sudo" ["rm", "-f", "dummy_mero.stdout"]
      callProcess "touch" ["dummy_mero.stdout"]
      -- spawn the dummy mero
      mld <- fmap ("LD_LIBRARY_PATH=" ++) <$> lookupEnv "LD_LIBRARY_PATH"
      bracket_ (callProcess "sudo" $
                  maybeToList mld ++
                  [ meroHalonTopDir </> "hastate" </> "call_dummy_mero.sh"
                    -- local addre
                  , dummyMeroAddress
                  , confdAddress
                  , halonAddress
                  ]
              )
              (callCommand "sudo kill $(cat dummy_mero.pid)")
        $ do
        putStrLn "Spawned dummy_mero."
        -- wait for dummy mero to be up
        callProcess (meroHalonTopDir </> "scripts" </> "wait_contents")
                    [ "120", "dummy_mero.stdout", "ready" ]

        -- Invoke again with root privileges
        putStrLn $ "Calling test with sudo ..."
        callProcess "sudo" $ maybeToList mld ++ prog : "--noscript" : args
      exitSuccess
  ) >>
  getDbDir >>= \dbDir ->
  (newEmptyMVar :: IO (MVar [ByteString])) >>= \mv ->
  (newEmptyMVar :: IO (MVar NVec)) >>= \mv' ->
  delete "--noscript" <$> getArgs >>= (\args -> case args of
    [] -> return [ halonAddress, dummyMeroAddress ]
    _ -> return args)
  >>= \[ localAddress , meroAddress ] ->
  bracket_ (initRPCAt dbDir) finalizeRPC $
  bracket (listen (dbDir </> "s2") (rpcAddress localAddress)$ ListenCallbacks
              { receive_callback = \it _ ->
                  getFragments it >>= putMVar mv >> return True
              }
          )
          stopListening $ \se ->
  let node_fid = Fid (fromIntegral (fromEnum 'n') `shiftL` (64 - 8) .|. 1) 1
   in
  bracket_ (initHAState (\nvecr -> void $ forkIO $ do
                           updateNVecRef nvecr
                             [ Note node_fid M0_NC_ACTIVE ]
                           doneGet nvecr 0
                         )
                         (\nvecs -> do
                               putMVar mv' nvecs
                               return 0
                         )
           ) finiHAState $ do

    c <- connect_se se (rpcAddress meroAddress) 5
    sendBlocking c [] 5
    -- check output of m0_ha_state_get
    takeMVar mv >>= \bss ->
      when ([[1]] /= map B.unpack bss) $ do
        putStrLn $ "m0_ha_state_get yielded bad result: "
                   ++ show (map B.unpack bss)
        exitFailure
    -- The literal below comes from mero-halon/hastate/dummy_mero.c
    let node_fid0 = Fid (fromIntegral (fromEnum 'n') `shiftL` (64 - 8) .|. 1) 0
    -- check output of m0_ha_state_set
    -- comparing with known note values written in "hastate/dummy_mero.c".
    takeMVar mv' >>= \ns -> do
        let expectedNotes = case ns of
                [n1,n2] | n1 == Note node_fid M0_NC_OFFLINE &&
                          n2 == Note node_fid0 M0_NC_RECOVERING
                          -> True
                _         -> False
        when (not expectedNotes) $ do
            putStrLn $ "m0_ha_state_set got unexpected result"
            exitFailure
    -- copied from $MERO_ROOT/m0t1fs/linux_kernel/st/st (0x70000000000000011, 0)
    let root_fid = Fid (fromIntegral (fromEnum 'p') `shiftL` (64 - 8) .|. 0x11)
                       0
    notify se (rpcAddress meroAddress)
           [ Note root_fid M0_NC_OFFLINE ] 5
    -- copied from $MERO_ROOT/m0t1fs/linux_kernel/st/st (0x66000000000000011, 1)
    let oid = Fid (fromIntegral (fromEnum 'f') `shiftL` (64 - 8) .|. 0x11) 1
    notify se (rpcAddress meroAddress) [ Note oid M0_NC_ACTIVE ] 5
    sendBlocking c [] 5
    disconnect c 5
    -- check output of m0_ha_state_accept
    --
    -- Dummy mero sends a bytestring with the state of each confc
    -- object traversing the hierarchy in pos-order.
    --
    -- The hierarchy is defined in $MERO_ROOT/m0t1fs/linux_kernel/st/st
    takeMVar mv >>= \bss ->
      when (map (fromIntegral . fromEnum) [ M0_NC_OFFLINE
                                          , M0_NC_ACTIVE
                                          , M0_NC_UNKNOWN
                                          , M0_NC_UNKNOWN
                                          , M0_NC_UNKNOWN
                                          , M0_NC_UNKNOWN
                                          , M0_NC_UNKNOWN
                                          ]
             /= (take 7 $ B.unpack $ B.concat bss)
           ) $ do
        putStrLn $ "m0_ha_state_accept produced a bad result "
                   ++ show (B.unpack (B.concat bss))
        exitFailure

getDbDir :: IO FilePath
getDbDir = do
  ntrDbDir <- try (getEnv "NTR_DB_DIR") :: IO (Either SomeException FilePath)
  return $ case ntrDbDir of
      Right dir | not (null (filter (not . isSpace) dir)) ->
          normalise (dir ++ [pathSeparator])
      _        -> ""
