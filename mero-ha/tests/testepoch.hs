--
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This program tests the "Network.Transport.Identify" module.

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

import Network.Transport.RPC ( rpcAddress  )

import Control.Monad (when)
import Control.Exception (bracket)
import System.Environment ( getArgs )
import HA.Network.Address
import Control.Concurrent (threadDelay)
import Mero.Epoch
import System.Exit (exitFailure)
import System.Process
import Data.Char (isSpace)
import Data.List (dropWhileEnd)

getEndpoint :: IO (Maybe String)
getEndpoint =
  do raw <- readProcess "mero_call" ["mym0dendpoint"] []
     case dropWhileEnd isSpace raw of
       "" -> return Nothing
       clean -> return $ Just clean

printTest :: String -> Bool -> IO ()
printTest s b = do putStr (s ++ ": ")
                   if b then putStrLn "Ok"
                        else (putStrLn "Failed" >> exitFailure)

tests :: Network -> IO ()
tests network = do
  Just rawaddr <- getEndpoint
  let Just addr = parseAddress rawaddr

  putStrLn $ "Testing Epochs, using address " ++ show addr

  bracket (createProcess $  -- proc "mero_call" ["dummyService",rawaddr])
                             proc "mero_call" ["m0d"])
          (\(_,_,_,m0d) -> terminateProcess m0d >> 
              putStrLn "Ending Epoch tests") $ \(_,_,_,m0d) -> do
     threadDelay 30000000
     
     running <- getProcessExitCode m0d
     when (running /= Nothing)
        (putStrLn "Mero exited prematurely" >> exitFailure)

     putStrLn $ "About to try to set epoch on " ++ show addr

     testEpoch addr "Update epoch to 2" 2 (Just 2)
     testEpoch addr "Update epoch to 3" 3 (Just 3)
     testEpoch addr "Re-update epoch to 3" 3 (Just 3)
     testEpoch addr "Update epoch backwards to 2" 2 (Just 3)

  where
     testEpoch addr desc val expected =
       do res <- sendEpochBlocking network addr val timeoutSecs
          printTest desc (res == expected)
     timeoutSecs = 60

main :: IO ()
main = do
  [nid] <- getArgs
  network <- startNetwork (rpcAddress $ nid ++ ":12345:34:2")
  tests network
