--
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This test program rehearses the calls to the digital ocean API.
--
-- It creates a droplet, copies a file, runs some commands via ssh,
-- and destroys the droplet.
--

import Control.Distributed.Commands
import Control.Distributed.Commands.DigitalOcean

import Control.Exception (throwIO, bracket)
import Control.Monad (when)
import Data.Maybe (isNothing)


main :: IO ()
main = withDigitalOceanDo $ do
    Just credentials <- getCredentialsFromEnv
    bracket
      (newDroplet credentials NewDropletArgs
           { name        = "test-droplet"
           , size_slug   = "512mb"
           , image_id    = "7055005"
           , region_slug = "ams2"
           , ssh_key_ids = ""
           }
      )
      (\d -> destroyDroplet credentials (dropletDataId d))
      $ \d -> do
        showDroplet credentials (dropletDataId d) >>= print
        scp (LocalPath "tests/digitalocean.hs")
            (RemotePath (Just "root") (dropletDataIP d) "digitalocean.hs")
        putStrLn "scp complete"
        rio <- runCommand (Just "root") (dropletDataIP d)
                          "(echo h; echo g 1>&2; echo i; ls) 2>&1"
        putStrLn "runCommand complete"
        rio >>= test "h" (Just "h" ==)
        rio >>= test "g" (Just "g" ==)
        rio >>= test "i" (Just "i" ==)
        rio >>= test "digitalocean.hs" (Just "digitalocean.hs" ==)
        rio >>= test "Nothing" isNothing
        putStrLn "test output complete"
    putStrLn "SUCCESS!"
  where
    test expected f a = when (not $ f a) $
      throwIO $ userError $ "test failed: expected " ++ expected ++ " but got "
                            ++ show a
