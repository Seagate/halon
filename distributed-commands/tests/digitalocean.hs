--
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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
import System.Exit (ExitCode(ExitSuccess))


main :: IO ()
main = do
    Just credentials <- getCredentialsFromEnv
    bracket
      (newDroplet credentials NewDropletArgs
           { name        = "test-droplet"
           , size_slug   = "512mb"
           , -- The image is provisioned with halon from an ubuntu system. It
             -- has a user dev with halon built in its home folder. The image
             -- also has /etc/ssh/ssh_config tweaked so copying files from
             -- remote to remote machine does not store hosts in known_hosts.
             image_id    = "7055005"
           , region_slug = "ams2"
           , ssh_key_ids = ""
           }
      )
      (\d -> destroyDroplet credentials (dropletDataId d))
      $ \d -> do
        showDroplet credentials (dropletDataId d) >>= print
        scp (LocalPath "tests/digitalocean.hs")
            (RemotePath (Just "dev") (dropletDataIP d) "digitalocean.hs")
        putStrLn "scp complete"
        rio <- systemThereAsUser "dev" (dropletDataIP d)
                          "(echo h; echo g 1>&2; echo i; ls) 2>&1"
        putStrLn "systemThereAsUser complete"
        rio >>= test "h" (Right "h" ==)
        rio >>= test "g" (Right "g" ==)
        rio >>= test "i" (Right "i" ==)
        rio >>= test "digitalocean.hs" (Right "digitalocean.hs" ==)
        rio >>= test "halon" (Right "halon" ==)
        rio >>= test "Successful termination" (Left ExitSuccess ==)
        putStrLn "test output complete"
    putStrLn "SUCCESS!"
  where
    test expected f a = when (not $ f a) $
      throwIO $ userError $ "test failed: expected " ++ expected ++ " but got "
                            ++ show a
