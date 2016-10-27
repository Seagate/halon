-- | Thin wrapper over various systemd functionality
--
-- Until we know exactly what we need, this is just a hotpot module.
module System.SystemD.API where

import Control.Exception

import Data.List (intercalate)
import qualified Data.Map.Strict as Map

import System.Directory
import System.Exit
import System.FilePath
import System.IO
import System.Process

import Text.Parsec

-- | Helper for service runners
runCtl :: [String] -> IO (ExitCode, String, String)
runCtl args = readProcessWithExitCode "systemctl" args ""

doService :: String -> String -> IO ExitCode
doService a n = runCtl [a, n] >>= \(c, _, _) -> return c

propsParser :: Parsec String () (Map.Map String String)
propsParser = do
    ps <- many $ do
      p <- readProperty
      _ <- optional $ char '\n'
      return p
    eof
    return $ Map.fromList ps
  where
    readProperty = do
      pname <- many (noneOf "=\n")
      _ <- char '='
      pval <- many (noneOf "=\n")
      return (pname, pval)

-- | Read properties of running services
readProperties :: String -> [String] -> IO (Map.Map String String)
readProperties srv props = do
    (ec, out, _) <- runCtl $ ["show", srv] ++ propArgs
    case ec of
      ExitSuccess -> case parse propsParser "" out of
        Left _ -> return Map.empty
        Right xs -> return xs
      ExitFailure _ -> return Map.empty
  where
    propArgs = case props of
      [] -> []
      xs -> ["-p", intercalate "," xs]

-- | Start the service with the given name. Returns the
--   exit code on a failure, or the PID of the started service
--   on a correct start.
startService :: String -> IO (Either Int (Maybe Int))
startService srv = do
  ec <- doService "start" srv
  case ec of
    ExitFailure i -> return $ Left i
    ExitSuccess -> do
      props <- readProperties srv ["MainPID"]
      return $ Right (read <$> Map.lookup "MainPID" props)

-- | Stop the service with the given name
stopService :: String -> IO ExitCode
stopService = doService "stop"

-- | Restart the service with the given name
restartService :: String -> IO (Either Int (Maybe Int))
restartService srv = do
  ec <- doService "restart" srv
  case ec of
    ExitFailure i -> return $ Left i
    ExitSuccess -> do
      props <- readProperties srv ["MainPID"]
      return $ Right (read <$> Map.lookup "MainPID" props)

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
