{-# LANGUAGE CPP #-} -- XXX DELETEME
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-} -- XXX DELETEME
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

import           Data.Typeable
import           Control.Monad.Trans (lift)
import qualified Control.Monad.Trans.State.Strict as State
import           Control.Distributed.Process
-- XXX DELETEME <<<<<<<
import           GHC.Generics (Generic)
import           Control.Distributed.Process.Internal.Types (isEncoded)
import           Data.UUID (UUID)
import           Unsafe.Coerce (unsafeCoerce)
-- XXX >>>>>>>
import           Control.Lens
import qualified Data.Map.Strict as M

import           Network.CEP.Buffer
import           Network.CEP.Execution
import           Network.CEP.Phase
import           Network.CEP.Types
import qualified Network.CEP.Log as Log

import           Data.Foldable (for_)
import           Debug.Trace

-- XXX DELETEME <<<<<<<
showXXX :: String -> Integer -> String -> String
showXXX func line rest = "XXX [" ++ func ++ ":" ++ show line ++ "]" ++ rest'
  where
    rest' = if null rest then "" else ' ':rest
-- XXX DELETEME >>>>>>>

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
newSM key _ rn _ _ _ _ | trace (showXXX "newSM" __LINE__ $ "key=" ++ show key ++ " rn=" ++ rn) False = undefined
newSM key startPhase rn ps initialBuffer initialL logger =
    trace (showXXX "newSM" __LINE__ $ "rn=" ++ rn) $ SM $ bootstrap initialBuffer
  where
    bootstrap :: Buffer -> SMIn app a -> a
    bootstrap b (SMMessage (TypeInfo _ (_ :: Proxy e)) msg) =
      let Just (a :: e) = runIdentity $ unwrapMessage msg in
      SM (bootstrap (bufferInsert a b))
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
    -- XXX DELETEME <<<<<<<
    interpretInput smId' l b phs (SMMessage (TypeInfo _ (_::Proxy e)) msg) | False =
      let Just (a :: e) = runIdentity $
            trace (showXXX "newSM.interpretInput" __LINE__ $ "rn=" ++ rn ++ " smId=" ++ show smId'
                   ++ (if show (typeOf a) == "HAEvent MeroFromSvc"
                       then " a=<" ++ show (let x = unsafeCoerce a :: HAEventXXX () in eventId x) ++ ">"
                       else " a :: " ++ show (typeOf a))
                   ++ " msg=" ++ (if isEncoded msg
                                  then "<EncodedMessage>"
                                  else show msg))
            $ unwrapMessage msg
      in SM (interpretInput smId' l (bufferInsert a b) phs)
    -- XXX DELETEME >>>>>>>
    interpretInput smId' l b phs (SMMessage (TypeInfo _ (_::Proxy e)) msg) =
      let Just (a :: e) = runIdentity $ unwrapMessage msg
      in trace (showXXX "newSM.interpretInput" __LINE__ $ "rn=" ++ rn ++ " smId=" ++ show smId' ++ "; SMMessage") $ SM (interpretInput smId' l (bufferInsert a b) phs)
    interpretInput smId' l b phs (SMExecute subs) =
      trace (showXXX "newSM.interpretInput" __LINE__ $ "rn=" ++ rn ++ " smId=" ++ show smId' ++ "; SMExecute") $ executeStack logger subs smId' l b id id phs

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
            let i = FailExe (jumpPhaseName jmp) SuspendExe b
            in trace (showXXX "newSM.executeStack" __LINE__ $ "rn=" ++ rn ++ " smId=" ++ show smId' ++ " i=" ++ show i) $ executeStack logs subs smId' l b (f . (nxt_jmp:)) (info . (i:)) phs
          Right ph -> do
            m <- trace (showXXX "newSM.executeStack" __LINE__ $ "rn=" ++ rn ++ " smId=" ++ show smId') $ runPhase rn subs logs smId' l b ph
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
                liftIO $ traceMarkerIO $ "cep: complete: " ++ pname
                let result = SMResult idm SMFinished (info [SuccessExe pname b buffer])
                g <- use engineStateGlobal
                for_ logger $ \lf ->
                  lift $ (sml_logger lf) (Log.Event (Log.Location (_ruleKeyName key) (getSMId idm) pname)
                                                    (Log.Restart (Log.RestartInfo (jumpPhaseName startPhase))))
                                         g

                fin_phs <- jumpEmitTimeout key startPhase
                traceM $ showXXX "newSM.executeStack.next" __LINE__ $ "pname=" ++ pname
                return [(result, SM $ interpretInput idm initialL buffer [fin_phs])]
              -- Rule completed sucessfully and there are next steps to run. In this case
              -- we continue.
              SM_Complete l' ph' -> do
                liftIO $ traceMarkerIO $ "cep: complete: " ++ pname
                let result = SMResult idm SMRunning (info [SuccessExe pname b buffer])
                fin_phs <- traverse (jumpEmitTimeout key) $ fmap mkPhase ph'
                traceM $ showXXX "newSM.executeStack.next" __LINE__ $ "pname=" ++ pname
                return [(result, SM $ interpretInput idm l' buffer fin_phs)]
              -- Rule is suspended. We continue execution in order to find next phase that will
              -- terminate.
              SM_Suspend -> trace (showXXX "newSM.executeStack.next" __LINE__ $ "pname=" ++ pname) $ executeStack logs subs smId' l b
                                (f.(normalJump ph:))
                                (info . ((FailExe pname SuspendExe b):))
                                phs
              -- Rule is stopped. We continue execution in order to find next phase that will
              -- terminate.
              SM_Stop -> trace (showXXX "newSM.executeStack.next" __LINE__ $ "pname=" ++ pname) $ executeStack logs subs smId' l b
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

-- XXX DELETEME
data HAEventXXX a = HAEventXXX
    { eventId      :: {-# UNPACK #-} !UUID
    , _eventPayload :: a
    } deriving (Generic, Typeable, Show)
