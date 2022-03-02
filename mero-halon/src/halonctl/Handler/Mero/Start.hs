{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Start
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
module Handler.Mero.Start
  ( parser
  , Options(..)
  , run
  ) where

import           Control.Distributed.Process hiding (bracket_)
import           Data.Maybe (mapMaybe)
import           Data.Monoid ((<>))
import           Data.Proxy
import           HA.EventQueue (promulgateEQ_)
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import           HA.RecoveryCoordinator.Castor.Node.Events
import           HA.RecoveryCoordinator.RC (subscribeOnTo, unsubscribeOnFrom)
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (showFid)
import           Network.CEP
import qualified Options.Applicative as Opt
import           System.Exit (exitFailure, exitSuccess)

data Options = Options Bool deriving (Eq, Show)

parser :: Opt.Parser Options
parser = Options
  <$> Opt.switch
       ( Opt.long "async"
       <> Opt.short 'a'
       <> Opt.help "Do not wait for cluster start.")


run :: [NodeId] -> Options -> Process ()
run eqnids (Options False) = do
  say "Starting cluster."
  subscribeOnTo eqnids (Proxy :: Proxy ClusterStartResult)
  promulgateEQ_ eqnids ClusterStartRequest
  Published msg _ <- expect :: Process (Published ClusterStartResult)
  unsubscribeOnFrom eqnids (Proxy :: Proxy ClusterStartResult)
  liftIO $ do
    putStr $ prettyClusterStartResult msg
    case msg of
      ClusterStartOk        -> exitSuccess
      ClusterStartTimeout{} -> exitFailure
      ClusterStartFailure{} -> exitFailure
run eqnids (Options True) = do
  promulgateEQ_ eqnids ClusterStartRequest
  liftIO $ putStrLn "Cluster start request sent."

-- | Nicely format 'ClusterStartResult' into something the user can
-- easily understand.
prettyClusterStartResult :: ClusterStartResult -> String
prettyClusterStartResult = \case
  ClusterStartOk -> "Cluster started successfully.\n"
  ClusterStartTimeout ns -> unlines $
    "Cluster failed to start on time. Still waiting for following processes:"
    : map (\n -> formatNode n " (Timeout)") ns
  ClusterStartFailure s spn -> unlines $
    ("Cluster failed with “" ++ s ++ "” due to:")
    : mapMaybe formatSPNR spn
  where
    formatSPNR :: StartProcessesOnNodeResult -> Maybe String
    formatSPNR (NodeProcessesStartTimeout n ps) = Just $ formatNode (n, ps) " (Timeout)"
    formatSPNR (NodeProcessesStartFailure n ps) = Just $ formatNode (n, ps) " (Failure)"
    formatSPNR NodeProcessesStarted{}           = Nothing

    formatProcess :: (M0.Process, M0.ProcessState) -> String
    formatProcess (p, s) = "\t\t" ++ showFid p ++ ": " ++ show s

    formatNode (n, ps) m = unlines $ ("\t" ++ showFid n ++ m) : map formatProcess ps
