{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Node.DiReb
-- Copyright : (C) 2018 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Halon control command to trigger direct rebalance of a node. A node
-- rebalance can be triggered when a failed node is replaced and has
-- to be re-populated with the data. It is possible that a node has
-- failed but the storage attached to it is fine, e.g. motherboard or
-- a network failure. Halon control command allows admin to trigger
-- node direct rebalance accordingly.

module Handler.Mero.Node.DiReb
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
  ( Process
  , NodeId
  , expectTimeout
  , liftIO
  )
import           Control.Monad (unless, void)
import           Data.Function (fix)
import           Data.Monoid ((<>))
import           Data.Proxy (Proxy(..))
import           HA.EventQueue (promulgateEQ)
import qualified HA.RecoveryCoordinator.Castor.Node.Events as Evt
import           HA.RecoveryCoordinator.RC (subscribeOnTo, unsubscribeOnFrom)
import           HA.Resources.Mero (Node(..))
import qualified Handler.Mero.Helpers as Helpers
import qualified Options.Applicative as Opt
import           System.Exit (exitFailure)
import           System.IO (hPutStrLn, stderr)

data Options = Options
  { node :: Node
  , rebTimeout :: Int
  } deriving (Show, Eq)

parseNode :: Opt.Parser Node
parseNode = Node <$> Helpers.fidOpt
                     ( Opt.long "node"
                    <> Opt.short 'n'
                    <> Opt.help "Fid of the node for direct rebalance"
                    <> Opt.metavar "FID" )

parser :: Opt.Parser Options
parser = Options
  <$> parseNode
  <*> Opt.option Opt.auto
      ( Opt.long "timeout"
     <> Opt.help "Time to wait for the operation to return in seconds"
     <> Opt.metavar "TIMEOUT (s)" )

run :: [NodeId] -> Options -> Process ()
run eqnids opts = do
  subscribeOnTo eqnids (Proxy :: Proxy Evt.NodeDiRebRes)
  void . promulgateEQ eqnids . Evt.NodeDiRebReq $ node opts
  success <- fix $ \loop -> do
    stat <- expectTimeout (rebTimeout opts * 1000000)
    let err = liftIO . hPutStrLn stderr
    case stat of
       Just (Evt.NodeDiRebReqSucccess n) | n == node opts ->
            return True
       Just (Evt.NodeDiRebReqFailed n e) | n == node opts -> do
            err $ "Node direct rebalance failed " ++ e
            return False
       Nothing -> do
            err "Node direct rebalance request timeout"
            return False
       _ -> loop
  unsubscribeOnFrom eqnids (Proxy :: Proxy Evt.NodeDiRebRes)
  unless success $ liftIO exitFailure
