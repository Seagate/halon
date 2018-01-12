-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
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
import qualified HA.Resources.RC as RC
import           Network.CEP

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
import Control.Distributed.Process.Serializable (decodeFingerprint)

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
updateRC :: RC.RC -> RC.RC -> PhaseM RC l ()
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
  rg <- getLocalGraph
  l "subscribers"
  for_ (G.connectedFrom RC.SubscribedTo rc rg) $
      \(RC.Subscriber p (BS64 bs)) -> do
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
    let s = RC.Subscriber pid (BS64 bs)
    modifyGraph $ G.connect (RC.SubProcessId pid) RC.IsSubscriber s
              >>> G.connect s RC.SubscribedTo rc

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
    rcLog' DEBUG [  ("process.pid", show pid)
                  , ("fingerprint", show fp)
                  ]
    liftProcess $ do
      self <- getSelfPid
      rawUnsubscribeThem self fp pid
    rc <- getCurrentRC
    modifyGraph $ \g -> do
      let s  = RC.Subscriber pid (BS64 bs)
          g' = G.disconnect (RC.SubProcessId pid) RC.IsSubscriber s
           >>> G.disconnect s RC.SubscribedTo rc
             $ g
      g'

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
      modifyLocalGraph $ \g -> do
        let subs = do
              sub <- G.connectedTo (RC.SubProcessId pid) RC.IsSubscriber g
                         :: Maybe RC.Subscriber
              rc  <- G.connectedTo sub RC.SubscribedTo g :: Maybe RC.RC
              return (sub,rc)
        flip execStateT g $ do
          for_ subs $ \(sub@(RC.Subscriber _ (BS64 bs)), rc) -> do
            let fp = decodeFingerprint bs
            State.modify $ G.disconnect sub RC.SubscribedTo rc
            State.modify $ G.disconnect (RC.SubProcessId pid) RC.IsSubscriber sub
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
