{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Reset
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module Handler.Mero.Reset
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process hiding (bracket_)
import           Control.Monad
import           Control.Monad.Fix (fix)
import           Data.Foldable
import           Data.Monoid ((<>))
import           HA.EventQueue (eventQueueLabel, DoClearEQ(..), DoneClearEQ(..) )
import           HA.EventQueue (promulgateEQ)
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import           HA.RecoveryCoordinator.Mero (labelRecoveryCoordinator)
import           Lookup (findEQFromNodes)
import qualified Options.Applicative as Opt
import           System.Exit (exitFailure, exitSuccess)
import           System.IO (hPutStrLn, stderr)

data Options = Options Bool Bool
  deriving (Eq, Show)

parser :: Opt.Parser Options
parser = Options
  <$> Opt.switch
    ( Opt.long "hard"
    <> Opt.help "Perform a hard reset. This clears the EQ and forces an RC restart."
    )
  <*> Opt.switch
    ( Opt.long "unstick"
    <> Opt.help "Clear the EQ and reset the RC remotely, in case of a stuck RC."
    )

run :: [NodeId]
             -> Options
             -> Process ()
run eqnids (Options hard unstick) = if unstick
  then do
    self <- getSelfPid
    eqs <- findEQFromNodes 1000000 eqnids
    case eqs of
      [] -> liftIO $ putStrLn "Cannot find EQ."
      eq:_ -> do
        nsendRemote eq eventQueueLabel $ DoClearEQ self
        msg <- expectTimeout 1000000
        case msg of
          Nothing -> liftIO $ putStrLn "No reply from EQ."
          Just DoneClearEQ -> liftIO $ putStrLn "EQ cleared."
    -- Attempt to kill the RC
    for_ eqnids $ \nid -> whereisRemoteAsync nid labelRecoveryCoordinator
    void . spawnLocal $ receiveTimeout 3000000 [] >> usend self ()
    fix $ \loop -> do
      void $ receiveWait
        [ matchIf (\(WhereIsReply s _) -> s == labelRecoveryCoordinator)
           $ \(WhereIsReply _ mp) -> case mp of
             Nothing -> loop
             Just p -> do
               liftIO $ putStrLn "Killing recovery coordinator."
               kill p "User requested `cluster reset --unstick`"
               liftIO exitSuccess
        , match $ \() -> liftIO $ do
            hPutStrLn stderr "Cannot determine the location of the RC."
            exitFailure
        ]
  else do
      promulgateEQ eqnids (ClusterResetRequest hard) >>= flip withMonitor wait
    where
      wait = void (expect :: Process ProcessMonitorNotification)
