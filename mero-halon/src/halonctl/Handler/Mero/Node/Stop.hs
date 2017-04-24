{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Node.Stop
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module Handler.Mero.Node.Stop
  ( parser
  , Options(..)
  , run
  ) where

import           Control.Distributed.Process hiding (bracket_)
import           Control.Monad
import           Control.Monad.Catch (bracket_)
import           Control.Monad.Fix (fix)
import           Data.Monoid ((<>))
import           Data.Proxy
import           HA.EventQueue (promulgateEQ)
import           HA.RecoveryCoordinator.Castor.Node.Events
import           HA.RecoveryCoordinator.RC (subscribeOnTo, unsubscribeOnFrom)
import           Mero.ConfC (strToFid)
import           Network.CEP
import qualified Options.Applicative as Opt
import           System.Exit (exitFailure)
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
    Nothing -> liftIO $ do
      hPutStrLn stderr "Not a fid"
      exitFailure
    Just fid -> do
      (schan, rchan) <- newChan
      subscribing $ do
         _ <- promulgateEQ eqnids $ StopNodeUserRequest
                fid (stopNodeForce opts) schan (stopNodeReason opts)
         r <- receiveChan rchan
         case r of
           NotANode{} ->liftIO $ do
             hPutStrLn stderr "Requested fid is not a node fid."
             exitFailure
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