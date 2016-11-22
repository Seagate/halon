{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE TypeFamilies               #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules for mero service and cluster maintenance
-- operations.
module HA.RecoveryCoordinator.Mero.Rules.Maintenance
  ( rules
  ) where

import HA.RecoveryCoordinator.RC.Actions
import HA.RecoveryCoordinator.Mero.Actions.Conf
  (lookupConfObjByFid)
import HA.RecoveryCoordinator.Mero.Events
import HA.RecoveryCoordinator.Mero.State
  (applyStateChanges)
import qualified HA.Resources.Mero.Note as M0
import Network.CEP

import Data.Traversable
import Data.Typeable
import Data.Maybe
import Control.Monad.Trans
import Control.Monad.Trans.Writer
import Control.Distributed.Process (sendChan)

-- | Set of all rules.
rules :: Definitions RC ()
rules = sequence_
 [ ruleUpdateObjectState
 ]

-- | Forcefully update objet state.
ruleUpdateObjectState :: Definitions RC ()
ruleUpdateObjectState = defineSimpleTask "mero::maintenance::update-object-state" $
  \(ForceObjectStateUpdateRequest fs chan) -> do
     (results,updates) <- runWriterT $ for fs $ \(fid, state) -> (fid,) <$> do
        case listToMaybe $ M0.fidConfObjDict fid of
          Nothing -> return DictNotFound
          Just (M0.SomeConfObjDict (Proxy :: Proxy b)) -> do
            mo :: Maybe b <- lift $ lookupConfObjByFid fid
            case mo of
              Nothing -> return ObjectNotFound
              Just o  -> case reads state of
               [(st, _)] -> do tell [stateSet o st]
                               return Success
               _ -> return ParseFailed
     applyStateChanges updates
     liftProcess $ sendChan chan $ ForceObjectStateUpdateReply results
