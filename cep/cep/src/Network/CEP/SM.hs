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

import Data.Typeable

import qualified Control.Monad.Trans.State.Strict as State
import           Control.Distributed.Process
import           Control.Lens
import qualified Data.Map.Strict as M

import Network.CEP.Buffer
import Network.CEP.Execution
import Network.CEP.Phase
import Network.CEP.Types

import Debug.Trace

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
      -> Jump (Phase app l)                -- ^ Initial phase.
      -> String                          -- ^ Rule name.
      -> M.Map String (Jump (Phase app l)) -- ^ Set of possible phases.
      -> Buffer                          -- ^ Initial buffer.
      -> l                               -- ^ Initial local state.
      -> Maybe (SMLogger app l)          -- ^ Logger
      -> SM app
newSM key startPhase rn ps initialBuffer initialL logger =
    SM $ bootstrap initialBuffer
  where
    bootstrap :: Buffer -> SMIn app a -> a
    bootstrap b (SMMessage (TypeInfo _ (_ :: Proxy e)) msg) =
      let Just (a :: e) = runIdentity $ unwrapMessage msg in
      SM (bootstrap (bufferInsert a b))
    bootstrap b i@(SMExecute _) = do
        ph <- jumpEmitTimeout key startPhase
        EngineState (SMId idx) t g p <- State.get
        State.put $ EngineState (SMId (idx+1)) t g p
        interpretInput (SMId idx) initialL b [ph] i

    interpretInput :: SMId
                   -> l
                   -> Buffer
                   -> [Jump (Phase app l)]
                   -> SMIn app a
                   -> a
    interpretInput smId' l b phs (SMMessage (TypeInfo _ (_::Proxy e)) msg) =
      let Just (a :: e) = runIdentity $ unwrapMessage msg in
      SM (interpretInput smId' l (bufferInsert a b) phs)
    interpretInput smId' l b phs (SMExecute subs) =
      executeStack logger subs smId' l b id id phs

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
    executeStack _ _ smId' l b f info [] = case f [] of
      [] -> return [stoppedSM info smId']
      ph -> return [(SMResult smId' SMSuspended (info [])
                    , SM $ interpretInput smId' l b ph)]
    executeStack logs subs smId' l b f info (jmp:phs) = do
        res <- jumpApplyTime key jmp
        case res of
          Left nxt_jmp ->
            let i   = FailExe (jumpPhaseName jmp) SuspendExe b in
            executeStack logs subs smId' l b (f . (nxt_jmp:)) (info . (i:)) phs
          Right ph -> do
            m <- runPhase rn subs logs smId' l b ph
            concat <$> traverse (next ph) m
      where
        next ph (idm, (buffer, out)) =
            case out of
              SM_Complete l' newPhases -> do
                liftIO $ traceMarkerIO $ "cep: complete: " ++ pname
                let (result, phs') = case newPhases of
                           -- This branch is required if we want to rule to be restarted
                          -- once it finishes "normally".
                          []  -> ( SMResult idm SMFinished
                                            (info [SuccessExe pname b buffer])
                                 , [startPhase]
                                 )
                          ph' -> let xs = fmap mkPhase ph'
                                 in ( SMResult idm SMRunning
                                               (info [SuccessExe pname b buffer])
                                    , xs)
                fin_phs <- traverse (jumpEmitTimeout key) phs'
                return [(result, SM $ interpretInput idm l' buffer fin_phs)]
              SM_Suspend -> executeStack logs subs smId' l b
                                (f.(normalJump ph:))
                                (info . ((FailExe pname SuspendExe b):))
                                phs
              SM_Stop -> executeStack logs subs smId' l b
                             f
                             (info . ((FailExe pname StopExe b):))
                             phs
          where
            pname = _phName ph

    mkPhase :: Jump PhaseHandle -> Jump (Phase app l)
    mkPhase jmp = jumpBaseOn jmp (ps M.! jumpPhaseHandle jmp)

    stoppedSM mkInfo smId'
      = ( SMResult smId' SMStopped (mkInfo [])
        , SM $ error "trying to run stack that was stopped")
