-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Rules that are needed in order to support mero service on RC side.
module HA.RecoveryCoordinator.RC.Rules
  ( rules
  , initialRule
  ) where

import           HA.Aeson (ByteString64(..))
import           HA.RecoveryCoordinator.Mero (IgnitionArguments(..))
import           HA.RecoveryCoordinator.RC.Actions
import           HA.RecoveryCoordinator.RC.Actions.Log
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.RecoveryCoordinator.RC.Events
import           HA.RecoveryCoordinator.RC.Internal
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import           HA.Resources.HalonVars
import qualified HA.Resources.RC as R
import Network.CEP


import Control.Distributed.Process
  ( ProcessMonitorNotification(..)
  , NodeMonitorNotification(..)
  , DidSpawn(..)
  , getSelfPid
  , monitor
  , usend
  , say
  , sendChan
  )
import Control.Distributed.Process.Serializable
  ( decodeFingerprint
  )

import Control.Category
import Control.Monad.Trans.State.Strict (execStateT)
import qualified Control.Monad.Trans.State.Strict as State
import Control.Monad.Trans (lift)
import Data.Foldable (for_)

import Prelude hiding ((.), id)

-- | RC rules.
rules :: Definitions RC ()
rules = sequence_
  [ ruleNewSubscription
  , ruleRemoveSubscription
  , ruleProcessMonitorNotification
  , ruleNodeMonitorNotification
  , ruleDidSpawn
  , ruleSetHalonVars
  , ruleGetHalonVars
  ]

-- | Describe how to update recovery coordinator, in case
-- if new version is used now.
updateRC :: R.RC -> R.RC -> PhaseM RC l ()
updateRC _old _new = return ()


-- | Store information about currently running RC in the Resource Graph
-- ('G.Graph'). We store current RC, and update old one if needed.
initialRule :: IgnitionArguments -> PhaseM RC l ()
initialRule argv = do
  let l = liftProcess . say
  l "make RC"
  -- Store current recovery coordinator in the graph and update
  -- graph if needed.
  rc <- makeCurrentRC updateRC
  -- subscribe all processes with persistent subscription.
  rg <- getGraph
  l "subscribers"
  for_ (G.connectedFrom R.SubscribedTo rc rg) $
      \(R.Subscriber p (BS64 bs)) -> do
    let fp = decodeFingerprint bs
    liftProcess $ do
      self <- getSelfPid
      _ <- monitor p
      rawSubscribeThem self fp p
  l "register angel"
  -- Run node monitoring angel.
  registerNodeMonitoringAngel
  -- Add all known nodes to cluster.
  Log.rcLog' Log.DEBUG "Adding known nodes" -- XXX: do not add ones that are not up
  l "add nodes"
  for_ (G.connectedTo R.Cluster R.Has rg) $
    addNodeToCluster (eqNodes argv)

-- | When new process is subscribed to some interesting events persistently,
-- we store that in RG and add announce that to CEP engine manually.
ruleNewSubscription :: Definitions RC ()
ruleNewSubscription = defineSimpleTask "halon::rc::new-subscription" $
  \(SubscribeToRequest pid bs) -> do
    let fp = decodeFingerprint bs
    rcLog' DEBUG [  ("process.pid", show pid)
                  , ("fingerprint", show fp)
                  ]
    liftProcess $ do
      self <- getSelfPid
      _ <- monitor pid
      rawSubscribeThem self fp pid
    rc <- getCurrentRC
    let s = R.Subscriber pid (BS64 bs)
    modifyGraph $ G.connect (R.SubProcessId pid) R.IsSubscriber s
              >>> G.connect s R.SubscribedTo rc

    registerSyncGraphCallback $ \_ _ -> do
      usend pid (SubscribeToReply bs)

-- | When new process is unsubscribed to some interesting events persistently,
-- we store that in RG and add announce that to CEP engine manually.
--
-- XXX: unmonitor process
ruleRemoveSubscription :: Definitions RC ()
ruleRemoveSubscription = defineSimpleTask "halon::rc::remove-subscription" $
  \(UnsubscribeFromRequest pid bs) -> do
    let fp = decodeFingerprint bs
    rcLog' DEBUG [ ("process.pid", show pid)
                 , ("fingerprint", show fp)
                 ]
    liftProcess $ do
      self <- getSelfPid
      rawUnsubscribeThem self fp pid
    rc <- getCurrentRC
    modifyGraph $ \rg -> do
      let s = R.Subscriber pid (BS64 bs)
          rg' = G.disconnect (R.SubProcessId pid) R.IsSubscriber s
           >>> G.disconnect s R.SubscribedTo rc
             $ rg
      rg'

-- | When monitored process dies we call all handlers who are intersted in that
-- event.
--
-- Additional if it was pprocess that requested subscription, we need to remove that
-- subscription from the graph.
ruleProcessMonitorNotification :: Definitions RC ()
ruleProcessMonitorNotification = defineSimple "halon::rc::process-monitor-notification" $
  \(ProcessMonitorNotification mref pid _) -> do
      self <- liftProcess $ getSelfPid

      runMonitorCallback mref

      -- Remove external subscribers
      modifyGraphM $ \rg -> do
        let subs = do
              sub <- G.connectedTo (R.SubProcessId pid) R.IsSubscriber rg
                         :: Maybe R.Subscriber
              rc  <- G.connectedTo sub R.SubscribedTo rg :: Maybe R.RC
              return (sub,rc)
        flip execStateT rg $ do
          for_ subs $ \(sub@(R.Subscriber _ (BS64 bs)), rc) -> do
            let fp = decodeFingerprint bs
            State.modify $ G.disconnect sub R.SubscribedTo rc
            State.modify $ G.disconnect (R.SubProcessId pid) R.IsSubscriber sub
            lift $ liftProcess $ rawUnsubscribeThem self fp pid

-- | When node dies we run all interested subscribers.
ruleNodeMonitorNotification :: Definitions RC ()
ruleNodeMonitorNotification = defineSimple "halon::rc::node-monitor-notification" $
  \(NodeMonitorNotification mref nid reason) -> do
     Log.actLog "nodeMonitorNotification" [ ("node", show nid)
                                          , ("reason", show reason)
                                          ]
     runMonitorCallback mref

-- | When process did spawn we run all interested subscribers.
ruleDidSpawn :: Definitions RC ()
ruleDidSpawn = defineSimple "halon::rc::did-spawn" $
  \(DidSpawn ref _) -> do
     Log.tagContext Log.Phase [ ("ref", show ref) ] Nothing
     runSpawnCallback ref

-- | Set the given 'HalonVars' in RG.
ruleSetHalonVars :: Definitions RC ()
ruleSetHalonVars = defineSimpleTask "halon::rc::set-halon-vars" $ \(SetHalonVars hvs) -> do
  setHalonVars hvs
  notify $ HalonVarsUpdated hvs

-- | Set the given 'HalonVars' in RG.
ruleGetHalonVars :: Definitions RC ()
ruleGetHalonVars = defineSimpleTask "halon::rc::get-halon-vars" $ \(GetHalonVars pid) -> do
  liftProcess . sendChan pid =<< getHalonVars
