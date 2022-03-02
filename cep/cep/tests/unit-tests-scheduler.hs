-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

module Main where

import Control.Exception

import Control.Distributed.Process.Node
import Network.Transport.InMemory
import Test.Tasty
import Test.Tasty.Ingredients.Basic
import Test.Tasty.Ingredients.FileReporter
import qualified CEP.Settings.Tests (tests)

import Control.Distributed.Process.Scheduler
import qualified Tests as Tests
import qualified Regression as Regression

import Control.Monad
import System.IO
import System.Posix.Env (setEnv)
import System.Random
import System.Timeout


ut :: IO TestTree
ut = do
    setEnv "DP_SCHEDULER_ENABLED" "1" True
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    s <- randomIO
    let clockSpeed = 5000 :: Int
        launch action = do
          forM_ [1..20] $ \i -> do
            t <- createTransport
            (>>= maybe (error "Timeout") return) $ timeout 5000000 $
              withScheduler (s + i) clockSpeed 1 t initRemoteTable $ const action
           `onException` do
             hPutStrLn stderr $ "Failing with seed: " ++ show (s + i)
    return $ testGroup "CEP - Unit tests - scheduler" $
               Regression.tests launch : CEP.Settings.Tests.tests launch:Tests.tests launch

main :: IO ()
main = do
    tree <- ut
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]] tree
