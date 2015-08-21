module CEP.Settings.Tests
  ( tests ) where

import Control.Distributed.Process
import Control.Concurrent

import Network.CEP

import Test.Tasty
import Test.Tasty.HUnit

tests :: (Process () -> IO ()) -> TestTree
tests launch = localOption (mkTimeout 500000) $ testGroup "Settings"
  [ testCase "logger-works" $ launch testSettingsLogger ]


dummyLogger :: MVar () -> Logs -> s -> Process ()
dummyLogger lock _ _ = liftIO $ putMVar lock ()

testSettingsLogger :: Process ()
testSettingsLogger = do
  lock <- liftIO $ newEmptyMVar
  self <- getSelfPid
  pid  <- spawnLocal $ execute () $ do
    setLogger $ dummyLogger lock
    define "rule" $ do
      ph1 <- phaseHandle "state-1"
      setPhase ph1 $ \() -> do
        phaseLog "test" "test"
        liftProcess $ usend self ()
      start ph1 ()
  usend pid ()
  () <- expect
  liftIO $ takeMVar lock
