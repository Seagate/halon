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

import qualified Control.Monad.State.Strict as State
import           Control.Distributed.Process
import qualified Data.Map.Strict as M

import Network.CEP.Buffer
import Network.CEP.Execution
import Network.CEP.Phase
import Network.CEP.Types

newtype SM g = SM { runSM :: forall a. SMIn g a -> a }

-- | Input to 'SM' (Stack Machine).
data SMIn g a where
    SMExecute :: Maybe SMLogs
              -> Subscribers
              -> g
              -> SMIn g (Process (g, [(SMResult, SM g)]))
    -- ^ Execute a single step of the 'SM'. Where subscribers is the list of
    -- the current 'Subscribers' and g is current Global State.
    SMMessage :: Monad m => TypeInfo -> Message -> SMIn g (m (SM g))
    -- ^ Feed a new message into state machine.

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
    bootstrap b (SMMessage (TypeInfo _ (_ :: Proxy e)) msg) = do
      Just (a :: e) <- unwrapMessage msg
      return $ SM (bootstrap (bufferInsert a b))
    bootstrap b i@(SMExecute _ _ _) = do
        ph <- jumpEmitTimeout key startPhase
        interpretInput initialL b [ph] i

    interpretInput :: l
                   -> Buffer
                   -> [Jump (Phase g l)]
                   -> SMIn g a
                   -> a
    interpretInput l b phs (SMMessage (TypeInfo _ (_::Proxy e)) msg) = do
      Just (a :: e) <- unwrapMessage msg
      return $ SM (interpretInput l (bufferInsert a b) phs)
    interpretInput l b phs (SMExecute logs subs g) =
      executeStack logs subs g l b id id phs

    -- We use '[Phase g l] -> [Phase g l]' in order to recreate stack in
    -- case if no branch have fired, this is needed only in presence of
    -- stop. In there is no `stop` keyword in a branches then we could
    -- live without it, and have more structure sharing.
    executeStack :: Maybe SMLogs
                 -> Subscribers
                 -> g
                 -> l
                 -> Buffer
                 -> ([Jump (Phase g l)] -> [Jump (Phase g l)])
                 -> ([ExecutionInfo] -> [ExecutionInfo])
                 -> [Jump (Phase g l)]
                 -> Process (g, [(SMResult, SM g)])
    executeStack _ _ g l b f info [] = case f [] of
      [] -> return (g, [stoppedSM info])
      ph -> return (g, [(SMResult SMSuspended (info []) Nothing
                        , SM $ interpretInput l b ph)])
    executeStack logs subs g l b f info (jmp:phs) = do
        res <- jumpApplyTime jmp
        case res of
          Left nxt_jmp ->
            let i   = FailExe (jumpPhaseName jmp) SuspendExe b in
            executeStack logs subs g l b (f . (nxt_jmp:)) (info . (i:)) phs
          Right ph -> do
            (g',m) <- runPhase subs logs g l b ph
            fmap concat <$> mapAccumLM (next ph) g' m
      where
        next ph gNext (buffer, out) =
            case out of
              SM_Complete l' newPhases rlogs -> do
                (result, phs') <- case newPhases of
                           -- This branch is required if we want to rule to be restarted
                          -- once it finishes "normally".
                          []  -> return ( SMResult SMFinished
                                                  (info [SuccessExe pname b buffer])
                                                  (mkLogs rn rlogs)
                                        , [startPhase]
                                        )
                          ph' -> do let xs = fmap mkPhase ph'
                                    return ( SMResult SMRunning
                                                      (info [SuccessExe pname b buffer])
                                                      (mkLogs rn rlogs)
                                           , xs)
                fin_phs <- traverse (jumpEmitTimeout key) phs'
                return (gNext, [(result, SM $ interpretInput l' buffer fin_phs)])
              SM_Suspend _ -> executeStack logs subs gNext l b
                                (f.(normalJump ph:))
                                (info . ((FailExe pname SuspendExe b):))
                                phs
              SM_Stop _ -> executeStack logs subs gNext l b
                             f
                             (info . ((FailExe pname StopExe b):))
                             phs
          where
            pname = _phName ph

    mkPhase :: Jump PhaseHandle -> Jump (Phase g l)
    mkPhase jmp = jumpBaseOn jmp (ps M.! jumpPhaseHandle jmp)

    stoppedSM mkInfo
      = ( SMResult SMStopped (mkInfo []) Nothing
        , SM $ error "trying to run stack that was stopped")

mkLogs :: String -> Maybe SMLogs -> Maybe Logs
mkLogs pn = fmap (Logs pn . toList)

-- |The 'mapAccumLM' works like 'Data.Traversable.mapAccumL' but
-- could perform effectfull operations.
mapAccumLM :: (Monad m , Traversable t)
           => (a -> b -> m (a, c))
           -> a
           -> t b
           -> m (a, t c)
mapAccumLM f s t = (\(a,b) -> (b,a)) <$> State.runStateT (traverse go t) s
  where
    go x = do s' <- State.get
              (s'', x') <- State.lift $ f s' x
              State.put s''
              return x'
