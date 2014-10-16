--
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This program shows how to define distributed benchmarks.
--
-- Call as
--
-- > $ DO_SSH_KEY_IDS=<ssh_key_ids> distributed-benchmark-example
--

import Control.Distributed.Commands
import Control.Distributed.Commands.DigitalOcean

import Control.Concurrent.Async.Lifted
import Control.Exception (bracket)
import Control.Monad (void, forM_, forM)
import Data.Maybe (isJust)
import System.Environment (lookupEnv)


main :: IO ()
main = withDigitalOceanDo $ do
    Just sshKeyIds <- lookupEnv "DO_SSH_KEY_IDS"
    Just credentials <- getCredentialsFromEnv
    bracket
      -- Create the droplets
      ((forM [1..3] $ \i -> async $ newDroplet credentials NewDropletArgs
            { name        = "test-droplet-1" ++ show i
            , size_slug   = "512mb"
            , image_id    = "6709658"
            , region_slug = "ams2"
            , ssh_key_ids = sshKeyIds
            }
       ) >>= mapM wait
      )
      -- Destroy the droplets
      (mapM (destroyDroplet credentials . dropletDataId))
      $ \ds -> do
        forM_ ds $ \d -> async $ do
          -- Copy the program to benchmark.
          scp (LocalPath "dist/build/the-benchmark/the-benchmark")
              (RemotePath (Just "root") (dropletDataIP d) "the-benchmark")
          -- Launch the slaves.
          readOutput <- runCommand "root" (dropletDataIP d)
                                          "~/the-benchmark --slave 2>&1"
          -- Wait until the slaves are ready
          mFirstLine <- readOutput
          case mFirstLine of
            Just "ready" -> return () -- the benchmark program states that it
                                      -- is ready to start
            _            -> error "something bad happened"

        -- Kick the benchmark.
        readOutput <- runCommand "root" (dropletDataIP (head ds))
                                       "~/the-benchmark --start 2>&1"
        -- Collect the output.
        void $ repeatWhileM isJust $ do
          mLine <- readOutput
          maybe (return ()) putStrLn mLine
          return mLine


-- | Repeats a given action while the given predicate evaluates to @True@.
-- Returns the result of the last repetition.
repeatWhileM :: Monad m => (a -> Bool) -> m a -> m a
repeatWhileM p ma = ma >>= \a -> if p a then repeatWhileM p ma else return a
