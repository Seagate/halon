-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Generic phase dispatcher. This can be used to control the flow
-- of execution in a multi-phase rule without introducing
-- multiple similar phases.
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
module HA.RecoveryCoordinator.Actions.Dispatch where

import Control.Lens

import Data.List (delete)
import Data.Proxy
import Data.Vinyl

import Network.CEP

-- | Holds dispatching information for complex jumps.
type FldDispatch = '("dispatch", Dispatch)
fldDispatch :: Proxy FldDispatch
fldDispatch = Proxy

data Dispatch = Dispatch {
    _waitPhases :: [Jump PhaseHandle]
  , _successPhase :: Jump PhaseHandle
  , _timeoutPhase :: Maybe (Int, Jump PhaseHandle)
}
makeLenses ''Dispatch

-- | Set the phase to transition to when all waiting phases have been
--   completed.
onSuccess :: forall a l. (FldDispatch ∈ l)
          => Jump PhaseHandle
          -> PhaseM a (FieldRec l) ()
onSuccess next =
  modify Local $ rlens fldDispatch . rfield . successPhase .~ next

-- | Add a phase to wait for
waitFor :: forall a l. (FldDispatch ∈ l)
         => Jump PhaseHandle
         -> PhaseM a (FieldRec l) ()
waitFor p = modify Local $ rlens fldDispatch . rfield . waitPhases %~
  (p :)

-- | Announce that this phase has finished waiting and remove from dispatch.
waitDone :: forall a l. (FldDispatch ∈ l)
         => Jump PhaseHandle
         -> PhaseM a (FieldRec l) ()
waitDone p = modify Local $ rlens fldDispatch . rfield . waitPhases %~
  (delete p)

mkDispatcher :: forall a l. (FldDispatch ∈ l)
             => RuleM a (FieldRec l) (Jump PhaseHandle)
mkDispatcher = do
  dispatcher <- phaseHandle "dispatcher::dispatcher"

  directly dispatcher $ do
    dinfo <- gets Local (^. rlens fldDispatch . rfield)
    phaseLog "dispatcher:awaiting" $ show (dinfo ^. waitPhases)
    phaseLog "dispatcher:onSuccess" $ show (dinfo ^. successPhase)
    phaseLog "dispatcher:onTimeout" $ show (dinfo ^. timeoutPhase)
    case dinfo ^. waitPhases of
      [] -> continue $ dinfo ^. successPhase
      xs -> switch (xs ++ (maybe [] ((:[]) . uncurry timeout)
                                    $ dinfo ^. timeoutPhase))

  return dispatcher
