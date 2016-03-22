{-# LANGUAGE ScopedTypeVariables #-}
module Regression (tests) where

import Control.Distributed.Process
import Control.Monad (replicateM)

import Test.Tasty
import Test.Tasty.HUnit (testCase)
import qualified Test.Tasty.HUnit as HU

import Network.CEP

assertEqual :: (Show a, Eq a) => String -> a -> a -> Process ()
assertEqual s i r = liftIO $ HU.assertEqual s i r

tests :: (Process () -> IO ()) -> TestTree
tests launch = testGroup "regression"
  [ testCase "fork-remove-messages" $ launch testFork
  ]

testFork :: Process ()
testFork = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () (rules self)
    usend pid (0::Int)
    usend pid ()
    usend pid (1::Int)
    usend pid (2::Int)
    usend pid ()
    usend pid (3::Int)
    usend pid (4::Int)
    usend pid ()
    usend pid (5::Int)

    assertEqual "foo"
      [ "load"
      , "work1"
      , "load"
      , "work3"
      , "load"
      , "work5"
      ] =<< replicateM 6 expect
  where

    rules sup = do
      enableDebugMode
      define "insert" $ do
        handler <- phaseHandle "load"
        work    <- phaseHandle "work"
        finish  <- phaseHandle "finish"

        setPhase handler $ \() -> do
          liftProcess $ do usend sup "load"
                           say "load"
          fork CopyNewerBuffer $ switch [ work, timeout 10 finish]

        setPhase work $ \(i :: Int) -> do
          liftProcess $ do usend sup ("work" ++ show i)
                           say ("work" ++ show i)
          continue finish

        directly finish $ stop
        startFork handler ()
