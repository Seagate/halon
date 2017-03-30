import Control.Concurrent (threadDelay)
import Control.Distributed.Commands.Internal.Probes (tryTimes)
import Control.Exception (throwIO)
import Data.IORef (readIORef, writeIORef, newIORef)
import System.IO.Error (tryIOError)


main :: IO ()
main = do
  testTryTimes

testTryTimes :: IO ()
testTryTimes = do
  testTryTimesSuccess
  testTryTimesFailure
  testTryTimesFailureDelay
  testTryTimesSuccessOnSecondGo

testTryTimesSuccess :: IO ()
testTryTimesSuccess = tryTimes "testTryTimesSuccess" 3 500000 $ return True

testTryTimesSuccessOnSecondGo :: IO ()
testTryTimesSuccessOnSecondGo = do
  ref <- newIORef False
  tryTimes "testTryTimesSuccessOnSecondGo" 3 500000 $ do
    v <- readIORef ref
    if v then return True
         else writeIORef ref True >> return False

testTryTimesFailure :: IO ()
testTryTimesFailure = testTryTimesFailureAction "testTryTimesFailure" (return False)

testTryTimesFailureDelay :: IO ()
testTryTimesFailureDelay = testTryTimesFailureAction "testTryTimesFailureDelay" $ do
  threadDelay 800000
  return True

testTryTimesFailureAction :: String -> IO Bool -> IO ()
testTryTimesFailureAction desc action = do
  res <- tryIOError $ tryTimes desc 3 500000 $ action
  case res of
    Left{} -> return () -- success
    Right _ -> throwIO $ userError $ desc ++ " succeeded when it should have failed"
