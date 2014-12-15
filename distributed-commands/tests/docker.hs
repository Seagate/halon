--
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This test program rehearses the calls to the docker API.
--
-- It creates a droplet, copies a file, runs some commands via ssh,
-- and destroys the droplet.
--

import Control.Distributed.Commands
import Control.Distributed.Commands.Docker

import Control.Exception (throwIO, bracket)
import Control.Monad (when)
import Data.Maybe (isNothing)


main :: IO ()
main = do
    Just credentials <- getCredentialsFromEnv
    bracket
      (newContainer credentials NewContainerArgs
           { image_id    = "tweagremote"
           }
      )
      (\d -> destroyContainer credentials (containerId d))
      $ \d -> do
        showContainer credentials (containerId d) >>= print
        scp (LocalPath "tests/docker.hs")
            (RemotePath (Just "dev") (containerIP d) "docker.hs")
        putStrLn "scp complete"
        rio <- systemThereAsUser "dev" (containerIP d)
                          "(echo h; echo g 1>&2; echo i; ls) 2>&1"
        putStrLn "systemThereAsUser complete"
        rio >>= test "h" (Just "h" ==)
        rio >>= test "g" (Just "g" ==)
        rio >>= test "i" (Just "i" ==)
        rio >>= test "docker.hs" (Just "docker.hs" ==)
        rio >>= test "Nothing" isNothing
        putStrLn "test output complete"
    putStrLn "SUCCESS!"
  where
    test expected f a = when (not $ f a) $
      throwIO $ userError $ "test failed: expected " ++ expected ++ " but got "
                            ++ show a
