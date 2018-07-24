{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
module Regression (tests) where

import Control.Distributed.Process
import Control.Monad (replicateM)

import Test.Tasty
import Test.Tasty.HUnit (testCase)
import qualified Test.Tasty.HUnit as HU

import Network.CEP

import Debug.Trace

data TestApp

instance Application TestApp where
  type GlobalState TestApp = ()
  type LogType TestApp = ()

assertEqual :: (Show a, Eq a) => String -> a -> a -> Process ()
assertEqual s i r = liftIO $ HU.assertEqual s i r

tests :: (Process () -> IO ()) -> TestTree
tests launch = testGroup "regression"
  [ testCase "fork-remove-messages" $ launch testFork
  , testCase "fork-prompt" $ launch testForkPrompt
  , testCase "fork-timeout" $ launch testForkTimeout
  ]

testFork :: Process ()
testFork = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () (rule self)
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

    rule :: ProcessId -> Specification TestApp ()
    rule sup = do
      define "fork-remove-msgs" $ do
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
    pid  <- spawnLocal $ execute () (rule self)
    usend pid ()
    usend pid (0::Int)
    -- usend pid ()
    -- usend pid (1::Int)

    assertEqual "foo"
      [ "load"
      , "work0"
      ] =<< replicateM 2 expect
  where
    rule :: ProcessId -> Specification TestApp ()
    rule sup = do
      define "fork-prompt" $ do
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

testForkTimeout :: Process ()
testForkTimeout = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () (rule self)
    usend pid (4::Int)
    usend pid (2::Int)
    assertEqual "foo"
      [ "work2", "work4"] =<< replicateM 2 expect
  where
    rule :: ProcessId -> Specification TestApp ()
    rule sup = do
      define "fork-timeout" $ do
        handler <- phaseHandle "load"
        work    <- phaseHandle "work"
        finish  <- phaseHandle "finish"

        setPhase handler $ \(i::Int) -> do
          put Local $ Just i
          fork CopyNewerBuffer $ switch [timeout i work]
          continue handler

        directly work $ do
          Just i <- get Local
          liftProcess $ usend sup $ "work"++show i
          continue finish

        directly finish $ stop
        start handler Nothing
