--
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Run all integration tests.

import qualified Test.ConfRead
import qualified Test.CopyConf
import qualified Test.MakeConf
import qualified Test.Management

import Control.Concurrent
import Control.Exception(bracket_, try, IOException)
import System.Process
import System.Environment

import Helper
import Test.Tasty
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)
import Test.Tasty.HUnit


tests :: TestTree
tests = testGroup "integration-tests" 
  [ runTestCase Test.ConfRead.name
  , runTestCase Test.MakeConf.name
  , runTestCase Test.CopyConf.name
  , runTestCase Test.Management.name
  ]

runTestCase :: String -> TestTree
runTestCase name = testCase name $ do
  prog <- getExecutablePath
  callCommand $ "CONF_TEST=" ++ name ++ " " ++ prog
 
main :: IO ()
main = withMeroRoot $ \meroRoot -> withSudo ["LD_LIBRARY_PATH", "MERO_ROOT"] $ do
  mtest <- lookupEnv "CONF_TEST"
  case mtest of
    Just test
      | test == Test.ConfRead.name   -> Test.ConfRead.test
      | test == Test.MakeConf.name   -> Test.MakeConf.test
      | test == Test.CopyConf.name   -> Test.CopyConf.test
      | test == Test.Management.name -> Test.Management.test
    _ -> bracket_
      (do setEnv "SANDBOX_DIR" "/var/mero/sandbox.conf-st"
          callCommand $ meroRoot ++ "/conf/st sstart")
      (do threadDelay $ 3*1000000
          tryIO $ callCommand $ meroRoot ++ "/conf/st sstop"
          tryIO $ callCommand $ meroRoot ++ "/conf/st rmmod") 
      (do nid <- getLnetNid
          setEnv confdEndpoint $ nid ++ ":12345:34:1001"
          setEnv confd2Endpoint $ nid ++ ":12345:34:1002"
          setEnv halonEndpoint  $ nid ++ ":12345:35:401"
          defaultMainWithIngredients  [fileTestReporter [consoleTestReporter]] tests)

tryIO :: IO a -> IO (Either IOException a)
tryIO = try
