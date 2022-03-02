-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Defines the logging type for the recovery coordinator.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
module HA.RecoveryCoordinator.Log where


import qualified HA.Resources as R (Node)
import HA.SafeCopy

import HA.Aeson
import Data.Typeable (Typeable)
import Data.UUID (UUID)

import GHC.Generics (Generic)

import Network.CEP.Log (Environment)

data Event =
    BeginLocalContext UUID
    -- ^ Begins a "local" context.
  | EndLocalContext UUID
    -- ^ Ends a "local" context.
  | TagContext TagContextInfo
  | EvtInContexts [Context] CtxEvent
  deriving (Eq, Generic, Ord, Show, Typeable)

instance ToJSON Event
instance FromJSON Event

--------------------------------------------------------------------------------
-- Contexts and scopes
--------------------------------------------------------------------------------

-- | Idea of a context for a log statement.
data Context =
    Rule -- ^ Relates to every instance of the rule.
  | SM -- ^ Relates to the whole SM.
  | Phase -- ^ Relates to the current phase.
  | Local UUID -- ^ Relates to some local scope.
  deriving (Eq, Generic, Ord, Show, Typeable)

instance ToJSON Context
instance FromJSON Context

-- | Used to associate data with a context.
data TagContextInfo = TagContextInfo {
    tc_context :: Context
  , tc_data :: TagContent
  , tc_msg :: Maybe String -- ^ Optional message describing the environment.
} deriving (Eq, Generic, Ord, Show, Typeable)

instance ToJSON TagContextInfo
instance FromJSON TagContextInfo

-- | Possible scopes with which one can tag a context. These should be used to
--   help in debugging particular subsets of the system.
data Scope =
    Thread UUID -- ^ Tag a "thread" of processing. This could be used to
                     --   group multiple rules all driven from a single message.
  | Node R.Node -- ^ Associated node
  | StorageDevice String -- ^ Associated storage device.
  | MeroConfObj String -- ^ Associated Mero configuration object.
  deriving (Eq, Generic, Ord, Show, Typeable)

instance ToJSON Scope
instance FromJSON Scope

data TagContent =
    TagScope [Scope] -- ^ Tag context with a set of scopes.
  | TagEnv Environment -- ^ Tag context with a general environment.
  | TagString String -- ^ Associate an arbitrary message with a context.
  deriving (Eq, Generic, Ord, Show, Typeable)

instance ToJSON TagContent
instance FromJSON TagContent

-- | An event which may be contextualised.
data CtxEvent =
    CE_SystemEvent SystemEvent
  | CE_UserEvent Level (Maybe SourceLoc) UserEvent
  deriving (Eq, Generic, Ord, Show, Typeable)

instance ToJSON CtxEvent
instance FromJSON CtxEvent

--------------------------------------------------------------------------------
-- System logging
--------------------------------------------------------------------------------

data SystemEvent =
    Promulgate String UUID
    -- ^ Declare that a message has been promulgated.
  | Todo UUID
    -- ^ Declare that an interest has been raised in a message.
  | Done UUID
    -- ^ Declare that an interest has been satisfied in a message.
  | StateChange StateChangeInfo
    -- ^ Declare that the state of a stateful resource has changed.
  | ActionCalled String Environment
    -- ^ Declare than an action has been called with certain parameters.
  | RCStarted R.Node
    -- ^ Declare that the RC has started on a node.
  deriving (Eq, Generic, Ord, Show, Typeable)

instance ToJSON SystemEvent
instance FromJSON SystemEvent

-- | Log that we are changing the state of an entity.
data StateChangeInfo = StateChangeInfo {
    lsc_entity :: String -- ^ From 'showFid'
  , lsc_oldState :: String
  , lsc_newState :: String
} deriving (Eq, Generic, Ord, Show, Typeable)

instance ToJSON StateChangeInfo
instance FromJSON StateChangeInfo

--------------------------------------------------------------------------------
-- User level logging
--------------------------------------------------------------------------------

data Level =
    TRACE -- ^ Very detailed logging to trace execution flow.
  | DEBUG -- ^ Standard log level. Information useful for inspection/debug.
  | WARN -- ^ Something unexpected happened, but does not threaten the system.
  | ERROR -- ^ A genuine error. System state may be indeterminate. Should
          --   be inspected.
  deriving (Eq, Generic, Ord, Show, Typeable)

instance ToJSON Level
instance FromJSON Level

-- | Log a location in source code. If used, it's expected that this will be
--   generated by some TH function.
--
--   Note that when we move to GHC 8, we could replace this with
--   `GHC.Stack.SrcLoc`, but since its constructors are unexported in current
--   base, we cannot derive JSON instances for it correctly.
data SourceLoc = SourceLoc {
    lsl_module :: String
  , lsl_line :: Int
} deriving (Eq, Generic, Ord, Show, Typeable)

instance ToJSON SourceLoc
instance FromJSON SourceLoc

data UserEvent =
    Env Environment
    -- ^ Log an "environment" - e.g. a mapping from keys to values. This should
    --   be preferred to 'Message', though it itself should be considered only
    --   if more specific logging cannot be used. It may often be more appropriate
    --   to associate much of an environment with a context - see 'TagContext'
    --   below.
  | Message String
    -- ^ Basic "log a message" type. We would like to avoid resorting to this
    --   where possible.
  deriving (Eq, Generic, Ord, Show, Typeable)

instance ToJSON UserEvent
instance FromJSON UserEvent

--------------------------------------------------------------------------------
-- Safecopy instances
--------------------------------------------------------------------------------
deriveSafeCopy 0 'base ''Context
deriveSafeCopy 0 'base ''CtxEvent
deriveSafeCopy 0 'base ''Event
deriveSafeCopy 0 'base ''Level
deriveSafeCopy 0 'base ''Scope
deriveSafeCopy 0 'base ''SourceLoc
deriveSafeCopy 0 'base ''StateChangeInfo
deriveSafeCopy 0 'base ''SystemEvent
deriveSafeCopy 0 'base ''TagContent
deriveSafeCopy 0 'base ''TagContextInfo
deriveSafeCopy 0 'base ''UserEvent
