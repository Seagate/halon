-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}
module HA.RecoveryCoordinator.Rules.Mero.Conf
  ( -- * Rules
    allRules
  , ruleService
  , ruleProcess
  , ruleNode
  , ruleEnclosure
  , ruleController
    -- * Triggers
    -- ** Service
  , serviceOnline
  , serviceTransient
  , serviceFailed
    -- ** Process
  , processOnline
  , processTransient
  , processFailed
    -- ** Node
  , nodeOnline
  , nodeTransient
  , nodeFailed
    -- ** Enclosure
  , enclosureOnline
  , enclosureTransient
  , enclosureFailed
  )  where

import HA.EventQueue.Types
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Conf
import HA.Services.Mero (notifyMero)
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.ResourceGraph as G
import Mero.ConfC (ServiceType(..))
import Data.Foldable (forM_, traverse_)
import Control.Monad (when)
import Network.CEP
import Control.Distributed.Process.Serializable

import Data.Binary
import Data.Hashable
import Data.Typeable
import GHC.Generics

newtype StateChangeEvent (a :: M0.ConfObjectState) b = StateChangeEvent { getEntity :: b } deriving
  (Eq, Show, Binary, Hashable, Generic)

-- | Collection of all rules that happens when some conf object changes its state
allRules :: Specification LoopState ()
allRules = sequence_
  [ ruleService
  , ruleProcess
  , ruleNode
  , ruleController
  , ruleEnclosure
  ]

-------------------------------------------------------------------------------
-- Service
-------------------------------------------------------------------------------

-- | Rules that fire when 'M0.Service' changes its state.
ruleService :: Specification LoopState ()
ruleService = defaultActions "service"
     EventHandlers { onFailure   = [ rmsServiceFailure]
                   , onTransient = [tryRecoverService]
                   , onOnline    = []
                   }
  where
    tryRecoverService _ = return ()
    rmsServiceFailure srv = when (M0.s_type srv == CST_RMS) $ return ()

-- | Mark 'M0.Service' as failed. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
serviceFailed :: M0.Service -> PhaseM LoopState l ()
serviceFailed = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_FAILED)

-- | Mark 'M0.Service' as transient. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
serviceTransient :: M0.Service -> PhaseM LoopState l ()
serviceTransient = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_TRANSIENT)

-- | Mark 'M0.Service' as online. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
serviceOnline :: M0.Service -> PhaseM LoopState l ()
serviceOnline = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_ONLINE)

-------------------------------------------------------------------------------
-- Process
-------------------------------------------------------------------------------

-- | Rules that fire when 'M0.Process' changes its state.
ruleProcess :: Specification LoopState ()
ruleProcess = defaultActions "process"
    (EventHandlers { onFailure   = [escalateFailureToService]
                   , onTransient = [escalateTransientToService]
                   , onOnline    = []
                   } :: EventHandlers M0.Process)
   where
     escalateFailureToService pr = getChildren pr >>= traverse_ serviceFailed
     escalateTransientToService pr = getChildren pr >>= traverse_ serviceFailed

-- | Mark 'M0.Process' as failed. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
processFailed :: M0.Process -> PhaseM LoopState l ()
processFailed = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_FAILED)

-- | Mark 'M0.Process' as transient. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
processTransient :: M0.Process -> PhaseM LoopState l ()
processTransient = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_TRANSIENT)

-- | Mark 'M0.Process' as online. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
processOnline :: M0.Process -> PhaseM LoopState l ()
processOnline = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_ONLINE)

-------------------------------------------------------------------------------
-- Node
-------------------------------------------------------------------------------

-- | Rules that fire when 'M0.Node' changes its state.
ruleNode :: Specification LoopState ()
ruleNode = defaultActions "node"
   (EventHandlers { onFailure   = [ escalateToController controllerFailed
                                  , escalateToProcess processFailed
                                  ]
                  , onTransient = [ escalateToController controllerFailed
                                  , escalateToProcess processTransient
                                  ]
                  , onOnline    = [ escalateToController controllerOnline]
                  } :: EventHandlers M0.Node)
  where
    escalateToController action node = do
      rg <- getLocalGraph
      traverse_ action (G.connectedTo node M0.IsOnHardware rg)
    escalateToProcess action node =
      getChildren node >>= traverse_ action

-- | Mark 'M0.Node' as failed. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
nodeFailed :: M0.Node -> PhaseM LoopState l ()
nodeFailed = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_FAILED)

-- | Mark 'M0.Node' as transient. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
nodeTransient :: M0.Node -> PhaseM LoopState l ()
nodeTransient = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_TRANSIENT)

-- | Mark 'M0.Node' as online. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
nodeOnline :: M0.Node -> PhaseM LoopState l ()
nodeOnline = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_ONLINE)


-------------------------------------------------------------------------------
-- Controller
-------------------------------------------------------------------------------

