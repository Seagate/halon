module Control.Distributed.Commands.Internal.Log where

  import Control.Applicative ( (<$>) )
  import Control.Monad (when)
  import Data.Maybe (isJust)
  import System.Environment (lookupEnv)
  import System.IO (hFlush, hPutStrLn, stderr)

  debugLog :: String -> IO ()
  debugLog s = do
    dcVerbose <- isVerbose
    when dcVerbose $ do
      hPutStrLn stderr s
      hFlush stderr

  isVerbose :: IO Bool
  isVerbose = isJust <$> lookupEnv "DC_VERBOSE"

