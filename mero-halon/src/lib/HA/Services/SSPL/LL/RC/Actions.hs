-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators #-}
module HA.Services.SSPL.LL.RC.Actions
  ( fldCommandAck
  , mkDispatchAwaitCommandAck
  ) where

import           Control.Lens
import           Control.Monad (when)
import           Data.List (delete)
import           Data.Proxy (Proxy(..))
import qualified Data.Text as T
import           Data.UUID (UUID)
import           Data.Vinyl
import           HA.EventQueue (HAEvent(..))
import           HA.RecoveryCoordinator.RC.Actions
import           HA.RecoveryCoordinator.RC.Actions.Dispatch
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.Services.SSPL.LL.Resources
import           Network.CEP

-- Rule Fragments

-- | Set of UUIDs to await.
type FldCommandAck = '("ssplCommandAck", [UUID])

-- | Command acknowledgements to wait for
fldCommandAck :: Proxy FldCommandAck
fldCommandAck = Proxy

-- | Create a dispatcher phase to await a command acknowledgement.
mkDispatchAwaitCommandAck :: forall l. (FldDispatch ∈ l, FldCommandAck ∈ l)
                          => Jump PhaseHandle -- ^ dispatcher
                          -> Jump PhaseHandle -- ^ failed phase
                          -> PhaseM RC (FieldRec l) () -- ^ Logging action
                          -> RuleM RC (FieldRec l) (Jump PhaseHandle)
mkDispatchAwaitCommandAck dispatcher failed logAction = do
    sspl_notify_done <- phaseHandle "dispatcher:await:sspl"

    setPhaseIf sspl_notify_done onCommandAck $ \(eid, uid, ack) -> do
      Log.rcLog' Log.DEBUG "SSPL notification complete"
      logAction
      modify Local $ rlens fldCommandAck . rfield %~ delete uid
      messageProcessed eid
      remaining <- gets Local (^. rlens fldCommandAck . rfield)
      when (null remaining) $ waitDone sspl_notify_done

      Log.rcLog' Log.DEBUG $ "SSPL ack for command "  ++ show (commandAckType ack)
      case commandAck ack of
        AckReplyPassed -> do
          Log.rcLog' Log.DEBUG $ "SSPL command successful."
          continue dispatcher
        AckReplyFailed -> do
          Log.rcLog' Log.WARN $ "SSPL command failed."
          continue failed
        AckReplyError msg -> do
          Log.rcLog' Log.ERROR $ "Error received from SSPL: " ++ (T.unpack msg)
          continue failed

    return sspl_notify_done
  where
    -- Phase guard for command acknowledgements
    onCommandAck (HAEvent eid (CAck cmd)) _ l =
      case (l ^. rlens fldCommandAck . rfield, commandAckUUID cmd) of
        (xs, Just y) | y `elem` xs -> return $ Just (eid, y, cmd)
        _ -> return Nothing
    onCommandAck _ _ _ = return Nothing
