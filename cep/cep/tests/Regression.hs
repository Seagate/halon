{-# LANGUAGE ScopedTypeVariables #-}
module Regression (tests) where

import Control.Distributed.Process
import Control.Monad (replicateM)

import Test.Tasty
import Test.Tasty.HUnit (testCase)
import qualified Test.Tasty.HUnit as HU

import Network.CEP

import Debug.Trace

assertEqual :: (Show a, Eq a) => String -> a -> a -> Process ()
assertEqual s i r = liftIO $ HU.assertEqual s i r

tests :: (Process () -> IO ()) -> TestTree
tests launch = testGroup "regression"
  [ testCase "fork-remove-messages" $ launch testFork
  , testCase "fork-prompt" $ launch testForkPrompt
  , localOption (mkTimeout 70000000) $ testCase "forks-works" $ launch testForks
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

testForkPrompt :: Process ()
testForkPrompt = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () (rules self)
    usend pid ()
    usend pid (0::Int)
    -- usend pid ()
    -- usend pid (1::Int)

    assertEqual "foo"
      [ "load"
      , "work0"
      ] =<< replicateM 2 expect
  where

    rules sup = do
      define "insert" $ do
        handler <- phaseHandle "load"
        work    <- phaseHandle "work"
        finish  <- phaseHandle "finish"

        setPhase handler $ \() -> do
          liftProcess $ do usend sup "load"
                           say "load"
                           liftIO $ traceMarkerIO "cep:load"
          fork CopyNewerBuffer $ switch [ work, timeout 10 finish]

        setPhase work $ \(i :: Int) -> do
          liftProcess $ do usend sup ("work" ++ show i)
                           say ("work" ++ show i)
                           liftIO $ traceMarkerIO $ "cep:work" ++ show i
          continue finish

        directly finish $ stop
        startFork handler ()

testForks :: Process ()
testForks = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () (rules self)
    _ <- receiveTimeout 65000000 []
    usend pid ()

    assertEqual "foo"
      [ "load"
      ] =<< replicateM 1 expect
  where

    rules sup = do
      define "insert" $ do
        handler <- phaseHandle "load"
        work    <- phaseHandle "work"
        bogus   <- phaseHandle "bogus"
        finish  <- phaseHandle "finish"

        setPhase handler $ \() -> do
          liftProcess $ do usend sup "load"
                           liftIO $ traceMarkerIO "cep:load"
                           say "load"
          fork CopyNewerBuffer $ switch [ work, timeout 10 finish]

        setPhase work $ \(i :: Int) -> do
          liftProcess $ do usend sup ("work" ++ show i)
                           say ("work" ++ show i)
                           liftIO $ traceMarkerIO "cep:work"
          continue finish

        setPhase bogus $ \(i :: Double) -> do
           liftProcess $ do usend sup ("bogus" ++ show i)
                            say ("bogus" ++ show i)
           continue finish

        directly finish $ stop
        startForks [bogus, handler] ()
