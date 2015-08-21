{-# LANGUAGE GADTs               #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module Network.CEP.SM
  ( -- * SM
    SM(..)
  , newSM
    -- * Feeding input
  , SMIn(..)
    -- * Reading results
  , SMResult(..)
  , extractLogs
  ) where

import Data.Traversable (for)
import Data.Traversable.Lib
import Data.Foldable (toList)
import Data.Typeable


import           Control.Distributed.Process
import qualified Data.Map.Strict as M

import Network.CEP.Buffer
-- import Network.CEP.Execution
import Network.CEP.Phase
import Network.CEP.Types

{-
data StackOut =
    StackOut
    { _soExeReport :: !ExecutionReport      -- ^ Execution report.
    , _soResult    :: !StackResult          -- ^ Result of running a stack.
    , _soLogs      :: [Logs]                -- ^ Logs.
    , _soStopped   :: !Bool                 -- ^ Flag that shows if SM should be removed from the queue.
    , _soSuspended :: !Bool                 -- ^ If stack is suspended or could run.
    }
    -}

newtype SM g = SM { runSM :: forall a. SMIn g a -> a }

data SMResult = SMRunning  (Maybe Logs)
              -- ^ 'SM' continues its run and could be executed.
              | SMFinished (Maybe Logs)
              -- ^ 'SM' finished evaluation in this case SM was started from beginning.
              | SMSuspended
              -- ^ 'SM' could not do a step forward until a new message will be fed.
              | SMStopped
              -- ^ 'SM' call 'stop' and should be removed from the execution.

extractLogs :: SMResult -> Maybe Logs
extractLogs (SMRunning  l) = l
extractLogs (SMFinished l) = l
extractLogs _              = Nothing


-- | Input to 'SM' (Stack Machine).
data SMIn g a where
    SMExecute :: Subscribers -> g -> SMIn g (Process (g, [(SMResult, SM g)]))
    -- ^ Execute a single step of the 'SM'. Where subscribers is the list of
    -- the current 'Subscribers' and g is current Global State.
    SMMessage :: Monad m => TypeInfo -> Message -> SMIn g (m (SM g))
    -- ^ Feed a new message into state machine.

-- | Create CEP state machine
newSM :: forall g l .
         Phase g l                  -- ^ Initial phase.
      -> String                     -- ^ Rule name.
      -> Maybe SMLogs               -- ^ Rule logger.
      -> M.Map String (Phase g l)   -- ^ Set of possible phases.
      -> Buffer                     -- ^ Initial buffer.
      -> l                          -- ^ Initial local state.
      -> SM g
newSM startPhase rn logs ps initialBuffer initialL =
    SM $ interpretInput initialL initialBuffer [startPhase]
  where
    interpretInput :: l -> Buffer -> [Phase g l] -> (SMIn g a) -> a
    interpretInput l b phs (SMMessage (TypeInfo _ (_::Proxy e)) msg) = do
      Just (a :: e) <- unwrapMessage msg
      return $ SM (interpretInput l (bufferInsert a b) phs)
    interpretInput l b phs (SMExecute subs g) =
      executeStack subs g l b id phs

    -- We use '[Phase g l] -> [Phase g l]' in order to recreate stack in
    -- case if no branch have fired, this is needed only in presence of
    -- stop. In there is no `stop` keyword in a branches then we could
    -- live without it, and have more structure sharing.
    executeStack :: Subscribers
                 -> g
                 -> l
                 -> Buffer
                 -> ([Phase g l] -> [Phase g l])
                 -> [Phase g l]
                 -> Process (g,[(SMResult, SM g)])
    executeStack _ g l b f [] = case f [] of
                               [] -> return (g, [stoppedSM])
                               ph -> return (g, [(SMSuspended, SM $ interpretInput l b ph)])
    executeStack subs g l b f (ph:phs) = do
        (g',m) <- runPhase subs logs g l b ph
        fmap concat <$> mapAccumLM next g' m
      where
        next gNext (buffer, out) =
         case out of
           SM_Complete l' newPhases rlogs -> do
              (result, phs') <- case newPhases of
                 -- This branch is required if we want to rule to be restarted
                 -- once it finishes "normally".
                 []  -> return (SMFinished (mkLogs rn rlogs), [startPhase])
                 ph' -> do xs <- for ph' mkPhase
                           return (SMRunning (mkLogs rn rlogs), xs)
              return (gNext, [(result, SM $ interpretInput l' buffer phs')])
           SM_Suspend  _ -> executeStack subs gNext l b (f.(ph:)) phs
           SM_Stop     _ -> executeStack subs gNext l b (f) phs

    mkPhase :: Monad m => PhaseHandle -> m (Phase g l)
    mkPhase h = case M.lookup (_phHandle h) ps of
      Just ph -> return ph
      Nothing -> fail $ "impossible: rule " ++ rn
                      ++ " doesn't have a phase named " ++ _phHandle h

    stoppedSM = (SMStopped, SM $ error "trying to run stack that was stopped")

mkLogs :: String -> Maybe SMLogs -> Maybe Logs
mkLogs pn = fmap (Logs pn . toList)
