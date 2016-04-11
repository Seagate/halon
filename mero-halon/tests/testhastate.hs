--
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This program tests the notification interface from the HA side.
-- Call as: ./testhastate local_rpc_address dummy_mero_rpc_address

import Prelude hiding ((<$>))
import HA.Resources.Mero.Note (ConfObjectState(..))
import Mero (withM0)
import Mero.ConfC (Fid(..))
import Mero.Notification.HAState
                    ( initHAState, finiHAState
                    , notify, Note(..)
                    , doneGet, updateNVecRef
                    , NVec
                    )

import Network.RPC.RPCLite
  ( rpcAddress, ListenCallbacks(..), listen, stopListening, getFragments
  , initRPC, finalizeRPC, sendBlocking, disconnect, connect_se
  )

import Control.Applicative ((<$>))
import Control.Concurrent ( forkIO, threadDelay )
import Control.Concurrent.MVar ( newEmptyMVar, takeMVar, putMVar, MVar )
import Control.Exception
  ( bracket, bracket_, catch, SomeException, throwIO, IOException, try)
import Control.Monad ( when, void )
import Data.Bits ( (.|.), shiftL )
import Data.ByteString ( ByteString )
import qualified Data.ByteString as B ( concat, unpack )
import Data.List (delete)
import Data.Maybe (maybeToList)
import System.Directory
    ( getCurrentDirectory
    , setCurrentDirectory
    , createDirectoryIfMissing
    )
import System.Environment ( getArgs, getExecutablePath, lookupEnv )
import System.Exit ( exitFailure, exitSuccess )
import System.FilePath ( (</>) )
import System.Process (readProcess, callProcess, callCommand)
import System.Posix.Temp (mkdtemp)


tryIO :: IO a -> IO (Either IOException a)
tryIO = try

main :: IO ()
main = getArgs >>= \args ->
  (if notElem "--noscript" args then
    bracket_ (callCommand "sudo systemctl start mero-mkfs")
             (do _ <- tryIO $ callCommand "sudo systemctl stop mero-mkfs"
                 return ()
             ) .
    bracket_ (callCommand "sudo systemctl start mero")
    (do threadDelay $ 2*1000000
        _ <- tryIO $ callCommand "sudo systemctl stop mero"
        threadDelay $ 2*1000000
        -- XXX: workaround for a bug in a mero test suite.
        _ <- tryIO $ callCommand $ "sudo killall -9 lt-m0d"
        threadDelay $ 2*1000000
    )
    else id
  ) $
  -- find the LNET NID
  (take 1 . lines <$> readProcess "sudo" ["lctl", "list_nids"] "")
  >>= \[testNid] ->
  let dummyMeroAddress = testNid ++ ":12345:34:2"
      confdAddress = testNid ++ ":12345:44:101"
      halonAddress = testNid ++ ":12345:34:3"
  in
  (do
    prog <- getExecutablePath
    when (notElem "--noscript" args) $ do
      meroHalonTopDir <- getCurrentDirectory
      testDir <- mkdtemp "/tmp/tmp-testhastate."
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
      let dummyMeroCmd =
                  maybeToList mld ++
                  [ meroHalonTopDir </> "hastate" </> "call_dummy_mero.sh"
                    -- local addre
                  , dummyMeroAddress
                  , confdAddress
                  , halonAddress
                  ]
      putStrLn $ "Calling dummy mero: " ++ unwords dummyMeroCmd
      bracket_ (callProcess "sudo" dummyMeroCmd)
               (callCommand "sudo kill $(cat dummy_mero.pid)")
        $ do
        -- wait for dummy mero to be up
        callProcess (meroHalonTopDir </> "scripts" </> "wait_contents")
                    [ "120", "dummy_mero.stdout", "ready" ]
        putStrLn "Spawned dummy_mero."

        -- Invoke again with root privileges
        putStrLn $ "Calling test with sudo ..."
        callProcess "sudo" $ maybeToList mld ++ prog : "--noscript" : args
      exitSuccess
  ) >>
  (newEmptyMVar :: IO (MVar [ByteString])) >>= \mv ->
  (newEmptyMVar :: IO (MVar NVec)) >>= \mv' ->
  (case delete "--noscript" args of
    [] -> return [ halonAddress, dummyMeroAddress ]
    _ -> return args)
  >>= \[ localAddress , meroAddress ] ->
  -- The literal below comes from mero-halon/hastate/dummy_mero.c
  let node_fid = Fid (fromIntegral (fromEnum 'n') `shiftL` (64 - 8) .|. 1) 1
   in bracket_ (initHAState (\nvecr -> void $ forkIO $ do
                          updateNVecRef nvecr
                            [ Note node_fid M0_NC_ONLINE ]
                          doneGet nvecr 0
                        )
                        (\nvecs -> do
                          putMVar mv' nvecs
                          return 0
                        )
                        (error "not used in this test")
           ) finiHAState $ withM0 $
  bracket_ initRPC finalizeRPC $
  bracket (listen (rpcAddress localAddress)$ ListenCallbacks
              { receive_callback = \it _ ->
                  getFragments it >>= putMVar mv >> return True
              }
          )
          (\se -> stopListening se) $ \se ->
    bracket (connect_se se (rpcAddress meroAddress) 5)
            (flip disconnect 5) $ \c -> do
    sendBlocking c [] 5 `catch` \e -> print (e :: SomeException) >> throwIO e
    -- check output of m0_ha_state_get
    takeMVar mv >>= \bss ->
      when ([[1, 0, 0, 0]] /= map B.unpack bss) $ do
        putStrLn $ "m0_ha_state_get yielded bad result: "
                   ++ show (map B.unpack bss)
        exitFailure
    -- The literal below comes from mero-halon/hastate/dummy_mero.c
    let node_fid0 = Fid (fromIntegral (fromEnum 'n') `shiftL` (64 - 8) .|. 1) 0
    -- check output of m0_ha_state_set
    -- comparing with known note values written in "hastate/dummy_mero.c".
    takeMVar mv' >>= \ns -> do
        let expectedNotes = [ Note node_fid M0_NC_ONLINE
                            , Note node_fid0 M0_NC_TRANSIENT
                            ]
        when (ns /= expectedNotes) $ do
            putStrLn $ "m0_ha_state_set got unexpected result " ++ show ns
                       ++ " but expected " ++ show expectedNotes
            exitFailure
    -- copied from
    -- _sandbox.conf-st/cont.txt which is generated by
    -- $MERO_ROOT/conf/st sstart
    let root_fid = Fid (fromIntegral (fromEnum 't') `shiftL` (64 - 8) .|. 0x1)
                       0
    notify se (rpcAddress meroAddress)
           [ Note root_fid M0_NC_TRANSIENT ] 5
    sendBlocking c [] 5
    -- check output of m0_ha_state_accept
    --
    -- Dummy mero sends a bytestring with the state of root confc
    -- object.
    takeMVar mv >>= \bss -> do
      let expected = map (fromIntegral . fromEnum) [ M0_NC_TRANSIENT ]
      when (expected /= B.unpack (B.concat bss)) $ do
        putStrLn $ "m0_ha_state_accept produced an unexpected result "
                   ++ show (B.unpack (B.concat bss)) ++ " but expected "
                   ++ show expected
        exitFailure
    putStrLn "SUCCESS"