-- | Rules that fire when 'M0.Controller' changes its state.
ruleController :: Specification LoopState ()
ruleController = defaultActions "controller"
    (EventHandlers { onFailure = [ escalateFailureToEnclosure
                                 , escalateToNode nodeFailed
                                 ]
                   , onTransient = [ escalateToNode nodeTransient
                                   ]
                   , onOnline    = [ escalateToNode nodeOnline ]
                   } :: EventHandlers M0.Controller)
  where
    escalateFailureToEnclosure cntr = do
      encls <- getParents cntr
      forM_ encls $ \encl -> do
        (cntrs :: [M0.Controller]) <- getChildren encl
        status <- filter (/= Just M0.M0_NC_FAILED) <$> traverse queryObjectStatus cntrs
        when (null status) $ enclosureFailed encl
    escalateToNode action cntr = do
      rg <- getLocalGraph
      traverse_ action (G.connectedFrom M0.IsOnHardware cntr rg)

-- | Mark 'M0.Controller' as failed. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
controllerFailed :: M0.Controller -> PhaseM LoopState l ()
controllerFailed = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_FAILED)

-- | Mark 'M0.Controller' as transient. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
controllerTransient :: M0.Controller -> PhaseM LoopState l ()
controllerTransient = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_TRANSIENT)

-- | Mark 'M0.Controller' as online. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
controllerOnline :: M0.Controller -> PhaseM LoopState l ()
controllerOnline = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_ONLINE)

-------------------------------------------------------------------------------
-- Enclosure
-------------------------------------------------------------------------------

-- | Rules that fire when 'M0.Enclosure' changes its state.
ruleEnclosure :: Specification LoopState ()
ruleEnclosure = defaultActions "enclosure"
  (EventHandlers { onFailure = [ escalateToController controllerFailed ]
                 , onTransient = [ escalateToController controllerTransient ]
                 , onOnline    = [ ]
                 } :: EventHandlers M0.Enclosure)
  where
    escalateToController action enclosure = getChildren enclosure >>= traverse_ action

-- | Mark 'M0.Enclosure' as failed. This message will be sent via EQ,
-- so may be processed only when the message will be back from EQ.
enclosureFailed :: M0.Enclosure -> PhaseM LoopState l ()
enclosureFailed = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_FAILED)

-- | Mark 'M0.Enclosure' as transient. This message will be sent via EQ,
-- so may be processed only then message will be back from EQ.
enclosureTransient :: M0.Enclosure -> PhaseM LoopState l ()
enclosureTransient = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_TRANSIENT)

-- | Mark 'M0.Enclosure' as online. This message will be sent via EQ,
-- so may be processed only then message will be back from EQ.
enclosureOnline :: M0.Enclosure -> PhaseM LoopState l ()
enclosureOnline = promulgateRC . stateChange (Proxy :: Proxy 'M0.M0_NC_ONLINE)

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- | Run action iff entity is not in given state.
whenNotState :: M0.HasConfObjectState a
              => M0.ConfObjectState -> a -> PhaseM LoopState l () -> PhaseM LoopState l ()
whenNotState st obj cont = do
  rg <- getLocalGraph
  when (M0.getConfObjState obj rg == st) $
    cont -- >> setObjectStatus obj st
{-# INLINE whenNotState #-}

-- | Helper for creating 'StateChangeEvent'
stateChange :: Proxy x  -- ^ State type witness.
            -> a        -- ^ Object that changes state.
            -> StateChangeEvent x a
stateChange _ = StateChangeEvent
{-# INLINE stateChange #-}

-- | Helper for writing state change function. It run simple one step action, calls 'todo'
-- and 'done', add logs and notify mero about changed state.
onStateChange :: (M0.HasConfObjectState b, Show b, Serializable a)
              => String             -- ^ Rule name.
              -> M0.ConfObjectState -- ^ New object state.
              -> (a -> b)           -- ^ Extract object from message.
              -> (forall l . [b -> PhaseM LoopState l ()]) -- ^ List of actions
              -> Specification LoopState ()
onStateChange name st getE actions = defineSimpleTask name $ \(HAEvent _ (getE -> entity) _) ->
   whenNotState st entity $ do
     phaseLog "conf-obj" $ show entity ++ " becomes " ++ show st
     sequence_ $ map ($ entity) actions
     notifyMero [M0.AnyConfObj entity] st
{-# INLINE onStateChange #-}

-- | Structure for keeping event handlers.
data EventHandlers a = EventHandlers
  { onFailure   :: (forall l . [a -> PhaseM LoopState l ()])
  , onTransient :: (forall l . [a -> PhaseM LoopState l ()])
  , onOnline    :: (forall l . [a -> PhaseM LoopState l ()])
  }

-- | Helper for implementing default action handlers, hiding some amount of boilerplate.
defaultActions :: forall a . M0.HasConfObjectState a
               => String  -- ^ Entity name.
               -> EventHandlers a -- ^ Event Handlers.
               -> Specification LoopState ()
defaultActions s (EventHandlers failure transient online) = sequence_
  [ onStateChange (s++":on-failure")
                  M0.M0_NC_FAILED
                  (getEntity :: StateChangeEvent 'M0.M0_NC_FAILED a -> a)
                  failure
  , onStateChange (s++":on-transient")
                  M0.M0_NC_TRANSIENT
                  (getEntity :: StateChangeEvent 'M0.M0_NC_TRANSIENT a -> a)
                  transient
  , onStateChange (s++":on-online")
                  M0.M0_NC_ONLINE
                  (getEntity :: StateChangeEvent 'M0.M0_NC_ONLINE a -> a)
                  online
  ]
{-# INLINE defaultActions #-}
