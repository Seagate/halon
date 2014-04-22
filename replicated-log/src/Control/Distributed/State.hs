-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Provides a simplified SQL-like interface to the replicated state maintained
-- by the log.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}
module Control.Distributed.State
       ( Command
       , commandEqDict
       , commandEqDict__static
       , commandSerializableDict
       , commandSerializableDict__static
       , CommandPort
       , Log
       , log
       , newPort
       , select
       , update
       , __remoteTable) where

import qualified Control.Distributed.Log as Log
import Control.Distributed.Log (EqDict(..), TypeableDict(..))
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
    ( closureApply
    , staticClosure )

import GHC.IORef
import Data.Word (Word64)
import Data.Binary (Binary, encode)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Data.Function (on)
import Prelude hiding (init, log)

data CommandId = CommandId
    { commandIdCounter   :: !Word64
    , commandIdProcessId :: !ProcessId
    } deriving (Eq, Ord, Generic, Typeable)

instance Binary CommandId

data Command s = Command
    { commandId      :: !CommandId
    , commandClosure :: CP s s
    } deriving (Generic, Typeable)

instance Typeable s => Binary (Command s)

instance Eq (Command s) where
    (==) = (==) `on` commandId

instance Ord (Command s) where
    compare = compare `on` commandId

data Result a = Result
    { resultId :: CommandId
    , result :: a
    } deriving (Generic, Typeable)

instance Binary a => Binary (Result a)

commandEqDict :: EqDict (Command s)
commandEqDict  = EqDict

commandSerializableDict :: TypeableDict s -> SerializableDict (Command s)
commandSerializableDict TypeableDict = SerializableDict

commandIdSerializableDict :: SerializableDict CommandId
commandIdSerializableDict = SerializableDict

selectWrapper :: SerializableDict a
              -> ProcessId
              -> CommandId
              -> (s -> Process a)
              -> s
              -> Process s
selectWrapper SerializableDict α cid f s = do
    x <- f s
    send α $ Result cid x
    return s

updateWrapper :: (s -> Process s)
              -> s
              -> Process s
updateWrapper = ($)

remotable [ 'commandEqDict, 'commandSerializableDict, 'commandIdSerializableDict
          , 'selectWrapper, 'updateWrapper ]

sdictCommandId :: Static (SerializableDict CommandId)
sdictCommandId = $(mkStatic 'commandIdSerializableDict)

cpSelectWrapper :: (Typeable a, Typeable s)
                => Static (SerializableDict a)
                -> ProcessId
                -> CommandId
                -> CP s a
                -> CP s s
cpSelectWrapper dict α cid f =
    staticClosure $(mkStatic 'selectWrapper)
      `closureApply` staticClosure dict
      `closureApply` closure (staticDecode sdictProcessId) (encode α)
      `closureApply` closure (staticDecode sdictCommandId) (encode cid)
      `closureApply` f

cpUpdateWrapper :: Typeable s => CP s s -> CP s s
cpUpdateWrapper f =
    staticClosure $(mkStatic 'updateWrapper)
      `closureApply` f

-- | A port for sending commands to the log. Currently, at most one command
-- port per process is supported.
data CommandPort s = CommandPort !(IORef Word64) !(Log.Handle (Command s))

type Log s = Log.Log (Command s)

log :: Typeable s => Process s -> Log s
log init = Log.Log
    { logInitialization = init
    , logNextState = \s (Command _ f) -> do
        unClosure f >>= ($ s)
    }

newPort :: Typeable s => Log.Handle (Command s) -> Process (CommandPort s)
newPort h = do
    ref <- liftIO $ newIORef 0
    return $ CommandPort ref h

nextCommandId :: CommandPort s -> Process CommandId
nextCommandId (CommandPort ref _) = do
    self <- getSelfPid
    liftIO $ atomicModifyIORef ref (\i -> (succ i, CommandId i self))

-- | Query the replicated state. The provided closure tells the replicas how
-- to create an answer from the current state.
select :: (Typeable a, Typeable s)
       => Static (SerializableDict a)
       -> CommandPort s
       -> CP s a
       -> Process a
select sdict port@(CommandPort _ h) f = do
    SerializableDict <- unStatic sdict
    self <- getSelfPid
    cid <- nextCommandId port
    Log.append h Log.Nullipotent $ Command cid $ cpSelectWrapper sdict self cid f
    receiveWait [ matchIf ((cid ==) . resultId) $ \Result{..} -> return result ]

-- | Update the replicated state. The provided closure tells the replicas what
-- to do to the state at each site.
update :: Typeable s => CommandPort s -> CP s s -> Process ()
update port@(CommandPort _ h) f = do
    cid <- nextCommandId port
    Log.append h Log.None $ Command cid $ cpUpdateWrapper f
