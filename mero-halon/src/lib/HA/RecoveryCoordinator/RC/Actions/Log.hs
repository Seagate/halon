{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}
-- |
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
module HA.RecoveryCoordinator.RC.Actions.Log
  ( -- $logging
    module HA.RecoveryCoordinator.Log
    -- * User logging - e.g. direct logging in rules
  , rcLog
  , rcLog'
    -- * System logging - e.g. logging of common actions
  , actLog
  , sysLog'
    -- * Contexts
    -- $contexts
  , withLocalContext
  , withLocalContext'
  , tagContext
  , tagLocalContext
    -- * Exported for use in defining the RC
  , emptyLocalContext
  ) where

import HA.RecoveryCoordinator.RC.Application
import HA.RecoveryCoordinator.Log

import qualified HA.Resources as R (Node(..))
import qualified HA.Resources.Castor as Cas (StorageDevice(..))

import qualified HA.Resources.Mero.Note as M0 (ShowFidObj(..))

import Control.Distributed.Process (NodeId, liftIO)

import Data.List (isPrefixOf, find)
import qualified Data.Map.Strict as Map
import Data.UUID (UUID)
import Data.UUID.V4 (nextRandom)

#if __GLASGOW_HASKELL__ < 800
import GHC.SrcLoc
#endif
import GHC.Stack

import Network.CEP hiding (Local)
import Network.CEP.Log (Environment)

-- $logging
--
-- The new logging framework is designed to make logging simpler for the
-- developer whilst giving much more information to the debugger. In order
-- to support this, here are some guidelines for logging.
--
-- The two most important functions in this module are 'tagContext' and
-- 'rcLog'', in that order. Tagging contexts (see '$context') is used to
-- associate data with logging statements. In general, where a rule concerns
-- some particular part of the cluster, or some configuration entity, these
-- should be attached to the relevant context (usually SM or Phase) using
-- 'tagContext'. This ensures that this information is available to any
-- logging calls made, and removes the need to encode these into message
-- strings.
--
-- 'rcLog' or 'rcLog'' should then be used to provide information about what's
-- happening. It is overloaded using the 'UserLoggable' class to support
-- logging of multiple types; in particular, there is support for logging
-- '[(String, String)]' in order to directly capture key-value information.
-- The need to perform string manipulation should be reduced; if you find
-- yourself using it, consider whether logging an 'Environment' or using
-- 'tagContext' would be better.
--
-- * Local contexts
--
-- Local contexts can be used to attach information to a block of log
-- statements. When using local contexts, the 'rcLog' call should be used in
-- place of 'rcLog'', since this call picks up on established local contexts.

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

-- $contexts
--
-- Contexts are used to associate data to multiple logging statements.
-- Fundamental to the use of contexts are two ideas:
--
-- - Tags are items of data which will be associated with any logging
--   statement made within the given context.
-- - Contexts delineate the set of messages which will be associated with
--   that context's tags.
--
-- There are currently four different contexts:
-- - Rule contexts associate tags with any log statement made in any instance of
--   the current rule. Their only likely use case is where some initial state
--   of the rule may be set on RC up, and we wish to associate this.
-- - SM contexts are the most common. The SM context associates tags with any
--   log statement made within the given instance of the rule. This context is
--   useful where a rule may fork and deal with a particular part of the
--   cluster - a node, say, or a disk.
-- - Phase contexts associate tags with messages in the current phase of the
--   SM.
-- - Local contexts can be used to establish a block within which any log
--   messages may be associated with tags. For example:
--   @
--     Left (StorageDevice.AnotherInSlot asdev) -> do
--    Log.withLocalContext' $ do
--      Log.tagLocalContext asdev Nothing
--      Log.tagLocalContext [("location"::String, show sdev_loc)] Nothing
--      Log.rcLog Log.ERROR
--        ("Insertion in a slot where previous device was inserted - removing old device.":: String)
--      StorageDevice.ejectFrom asdev sdev_loc
--      notify $ DriveRemoved uuid node sdev_loc asdev mis_powered
--   @
--
-- Tags typically fall into two categories:
-- - Entities in the resource graph, such as nodes and Mero conf objects.
-- - General strings and key-value string pairs.
--
-- Which things can be used to tag contexts is determined by the 'Taggable'
-- class. If you find yourself repeatedly tagging contexts with a particular
-- type, consider adding it as a potential 'HA.RecoveryCoordinator.Log.Scope'
-- and adding a 'Taggable' instance rather than using 'show'.

