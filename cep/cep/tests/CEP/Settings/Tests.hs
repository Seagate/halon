{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE TypeFamilies               #-}
module CEP.Settings.Tests
  ( tests ) where

import Control.Distributed.Process

import Network.CEP
import qualified Network.CEP.Log as Log

import Test.Tasty
import Test.Tasty.HUnit

data TestApp

instance Application TestApp where
  type GlobalState TestApp = ()
  type LogType TestApp = ()

tests :: (Process () -> IO ()) -> TestTree
tests launch = testGroup "Settings"
  [ testCase "logger-works" $ launch testSettingsLogger ]

dummyLogger :: ProcessId -> Log.Event s -> () -> Process ()
dummyLogger driverPid _ _ = usend driverPid ((), ())

testSettingsLogger :: Process ()
testSettingsLogger = do
  self <- getSelfPid
  let spec :: Specification TestApp ()
      spec = do
        setLogger $ dummyLogger self
        define "rule" $ do
          ph1 <- phaseHandle "state-1"
          setPhase ph1 $ \() -> do
            appLog ()
            liftProcess $ usend self ()
          start ph1 ()
  pid  <- spawnLocal $ execute () spec
  usend pid ()
  () <- expect
  ((), ()) <- expect
  return ()
