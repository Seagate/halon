{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Process.Start
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module Handler.Mero.Process.Start
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process hiding (die)
import           Data.Monoid ((<>))
import           HA.EventQueue (promulgateEQ_)
import           HA.RecoveryCoordinator.Castor.Process.Events
import           HA.RecoveryCoordinator.RC.Events.Info
import qualified Handler.Mero.Helpers as Helpers
import           Mero.ConfC (Fid)
import qualified Options.Applicative as Opt
import           System.Exit (die)
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
  promulgateEQ_ nids $! ProcessQueryRequest (_fid opts) sp
  receiveChan rp >>= \case
    Nothing -> liftIO . die $
      "RC didn't find process with fid " ++ show (_fid opts)
    Just p -> Helpers.runJob nids (ProcessStartRequest p) act
  where
    act = if _async opts
          then Nothing
          else Just $ liftIO . \case
      ProcessStarted{} -> putStrLn $ printf "%s started." (show $ _fid opts)
      r -> die $ printf "%s failed to start: %s" (show $ _fid opts) (show r)
