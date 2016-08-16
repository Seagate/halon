{-# LANGUAGE GADTs      #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -Wall -Werror #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
module Network.CEP.Phase
  ( runPhase
  , runPhaseM
  , PhaseOut(..)
  ) where

import Data.Foldable (for_)
import Data.Typeable

import           Control.Distributed.Process hiding (try)
import           Control.Distributed.Process.Serializable
import           Control.Monad.Operational
import           Control.Exception (fromException, throwIO)
import qualified Control.Monad.Catch as Catch
import           Control.Monad (unless)
import           Control.Monad.Trans
import qualified Control.Monad.Trans.State.Strict as State
import qualified Data.Map as M
import qualified Data.Sequence as S
import           Data.Traversable (for)
import           Data.Foldable (traverse_)
import           Control.Lens hiding (Index)

import Network.CEP.Buffer
import Network.CEP.Types

-- | 'SM_Complete': The phase has finished processing, yielding a new
-- set of SMs to run.
--
-- 'SM_Suspend': The phase has stopped temporarily, and should be
-- invoked again.
--
-- 'SM_Stop': The phase has stopped, and should not be executed again.
data PhaseOut l where
    SM_Complete :: l -> [Jump PhaseHandle] -> Maybe SMLogs -> PhaseOut l
    SM_Suspend  :: Maybe SMLogs -> PhaseOut l
    SM_Stop     :: Maybe SMLogs -> PhaseOut l

-- | Notifies every subscriber that a message those are interested in has
--   arrived.
notifySubscribers :: Serializable a => Subscribers -> a -> Process ()
notifySubscribers subs a = do
    self <- getSelfPid
    for_ (M.lookup (fingerprint a) subs) $
      traverse_ (\pid -> usend pid (Published a self))

-- | Simple product type used as a result of message buffer extraction.
data Extraction b =
    Extraction
    { _extractBuf :: !Buffer
      -- ^ The buffer we have minus the elements we extracted from it.
    , _extractMsg :: !b
      -- ^ The extracted message.
    , _extractIndex :: !Index
    }

-- | Extracts messages from a 'Buffer' based based on 'PhaseType' need.
extractMsg :: (Serializable a, Serializable b)
           => PhaseType g l a b
           -> l
           -> Buffer
           -> State.StateT g Process (Maybe (Extraction b))
extractMsg typ l buf =
    case typ of
      PhaseWire _  -> error "phaseWire: not implemented yet"
      PhaseMatch p -> extractMatchMsg p l buf
      PhaseNone    -> return $! extractNormalMsg (Proxy :: Proxy a) buf
      PhaseSeq _ s -> return $! extractSeqMsg s buf

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
                -> l
                -> Buffer
                -> State.StateT g Process (Maybe (Extraction b))
extractMatchMsg p l buf = go (-1)
  where
    go lastIdx =
        case bufferGetWithIndex lastIdx buf of
          Just (newIdx, a, newBuf) -> do
            res <- State.get >>= \g -> lift (Catch.mask_ $ trySome $ p a g l)
            case res of
              Left _ -> return Nothing
              Right Nothing  -> go newIdx
              Right (Just b) ->
                let ext = Extraction
                          { _extractBuf = newBuf
                          , _extractMsg = b
                          , _extractIndex = newIdx
                          } in
                return $ Just ext
          _ -> return Nothing
    trySome :: Process a -> Process (Either Catch.SomeException a)
    trySome = Catch.try

-- | Extracts a simple message from the 'Buffer'.
extractNormalMsg :: forall a. Serializable a
                 => Proxy a
                 -> Buffer
                 -> Maybe (Extraction a)
extractNormalMsg _ buf =
    case bufferGet buf of
      Just (newIdx, a, buf') ->
        let ext = Extraction
                  { _extractBuf = buf'
                  , _extractMsg = a
                  , _extractIndex = newIdx
                  } in
        Just ext
      _ -> Nothing

-- | Extracts a message based on messages coming sequentially.
extractSeqMsg :: PhaseStep a b -> Buffer -> Maybe (Extraction b)
extractSeqMsg s sbuf = go (-1) sbuf s
  where
    go lastIdx buf (Await k) =
        case bufferGetWithIndex lastIdx buf of
          Just (idx, i, buf') -> go idx buf' $ k i
          _                   -> Nothing
    go lastIdx buf (Emit b) =
        let ext = Extraction
                  { _extractBuf = buf
                  , _extractMsg = b
                  , _extractIndex = lastIdx
                  } in
        Just ext
    go _ _ _ = Nothing

-- | Execute a single 'Phase'
--
--   If it's 'DirectCall' 'Phase', it's run
--   directly. If it's 'ContCall' one, we make sure we can satisfy its
--   dependency. Otherwise, we 'Suspend' that phase.
--
--   Call is evaluated until a safe point that is either final 'return'
--   or 'suspend' or 'commit'.
runPhase :: Subscribers   -- ^ Subscribers.
         -> Maybe SMLogs  -- ^ Current logger.
         -> SMId          -- ^ State machine id.
         -> l             -- ^ Local state.
         -> Buffer        -- ^ Current buffer.
         -> Phase g l     -- ^ Phase handle to interpret.
         -> State.StateT (EngineState g) Process [(SMId, (Buffer,PhaseOut l))]
runPhase subs logs idm l buf ph =
    case _phCall ph of
      DirectCall action -> runPhaseM pname subs logs idm l Nothing buf action
      ContCall tpe k -> do
        res <- zoom engineStateGlobal $ extractMsg tpe l buf
        case res of
          Just (Extraction new_buf b idx) -> do
            result <- runPhaseM pname subs logs idm l (Just idx) new_buf (k b)
            for_ (snd <$> result) $ \(_,out) ->
              case out of
                SM_Complete{} -> lift $ notifySubscribers subs b
                _             -> return ()
            return result
          Nothing -> return [(idm, (buf, SM_Suspend logs))]
  where
    pname = _phName ph

-- | 'Phase' state machine execution main loop. Runs until its stack is empty
--   except if get a 'Suspend' or 'Stop' instruction.
--   This execution is run goes not switch between forked threads. First parent
--   thread is executed to a safe point, and then child is run.
runPhaseM :: forall g l. String  -- ^ Process name.
          -> Subscribers         -- ^ List of events subscribers.
          -> Maybe SMLogs        -- ^ Logs.
          -> SMId                -- ^ Machine index
          -> l                   -- ^ Local state
          -> Maybe Index         -- ^ Current index.
          -> Buffer              -- ^ Buffer
          -> PhaseM g l ()
          -> State.StateT (EngineState g) Process [(SMId, (Buffer, PhaseOut l))]
runPhaseM pname subs plogs idx pl mindex pb action = consume [(idx, (pb,pl,action))] where
    consume []     = return []
    consume ((idm, (b,l,p)):ps) = do
      (t,phases,_) <- reverseOn (\x -> case x ^. _1 . _2 of SM_Complete{} -> True ; _ -> False)
                                (zoom engineStateGlobal $ go l plogs b p)
      phases' <- for phases $ \z -> (,z) <$> (engineStateMaxId <<%= (+1))
      ((idm,t):) <$> consume (ps ++ phases')

    reverseOn :: (a -> Bool) -> State.StateT (EngineState g) Process a -> State.StateT (EngineState g) Process a
    reverseOn p f = do
      old <- use engineStateGlobal
      x <- f
      unless (p x) (engineStateGlobal .= old)
      return x

    go :: l -> Maybe SMLogs -> Buffer -> PhaseM g l a
       -> State.StateT g Process ((Buffer, PhaseOut l), [(Buffer, l, PhaseM g l ())], Maybe a)
    go l lgs buf a = lift (viewT a) >>= inner
      where
        inner :: ProgramViewT (PhaseInstr g l) Process a
              -> State.StateT g Process ((Buffer, PhaseOut l), [(Buffer, l, PhaseM g l ())], Maybe a)
        inner (Return t) = return ((buf, SM_Complete l [] lgs), [], Just t)
        inner (Catch f h :>>= next) = do
          ef <- Catch.try $ go l lgs buf f
          case ef of
            Right ((buf', out), sm, mr) -> case (out,mr) of
              -- XXX: pass sm in continuation passing style
              (SM_Complete l' [] lgs', Just r) -> do
                  (z, sm',t) <- go l' lgs' buf' $ next r
                  return (z, sm++sm',t)
              _ -> return ((buf, out), sm, Nothing)
            Left se -> case fromException se of
              -- Rethrow exception if type does not match
              Nothing -> liftIO $ throwIO se
              Just e  -> do
                -- Run exception handler
                ((buf', out), sm, mr) <- go l lgs buf (h e)
                case (out, mr) of
                  -- If handler completes and have result, then continue
                  (SM_Complete l' _ lgs', Just r) -> do
                     (z, sm', s) <- go l' lgs' buf' (next r)
                     return (z, sm++sm',s)
                  -- Otherwise return current suspention
                  _ -> return ((buf', out), sm, Nothing)
        inner (Continue ph :>>= _) =
          return ((buf, SM_Complete l [ph] lgs), [], Nothing)
        inner (Get Global :>>= k)   = go l lgs buf . k =<< State.get
        inner (Get Local  :>>= k)   = go l lgs buf $ k l
        inner (Put Global s :>>= k) = State.put s >> (go l lgs buf $ k ())
        inner (Put Local s :>>= k) = go s lgs buf $ k ()
        inner (Stop :>>= _)        = return ((buf, SM_Stop lgs), [], Nothing)
        inner (Fork typ naction :>>= k) =
          let buf' = case typ of
                      NoBuffer -> emptyFifoBuffer
                      CopyBuffer -> buf
                      CopyNewerBuffer -> maybe buf (`bufferDrop` buf) mindex
          in do ((b', out), sm, s) <- go l (fmap (const S.empty) lgs) buf (k ())
                return ((b', out), (buf',l,naction):sm, s)
        inner (Lift m :>>= k) = do
          a' <- lift m
          go l lgs buf (k a')
        inner (Suspend :>>= _) =
          return ((buf, SM_Suspend lgs),[], Nothing)
        inner (Publish e :>>= k) = do
          lift $ notifySubscribers subs e
          go l lgs buf (k ())
        inner (PhaseLog ctx lg :>>= k) =
          let new_logs = fmap (S.|> (pname,ctx,lg)) lgs in
          go l new_logs buf $ k ()
        inner (Switch xs :>>= _) =
          return ((buf, SM_Complete l xs lgs), [], Nothing)
        inner (Peek idd :>>= k) = do
          case bufferPeek idd buf of
            Nothing -> return ((buf, SM_Suspend lgs), [], Nothing)
            Just r  -> go l lgs buf $ k r
        inner (Shift idd :>>= k) =
            case bufferGetWithIndex idd buf of
              Nothing   -> return ((buf, SM_Suspend lgs),[], Nothing)
              Just (r, z, buf') -> go l lgs buf' $ k (r,z)
