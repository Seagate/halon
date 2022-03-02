{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Process.Stop
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module Handler.Mero.Process.Stop
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process hiding (die)
import           Data.Monoid ((<>))
import           HA.EventQueue (promulgateEQ_)
import           HA.RecoveryCoordinator.Castor.Process.Events
import qualified HA.Resources.Mero as M0
import qualified Handler.Mero.Helpers as Helpers
import           Mero.ConfC (Fid)
import qualified Data.Text as T (unpack)
import qualified Options.Applicative as Opt
import           System.Exit (die)
import           Text.Printf (printf)

data Options = Options
  { _async :: !Bool
  , _fid :: !Fid
  , _force :: !Bool
  } deriving (Show, Eq)

parser :: Opt.Parser Options
parser = Options
  <$> Opt.switch
    ( Opt.long "async"
   <> Opt.help "Do not wait for the process stop result." )
  <*> Helpers.fidOpt
    ( Opt.metavar "FID"
   <> Opt.long "fid"
   <> Opt.help "Fid of the process to stop." )
  <*> Opt.switch
    ( Opt.long "force"
   <> Opt.help "Try to stop process, skipping cluster liveness check" )


run :: [NodeId] -> Options -> Process ()
run nids opts = do
  (sp, rp) <- newChan
  waitResult <- Helpers.waitJob nids act
  promulgateEQ_ nids $! StopProcessUserRequest (_fid opts) (_force opts) sp
  receiveChan rp >>= \case
    NoSuchProcess -> liftIO . die $
      "RC didn't find process with fid " ++ show (_fid opts)
    StopWouldBreakCluster reason -> liftIO . die $
      "Process stop would lower cluster liveness: " ++ T.unpack reason
    StopProcessInitiated l -> do
      liftIO $! putStrLn "Process stop initiated."
      waitResult l
  where
    act = if _async opts
          then Nothing
          else Just $ liftIO . \case
      StopProcessResult (_, M0.PSOffline) ->
        putStrLn $ printf "%s stopped." (show $ _fid opts)
      r -> die $ printf "%s failed to stop: %s" (show $ _fid opts) (show r)
