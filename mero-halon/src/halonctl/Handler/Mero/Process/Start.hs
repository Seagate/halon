{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Process.Start
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module Handler.Mero.Process.Start
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
import           Data.Monoid ((<>))
import           HA.EventQueue (promulgateEQ)
import           HA.RecoveryCoordinator.Castor.Process.Events
import           HA.RecoveryCoordinator.RC.Events.Info
import qualified Handler.Mero.Helpers as Helpers
import           Mero.ConfC (Fid)
import qualified Options.Applicative as Opt
import           System.Exit (exitFailure)
import           System.IO (hPutStrLn, stderr)
import           Text.Printf (printf)

data Options = Options
  { _async :: !Bool
  , _fid :: !Fid
  } deriving (Show, Eq)

parser :: Opt.Parser Options
parser = Options
  <$> Opt.switch
    ( Opt.long "async"
   <> Opt.help "Do not wait for the process start result." )
  <*> Helpers.fidOpt
    ( Opt.metavar "FID"
   <> Opt.long "fid"
   <> Opt.long "Fid of the process to start." )

run :: [NodeId] -> Options -> Process ()
run nids opts = do
  (sp, rp) <- newChan
  _ <- promulgateEQ nids $! ProcessQueryRequest (_fid opts) sp
  receiveChan rp >>= \case
    Nothing -> liftIO $ do
      hPutStrLn stderr $
        printf "RC didn't find process with fid %s" (show $ _fid opts)
      exitFailure
    Just p -> Helpers.runJob nids (ProcessStartRequest p) act
  where
    act = if _async opts
          then Nothing
          else Just $ liftIO . \case
      ProcessStarted{} -> putStrLn $ printf "%s started." (show $ _fid opts)
      r -> do
        hPutStrLn stderr $
          printf "%s failed to start: %s" (show $ _fid opts) (show r)
        exitFailure
