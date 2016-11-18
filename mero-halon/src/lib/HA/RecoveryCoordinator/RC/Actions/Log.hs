{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}
-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.RC.Actions.Log
  ( module HA.RecoveryCoordinator.Log
    -- * User logging - e.g. direct logging in rules
  , rcLog
  , rcLog'
    -- * System logging - e.g. logging of common actions
  , actLog
  , sysLog'
    -- * Contexts
  , withLocalContext
  , withLocalContext'
  , tagContext
  , tagLocalContext
    -- * Exported for use in defining the RC
  , emptyLocalContext
  ) where

import HA.RecoveryCoordinator.RC.Application
import HA.RecoveryCoordinator.Log

import qualified HA.Resources as Res (Node(..))
import qualified HA.Resources.Castor as Res (StorageDevice(..))

#ifdef USE_MERO
import qualified HA.Resources.Mero.Note as M0 (ShowFidObj(..))
#endif

import Control.Distributed.Process (NodeId, liftIO)

import qualified Data.Map.Strict as Map
import Data.UUID (UUID)
import Data.UUID.V4 (nextRandom)

import Network.CEP hiding (Local)
import Network.CEP.Log (Environment)

-- | Simple class which lets us log basic types more easily. This allows the
--   user to just log "things" whilst constructing sensible types for logging,
--   rather than stringifying.
class UserLoggable a where
  toUserEvent :: a -> UserEvent

instance UserLoggable String where
  toUserEvent = Message

instance UserLoggable Environment where
  toUserEvent = Env

instance UserLoggable [(String, String)] where
  toUserEvent = Env . Map.fromList

instance UserLoggable (String, String) where
  toUserEvent = Env . Map.fromList . (:[])

-- | Hidden type to collect local contexts implicitly.
newtype LocalContext = LocalContext {unLocalContext :: [UUID]}

emptyLocalContext :: LocalContext
emptyLocalContext = LocalContext []

-- | Establishes an implicit local context which will be picked up by any log
--   statements in the given action.
withLocalContext :: (?ctx :: LocalContext) => PhaseM RC l a -> PhaseM RC l a
withLocalContext action = do
  uuid <- liftProcess . liftIO $ nextRandom
  appLog $ BeginLocalContext uuid
  res <- let ?ctx = (LocalContext $ (uuid :) $ unLocalContext ?ctx) in action
  appLog $ EndLocalContext uuid
  return res

-- | Establishes an implicit local context ex nihilo; thus this can be used
--   without any existing contexts in scope.
--   Note that nesting calls to 'withLocalContext\'' will not work. However,
--   'withLocalContext' can safely be nested within 'withLocalContext\''
withLocalContext' :: ((?ctx :: LocalContext) => PhaseM RC l a) -> PhaseM RC l a
withLocalContext' = let ?ctx = emptyLocalContext in withLocalContext

-- | Log a user loggable event to the decision log framework.
rcLog :: (UserLoggable a, ?ctx :: LocalContext) => Level -> a -> PhaseM RC l ()
rcLog lvl x = let
    contexts = [Rule, SM, Phase] ++ (Local <$> unLocalContext ?ctx)
    evt = EvtInContexts contexts . CE_UserEvent lvl Nothing $ toUserEvent x
  in appLog evt

-- | Log a user loggable event to the decision log framework.
--   This variant does not attempt to discover local contexts - 'Rule', 'SM'
--   and 'Phase' contexts will be applied to any log statements made, but
--   if run within a 'withLocalContext' block, that context will not be found.
rcLog' :: (UserLoggable a) => Level -> a -> PhaseM RC l ()
rcLog' = let ?ctx = emptyLocalContext in rcLog

-- | Log an action call to the decision log framework.
actLog :: String -> [(String, String)] -> PhaseM RC l ()
actLog name params = sysLog' $ ActionCalled name (Map.fromList params)

-- | Log a system loggable event to the decision log framework. No Local
--   contexts will be discovered.
sysLog' :: SystemEvent -> PhaseM RC l ()
sysLog' se = let
    contexts = [Rule, SM, Phase]
    evt = EvtInContexts contexts $ CE_SystemEvent se
  in appLog evt

-- | Class to simplify tagging contexts.
class Taggable a where
  toTagContent :: a -> TagContent

instance Taggable TagContent where
  toTagContent = id

instance Taggable String where
  toTagContent = TagString

instance Taggable Environment where
  toTagContent = TagEnv

instance Taggable [(String, String)] where
  toTagContent = TagEnv . Map.fromList

instance Taggable UUID where
  toTagContent uuid = TagScope [Thread uuid]

instance Taggable Res.Node where
  toTagContent node = TagScope [Node node]

instance Taggable NodeId where
  toTagContent nid = TagScope [Node (Res.Node nid)]

instance Taggable Res.StorageDevice where
  toTagContent (Res.StorageDevice uuid) = TagScope [StorageDevice uuid]

#ifdef USE_MERO
-- | Note that it's safe to overlap here because we know that none of our
--   other instances can have `M0.ShowFidObj` instances. `Taggable` isn't
--   exported so new instances are not possible outside of this module.
instance {-# OVERLAPPABLE #-} M0.ShowFidObj a => Taggable a where
  toTagContent obj = TagScope [MeroConfObj $ M0.showFid obj]
#endif

-- | Tag a context with some additional information.
tagContext :: Taggable a => Context -> a -> Maybe String -> PhaseM RC l ()
tagContext ctx ctn msg = let
    evt = TagContext $ TagContextInfo {
            tc_context = ctx
          , tc_data = toTagContent ctn
          , tc_msg = msg
          }
  in appLog evt

-- | Tag the most recent 'local' context, if it exists.
tagLocalContext :: (?ctx :: LocalContext, Taggable a)
                => a -> Maybe String -> PhaseM RC l ()
tagLocalContext a msg = case unLocalContext ?ctx of
  (x:_) -> tagContext (Local x) a msg
  [] -> return ()