-- | Hidden type to collect local contexts implicitly.
newtype LocalContext = LocalContext {unLocalContext :: [UUID]}

-- | 'LocalContext' with no information.
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
--   Note that nesting calls to 'withLocalContext'' will not work. However,
--   'withLocalContext' can safely be nested within 'withLocalContext''
withLocalContext' :: ((?ctx :: LocalContext) => PhaseM RC l a) -> PhaseM RC l a
withLocalContext' = let ?ctx = emptyLocalContext in withLocalContext

-- | Log a user loggable event to the decision log framework.
--
--   'rcLog' (or its non-local context sensitive analogue, 'rcLog''), should
--   be the go-to stop for most logging. It has a number of benefits over
--   'phaseLog':
--   - Messages will be associated with any tags established in its contexts.
--   - Source location will be recorded for easier debugging.
--   - Log levels may be used for filtering.
--   - Key-value pairs may be logged directly without the need for formatting
--     into a single string, or using multiple log calls.
rcLog :: (UserLoggable a, ?ctx :: LocalContext, ?loc :: CallStack)
      => Level -> a -> PhaseM RC l ()
rcLog lvl x = let
    !cs = ?loc
    contexts = [Rule, SM, Phase] ++ (Local <$> unLocalContext ?ctx)
    evt = EvtInContexts contexts . CE_UserEvent lvl srcLoc $ toUserEvent x
    srcLoc = extractSrcLoc . snd <$> (find (isPrefixOf "rcLog" . fst)
                                  . reverse . getCallStack $ cs)
    extractSrcLoc !sl = SourceLoc (srcLocModule sl) (srcLocStartLine sl)
  in appLog evt

-- | Log a user loggable event to the decision log framework.
--
--   This variant does not attempt to discover local contexts - 'Rule', 'SM'
--   and 'Phase' contexts will be applied to any log statements made, but
--   if run within a 'withLocalContext' block, that context will not be found.
rcLog' :: (UserLoggable a, ?loc :: CallStack) => Level -> a -> PhaseM RC l ()
rcLog' = let ?ctx = emptyLocalContext in rcLog

-- | Log an action call to the decision log framework. This should only be used
--   within named actions to log calls to that action, and any arguments it is
--   called with.
actLog :: String -- ^ Name of the action called.
       -> [(String, String)] -- ^ Arguments passed to the function.
       -> PhaseM RC l ()
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

instance Taggable R.Node where
  toTagContent node = TagScope [Node node]

instance Taggable NodeId where
  toTagContent nid = TagScope [Node (R.Node nid)]

instance Taggable Cas.StorageDevice where
  toTagContent (Cas.StorageDevice serial) = TagScope [StorageDevice serial]

-- | Note that it's safe to overlap here because we know that none of our
--   other instances can have `M0.ShowFidObj` instances. `Taggable` isn't
--   exported so new instances are not possible outside of this module.
instance {-# OVERLAPPABLE #-} M0.ShowFidObj a => Taggable a where
  toTagContent obj = TagScope [MeroConfObj $ M0.showFid obj]

-- | Tag a context with some additional information.
--   See $contexts
tagContext :: Taggable a => Context -> a -> Maybe String -> PhaseM RC l ()
tagContext ctx ctn msg = let
    evt = TagContext $ TagContextInfo {
            tc_context = ctx
          , tc_data = toTagContent ctn
          , tc_msg = msg
          }
  in appLog evt

-- | Tag the most recent 'local' context, if it exists. This function is
--   provided for convenience; usually one will not care about nesting contexts,
--   and it is a pain to have to find the UUID of the local context to address
--   it correctly.
tagLocalContext :: (?ctx :: LocalContext, Taggable a)
                => a -> Maybe String -> PhaseM RC l ()
tagLocalContext a msg = case unLocalContext ?ctx of
  (x:_) -> tagContext (Local x) a msg
  [] -> return ()
