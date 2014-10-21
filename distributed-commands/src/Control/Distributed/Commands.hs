module Control.Distributed.Commands where

import Control.Exception (throwIO)
import System.Exit (ExitCode(..))
import System.IO (hGetLine, IOMode(..), withFile)
import System.IO.Error (catchIOError, isEOFError)
import System.Process
    ( StdStream(..)
    , proc
    , createProcess
    , CreateProcess(..)
    , waitForProcess
    )


-- | 'scp' paths are either local or remote.
data ScpPath = LocalPath FilePath
             | -- | @RemotePath (Just user) host path@
               RemotePath (Maybe String) String FilePath

-- | @scp src dst@
--
-- Copies files with scp.
--
scp :: ScpPath -> ScpPath -> IO ()
scp src dst =
    withFile "/dev/null" ReadWriteMode $ \dev_null -> do
      (_, _, _, ph) <- createProcess
        (proc "scp" [ "-r"
                    , "-o", "UserKnownHostsFile=/dev/null"
                    , "-o", "StrictHostKeyChecking=no"
                    , showPath src
                    , showPath dst
                    ])
        { std_in  = UseHandle dev_null
        , std_out = UseHandle dev_null
        , std_err = UseHandle dev_null
        }
      ret <- waitForProcess ph
      case ret of
        ExitSuccess -> return ()
        ExitFailure r -> throwIO $ userError $ "scp error: " ++ show r
  where
    showPath (LocalPath f) = f
    showPath (RemotePath mu h f) = maybe "" (++ "@") mu ++ h ++ ":" ++ f

-- | Runs a command in the given host.
-- Returns the standard output.
-- The call returns immediately.
--
-- Each call of the returned IO action yields potentially
-- a line of output and Nothing when all the output has
-- been consumed and the program has terminated.
--
-- To wait for completion of the command, execute
--
-- > runCommand user host cmd >>= dropWhileM isJust
--
-- To capture the standard error, run as:
--
-- > runCommand user host "(... cmd ...) 2>&1" >>= dropWhileM isJust
--
runCommand :: Maybe String -> String -> String -> IO (IO (Maybe String))
runCommand muser host cmd = do
    -- Connect to the remote host.
    withFile "/dev/null" ReadWriteMode $ \dev_null -> do
      (_, Just sout, ~(Just _), _) <- createProcess (proc "ssh"
        [ maybe "" (++ "@") muser ++ host
        , "-o", "UserKnownHostsFile=/dev/null"
        , "-o", "StrictHostKeyChecking=no"
        , "--", cmd ])
        { std_out = CreatePipe
        , std_err = UseHandle dev_null
        }
      return $ catchIOError (fmap Just $ hGetLine sout)
                            (\e -> if isEOFError e then return Nothing
                                     else ioError e
                            )
