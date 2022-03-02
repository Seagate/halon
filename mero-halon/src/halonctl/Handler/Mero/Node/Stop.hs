{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Node.Stop
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
module Handler.Mero.Node.Stop
  ( parser
  , Options(..)
  , run
  ) where

import           Control.Distributed.Process hiding (bracket_, die)
import           Control.Monad
import           Control.Monad.Catch (bracket_)
import           Data.Function (fix)
import           Data.Monoid ((<>))
import           Data.Proxy
import           HA.EventQueue (promulgateEQ_)
import           HA.RecoveryCoordinator.Castor.Node.Events
import           HA.RecoveryCoordinator.RC (subscribeOnTo, unsubscribeOnFrom)
import           Mero.ConfC (strToFid)
import           Network.CEP
import qualified Options.Applicative as Opt
import           System.Exit (die, exitFailure)
import           System.IO (hPutStrLn, stderr)

data Options = Options
       { stopNodeForce :: Bool
       , stopNodeFid   :: String
       , stopNodeSync  :: Bool
       , stopNodeReason :: String
       } deriving (Eq, Show)

parser :: Opt.Parser Options
parser = Options
   <$> Opt.switch (Opt.long "force" <> Opt.short 'f' <> Opt.help "force stop, even if it reduces liveness.")
   <*> Opt.strOption (Opt.long "node" <> Opt.help "Node to shutdown" <>  Opt.metavar "NODE")
   <*> Opt.switch (Opt.long "sync" <> Opt.short 's' <> Opt.help "exit when operation finished.")
   <*> Opt.strOption (Opt.long "reason" <> Opt.help "Reason for stopping the node" <> Opt.value "unspecified" <> Opt.metavar "REASON")

run :: [NodeId] -> Options -> Process ()
run eqnids opts = do
  case strToFid (stopNodeFid opts) of
    Nothing -> liftIO $ die "Not a fid"
    Just fid -> do
      (sp, rp) <- newChan
      subscribing $ do
         promulgateEQ_ eqnids $ StopNodeUserRequest fid (stopNodeForce opts) sp
             (stopNodeReason opts)
         r <- receiveChan rp
         case r of
           NotANode{} -> liftIO $ die "Requested fid is not a node fid."
           CantStop _ _ results -> liftIO $ do
             hPutStrLn stderr "Can't stop node because it leads to:"
             forM_ results $ \result -> hPutStrLn stderr $ "    " ++ result
             exitFailure
           StopInitiated _ node -> do
             liftIO $ putStrLn "Stop initiated."
             when (stopNodeSync opts) $ do
                liftIO $ putStrLn "Waiting for completion."
                fix $ \inner -> do
                  Published msg _ <- expect :: Process (Published MaintenanceStopNodeResult)
                  case msg of
                    MaintenanceStopNodeOk rnode | rnode /= node -> inner
                    MaintenanceStopNodeTimeout rnode | rnode /= node -> inner
                    MaintenanceStopNodeFailed rnode _ | rnode /= node -> inner
                    MaintenanceStopNodeOk{} -> liftIO $ putStrLn "Stop node finished."
                    MaintenanceStopNodeTimeout{} -> liftIO $ putStrLn "Stop node timeout."
                    MaintenanceStopNodeFailed _ err -> liftIO . putStrLn $ "Stop node failed: " ++ err
  where
   subscribing | stopNodeSync opts = bracket_
     (subscribeOnTo eqnids (Proxy :: Proxy MaintenanceStopNodeResult))
     (unsubscribeOnFrom eqnids (Proxy :: Proxy MaintenanceStopNodeResult))
               | otherwise = id
