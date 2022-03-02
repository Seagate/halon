{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE TypeFamilies               #-}
-- |
-- Module    : HA.RecoveryCoordinator.Mero.Actions.Spiel
-- Copyright : (C) 2015-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
module HA.RecoveryCoordinator.Mero.Actions.Spiel
  ( haAddress
  , getSpielAddressRC
  , LiftRC
  , withSpielRC
  , withSpielIO
  , withRConfIO
    -- * SNS operations
  , mkRepairStartOperation
  , mkRepairContinueOperation
  , mkRepairQuiesceOperation
  , mkRepairStatusRequestOperation
  , mkRepairAbortOperation
  , mkRebalanceStartOperation
  , mkRebalanceContinueOperation
  , mkRebalanceQuiesceOperation
  , mkRebalanceAbortOperation
  , mkRebalanceStatusRequestOperation
  , mkDirectRebalanceStartOperation
  , SNSOperationRetryState(..)
  , FldSNSOperationRetryState
  , fldSNSOperationRetryState
  , defaultSNSOperationRetryState
    -- * Sync operation
  , defaultConfSyncState
  , fldConfSyncState
  , mkSyncAction
  , syncToBS
  , mkSyncToConfd
  , validateTransactionCache
    -- * Pool repair information
  , getPoolRepairInformation
  , getPoolRepairStatus
  , getNodeDiRebInformation
  , setNodeDiRebStatus
  , getTimeUntilHourlyQuery
  , modifyPoolRepairInformation
  , setPoolRepairInformation
  , setPoolRepairStatus
  , unsetPoolRepairStatus
  , unsetPoolRepairStatusWithUUID
  , unsetNodeDiRebStatus
  , updatePoolRepairQueryTime
  , updateSnsStartTime
  ) where

import           HA.RecoveryCoordinator.Castor.Drive.Actions.Graph
  (lookupDiskSDev)
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Job.Events
import           HA.RecoveryCoordinator.Mero.Actions.Conf
import           HA.RecoveryCoordinator.Mero.Actions.Core
import           HA.RecoveryCoordinator.Mero.Events
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources.Castor as Cas
import qualified HA.Resources.Castor.Initial as CI
import           HA.Resources.HalonVars
import           HA.Resources.Mero (SyncToConfd(..))
import qualified HA.Resources.Mero as M0

import           Mero.ConfC (Fid, PDClustAttr(..), confPVerLvlDrives)
import           Mero.Lnet
import           Mero.M0Worker
import           Mero.Notification hiding (notifyMero)
import           Mero.Spiel (SpielTransaction)
import qualified Mero.Spiel as Spiel

import           Control.Applicative (liftA2)
import qualified Control.Distributed.Process as DP
import           Control.Monad (void, join)
import           Control.Monad.Catch
import           Control.Lens

import           Data.Bifunctor (first)
import           Data.Binary (Binary)
import qualified Data.ByteString as BS
import           Data.Foldable (traverse_, for_)
import           Data.Hashable (hash)
import           Data.IORef (writeIORef)
import           Data.List (sortOn, (\\))
import           Data.Maybe (catMaybes, listToMaybe)
import qualified Data.Text as T
import           Data.Traversable (for)
import           Data.Typeable
import           Data.UUID (UUID)
import           Data.UUID.V4 (nextRandom)
import           Data.Vinyl

import           Network.CEP
import           System.IO

import           GHC.Generics
import           GHC.TypeLits
import           GHC.Exts

import           Prelude hiding (id)

-- | Default HA process endpoint listen address.
haAddress :: LNid -> Endpoint
haAddress lnid = Endpoint {
    network_id = lnid
  , process_id = 12345
  , portal_number = 34
  , transfer_machine_id = 101
  }

-- | Configuration update state.
data ConfSyncState = ConfSyncState
      { _cssHash :: Maybe Int -- ^ Hash of the graph sync request.
      , _cssForce :: Bool     -- ^ Should we force synchronization?
      , _cssQuiescing :: [ListenerId] -- ^ List of the pending SNS quiece jobs.
      , _cssAborting :: [ListenerId] -- ^ List of the pending SNS abort jobs.
      } deriving (Generic, Show)

-- | Field for 'ConfSyncState'.
fldConfSyncState :: Proxy '("hash", ConfSyncState)
fldConfSyncState = Proxy

-- | Default 'ConfSyncState'.
defaultConfSyncState :: ConfSyncState
defaultConfSyncState = ConfSyncState Nothing False [] []

makeLenses ''ConfSyncState

-- | SNS operation retry state.
data SNSOperationRetryState = SNSOperationRetryState
  { _sorStatusAttempts :: Int
  -- ^ How many times to ask for the status of SNS operation before giving up
  --   and retrying.
  , _sorRetryAttempts :: Int
  -- ^ How many attempts to execute SNS operation to make before giving up
  --   and failing.
  } deriving (Generic, Show)

-- | Default 'SNSOperationRetryState'.
defaultSNSOperationRetryState :: SNSOperationRetryState
defaultSNSOperationRetryState = SNSOperationRetryState 0 0

makeLenses ''SNSOperationRetryState

type FldSNSOperationRetryState = '("snsOperationRetryState", SNSOperationRetryState)

-- | Field for 'SNSOperationRetryState'.
fldSNSOperationRetryState :: Proxy FldSNSOperationRetryState
fldSNSOperationRetryState = Proxy

-- | Try to connect to spiel and run the 'PhaseM' on the
-- 'SpielContext'.
--
-- The user is responsible for making sure that inner 'IO' actions run
-- on the global m0 worker if needed.
withSpielRC :: (LiftRC -> PhaseM RC l a)
            -> PhaseM RC l (Either SomeException a)
withSpielRC f = withResourceGraphCache $ try $ withM0RC f

-- | Try to connect to spiel and run the 'IO' action in the 'SpielContext'.
--
-- All internal actions are run on m0 thread.
withSpielIO :: IO ()
            -> PhaseM RC l (Either SomeException ())
withSpielIO = withResourceGraphCache . try . withM0RC . flip m0asynchronously_

-- | Try to start rconf sesion and run 'IO' action in the 'SpielContext'.
-- This call is required for running spiel management commands.
--
-- Internal action will be running in mero thread allocated to RC service.
--
-- XXX-MULTIPOOLS: What about multiple profiles?
withRConfIO :: Maybe M0.Profile -> IO a -> IO a
withRConfIO mprof action = do
  Spiel.setCmdProfile (fmap (show . M0.fid) mprof)
  Spiel.rconfStart
  action `finally` Spiel.rconfStop

-------------------------------------------------------------------------------
-- Generic operations helpers.
-------------------------------------------------------------------------------

data GenericSNSOperationResult (k::Symbol) a = GenericSNSOperationResult M0.Pool (Either String a)
  deriving (Generic, Typeable)
instance Binary a => Binary (GenericSNSOperationResult k a)

data GenericNodeOperationResult (k::Symbol) a = GenericNodeOperationResult M0.Node (Either String a)
  deriving (Generic, Typeable)
instance Binary a => Binary (GenericNodeOperationResult k a)

-- | Helper for implementation call to generic spiel operation. This
-- call is done asynchronously.
mkGenericSNSOperation :: (Typeable a, Binary a, KnownSymbol k, Typeable k)
  => Proxy# k -- ^ Operation name
  -> (M0.Pool -> Either SomeException a -> GenericSNSOperationResult k a)
  -- ^ Handler
  -> (M0.Pool -> IO a)
  -- ^ SNS action
  -> M0.Pool
  -- ^ Pool of interest
  -> PhaseM RC l ()
mkGenericSNSOperation operation_name operation_reply operation_action pool = do
  Log.tagContext Log.SM [ ("spiel", symbolVal' operation_name)
                        , ("pool.fid", show (M0.fid pool))
                        ] Nothing
  unlift <- mkUnliftProcess
  next <- liftProcess $ do
    rc <- DP.getSelfPid
    return $ DP.usend rc . operation_reply pool
  mprof <- theProfile -- XXX-MULTIPOOLS: What about other profiles?
  er <- withSpielIO $
          withRConfIO mprof $ try (operation_action pool) >>= unlift . next
  case er of
    Right () -> return ()
    Left e -> liftProcess $ next $ Left e

-- | Helper for implementation call to generic spiel operation for node. This
-- call is done asynchronously.
mkGenericNodeOperation :: (Typeable a, Binary a, KnownSymbol k, Typeable k)
  => Proxy# k -- ^ Operation name
  -> (M0.Node -> Either SomeException a -> GenericNodeOperationResult k a)
  -- ^ Handler
  -> (M0.Node -> IO a)
  -- ^ Node action
  -> M0.Node
  -- ^ Node of interest
  -> PhaseM RC l ()
mkGenericNodeOperation operation_name operation_reply operation_action node = do
  Log.tagContext Log.SM [ ("spiel", symbolVal' operation_name)
                        , ("node.fid", show (M0.fid node))
                        ] Nothing
  unlift <- mkUnliftProcess
  next <- liftProcess $ do
    rc <- DP.getSelfPid
    return $ DP.usend rc . operation_reply node
  mprof <- theProfile -- XXX-MULTIPOOLS: What about other profiles?
  er <- withSpielIO $
          withRConfIO mprof $ try (operation_action node) >>= unlift . next
  case er of
    Right () -> return ()
    Left e -> liftProcess $ next $ Left e

-- | 'mkGenericSpielOperation' specialized for the most common case.
mkGenericSNSOperationSimple :: (Binary a, Typeable a, Typeable k, KnownSymbol k)
  => Proxy# k
  -> (Fid -> IO a)
  -> M0.Pool
  -> PhaseM RC l ()
mkGenericSNSOperationSimple n f = mkGenericSNSOperation n
  (\pool eresult -> GenericSNSOperationResult pool (first show eresult))
  (\pool -> f (M0.fid pool))

mkGenericNodeOperationSimple :: (Binary a, Typeable a, Typeable k, KnownSymbol k)
  => Proxy# k
  -> (Fid -> IO a)
  -> M0.Node
  -> PhaseM RC l ()
mkGenericNodeOperationSimple n f = mkGenericNodeOperation n
  (\node eresult -> GenericNodeOperationResult node (first show eresult))
  (\node -> f (M0.fid node))

-- | Helper for implementation call to generic spiel operation.
mkGenericSNSReplyHandler :: forall a b c k l . (Show c, Binary c, Typeable c, Typeable k, KnownSymbol k)
  => Proxy# k                                        -- ^ Rule name
  -> (String -> M0.Pool -> PhaseM RC l (Either a b)) -- ^ Error result converter.
  -> (c      -> M0.Pool -> PhaseM RC l (Either a b)) -- ^ Success result onverter.
  -> (M0.Pool -> (Either a b) -> PhaseM RC l ())     -- ^ Handler
  -> RuleM RC l (Jump PhaseHandle)
mkGenericSNSReplyHandler n onError onSuccess action = do
  ph <- phaseHandle $ symbolVal' n ++ " reply"
  setPhase ph $ \(GenericSNSOperationResult pool er :: GenericSNSOperationResult k c) -> do
    Log.tagContext Log.SM [ ("pool.fid", show (M0.fid pool)) ] Nothing
    result <- case er of
      Left s -> do Log.rcLog' Log.ERROR s
                   onError s pool
      Right x -> do Log.rcLog' Log.DEBUG (show x)
                    onSuccess x pool
    action pool result
  return ph

-- Helper for implementation call to generic node spiel operation
mkGenericNodeReplyHandler :: forall a b c k l . (Show c, Binary c, Typeable c, Typeable k, KnownSymbol k)
  => Proxy# k                                        -- ^ Rule name
  -> (String -> M0.Node -> PhaseM RC l (Either a b)) -- ^ Error result converter.
  -> (c      -> M0.Node -> PhaseM RC l (Either a b)) -- ^ Success result onverter.
  -> (M0.Node -> (Either a b) -> PhaseM RC l ())     -- ^ Handler
  -> RuleM RC l (Jump PhaseHandle)
mkGenericNodeReplyHandler n onError onSuccess action = do
  ph <- phaseHandle $ symbolVal' n ++ " reply"
  setPhase ph $ \(GenericNodeOperationResult node er :: GenericNodeOperationResult k c) -> do
    Log.tagContext Log.SM [ ("node.fid", show (M0.fid node)) ] Nothing
    result <- case er of
      Left s -> do Log.rcLog' Log.ERROR s
                   onError s node
      Right x -> do Log.rcLog' Log.DEBUG (show x)
                    onSuccess x node
    action node result
  return ph

-- | 'mkGenericSpielReplyHandler' specialized for the most common case.
mkGenericSNSReplyHandlerSimple :: (Typeable b, Binary b, KnownSymbol k, Typeable k, Show b)
  => Proxy# k
  -> (M0.Pool -> String  -> PhaseM RC l ()) -- ^ Error handler
  -> (M0.Pool -> b -> PhaseM RC l ())       -- ^ Result handler
  -> RuleM RC l (Jump PhaseHandle)
mkGenericSNSReplyHandlerSimple n onError onResult =
  mkGenericSNSReplyHandler n (const . return . Left) (const . return . Right)
    (\pool-> either (onError pool) (onResult pool))

-- Tier 2

-- | Generate function for the very simple case when there is no logic
-- rather than send request and receive reply.
mkSimpleSNSOperation :: forall a l n . (KnownSymbol n, Typeable a, Typeable n, Binary a, Show a)
                     => Proxy n
                     -> (Fid -> IO a)
                     -> (M0.Pool -> String -> PhaseM RC l ())
                     -> (M0.Pool -> a -> PhaseM RC l ())
                     -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkSimpleSNSOperation _ action onFailure onResult = do
  phase <- handleReply onFailure onResult
  return ( phase
         , mkGenericSNSOperationSimple p action)
  where
    p :: Proxy# n
    p = proxy#
    handleReply :: (M0.Pool -> String -> PhaseM RC l ())
                -> (M0.Pool -> a      -> PhaseM RC l ())
                -> RuleM RC l (Jump PhaseHandle)
    handleReply = mkGenericSNSReplyHandlerSimple p

-- Tier 3

-- | Generate function that query status until operation will complete.
mkStatusCheckingSNSOperation :: forall l' l n .
    ( FldSNSOperationRetryState ∈ l'
    , l ~ FieldRec l'
    , KnownSymbol n
    , Typeable n)
  => Proxy n
  -> (    (M0.Pool -> String -> PhaseM RC l ())
       -> (M0.Pool -> [Spiel.SnsStatus] -> PhaseM RC l ())
       -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ()))
  -> (Fid -> IO ())
  -> [Spiel.SnsCmStatus]
  -> Int                        -- ^ Timeout between retries (in seconds).
  -> (l -> M0.Pool)             -- ^ Getter of the pool.
  -> (M0.Pool -> String -> PhaseM RC l ()) -- ^ Handler on failure.
  -> (M0.Pool -> [(Fid, Spiel.SnsCmStatus)] -> PhaseM RC l ()) -- ^ Handler on success.
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkStatusCheckingSNSOperation name mk action interesting dt getter onFailure onSuccess = do
  next_request <- phaseHandle $ symbolVal name ++ "::next request"
  operation_done <- phaseHandle $ symbolVal name ++ "::operation_done"
  (status_received, statusRequest) <- mk onFailure $ \pool xs -> do
     if all (`elem` interesting) (map Spiel._sss_state xs)
     then onSuccess pool (map ((,) <$> Spiel._sss_fid <*> Spiel._sss_state) xs)
     else do
       nqa <- gets Local (^. rlens fldSNSOperationRetryState . rfield . sorStatusAttempts)
       nqaMax <- getHalonVar _hv_sns_operation_status_attempts
       if nqa == nqaMax
       then do
         nra <- gets Local (^. rlens fldSNSOperationRetryState . rfield . sorRetryAttempts)
         nraMax <- getHalonVar _hv_sns_operation_retry_attempts
         if nra == nraMax
         then onFailure pool "Exceeded maximum number of retry attempts."
         else do
           modify Local $ rlens fldSNSOperationRetryState . rfield .~ (SNSOperationRetryState (nra +1) 0)
           operation pool
           continue operation_done
       else do
         modify Local $ rlens fldSNSOperationRetryState . rfield . sorStatusAttempts %~ (+ 1)
         continue (timeout dt next_request)
  handleReply operation_done onFailure $ \pool _ -> do
    statusRequest pool
    continue status_received
  directly next_request $ do
    pool <- gets Local getter
    statusRequest pool
    continue status_received
  return (operation_done, operation)
  where
    p :: Proxy# n
    p = proxy#
    operation = mkGenericSNSOperationSimple p action
    handleReply :: Jump PhaseHandle
                -> (M0.Pool -> String -> PhaseM RC l ())
                -> (M0.Pool -> ()     -> PhaseM RC l ())
                -> RuleM RC l ()
    handleReply ph onError' onSuccess' =
        setPhase ph $ \(GenericSNSOperationResult pool er :: GenericSNSOperationResult n ()) -> do
          Log.tagContext Log.SM [ ("pool.fid", show (M0.fid pool)) ] Nothing
          either (onError' pool) (onSuccess' pool) er

-------------------------------------------------------------------------------
-- SNS Operations
-------------------------------------------------------------------------------

-- | Start the repair operation on the given 'M0.Pool' asynchronously.
mkRepairStartOperation ::
  (M0.Pool -> Either String UUID -> PhaseM RC l ()) -- ^ Result handler.
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRepairStartOperation handler = do
  operation_started <- mkRepairOperationStarted handler
  return ( operation_started
         , mkGenericSNSOperationSimple p Spiel.poolRepairStart
         )
  where
    p :: Proxy# "Repair start"
    p = proxy#
    -- | Create a phase to handle pool repair operation start result.
    mkRepairOperationStarted ::
           (M0.Pool -> Either String UUID -> PhaseM RC l ())
        -> RuleM RC l (Jump PhaseHandle)
    mkRepairOperationStarted = mkGenericSNSReplyHandler p
      (const . return . Left)
      (\() pool -> do
         uuid <- DP.liftIO nextRandom
         setPoolRepairStatus pool $ M0.PoolRepairStatus M0.Repair uuid Nothing
         return (Right uuid))

-- | Start the rebalance operation on the given 'M0.Pool' asynchronously.
mkRebalanceStartOperation ::
  (M0.Pool -> Either String UUID -> PhaseM RC l ()) -- ^ Result handler.
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> [M0.Disk] -> PhaseM RC l ())
mkRebalanceStartOperation handler = do
  operation_started <- handleReply handler
  return ( operation_started
         , \pool disks -> do
             Log.tagContext Log.Phase [ ("pool", show pool)
                                      , ("disks", show disks)
                                      ] Nothing
             Log.rcLog' Log.DEBUG "Starting rebalance on pool"
             for_ disks $ \d -> do
               mt <- lookupDiskSDev d
               for_ mt $ unmarkSDevReplaced -- XXX: (qnikst) we should do that when finished rebalance, shouldm't we?
             mkGenericSNSOperationSimple p Spiel.poolRebalanceStart pool
         )
  where
    p :: Proxy# "Rebalance start"
    p = proxy#
    handleReply :: (M0.Pool -> Either String UUID -> PhaseM RC l ())
                -> RuleM RC l (Jump PhaseHandle)
    handleReply = mkGenericSNSReplyHandler p
      (const . return . Left)
      (\() pool -> do
         uuid <- DP.liftIO nextRandom
         setPoolRepairStatus pool $ M0.PoolRepairStatus M0.Rebalance uuid Nothing
         return (Right uuid))

-- | Start the direct rebalance operation for the given node asynchronously.
mkDirectRebalanceStartOperation ::
  (M0.Node -> Either String UUID -> PhaseM RC l ()) -- ^ Result handler.
  -> RuleM RC l (Jump PhaseHandle, M0.Node -> PhaseM RC l ())
mkDirectRebalanceStartOperation handler = do
  operation_started <- mkDirectRebalanceOperationStarted handler
  return ( operation_started
         , mkGenericNodeOperationSimple p Spiel.nodeDirectRebalanceStart
         )
  where
    p :: Proxy# "Direct rebalance start"
    p = proxy#
    -- | Create a phase to handle direct rebalance operation start result.
    mkDirectRebalanceOperationStarted ::
           (M0.Node -> Either String UUID -> PhaseM RC l ())
        -> RuleM RC l (Jump PhaseHandle)
    mkDirectRebalanceOperationStarted = mkGenericNodeReplyHandler p
      (const . return . Left)
      (\() node -> do
         uuid <- DP.liftIO nextRandom
         setNodeDiRebStatus node $ M0.NodeDiRebStatus uuid Nothing
         return (Right uuid))

-- | Create a phase to handle pool repair operation start result.
mkRepairStatusRequestOperation ::
     (M0.Pool -> String -> PhaseM RC l ())
  -> (M0.Pool -> [Spiel.SnsStatus] -> PhaseM RC l ())
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRepairStatusRequestOperation =
  mkSimpleSNSOperation (Proxy :: Proxy "Repair status request") Spiel.poolRepairStatus

-- | Continue the rebalance operation.
mkRepairContinueOperation ::
     (M0.Pool -> String -> PhaseM RC l ())
  -> (M0.Pool -> () -> PhaseM RC l ())
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRepairContinueOperation =
  mkSimpleSNSOperation (Proxy :: Proxy "Repair continue") Spiel.poolRepairContinue


-- | Continue the rebalance operation.
mkRebalanceContinueOperation ::
     (M0.Pool -> String -> PhaseM RC l ())
  -> (M0.Pool -> ()     -> PhaseM RC l ())
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRebalanceContinueOperation = do
  mkSimpleSNSOperation (Proxy :: Proxy "Rebalance continue") Spiel.poolRebalanceContinue

-- | Create a phase to handle pool repair operation start result.
mkRebalanceStatusRequestOperation ::
     (M0.Pool -> String -> PhaseM RC l ())
  -> (M0.Pool -> [Spiel.SnsStatus] -> PhaseM RC l ())
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRebalanceStatusRequestOperation = do
  mkSimpleSNSOperation (Proxy :: Proxy "Rebalance status request") Spiel.poolRebalanceStatus

-- | Create code that allow to quisce repair operation.
mkRepairQuiesceOperation ::
    ( FldSNSOperationRetryState ∈ l'
    , l ~ FieldRec l')
  => Int                        -- ^ Timeout between retries (in seconds).
  -> (l -> M0.Pool)             -- ^ Getter of the pool.
  -> (M0.Pool -> String -> PhaseM RC l ()) -- ^ Handler on failure.
  -> (M0.Pool -> [(Fid, Spiel.SnsCmStatus)] -> PhaseM RC l ()) -- ^ Handler on success.
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRepairQuiesceOperation =
  mkStatusCheckingSNSOperation
    (Proxy :: Proxy "Repair quiesce")
    mkRepairStatusRequestOperation
    Spiel.poolRepairQuiesce
    [ Spiel.M0_SNS_CM_STATUS_FAILED
    , Spiel.M0_SNS_CM_STATUS_PAUSED
    , Spiel.M0_SNS_CM_STATUS_IDLE]

-- | Create an action and helper phases that will allow to abort SNS operation
-- and wait until it will be really aborted.
mkRepairAbortOperation ::
    ( FldSNSOperationRetryState ∈ l'
    , l ~ FieldRec l')
  => Int
  -> (l -> M0.Pool)
  -> (M0.Pool -> String -> PhaseM RC l ()) -- ^ Handler on failure.
  -> (M0.Pool -> [(Fid, Spiel.SnsCmStatus)] -> PhaseM RC l ()) -- ^ Handler on success.
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRepairAbortOperation =
  mkStatusCheckingSNSOperation
    (Proxy :: Proxy "Repair abort")
    mkRepairStatusRequestOperation
    Spiel.poolRepairAbort
    [ Spiel.M0_SNS_CM_STATUS_FAILED
    , Spiel.M0_SNS_CM_STATUS_PAUSED
    , Spiel.M0_SNS_CM_STATUS_IDLE]

-- | Create code that allow to quisce repair operation.
mkRebalanceQuiesceOperation ::
    ( FldSNSOperationRetryState ∈ l'
    , l ~ FieldRec l')
  => Int                        -- ^ Timeout between retries (in seconds).
  -> (l -> M0.Pool)             -- ^ Getter of the pool.
  -> (M0.Pool -> String -> PhaseM RC l ()) -- ^ Handler on failure.
  -> (M0.Pool -> [(Fid, Spiel.SnsCmStatus)] -> PhaseM RC l ()) -- ^ Handler on success.
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRebalanceQuiesceOperation = do
  mkStatusCheckingSNSOperation
    (Proxy :: Proxy "Rebalance quiesce")
    mkRebalanceStatusRequestOperation
    Spiel.poolRebalanceQuiesce
    [ Spiel.M0_SNS_CM_STATUS_FAILED
    , Spiel.M0_SNS_CM_STATUS_PAUSED
    , Spiel.M0_SNS_CM_STATUS_IDLE]

-- | Generate code to call abort operation.
mkRebalanceAbortOperation ::
    ( FldSNSOperationRetryState ∈ l'
    , l ~ FieldRec l')
  => Int
  -> (l -> M0.Pool)
  -> (M0.Pool -> String -> PhaseM RC l ()) -- ^ Handler on failure.
  -> (M0.Pool -> [(Fid, Spiel.SnsCmStatus)] -> PhaseM RC l ()) -- ^ Handler on success.
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRebalanceAbortOperation = do
  mkStatusCheckingSNSOperation
    (Proxy :: Proxy "Rebalance abort")
    mkRebalanceStatusRequestOperation
    Spiel.poolRebalanceAbort
    [ Spiel.M0_SNS_CM_STATUS_FAILED
    , Spiel.M0_SNS_CM_STATUS_PAUSED
    , Spiel.M0_SNS_CM_STATUS_IDLE]

-- | Synchronize graph to confd.
-- Currently all Exceptions during this operation are caught, this is required in because
-- there is no good exception handling in RC and uncaught exception will lead to RC failure.
-- Also it's behaviour of RC in case of mero exceptions is not specified.
mkSyncAction :: Lens' l ConfSyncState
             -> Jump PhaseHandle
             -> RuleM RC l (SyncToConfd -> PhaseM RC l ())
mkSyncAction lstate next = do
   (synchronized, synchronizeToConfd) <- mkSyncToConfd lstate next

   return $ \sync -> do
     flip catch (\e -> Log.rcLog' Log.ERROR $ "Exception during sync: "++show (e::SomeException))
         $ do
      case sync of
        SyncToConfdServersInRG f -> flip catch (handler (const $ return ())) $ do
          Log.rcLog' Log.DEBUG "Syncing RG to confd servers in RG."
          _ <- synchronizeToConfd f
          continue synchronized
        SyncDumpToBS pid -> flip catch (handler $ failToBS pid) $ do
          bs <- syncToBS
          liftProcess . DP.usend pid . M0.SyncDumpToBSReply $ Right bs
          continue next
  where
    failToBS :: DP.ProcessId -> SomeException -> DP.Process ()
    failToBS pid = DP.usend pid . M0.SyncDumpToBSReply . Left . show

    handler :: (SomeException -> DP.Process ())
            -> SomeException
            -> PhaseM RC l ()
    handler act e = do
      Log.rcLog' Log.ERROR $ "Exception during sync: " ++ show e
      liftProcess $ act e

-- | Dump the conf into a 'BS.ByteString'.
--
--   Note that this uses a local worker, because it may be invoked before
--   `ha_interface` is loaded and hence no Spiel context is available.
--
--   We need to quiesce or abort spiel SNS operation during sync request,
--   this way spiel state machines will be able to return all locks to RM,
--   and take them and resubscribe later.
syncToBS :: PhaseM RC l BS.ByteString
syncToBS = loadConfData >>= \case
  Just tx -> getHalonVar _hv_mero_workers_allowed >>= \case
    True -> do
      M0.ConfUpdateVersion verno _ <- getConfUpdateVersion
      wrk <- DP.liftIO newM0Worker
      bs <- txOpenLocalContext (mkLiftRC wrk)
        >>= txPopulate (mkLiftRC wrk) tx
        >>= m0synchronously (mkLiftRC wrk) . flip Spiel.txToBS verno
      DP.liftIO $ terminateM0Worker wrk
      return bs
    False -> do
      Log.rcLog' Log.WARN "syncToBS: returning empty string due to HalonVars"
      return BS.empty
  Nothing -> error "Cannot load configuration data from graph."

data Synchronized = Synchronized (Maybe Int) (Either String ())
  deriving (Generic, Show)

instance Binary Synchronized

-- | Create synchronization action.
-- Returns a @(phase, action)@ pair where action triggers the asynchronous
-- synchronization and user should jump to @phase@ to wait the end of the
-- async action.
mkSyncToConfd :: forall l . Lens' l ConfSyncState -- ^ Accessor to the internal state
              -> Jump PhaseHandle       -- ^ Phase to jump when sync is complete.
              -> RuleM RC l (Jump PhaseHandle
                            , Bool -> PhaseM RC l (Either SomeException ()))
mkSyncToConfd lstate next = do
  quiesce         <- phaseHandle "quiese-sns"
  on_quiesced     <- phaseHandle "on-quiesced"
  on_aborted      <- phaseHandle "on-abort"
  on_synchronized <- phaseHandle "on-synchronized"

  let synchronize = do
        eresult <- do
          force <- (\x -> x ^. lstate . cssForce) <$> get Local
          withSpielRC $ \lift -> do
            setProfileRC lift -- XXX-MULTIPOOLS
            loadConfData >>= traverse_ (\x -> do
              t0 <- txOpenContext lift
              t1 <- txPopulate lift x t0
              txSyncToConfd force (lstate.cssHash) lift t1)
        case eresult of
          Left ex -> Log.rcLog' Log.ERROR $ "Exception during sync: " ++ show ex
          _ -> return ()

      clean_and_run :: Lens' ConfSyncState [ListenerId] -> [ListenerId] -> PhaseM RC l ()
      clean_and_run ls listeners = do
        state <- get Local
        let state' = state & lstate . ls %~ (\x -> x \\ listeners)
        put Local state'
        if (null $ state' ^. lstate . cssQuiescing)
           && (null $ state' ^. lstate . cssAborting)
        then synchronize
        else switch [on_quiesced, on_aborted]

  directly quiesce $ do
     rg <- getGraph
     let pools = [ pool
                 | prs :: M0.PoolRepairStatus <- G.getResourcesOfType rg
                 , Just (pool::M0.Pool) <- [G.connectedFrom Has prs rg]
                 ]
     case pools of
       [] -> synchronize
       _  -> do lids <- for pools $ startJob . QuiesceSNSOperation
                modify Local $ \x -> x & lstate . cssQuiescing .~  lids
                switch [on_quiesced, on_aborted]

  setPhase on_quiesced $ \case
    JobFinished listeners QuiesceSNSOperationSkip{} ->
      clean_and_run cssQuiescing listeners
    JobFinished listeners QuiesceSNSOperationOk{} ->
      clean_and_run cssQuiescing listeners
    JobFinished listeners (QuiesceSNSOperationFailure pool _) -> do
      mprs <- getPoolRepairStatus pool
      for_ mprs $ \prs -> do
        lid <- startJob (AbortSNSOperation pool $ M0.prsRepairUUID prs)
        l <- get Local
        put Local $ l & lstate . cssAborting %~ (lid:)
      clean_and_run cssQuiescing listeners

  setPhase on_aborted $ \(JobFinished listeners (_::QuiesceSNSOperationResult)) ->
    clean_and_run cssAborting listeners

  setPhaseIf on_synchronized (\(Synchronized h r) _ l ->
     if l ^. lstate . cssHash == h
     then return (Just (h, r))
     else return Nothing
     ) $ \(h', er) -> do
     Log.rcLog' Log.DEBUG "Transaction closed."
     case er of
       Right () -> do
         -- spiel increases conf version here so we should too; alternative
         -- would be querying spiel after transaction for the new version
         modifyConfUpdateVersion (\(M0.ConfUpdateVersion i _) -> M0.ConfUpdateVersion (succ i) h')
         Log.rcLog' Log.DEBUG $ "Transaction committed, new hash: " ++ show h'
       Left err -> do
         Log.rcLog' Log.DEBUG $ "Transaction commit failed with cache failure:" ++ err
     continue next

  return ( on_synchronized
         , \force -> do
               modify Local $ set (lstate.cssForce) force
               continue quiesce)

-- | Open a transaction. Ultimately this should not need a
--   spiel context.
txOpenContext :: LiftRC -> PhaseM RC l SpielTransaction
txOpenContext lift = m0synchronously lift Spiel.openTransaction

txOpenLocalContext :: LiftRC -> PhaseM RC l SpielTransaction
txOpenLocalContext lift = m0synchronously lift Spiel.openLocalTransaction

txSyncToConfd :: Bool -> Lens' l (Maybe Int) -> LiftRC -> SpielTransaction -> PhaseM RC l ()
txSyncToConfd force luuid lift tx = do
  Log.rcLog' Log.DEBUG "Committing transaction to confd"
  M0.ConfUpdateVersion v h <- getConfUpdateVersion
  h' <- return . hash <$> m0synchronously lift (Spiel.txToBS tx v)
  if h /= h' || force
  then do
     put Local . set luuid h' =<< get Local
     self <- liftProcess DP.getSelfPid
     m0asynchronously lift (DP.usend self . Synchronized h' . first show)
                           (void $ (first (SomeException . userError) <$> Spiel.commitTransactionForced tx False v)
                                    `finally` Spiel.closeTransaction tx)
  else Log.rcLog' Log.DEBUG $ "Conf unchanged with hash " ++ show h' ++ ", not committing"
  Log.rcLog' Log.DEBUG "Transaction closed."

-- XXX-MULTIPOOLS: There should be multiple profiles.
data TxConfData = TxConfData M0.M0Globals M0.Profile

loadConfData :: PhaseM RC l (Maybe TxConfData)
loadConfData = liftA2 TxConfData
            <$> getM0Globals
            <*> theProfile    -- XXX-MULTIPOOLS: no "global profile", please

-- | Gets the current 'ConfUpdateVersion' used when dumping
-- 'SpielTransaction' out. If this is not set, it's set to the default of @1@.
getConfUpdateVersion :: PhaseM RC l M0.ConfUpdateVersion
getConfUpdateVersion = do
  rg <- getGraph
  case G.connectedTo Cluster Has rg of
    Just ver -> return ver
    Nothing -> do
      let csu = M0.ConfUpdateVersion 1 Nothing
      modifyGraph $ G.connect Cluster Has csu
      return csu

modifyConfUpdateVersion :: (M0.ConfUpdateVersion -> M0.ConfUpdateVersion)
                        -> PhaseM RC l ()
modifyConfUpdateVersion f = do
  csu <- getConfUpdateVersion
  let fcsu = f csu
  Log.rcLog' Log.TRACE $ "Setting ConfUpdateVersion to " ++ show fcsu
  modifyGraphM $ return . G.connect Cluster Has fcsu

-- XXX REFACTORME
txPopulate :: LiftRC -> TxConfData -> SpielTransaction -> PhaseM RC l SpielTransaction
txPopulate lift (TxConfData CI.M0Globals{..} (M0.Profile pfid)) t = do
  rg <- getGraph
  let root@M0.Root{..} = M0.getM0Root rg
  m0synchronously lift $ do
    Spiel.addRoot t rt_fid rt_mdpool rt_imeta_pver m0_md_redundancy []
    Spiel.addProfile t pfid -- XXX-MULTIPOOLS: multiple profiles
  Log.rcLog' Log.DEBUG "Added root and profile"
  -- Sites, racks, encls, controllers, disks
  let sites = G.connectedTo root M0.IsParentOf rg :: [M0.Site]
  for_ sites $ \site -> do
    m0synchronously lift $ Spiel.addSite t (M0.fid site)
    let racks = G.connectedTo site M0.IsParentOf rg :: [M0.Rack]
    for_ racks $ \rack -> do
      m0synchronously lift $ Spiel.addRack t (M0.fid rack) (M0.fid site)
      let encls = G.connectedTo rack M0.IsParentOf rg :: [M0.Enclosure]
      for_ encls $ \encl -> do
        m0synchronously lift $ Spiel.addEnclosure t (M0.fid encl) (M0.fid rack)
        let ctrls = G.connectedTo encl M0.IsParentOf rg :: [M0.Controller]
        for_ ctrls $ \ctrl -> do
          -- Get node fid
          let Just (node :: M0.Node) = G.connectedFrom M0.IsOnHardware ctrl rg
          m0synchronously lift $ Spiel.addController t (M0.fid ctrl) (M0.fid encl) (M0.fid node)
          let drives = G.connectedTo ctrl M0.IsParentOf rg :: [M0.Disk]
          for_ drives $ \drive -> do
            m0synchronously lift $ Spiel.addDrive t (M0.fid drive) (M0.fid ctrl)
  -- Nodes, processes, services, sdevs
  for_ (M0.getM0Nodes rg) $ \node -> do
    let attrs =
          [ a
          | Just (ctrl :: M0.Controller) <- [G.connectedTo node M0.IsOnHardware rg]
          , Just (host :: Cas.Host) <- [G.connectedTo ctrl M0.At rg]
          , a :: Cas.HostAttr <- G.connectedTo host Has rg
          ]
        defaultMem = 1024
        defCPUCount = 1
        memsize = maybe defaultMem fromIntegral
                $ listToMaybe . catMaybes $ fmap getMem attrs
        cpucount = maybe defCPUCount fromIntegral
                 $ listToMaybe . catMaybes $ fmap getCpuCount attrs
        getMem (Cas.HA_MEMSIZE_MB x) = Just x
        getMem _ = Nothing
        getCpuCount (Cas.HA_CPU_COUNT x) = Just x
        getCpuCount _ = Nothing
    m0synchronously lift $ Spiel.addNode t (M0.fid node) memsize cpucount 0 0
    let procs = G.connectedTo node M0.IsParentOf rg :: [M0.Process]
        ep2s = T.unpack . encodeEndpoint
    for_ procs $ \proc@M0.Process{..} -> do
      m0synchronously lift $ Spiel.addProcess t r_fid (M0.fid node) r_cores
                            r_mem_as r_mem_rss r_mem_stack r_mem_memlock
                            (T.unpack . encodeEndpoint $ r_endpoint)
      let servs = G.connectedTo proc M0.IsParentOf rg :: [M0.Service]
      for_ servs $ \serv@M0.Service{..} -> do
        m0synchronously lift $ Spiel.addService t s_fid r_fid
          (Spiel.ServiceInfo s_type $ fmap ep2s s_endpoints)
        let sdevs = G.connectedTo serv M0.IsParentOf rg :: [M0.SDev]
        for_ sdevs $ \sdev@M0.SDev{..} -> do
          let mdisk = G.connectedTo sdev M0.IsOnHardware rg :: Maybe M0.Disk
          m0synchronously lift $ Spiel.addDevice t d_fid s_fid (M0.fid <$> mdisk) d_idx
                   Spiel.M0_CFG_DEVICE_INTERFACE_SATA
                   Spiel.M0_CFG_DEVICE_MEDIA_DISK d_bsize d_size 0 0 d_path
  Log.rcLog' Log.DEBUG "Finished adding concrete entities."
  -- Pool versions
  let pools = G.connectedTo root M0.IsParentOf rg :: [M0.Pool]
      pvNegWidth pver = case pver of
                         M0.PVer _ (Right pva) -> negate . _pa_P $ M0.va_attrs pva
                         M0.PVer _ _ -> 0
  for_ pools $ \pool -> do
    m0synchronously lift $ do
      Spiel.addProfilePool t pfid (M0.fid pool)
      Spiel.addPool t (M0.fid pool) 0
    let pvers = sortOn pvNegWidth $ G.connectedTo pool M0.IsParentOf rg :: [M0.PVer]
    for_ pvers $ \pver -> do
      case M0.v_data pver of
        Right pva -> do
          m0synchronously lift $ Spiel.addPVerActual t (M0.fid pver) (M0.fid pool) (M0.va_attrs pva) (M0.va_tolerance pva)
          let sitevs = G.connectedTo pver M0.IsParentOf rg :: [M0.SiteV]
          for_ sitevs $ \sitev -> do
            let Just (site :: M0.Site) = G.connectedFrom M0.IsRealOf sitev rg
            m0synchronously lift $ Spiel.addSiteV t (M0.fid sitev) (M0.fid pver) (M0.fid site)
            let rackvs = G.connectedTo sitev M0.IsParentOf rg :: [M0.RackV]
            for_ rackvs $ \rackv -> do
              let Just (rack :: M0.Rack) = G.connectedFrom M0.IsRealOf rackv rg
              m0synchronously lift $ Spiel.addRackV t (M0.fid rackv) (M0.fid sitev) (M0.fid rack)
              let enclvs = G.connectedTo rackv M0.IsParentOf rg :: [M0.EnclosureV]
              for_ enclvs $ \enclv -> do
                let Just (encl :: M0.Enclosure) = G.connectedFrom M0.IsRealOf enclv rg
                m0synchronously lift $ Spiel.addEnclosureV t (M0.fid enclv) (M0.fid rackv) (M0.fid encl)
                let ctrlvs = G.connectedTo enclv M0.IsParentOf rg :: [M0.ControllerV]
                for_ ctrlvs $ \ctrlv -> do
                  let Just (ctrl :: M0.Controller) = G.connectedFrom M0.IsRealOf ctrlv rg
                  m0synchronously lift $ Spiel.addControllerV t (M0.fid ctrlv) (M0.fid enclv) (M0.fid ctrl)
                  let drivevs = G.connectedTo ctrlv M0.IsParentOf rg :: [M0.DiskV]
                  for_ drivevs $ \drivev -> do
                    let Just (drive :: M0.Disk) = G.connectedFrom M0.IsRealOf drivev rg
                    m0synchronously lift $ Spiel.addDriveV t (M0.fid drivev) (M0.fid ctrlv) (M0.fid drive)
          m0synchronously lift $ Spiel.poolVersionDone t (M0.fid pver)
        Left pvf -> do
          base <- lookupConfObjByFid (M0.vf_base pvf)
          case M0.v_data <$> base of
            Nothing -> Log.rcLog' Log.WARN $ "Ignoring pool version " ++ show pvf
                   ++ " because base pver cannot be found"
            Just (Right pva) -> do
              let PDClustAttr n k p _ _ = M0.va_attrs pva
              if M0.vf_allowance pvf !! confPVerLvlDrives <= p - (n + 2*k)
              then m0synchronously lift $ Spiel.addPVerFormulaic t (M0.fid pver) (M0.fid pool)
                            (M0.vf_id pvf) (M0.vf_base pvf) (M0.vf_allowance pvf)
              else Log.rcLog' Log.WARN $ "Ignoring pool version " ++ show pvf
                     ++ " because it doesn't meet"
                     ++ " allowance[M0_CONF_PVER_LVL_DRIVES] <=  P - (N+2K) criteria"
            Just _ ->
              Log.rcLog' Log.WARN $ "Ignoring pool version " ++ show pvf
                 ++ " because base pver is not an actual pversion"
  return t

-- | Load the current conf data, create a transaction that we would
-- send to spiel and ask mero if the transaction cache is valid.
validateTransactionCache :: PhaseM RC l (Either SomeException (Maybe String))
validateTransactionCache = loadConfData >>= \case
  Nothing -> do
    Log.rcLog' Log.DEBUG "validateTransactionCache: loadConfData failed"
    return $! Right Nothing
  Just x -> do
    Log.rcLog' Log.DEBUG "validateTransactionCache: validating context"
    getHalonVar _hv_mero_workers_allowed >>= \case
      True -> do
        -- We can use withSpielRC because SpielRC require ha_interface
        -- to be started in order to read spiel context out of it.
        -- However we may not be able to start ha_interface because it
        -- require configuraion to be loaded. And this call can be run
        -- on unbootstrapped cluster.
        wrk <- DP.liftIO newM0Worker
        r <- try $ txOpenLocalContext (mkLiftRC wrk)
               >>= txPopulate (mkLiftRC wrk) x
               >>= m0synchronously (mkLiftRC wrk) . Spiel.txValidateTransactionCache
        DP.liftIO $ terminateM0Worker wrk
        return r
      False -> do
        Log.rcLog' Log.DEBUG "validateTransactionCache: disabled by HalonVars"
        return $! Right Nothing

-- | RC wrapper for 'getSpielAddress'.
getSpielAddressRC :: PhaseM RC l (Maybe M0.SpielAddress)
getSpielAddressRC = getSpielAddress True <$> getGraph

-- | Store 'ResourceGraph' in 'globalResourceGraphCache' in order to avoid dead
-- lock conditions. RC performing all queries sequentially, thus it can't reply
-- to the newly arrived queries to 'ResourceGraph'. This opens a possiblity of
-- a deadlock if some internal operation that RC is performing creates a query
-- to RC, and such deadlock happens in spiel operations.
-- For this reason we store a graph projection in a variable and methods that
-- could be blocked should first query this cached value first.
withResourceGraphCache :: PhaseM RC l a -> PhaseM RC l a
withResourceGraphCache action = do
  rg <- getGraph
  liftProcess $ DP.liftIO $ writeIORef globalResourceGraphCache (Just rg)
  x <- action
  liftProcess $ DP.liftIO $ writeIORef globalResourceGraphCache Nothing
  return x

----------------------------------------------------------
-- Pool repair information functions                    --
----------------------------------------------------------

-- | Return the 'M0.PoolRepairStatus' structure. If one is not in
-- the graph, it means no repairs are going on
getPoolRepairStatus :: M0.Pool
                    -> PhaseM RC l (Maybe M0.PoolRepairStatus)
getPoolRepairStatus pool = G.connectedTo pool Has <$> getGraph

-- | Return the 'M0.PoolRepairStatus' structure. If one is not in
-- the graph, it means no repairs are going on
--getNodeDiRebStatus :: M0.Node
  --                  -> PhaseM RC l (Maybe M0.NodeDiRebStatus)
--getNodeDiRebStatus node = G.connectedTo node Has <$> getGraph

-- | Set the given 'M0.PoolRepairStatus' in the graph. Any
-- previously connected @PRI@s are disconnected.
setPoolRepairStatus :: M0.Pool -> M0.PoolRepairStatus -> PhaseM RC l ()
setPoolRepairStatus pool prs =
  modifyGraphM $ return . G.connect pool Has prs

-- | Set the given 'M0.NodeDiRebStatus' in the graph. Any
-- previously connected @PRI@s are disconnected.
setNodeDiRebStatus :: M0.Node -> M0.NodeDiRebStatus -> PhaseM RC l ()
setNodeDiRebStatus node nrs =
  modifyGraphM $ return . G.connect node Has nrs

unsetNodeDiRebStatus :: M0.Node -> PhaseM RC l ()
unsetNodeDiRebStatus node = do
  Log.rcLog' Log.DEBUG $ "Unsetting NRS from " ++ show node
  modifyGraphM $ return . G.disconnectAllFrom node Has (Proxy :: Proxy M0.NodeDiRebStatus)

-- | Remove all 'M0.PoolRepairStatus' connection to the given 'M0.Pool'.
unsetPoolRepairStatus :: M0.Pool -> PhaseM RC l ()
unsetPoolRepairStatus pool = do
  Log.rcLog' Log.DEBUG $ "Unsetting PRS from " ++ show pool
  modifyGraphM $ return . G.disconnectAllFrom pool Has (Proxy :: Proxy M0.PoolRepairStatus)

-- | Remove 'M0.PoolRepairStatus' connection to the given 'M0.Pool' as
-- long as it has the matching 'M0.prsRepairUUID'. This is useful if
-- we want to clean up but we're not sure if the 'M0.PoolRepairStatus'
-- belongs to the clean up handler.
unsetPoolRepairStatusWithUUID :: M0.Pool -> UUID -> PhaseM RC l ()
unsetPoolRepairStatusWithUUID pool uuid = getPoolRepairStatus pool >>= \case
  Just prs | M0.prsRepairUUID prs == uuid -> unsetPoolRepairStatus pool
  _ -> return ()

-- | Return the 'M0.PoolRepairInformation' structure. If one is not in
-- the graph, it means no repairs are going on.
getPoolRepairInformation :: M0.Pool
                         -> PhaseM RC l (Maybe M0.PoolRepairInformation)
getPoolRepairInformation pool =
    join . fmap M0.prsPri . G.connectedTo pool Has <$>
    getGraph

-- | Return the 'M0.NodeDiRebInformation' structure. If one is not in
-- the graph, it means no node rebalance is in progress.
getNodeDiRebInformation :: M0.Node
                         -> PhaseM RC l (Maybe M0.NodeDiRebInformation)
getNodeDiRebInformation node =
    join . fmap M0.nrsNri . G.connectedTo node Has <$>
    getGraph

-- | Set the given 'M0.PoolRepairInformation' in the graph. Any
-- previously connected @PRI@s are disconnected.
--
-- Does nothing if we haven't at least set 'M0.PoolRepairType'
-- already.
setPoolRepairInformation :: M0.Pool
                         -> M0.PoolRepairInformation
                         -> PhaseM RC l ()
setPoolRepairInformation pool pri = getPoolRepairStatus pool >>= \case
  Nothing -> return ()
  Just (M0.PoolRepairStatus prt uuid _) -> do
    let prs = M0.PoolRepairStatus prt uuid $ Just pri
    Log.rcLog' Log.DEBUG $ "Setting PRS for " ++ show pool ++ " to " ++ show prs
    modifyGraphM $ return . G.connect pool Has prs

-- | Modify the  'PoolRepairInformation' in the graph with the given function.
-- Any previously connected @PRI@s are disconnected.
modifyPoolRepairInformation :: M0.Pool
                            -> (M0.PoolRepairInformation -> M0.PoolRepairInformation)
                            -> PhaseM RC l ()
modifyPoolRepairInformation pool f = modifyGraphM $ \rg ->
  case G.connectedTo pool Has $ rg of
    Just (M0.PoolRepairStatus prt uuid (Just pri)) ->
      return $ G.connect pool Has (M0.PoolRepairStatus prt uuid (Just $ f pri)) rg
    _ -> return rg

-- | Update time of completion for 'M0.PoolRepairInformation'. If
-- 'M0.PoolRepairStatus' does not yet exist or
-- 'M0.PoolRepairInformation' already exists, nothing happens.
updateSnsStartTime :: M0.Pool -> PhaseM RC l ()
updateSnsStartTime pool = getPoolRepairInformation pool >>= \case
  Nothing -> do
    tnow <- DP.liftIO M0.getTime
    -- We don't have PRI but we may also not have PRS:
    -- setPoolRepairInformation does nothing if we don't have PRS, as
    -- intended. If we *do* have PRS but don't have PRI then it means
    -- it's the first time PRI is being set: initialise time fields.
    setPoolRepairInformation pool $ M0.PoolRepairInformation
      { priTimeOfSnsStart = tnow
      , priTimeLastHourlyRan = tnow
      , priStateUpdates = [] }
  Just{} -> return ()

-- | Updates the last time hourly SNS status query has ran.
updatePoolRepairQueryTime :: M0.Pool -> PhaseM RC l ()
updatePoolRepairQueryTime pool = getPoolRepairStatus pool >>= \case
  Just (M0.PoolRepairStatus _ _ (Just pr)) -> do
    t <- DP.liftIO M0.getTime
    setPoolRepairInformation pool $ pr { M0.priTimeLastHourlyRan = t }
  _ -> return ()

-- | Returns number of seconds until we have to run the hourly PRI
-- query.
getTimeUntilHourlyQuery :: M0.Pool -> PhaseM RC l Int
getTimeUntilHourlyQuery pool = getPoolRepairInformation pool >>= \case
  Nothing -> return 0
  Just pri -> do
    tn <- DP.liftIO M0.getTime
    let elapsed = tn - M0.priTimeLastHourlyRan pri
        untilHourPasses = M0.mkTimeSpec 3600 - elapsed
    return $ M0.timeSpecToSeconds untilHourPasses

-- | Set profile in current thread.
--
-- XXX-MULTIPOOLS: How do we know which profile to use?
setProfileRC :: LiftRC -> PhaseM RC l ()
setProfileRC lift = do
  mprof <- theProfile
  Log.rcLog' Log.DEBUG $ "set command profile to " ++ show mprof
  m0synchronously lift . Spiel.setCmdProfile $ fmap (show . M0.fid) mprof
