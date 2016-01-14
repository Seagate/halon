-- | Thin wrapper over various systemd functionality
--
-- Until we know exactly what we need, this is just a hotpot module.
module System.SystemD.API where

import Control.Exception
import System.Directory
import System.Exit
import System.FilePath
import System.IO
import System.Process

-- | Helper for service runners
runCtl :: [String] -> IO ExitCode
runCtl args = do
  readProcessWithExitCode "systemctl" args "" >>= \(c, _, _) -> return c

doService :: String -> String -> IO ExitCode
doService a n = runCtl [a, n]

-- | Start the service with the given name
startService :: String -> IO ExitCode
startService = doService "start"

-- | Stop the service with the given name
stopService :: String -> IO ExitCode
stopService = doService "stop"

-- | Restart the service with the given name
restartService :: String -> IO ExitCode
restartService = doService "restart"

-- | Load in the conf in format that @systemd-tmpfiles@ expectes
createConf :: [String] -- ^ Configuration strings
           -> IO ExitCode
createConf content = do
  tmp <- getTemporaryDirectory
  (fp, h) <- openTempFile tmp "halon-conf"
  hPutStr h $ unlines content
  hClose h
  (c, _, _) <- readProcessWithExitCode "systemd-tmpfiles" ["--create", fp] ""
  removeFile fp
  return c

-- | Take in a list env var assignments and store it in
-- @/etc/sysconfig@ with the given 'FilePath'.
sysctlFile :: FilePath -- ^ The filename to save under
           -> [(String, String)] -- ^ (varname, value)
           -> IO (Maybe SomeException)
sysctlFile fp vars = flip catch (return . Just) $ do
  createDirectoryIfMissing True "/etc/sysconfig"
  writeFile (sysconfDir </> fp) . unlines $ map formatVars vars
  return Nothing
  where
    sysconfDir = "/etc/sysconfig"
    formatVars (var, v) = var ++ "='" ++ v ++ "'"
