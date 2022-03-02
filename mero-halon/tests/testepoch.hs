--
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This program tests mero epoch interface.

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

import Prelude hiding ((<$>))
import Network.Transport.RPC as RPC
import HA.Network.Transport (writeTransportGlobalIVar)
import Mero.Epoch

import Control.Applicative ((<$>))
import Control.Monad (when)
import Data.List (isInfixOf)
import Data.Maybe (maybeToList)
import System.Directory (setCurrentDirectory, createDirectoryIfMissing)
import System.Environment (getExecutablePath, getArgs, lookupEnv)
import System.Exit (die, exitSuccess)
import System.FilePath ((</>), takeDirectory)
import System.Process (readProcess, callProcess)


printTest :: String -> Bool -> IO ()
printTest s b = do putStr (s ++ ": ")
                   if b then putStrLn "Ok"
                        else die "Failed"

tests :: RPCAddress -> IO ()
tests addr = do
    putStrLn $ "Testing Epochs, using address " ++ show addr
    testEpoch addr "Update epoch to 2" 2 (Just 2)
    testEpoch addr "Update epoch to 3" 3 (Just 3)
    testEpoch addr "Re-update epoch to 3" 3 (Just 3)
    testEpoch addr "Update epoch backwards to 2" 2 (Just 3)
  where
     testEpoch addr' desc val expected =
       do res <- sendEpochBlocking addr' val timeoutSecs
          printTest desc (res == expected)
     timeoutSecs = 60

main :: IO ()
main = do
  prog <- getExecutablePath
  args <- getArgs
  -- test if we have root privileges
  ((userid, _): _ ) <- reads <$> readProcess "id" ["-u"] ""
  when (userid /= (0 :: Int)) $ do
    -- change directory so mero files are produced under the dist folder
    let testDir = takeDirectory (takeDirectory $ takeDirectory prog) </> "test"
    createDirectoryIfMissing True testDir
    setCurrentDirectory testDir
    putStrLn $ "Changed directory to: " ++ testDir
    -- Invoke again with root privileges
    putStrLn $ "Calling test with sudo ..."
    mld <- fmap ("LD_LIBRARY_PATH=" ++) <$> lookupEnv "LD_LIBRARY_PATH"
    callProcess "sudo" $ maybeToList mld ++ prog : args
    exitSuccess
  addr <- if null args
          then do
            [lnetaddr] <- take 1 . lines <$>
                    readProcess "sudo" ["lctl", "list_nids"] ""
            -- form the rpc address from the LNET node Id
            -- rpc address =  ip@network:pid:portal:buffer_pool_id
            --
            -- The pid and the portal are mostly fixed in all addresses.
            -- The buffer pool id varies allowing multiple RPC endpoints
            -- on a single host.
            let rpcaddr = lnetaddr ++ ":12345:34:2"
            putStrLn $ "Using rpc address: " ++ rpcaddr
            return $ rpcAddress rpcaddr
          else return $ rpcAddress $ head args
  rpcTransport <- RPC.createTransport "s1" addr RPC.defaultRPCParameters
  writeTransportGlobalIVar rpcTransport
  tests addr
