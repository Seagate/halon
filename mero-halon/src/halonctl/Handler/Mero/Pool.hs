{-# LANGUAGE StrictData #-}
{-# LANGUAGE LambdaCase #-}
-- |
-- Module    : Handler.Mero.Pool
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Operations on pools.
module Handler.Mero.Pool
  ( parser
  , Options(..)
  , run
  ) where

import           Control.Distributed.Process
  ( Process
  , NodeId
  , expectTimeout
  , liftIO
  , matchIf
  , receiveTimeout
  )
import           Control.Monad (unless, void)
import           Data.Function (fix)
import           Data.Monoid ((<>))
import           Data.Proxy (Proxy(..))
import           Data.UUID (UUID)
import qualified Data.UUID as UUID
import           HA.EventQueue (promulgateEQ)
import qualified HA.RecoveryCoordinator.Castor.Cluster.Events as Evt
import qualified HA.RecoveryCoordinator.Mero.Events as Evt
import           HA.RecoveryCoordinator.RC (subscribeOnTo, unsubscribeOnFrom)
import           HA.Resources.Mero (Pool(..))
import qualified HA.Resources.Mero.Note as M0 (showFid)
import qualified Handler.Mero.Helpers as Helpers
import           Options.Applicative ((<|>))
import qualified Options.Applicative as Opt
import           Options.Applicative.Extras (command')
import           System.Exit (exitFailure)
import           System.IO (hPutStrLn, stderr)

data Options = RepReb RepRebCommands
  deriving (Eq, Show)

data RepRebCommands =
    Abort SNSOpts
  | Quiesce SNSOpts
  | Restart SNSOpts
  | Resume SNSOpts
  deriving (Eq, Show)

data SNSOpts = SNSOpts {
    pool :: Pool
  , opUUID :: UUID
  , opTimeout :: Int
} deriving (Eq, Show)

parser :: Opt.Parser Options
parser = RepReb <$> Opt.hsubparser ( command' "repreb" parseRepRebCommands
                                     "Control repair/rebalance." )

parseRepRebCommands :: Opt.Parser RepRebCommands
parseRepRebCommands =
      ( Abort <$> Opt.hsubparser ( command' "abort" parseSNSOpts
                                   "Abort in-progress repair/rebalance." ))
  <|> ( Quiesce <$> Opt.hsubparser ( command' "quiesce" parseSNSOpts
                                     "Quiesce in-progress repair/rebalance." ))
  <|> ( Restart <$> Opt.hsubparser ( command' "restart" parseSNSOpts
                                     "Restart in-progress repair/rebalance." ))
  <|> ( Resume <$> Opt.hsubparser ( command' "resume" parseSNSOpts
                                    "Resume in-progress repair/rebalance." ))

parsePool :: Opt.Parser Pool
parsePool = Pool <$> Helpers.fidOpt
    ( Opt.long "pool"
    <> Opt.short 'p'
    <> Opt.help "Fid of the pool to control operations on."
    <> Opt.metavar "POOLFID"
    )

parseSNSOpts :: Opt.Parser SNSOpts
parseSNSOpts = SNSOpts
  <$> parsePool
  <*> Opt.option (Opt.maybeReader UUID.fromString)
      ( Opt.long "uuid"
      <> Opt.short 'u'
      <> Opt.help "UUID of the pool operation. Shown in `hctl mero status`."
      <> Opt.metavar "UUID"
      )
  <*> Opt.option Opt.auto
      ( Opt.long "timeout"
      <> Opt.short 't'
      <> Opt.help "Time to wait for SNS operation to return in seconds."
      <> Opt.metavar "TIMEOUT (s)"
      )

run :: [NodeId] -> Options -> Process ()
run eqnids (RepReb r) = runRepReb eqnids r

-- | Trigger repair or rebalance operations.
runRepReb :: [NodeId] -> RepRebCommands -> Process ()
runRepReb eqnids (Abort opts) = do
  subscribeOnTo eqnids (Proxy :: Proxy Evt.AbortSNSOperationResult)
  void $ promulgateEQ eqnids (Evt.AbortSNSOperation
                        (pool opts) (opUUID opts))
  success <- fix $ \f -> do
    expectTimeout (opTimeout opts * 1000000) >>= \case
      Nothing -> liftIO $ do
        hPutStrLn stderr "Timeout waiting for abort SNS reply."
        return False
      Just res -> case res of
        Evt.AbortSNSOperationOk p | p == pool opts ->
          return True
        Evt.AbortSNSOperationFailure p err | p == pool opts -> liftIO $ do
          hPutStrLn stderr $ "SNS abort failed: " ++ err
          return False
        Evt.AbortSNSOperationSkip p | p == pool opts -> liftIO $ do
          hPutStrLn stderr $ "SNS abort skipped - no operation running."
          return False
        _ -> f
  unsubscribeOnFrom eqnids (Proxy :: Proxy Evt.AbortSNSOperationResult)
  unless success $ liftIO exitFailure

runRepReb eqnids (Quiesce opts) = do
  subscribeOnTo eqnids (Proxy :: Proxy Evt.QuiesceSNSOperationResult)
  void $ promulgateEQ eqnids (Evt.QuiesceSNSOperation (pool opts))
  success <- fix $ \f -> do
    expectTimeout (opTimeout opts * 1000000) >>= \case
      Nothing -> liftIO $ do
        hPutStrLn stderr "Timeout waiting for quiesce SNS reply."
        return False
      Just res -> case res of
        Evt.QuiesceSNSOperationOk p | p == pool opts ->
          return True
        Evt.QuiesceSNSOperationFailure p err | p == pool opts -> liftIO $ do
          hPutStrLn stderr $ "SNS quiesce failed: " ++ err
          return False
        Evt.QuiesceSNSOperationSkip p | p == pool opts -> liftIO $ do
          hPutStrLn stderr $ "SNS quiesce skipped - no operation running."
          return False
        _ -> f
  unsubscribeOnFrom eqnids (Proxy :: Proxy Evt.QuiesceSNSOperationResult)
  unless success $ liftIO exitFailure

runRepReb eqnids (Restart opts) = do
  subscribeOnTo eqnids (Proxy :: Proxy Evt.RestartSNSOperationResult)
  void $ promulgateEQ eqnids (Evt.RestartSNSOperationRequest
                        (pool opts) (opUUID opts))
  success <- fix $ \f -> do
    expectTimeout (opTimeout opts * 1000000) >>= \case
      Nothing -> liftIO $ do
        hPutStrLn stderr "Timeout waiting for restart SNS reply."
        return False
      Just res -> case res of
        Evt.RestartSNSOperationSuccess p | p == pool opts ->
          return True
        Evt.RestartSNSOperationFailed p err | p == pool opts -> liftIO $ do
          hPutStrLn stderr $ "SNS restart failed: " ++ err
          return False
        Evt.RestartSNSOperationSkip p | p == pool opts -> liftIO $ do
          hPutStrLn stderr $ "SNS restart skipped - no operation running."
          return False
        _ -> f
  unsubscribeOnFrom eqnids (Proxy :: Proxy Evt.RestartSNSOperationResult)
  unless success $ liftIO exitFailure

runRepReb eqnids (Resume opts) = do
  subscribeOnTo eqnids (Proxy :: Proxy Evt.PoolRepairStartResult)
  subscribeOnTo eqnids (Proxy :: Proxy Evt.PoolRebalanceStarted)
  void $ promulgateEQ eqnids (Evt.PoolRepairRequest $ pool opts)
  void $ promulgateEQ eqnids (Evt.PoolRebalanceRequest $ pool opts)
  let
    f x = if x == 2 then return True else do
      res <- receiveTimeout (opTimeout opts * 1000000)
        [ matchIf
            (\(Evt.PoolRepairStarted p) -> p == pool opts)
            (\(Evt.PoolRepairStarted p) -> do
              unsubscribeOnFrom eqnids (Proxy :: Proxy Evt.PoolRepairStartResult)
              liftIO . putStrLn
                $ "Resuming repair on pool " ++ M0.showFid p
              f $ x + 1
            )
        , matchIf
            (\(Evt.PoolRepairFailedToStart p _) -> p == pool opts)
            (\(Evt.PoolRepairFailedToStart _ msg) -> do
              unsubscribeOnFrom eqnids (Proxy :: Proxy Evt.PoolRepairStartResult)
              liftIO . putStrLn
                $ "Not starting repair due to: " ++ msg
              f $ x + 1
            )
        , matchIf
            (\(Evt.PoolRebalanceStarted p) -> p == pool opts)
            (\(Evt.PoolRebalanceStarted p) -> do
              unsubscribeOnFrom eqnids (Proxy :: Proxy Evt.PoolRebalanceStarted)
              liftIO . putStrLn
                $ "Resuming rebalance on pool " ++ M0.showFid p
              f $ x + 1
            )
        , matchIf
            (\(Evt.PoolRebalanceFailedToStart p) -> p == pool opts)
            (\(Evt.PoolRebalanceStarted _) -> do
              unsubscribeOnFrom eqnids (Proxy :: Proxy Evt.PoolRebalanceStarted)
              liftIO . putStrLn $ "Not starting rebalance"
              f $ x + 1
            )
        ]
      case res of
        Just True -> return True
        _ -> return False
  success <- f (0 :: Int)
  unless success (liftIO exitFailure)
