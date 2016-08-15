-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.RC.Rules
  ( rules
  , initialRule
  ) where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.RC.Actions
import HA.RecoveryCoordinator.RC.Events
import HA.Resources.RC
import qualified HA.ResourceGraph as G
import Network.CEP

import Control.Distributed.Process
  ( ProcessMonitorNotification(..)
  , getSelfPid
  , monitor
  , usend
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
rules :: Definitions LoopState ()
rules = sequence_
  [ ruleNewSubscription
  , ruleRemoveSubscription
  , ruleSubscriberDied
  ]

-- | Describe how to update recovery coordinator, in case
-- if new version is used now.
updateRC :: RC -> RC -> PhaseM LoopState l ()
updateRC _old _new = return ()


-- | Store information about currently running RC in the Resource Graph
-- ('G.Graph'). We store current RC, and update old one if needed.
initialRule :: PhaseM LoopState l ()
initialRule = do
  -- Store current recovery coordinator in the graph and update
  -- graph if needed.
  rc <- makeCurrentRC updateRC
  -- subscribe all processes with persistent subscription.
  rg <- getLocalGraph
  for_ (G.connectedFrom SubscribedTo rc rg) $ \(Subscriber p bs) -> do
    let fp = decodeFingerprint bs
    liftProcess $ do
      self <- getSelfPid
      monitor p
      rawSubscribeThem self fp p

-- | When new process is subscribed to some interesting events persistently,
-- we store that in RG and add announce that to CEP engine manually.
ruleNewSubscription :: Definitions LoopState ()
ruleNewSubscription = defineSimpleTask "halon::rc::new-subscription" $
  \(SubscribeToRequest pid bs) -> do
    let fp = decodeFingerprint bs
    phaseLog "info" $ "process.pid=" ++ show pid
    phaseLog "info" $ "fingerprint=" ++ show fp
    liftProcess $ do
      self <- getSelfPid
      monitor pid
      rawSubscribeThem self fp pid
    rc <- getCurrentRC
    modifyGraph $ \g -> do
      let s  = Subscriber pid bs
          p  = SubProcessId pid
      let g' = G.newResource s
           >>> G.newResource p
           >>> G.connect p IsSubscriber s
           >>> G.connect s SubscribedTo rc
             $ g
      g'
    registerSyncGraphCallback $ \_ _ -> do
      usend pid (SubscribeToReply bs)

-- | When new process is unsubscribed to some interesting events persistently,
-- we store that in RG and add announce that to CEP engine manually.
--
-- XXX: unmonitor process
ruleRemoveSubscription :: Definitions LoopState ()
ruleRemoveSubscription = defineSimpleTask "halon::rc::remove-subscription" $
  \(UnsubscribeFromRequest pid bs) -> do
    let fp = decodeFingerprint bs
    phaseLog "info" $ "process.pid=" ++ show pid
    phaseLog "info" $ "fingerprint=" ++ show fp
    liftProcess $ do
      self <- getSelfPid
      rawUnsubscribeThem self fp pid
    rc <- getCurrentRC
    modifyGraph $ \g -> do
      let s  = Subscriber pid bs
          p  = SubProcessId pid
      let g' = G.disconnect p IsSubscriber s
           >>> G.disconnect s SubscribedTo rc
             $ g
      g'

-- | When process that requested subscription dies, we need to remove that
-- subscription from the graph.
ruleSubscriberDied :: Definitions LoopState ()
ruleSubscriberDied = defineSimpleTask "halon::rc::subscriber-died" $
  \(ProcessMonitorNotification _ pid _) -> do
      self <- liftProcess $ getSelfPid
      modifyLocalGraph $ \g -> do
        let subs =
             [ (sub,rc)
             | sub <- G.connectedTo (SubProcessId pid) IsSubscriber g :: [Subscriber]
             , rc  <- G.connectedTo sub SubscribedTo g :: [RC]
             ]
        flip execStateT g $ do
          for_ subs $ \(sub@(Subscriber _ bs), rc) -> do
            let fp = decodeFingerprint bs
            State.modify $ G.disconnect sub SubscribedTo rc
            State.modify $ G.disconnect (SubProcessId pid) IsSubscriber sub
            lift $ liftProcess $ rawUnsubscribeThem self fp pid
