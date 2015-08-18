{-# LANGUAGE GADTs      #-}
{-# LANGUAGE Rank2Types #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module Network.CEP.SM where

import Data.Foldable (for_)
import Data.Maybe
import Data.Typeable

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Monad.Operational
import qualified Data.MultiMap as MM
import qualified Data.Sequence as S

import Network.CEP.Buffer
import Network.CEP.Types

data PhaseBufAction = CopyThatBuffer Buffer | CreateNewBuffer

data SpawnSM g l = SpawnSM PhaseBufAction l (PhaseM g l ())

-- | Input type to a state machine.
data SM_In g l a where
    PushMsg :: Typeable m => m -> SM_In g l ()
    -- ^ Push a new message into the state machine's buffer.
    Execute :: Subscribers -> g -> (Phase g l) -> SM_In g l a
    -- ^ Execute the next phase of a state machine.

-- | Output type of a state machine.
data SM_Out g l where
    SM_Complete :: g -> l -> [SpawnSM g l] -> [PhaseHandle] -> Maybe SMLogs -> SM_Out g l
    -- ^ The phase has finished processing, yielding a new set of SMs to run.
    SM_Suspend  :: Maybe SMLogs -> SM_Out g l
    -- ^ The phase has stopped temporarily, and should be invoked again.
    SM_Stop     :: Maybe SMLogs -> SM_Out g l
    -- ^ The phase has stopped, and should not be executed again.
    SM_Unit     :: SM_Out g l
    -- ^ The SM has successfully accepted a pushed message.

smLocalState :: SM_Out g l -> Maybe l
smLocalState (SM_Complete _ l _ _ _) = Just l
smLocalState _                       = Nothing

-- | Notifies every subscriber that a message those are interested in has
--   arrived.
notifySubscribers :: Serializable a => Subscribers -> a -> Process ()
notifySubscribers subs a = do
    self <- getSelfPid
    for_ (MM.lookup (fingerprint a) subs) $ \pid ->
      usend pid (Published a self)

-- | Phase Mealy finite state machine.
newtype SM g l =
    SM { unSM :: forall a. SM_In g l a
              -> Process (Buffer, Buffer, SM_Out g l, SM g l) }

newSM :: Buffer -> Maybe SMLogs -> l -> SM g l
newSM buf logs l = SM $ runPhase buf logs l

-- | Simple product type used as a result of message buffer extraction.
data Extraction b =
    Extraction
    { _extractBuf :: !Buffer
      -- ^ The buffer we have minus the elements we extracted from it.
    , _extractMsg :: !b
      -- ^ The extracted message.
    }

-- | Extracts messages from a 'Buffer' based based on 'PhaseType' need.
extractMsg :: (Serializable a, Serializable b)
           => PhaseType g l a b
           -> g
           -> l
           -> Buffer
           -> Process (Maybe (Extraction b))
extractMsg typ g l buf =
    case typ of
      PhaseWire _  -> error "phaseWire: not implemented yet"
      PhaseMatch p -> extractMatchMsg p g l buf
      PhaseNone    -> extractNormalMsg (Proxy :: Proxy a) buf
      PhaseSeq _ s -> extractSeqMsg s buf

-- -- | Extracts messages from a Netwire wire.
-- extractWireMsg :: forall a b. (Serializable a, Serializable b)
--                => TimeSession
--                -> CEPWire a b
--                -> Buffer
--                -> Process (Maybe (Extraction b))
-- extractWireMsg = error "wire extraction: not implemented yet"

-- | Extracts a message that satifies the predicate. If it does, it's passed
--   to an effectful callback.
extractMatchMsg :: Serializable a
                => (a -> g -> l -> Process (Maybe b))
                -> g
                -> l
                -> Buffer
                -> Process (Maybe (Extraction b))
extractMatchMsg p g l buf = go (-1)
  where
    go lastIdx =
        case bufferGetWithIndex lastIdx buf of
          (Just (newIdx, a), newBuf) -> do
            res <- p a g l
            case res of
              Nothing -> go newIdx
              Just b  ->
                let ext = Extraction
                          { _extractBuf = newBuf
                          , _extractMsg = b
                          } in
                return $ Just ext
          _ -> return Nothing

-- | Extracts a simple message from the 'Buffer'.
extractNormalMsg :: forall a. Serializable a
                 => Proxy a
                 -> Buffer
                 -> Process (Maybe (Extraction a))
extractNormalMsg _ buf =
    case bufferGet buf of
      (Just a, buf') ->
        let ext = Extraction
                  { _extractBuf = buf'
                  , _extractMsg = a
                  } in
        return $ Just ext
      _ -> return Nothing

-- | Extracts a message based on messages coming sequentially.
extractSeqMsg :: PhaseStep a b -> Buffer -> Process (Maybe (Extraction b))
extractSeqMsg s sbuf = go (-1) sbuf s
  where
    go lastIdx buf (Await k) =
        case bufferGetWithIndex lastIdx buf of
          (Just (idx, i), buf') -> go idx buf' $ k i
          _                     -> return Nothing
    go _ buf (Emit b) =
        let ext = Extraction
                  { _extractBuf = buf
                  , _extractMsg = b
                  } in
        return $ Just ext
    go _ _ _ = return Nothing


-- | Execute a single phase of a 'Phase' state machine.
--
--   If it's 'DirectCall' 'Phase', it's run
--   directly. If it's 'ContCall' one, we make sure we can satisfy its
--   dependency. Otherwise, we 'Suspend' that phase.
runPhase :: Buffer
         -> Maybe SMLogs
         -> l
         -> SM_In g l a
         -> Process (Buffer, Buffer, SM_Out g l, SM g l)
runPhase buf logs l (PushMsg msg) =
    let new_buf = bufferInsert msg buf in
    return (buf, new_buf, SM_Unit, SM $ runPhase new_buf logs l)
runPhase buf logs l (Execute subs g ph) =
    case _phCall ph of
      DirectCall action -> do
        (new_buf, out) <- runPhaseM (_phName ph) subs buf g l [] logs action
        let final_buf =
              case out of
                SM_Suspend{} -> buf
                SM_Stop{}    -> buf
                _            -> new_buf
            nxt_l = fromMaybe l $ smLocalState out
        return (buf, final_buf, out, SM $ runPhase final_buf logs nxt_l)
      ContCall tpe k -> do
        res <- extractMsg tpe g l buf
        case res of
          Just (Extraction new_buf b) -> do
            notifySubscribers subs b
            let name = _phName ph
            (lastest_buf, out) <- runPhaseM name subs new_buf g l [] logs (k b)
            let final_buf =
                  case out of
                    SM_Suspend{} -> buf
                    SM_Stop{}    -> buf
                    _            -> lastest_buf
                nxt_l = fromMaybe l $ smLocalState out
            case out of
              SM_Complete{} -> notifySubscribers subs b
              _             -> return ()
            return (buf, final_buf, out, SM $ runPhase final_buf logs nxt_l)
          Nothing -> return (buf, buf, SM_Suspend Nothing, SM $ runPhase buf logs l)

-- | 'PhaseM' state machine execution main loop. Runs a single phase until
--   there are no more instructions, or until we receive a terminating
--   instruction.
--   Terminating instructions are:
--   - Continue
--   - Stop
--   - Suspend
runPhaseM :: String
          -> Subscribers
          -> Buffer
          -> g
          -> l
          -> [SpawnSM g l]
          -> Maybe SMLogs
          -> PhaseM g l ()
          -> Process (Buffer, SM_Out g l)
runPhaseM pname subs buf g l stk logs action = viewT action >>= go
  where
    go (Return _) = return (buf, SM_Complete g l (reverse stk) [] logs)
    go (Continue ph :>>= _) = return (buf, SM_Complete g l (reverse stk) [ph] logs)
    go (Get Global :>>= k) = runPhaseM pname subs buf g l stk logs $ k g
    go (Get Local :>>= k) = runPhaseM pname subs buf g l stk logs $ k l
    go (Put Global s :>>= k) = runPhaseM pname subs buf s l stk logs $ k ()
    go (Put Local l' :>>= k) = runPhaseM pname subs buf g l' stk logs $ k ()
    go (Stop :>>= _) = return (buf, SM_Stop logs)
    go (Fork typ naction :>>= k) =
        let bufAction =
              case typ of
                NoBuffer   -> CreateNewBuffer
                CopyBuffer -> CopyThatBuffer buf

            ssm = SpawnSM bufAction l naction in
        runPhaseM pname subs buf g l (ssm : stk) logs $ k ()
    go (Lift m :>>= k) = do
        a <- m
        runPhaseM pname subs buf g l stk logs $ k a
    go (Suspend :>>= _) = return (buf, SM_Suspend logs)
    go (Publish e :>>= k) = do
        notifySubscribers subs e
        runPhaseM pname subs buf g l stk logs $ k ()
    go (PhaseLog ctx lg :>>= k) =
        let new_logs = fmap (S.|> (pname,ctx,lg)) logs in
        runPhaseM pname subs buf g l stk new_logs $ k ()
    go (Switch xs :>>= _) = return (buf, SM_Complete g l (reverse stk) xs logs)
    go (Peek idx :>>= k) = do
        case bufferPeek idx buf of
          Nothing -> return (buf, SM_Suspend logs)
          Just r  -> runPhaseM pname subs buf g l stk logs $ k r
    go (Shift idx :>>= k) =
        case bufferGetWithIndex idx buf of
          (Nothing, _)   -> return (buf, SM_Suspend logs)
          (Just r, buf') -> runPhaseM pname subs buf' g l stk logs $ k r
