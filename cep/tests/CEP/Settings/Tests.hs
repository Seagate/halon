module CEP.Settings.Tests
  ( tests ) where

import Control.Distributed.Process

import Network.CEP

import Test.Tasty
import Test.Tasty.HUnit

tests :: (Process () -> IO ()) -> TestTree
tests launch = testGroup "Settings"
  [ testCase "logger-works" $ launch testSettingsLogger ]


dummyLogger :: ProcessId -> Logs -> s -> Process ()
dummyLogger driverPid _ _ = usend driverPid ((), ())

testSettingsLogger :: Process ()
testSettingsLogger = do
  self <- getSelfPid
  pid  <- spawnLocal $ execute () $ do
    setLogger $ dummyLogger self
    define "rule" $ do
      ph1 <- phaseHandle "state-1"
      setPhase ph1 $ \() -> do
        phaseLog "test" "test"
        liftProcess $ usend self ()
      start ph1 ()
  usend pid ()
  () <- expect
  ((), ()) <- expect
  return ()
