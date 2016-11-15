{-# LANGUAGE GADTs               #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
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

import Data.Foldable (toList)
import Data.Typeable

import           Control.Monad.Trans
import qualified Control.Monad.Trans.State.Strict as State
import           Control.Distributed.Process
import           Control.Lens
import qualified Data.Map.Strict as M

import Network.CEP.Buffer
import Network.CEP.Execution
import Network.CEP.Phase
import Network.CEP.Types

import Debug.Trace

newtype SM g = SM { runSM :: forall a. SMIn g a -> a }

-- | Input to 'SM' (Stack Machine).
--
-- 'SMExecute': Execute a single step of the 'SM'. Where subscribers
-- is the list of the current 'Subscribers' and g is current Global
-- State.
--
-- 'SMMessage': Feed a new message into state machine.
data SMIn g a where
    SMExecute :: Maybe SMLogs
              -> Subscribers
              -> SMIn g (State.StateT (EngineState g) Process [(SMResult, SM g)])
    SMMessage :: TypeInfo -> Message -> SMIn g (SM g)

-- | Create CEP state machine
newSM :: forall g l. RuleKey
      -> Jump (Phase g l)                -- ^ Initial phase.
      -> String                          -- ^ Rule name.
      -> M.Map String (Jump (Phase g l)) -- ^ Set of possible phases.
      -> Buffer                          -- ^ Initial buffer.
      -> l                               -- ^ Initial local state.
      -> SM g
newSM key startPhase rn ps initialBuffer initialL =
    SM $ bootstrap initialBuffer
  where
    bootstrap :: Buffer -> SMIn g a -> a
    bootstrap b (SMMessage (TypeInfo _ (_ :: Proxy e)) msg) =
      let Just (a :: e) = runIdentity $ unwrapMessage msg in
      SM (bootstrap (bufferInsert a b))
    bootstrap b i@(SMExecute _ _) = do
        ph <- jumpEmitTimeout key startPhase
        EngineState (SMId idx) t g p <- State.get
        State.put $ EngineState (SMId (idx+1)) t g p
        interpretInput (SMId idx) initialL b [ph] i

    interpretInput :: SMId
                   -> l
                   -> Buffer
                   -> [Jump (Phase g l)]
                   -> SMIn g a
                   -> a
    interpretInput smId' l b phs (SMMessage (TypeInfo _ (_::Proxy e)) msg) =
      let Just (a :: e) = runIdentity $ unwrapMessage msg in
      SM (interpretInput smId' l (bufferInsert a b) phs)
    interpretInput smId' l b phs (SMExecute logs subs) =
      executeStack logs subs smId' l b id id phs

    -- We use '[Phase g l] -> [Phase g l]' in order to recreate stack in
    -- case if no branch have fired, this is needed only in presence of
    -- stop. In there is no `stop` keyword in a branches then we could
    -- live without it, and have more structure sharing.
    executeStack :: Maybe SMLogs
                 -> Subscribers
                 -> SMId
                 -> l
                 -> Buffer
                 -> ([Jump (Phase g l)] -> [Jump (Phase g l)]) -- ^ Stack recreation.
                 -> ([ExecutionInfo] -> [ExecutionInfo]) -- ^ Gather execution info.
                 -> [Jump (Phase g l)]
                 -> State.StateT (EngineState g) Process [(SMResult, SM g)]
    executeStack _ _ smId' l b f info [] = case f [] of
      [] -> return [stoppedSM info smId']
      ph -> return [(SMResult smId' SMSuspended (info []) Nothing
                    , SM $ interpretInput smId' l b ph)]
    executeStack logs subs smId' l b f info (jmp:phs) = do
        res <- jumpApplyTime key jmp
        case res of
          Left nxt_jmp ->
            let i   = FailExe (jumpPhaseName jmp) SuspendExe b in
            executeStack logs subs smId' l b (f . (nxt_jmp:)) (info . (i:)) phs
          Right ph -> do
            m <- runPhase subs logs smId' l b ph
            concat <$> traverse (next ph) m
      where
        next ph (idm, (buffer, out)) =
            case out of
              SM_Complete l' newPhases rlogs -> do
                liftIO $ traceMarkerIO $ "cep: complete: " ++ pname
                let (result, phs') = case newPhases of
                           -- This branch is required if we want to rule to be restarted
                          -- once it finishes "normally".
                          []  -> ( SMResult idm SMFinished
                                            (info [SuccessExe pname b buffer])
                                            (mkLogs rn rlogs)
                                 , [startPhase]
                                 )
                          ph' -> let xs = fmap mkPhase ph'
                                 in ( SMResult idm SMRunning
                                               (info [SuccessExe pname b buffer])
                                               (mkLogs rn rlogs)
                                    , xs)
                fin_phs <- traverse (jumpEmitTimeout key) phs'
                return [(result, SM $ interpretInput idm l' buffer fin_phs)]
              SM_Suspend _ -> executeStack logs subs smId' l b
                                (f.(normalJump ph:))
                                (info . ((FailExe pname SuspendExe b):))
                                phs
              SM_Stop _ -> executeStack logs subs smId' l b
                             f
                             (info . ((FailExe pname StopExe b):))
                             phs
          where
            pname = _phName ph

    mkPhase :: Jump PhaseHandle -> Jump (Phase g l)
    mkPhase jmp = jumpBaseOn jmp (ps M.! jumpPhaseHandle jmp)

    stoppedSM mkInfo smId'
      = ( SMResult smId' SMStopped (mkInfo []) Nothing
        , SM $ error "trying to run stack that was stopped")

mkLogs :: String -> Maybe SMLogs -> Maybe Logs
mkLogs pn = fmap (Logs pn . toList)
