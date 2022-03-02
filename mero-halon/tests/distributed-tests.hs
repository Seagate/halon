-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module Main where

import qualified HA.Test.Distributed.Autoboot
import qualified HA.Test.Distributed.ClusterDeath
import qualified HA.Test.Distributed.ConfigureServices
import qualified HA.Test.Distributed.MoveState
import qualified HA.Test.Distributed.NodeDeath
import qualified HA.Test.Distributed.RCInsists
import qualified HA.Test.Distributed.RCInsists2
import qualified HA.Test.Distributed.Snapshot3
import qualified HA.Test.Distributed.StartService
import qualified HA.Test.Distributed.StressRC
import qualified HA.Test.Distributed.TSDisconnects
import qualified HA.Test.Distributed.TSDisconnects2
import qualified HA.Test.Distributed.TSRecovers
import qualified HA.Test.Distributed.TSRecovers2
import qualified HA.Test.Distributed.TSTotalIsolation
import qualified HA.Test.Distributed.TSTotalIsolation2

import Test.Tasty (TestTree, defaultMainWithIngredients, testGroup)
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)
import System.IO (hSetBuffering, BufferMode(..), stdout, stderr)


tests :: TestTree
tests = testGroup "mero-halon" $ (:[]) $
    testGroup "distributed"
      [ HA.Test.Distributed.Autoboot.test
      , HA.Test.Distributed.ClusterDeath.test
      , HA.Test.Distributed.ConfigureServices.test
      , HA.Test.Distributed.MoveState.test
      , HA.Test.Distributed.NodeDeath.test
      , HA.Test.Distributed.RCInsists.test
      , HA.Test.Distributed.RCInsists2.test
      , HA.Test.Distributed.Snapshot3.test
      , HA.Test.Distributed.StressRC.test
      , HA.Test.Distributed.StartService.test
      , HA.Test.Distributed.TSDisconnects.test
      , HA.Test.Distributed.TSDisconnects2.test
      , HA.Test.Distributed.TSRecovers.test
      , HA.Test.Distributed.TSRecovers2.test
      , HA.Test.Distributed.TSTotalIsolation.test
      , HA.Test.Distributed.TSTotalIsolation2.test
      ]

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]] tests
