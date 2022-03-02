{-# LANGUAGE GADTs               #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
--
module Network.CEP.SM
  ( -- * SM
    SM(..)
  , newSM
    -- * Feeding input
  , SMIn(..)
    -- * Reading results
  , SMResult(..)
  , SMState(..)
  ) where

import           Control.Distributed.Process
import           Control.Lens
import           Control.Monad.Trans (lift)
import qualified Control.Monad.Trans.State.Strict as State
import           Data.Foldable (for_)
import           Data.Map.Strict (Map, (!))
import           Data.Typeable
import           Debug.Trace (traceMarkerIO)

import           Network.CEP.Buffer
import           Network.CEP.Execution
import qualified Network.CEP.Log as Log
import           Network.CEP.Phase
import           Network.CEP.Types

newtype SM app = SM { runSM :: forall a. SMIn app a -> a }

-- | Input to 'SM' (Stack Machine).
--
-- 'SMExecute': Execute a single step of the 'SM'. Where subscribers
-- is the list of the current 'Subscribers' and app is current Global
-- State.
--
-- 'SMMessage': Feed a new message into state machine.
data SMIn app a where
    SMExecute :: Application app
              => Subscribers
              -> SMIn app ( State.StateT
                              (EngineState (GlobalState app))
                              Process [(SMResult, SM app)]
                          )
    SMMessage :: TypeInfo -> Message -> SMIn app (SM app)

-- | Create CEP state machine
newSM :: forall app l. Application app
      => RuleKey
      -> Jump (Phase app l)              -- ^ Initial phase.
      -> String                          -- ^ Rule name.
      -> Map String (Jump (Phase app l)) -- ^ Set of possible phases.
      -> Buffer                          -- ^ Initial buffer.
      -> l                               -- ^ Initial local state.
      -> Maybe (SMLogger app l)          -- ^ Logger.
      -> SM app
newSM key startPhase rn ps initialBuffer initialL logger =
    SM $ bootstrap initialBuffer
  where
    bootstrap :: Buffer -> SMIn app a -> a
    bootstrap b (SMMessage (TypeInfo _ (_ :: Proxy e)) msg) =
      let Just (a :: e) = runIdentity $ unwrapMessage msg
      in SM (bootstrap (bufferInsert a b))
    bootstrap b i@(SMExecute _) = do
        ph <- jumpEmitTimeout key startPhase
        sm <- nextSmId
        interpretInput sm initialL b [ph] i

    interpretInput :: SMId
                   -> l
                   -> Buffer
                   -> [Jump (Phase app l)]
                   -> SMIn app a
                   -> a
    interpretInput smid l b phs (SMMessage (TypeInfo _ (_ :: Proxy e)) msg) =
      let Just (a :: e) = runIdentity $ unwrapMessage msg
      in SM (interpretInput smid l (bufferInsert a b) phs)
    interpretInput smid l b phs (SMExecute subs) =
      executeStack logger subs smid l b id id phs

    -- We use '[Phase app l] -> [Phase app l]' in order to recreate stack in
    -- case if no branch have fired, this is needed only in presence of
    -- stop. In there is no `stop` keyword in a branches then we could
    -- live without it, and have more structure sharing.
    executeStack :: Maybe (SMLogger app l)
                 -> Subscribers
                 -> SMId
                 -> l
                 -> Buffer
                 -> ([Jump (Phase app l)] -> [Jump (Phase app l)]) -- ^ Stack recreation.
                 -> ([ExecutionInfo] -> [ExecutionInfo]) -- ^ Gather execution info.
                 -> [Jump (Phase app l)]
                 -> State.StateT (EngineState (GlobalState app)) Process [(SMResult, SM app)]
    executeStack _ _ smid l b f info [] = case f [] of
      []  -> return [stoppedSM info smid]
      phs -> return [(SMResult smid SMSuspended (info [])
                    , SM $ interpretInput smid l b phs)]
    executeStack logs subs smid l b f info (jmp:phs) = do
        res <- jumpApplyTime key jmp
        case res of
          Left nxt_jmp ->
            let i = FailExe (jumpPhaseName jmp) SuspendExe b
            in executeStack logs subs smid l b (f . (nxt_jmp:)) (info . (i:)) phs
          Right ph -> do
            m <- runPhase rn subs logs smid l b ph
            concat <$> traverse (next ph) m
      where
        -- Interpret results of the state machine execution. We have phase that was executed
        -- it's Id, resulting buffer and out - information about how rule have finished
        next ph (idm, (buffer, out)) =
            case out of
              -- Rule completed successfully, but it's ended, i.e. there are no next steps.
              --
              -- Currect semantics specifies that in such case rule have to be restarted from
              -- beginning. This includes:
              --
              --   1. emit Log.Restart event
              --   2. set rule state to initial one
              --   3. keep current buffer.
              --
              SM_Complete _ [] -> do
                -- This branch is required if we want to rule to be restarted
                -- once it finishes "normally".
                liftIO $ traceMarkerIO $ "cep: complete0: " ++ pname
                let result = SMResult idm SMFinished (info [SuccessExe pname b buffer])
                g <- use engineStateGlobal
                for_ logger $ \lf ->
                  lift $ (sml_logger lf) (Log.Event (Log.Location (_ruleKeyName key) (getSMId idm) pname)
                                                    (Log.Restart (Log.RestartInfo (jumpPhaseName startPhase))))
                                         g

                fin_phs <- jumpEmitTimeout key startPhase
                return [(result, SM $ interpretInput idm initialL buffer [fin_phs])]
              -- Rule completed sucessfully and there are next steps to run. In this case
              -- we continue.
              SM_Complete l' phs' -> do
                liftIO $ traceMarkerIO $ "cep: complete: " ++ pname
                let result = SMResult idm SMRunning (info [SuccessExe pname b buffer])
                fin_phs <- traverse (jumpEmitTimeout key) $ fmap mkPhase phs'
                return [(result, SM $ interpretInput idm l' buffer fin_phs)]
              -- Rule is suspended. We continue execution in order to find next phase that will
              -- terminate.
              SM_Suspend -> executeStack logs subs smid l b
                                (f.(normalJump ph:))
                                (info . ((FailExe pname SuspendExe b):))
                                phs
              -- Rule is stopped. We continue execution in order to find next phase that will
              -- terminate.
              SM_Stop -> executeStack logs subs smid l b
                             f
                             (info . ((FailExe pname StopExe b):))
                             phs
          where
            pname = _phName ph

    mkPhase :: Jump PhaseHandle -> Jump (Phase app l)
    mkPhase jmp = jumpBaseOn jmp (ps ! jumpPhaseHandle jmp)

    stoppedSM mkInfo smid
      = ( SMResult smid SMStopped (mkInfo [])
        , SM $ error "trying to run stack that was stopped")
