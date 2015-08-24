{-# LANGUAGE GADTs      #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module Network.CEP.Phase
  ( runPhase
  , PhaseOut(..)
  ) where

import Data.Foldable (for_)
import Data.Typeable

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Monad.Operational
import qualified Data.MultiMap as MM
import qualified Data.Sequence as S

import Network.CEP.Buffer
import Network.CEP.Types

data PhaseOut l where
    SM_Complete :: l -> [PhaseHandle] -> Maybe SMLogs -> PhaseOut l
    -- ^ The phase has finished processing, yielding a new set of SMs to run.
    SM_Suspend  :: Maybe SMLogs -> PhaseOut l
    -- ^ The phase has stopped temporarily, and should be invoked again.
    SM_Stop     :: Maybe SMLogs -> PhaseOut l
    -- ^ The phase has stopped, and should not be executed again.

-- | Notifies every subscriber that a message those are interested in has
--   arrived.
notifySubscribers :: Serializable a => Subscribers -> a -> Process ()
notifySubscribers subs a = do
    self <- getSelfPid
    for_ (MM.lookup (fingerprint a) subs) $ \pid ->
      usend pid (Published a self)

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
         -> g             -- ^ Global state.
         -> l             -- ^ Local state.
         -> Buffer        -- ^ Current buffer.
         -> Phase g l     -- ^ Phase handle to interpret.
         -> Process (g, [(Buffer,PhaseOut l)])
runPhase subs logs g l buf ph =
    case _phCall ph of
      DirectCall action -> runPhaseM (_phName ph) subs logs g l buf action
      ContCall tpe k -> do
        res <- extractMsg tpe g l buf
        case res of
          Just (Extraction new_buf b) -> do
            result <- runPhaseM (_phName ph) subs logs g l new_buf (k b)
            for_ (snd result) $ \(_,out) ->
              case out of
                SM_Complete{} -> notifySubscribers subs b
                _             -> return ()
            return result
          Nothing -> do
            return (g, [(buf, SM_Suspend logs)])

-- | 'Phase' state machine execution main loop. Runs until its stack is empty
--   except if get a 'Suspend' or 'Stop' instruction.
--   This execution is run goes not switch between forked threads. First parent
--   thread is executed to a safe point, and then child is run.
runPhaseM :: forall g l . String -- ^ Process name.
          -> Subscribers         -- ^ List of events subscribers.
          -> Maybe SMLogs        -- ^ Logs.
          -> g                   -- ^ Global state.
          -> l                   -- ^ Local state
          -> Buffer              -- ^ Buffer
          -> PhaseM g l ()
          -> Process (g, [(Buffer, PhaseOut l)])
runPhaseM pname subs plogs pg pl pb action = do
    (g,t@(_,out), phases) <- go pg pl plogs pb action
    let g' = case out of
                SM_Complete{} -> g
                _ -> pg
    fmap (t:) <$> consume g' phases
  where
    consume g []     = return (g, [])
    consume g ((b,l,p):ps) = do
      (g',t@(_,out), phases) <- go g l plogs b p
      case out of
        SM_Complete{} -> fmap (t:) <$> consume g' (ps++phases)
        _             -> fmap (t:) <$> consume g  (ps++phases)
    go g l lgs buf a = viewT a >>= inner
      where
        inner (Return _) = return (g, (buf, SM_Complete l [] lgs), [])
        inner (Continue ph :>>= _)  = return (g, (buf, SM_Complete l [ph] lgs), [])
        inner (Get Global :>>= k)   = go g l lgs buf $ k g
        inner (Get Local  :>>= k)   = go g l lgs buf $ k l
        inner (Put Global s :>>= k) = go s l lgs buf $ k ()
        inner (Put Local  s :>>= k) = go g s lgs buf $ k ()
        inner (Stop :>>= _)         = return (g, (buf, SM_Stop lgs), [])
        inner (Fork typ naction :>>= k) =
          let buf' = case typ of
                      NoBuffer -> emptyFifoBuffer
                      CopyBuffer -> buf
          in do (g', (b', out), sm) <- go g l (fmap (const S.empty) lgs) buf (k ())
                return (g', (b', out), (buf',l,naction):sm)
        inner (Lift m :>>= k) = do
          a' <- m
          go g l lgs buf (k a')
        inner (Suspend :>>= _) =
          return (g, (buf, SM_Suspend lgs),[])
        inner (Publish e :>>= k) = do
          notifySubscribers subs e
          go g l lgs buf (k ())
        inner (PhaseLog ctx lg :>>= k) =
          let new_logs = fmap (S.|> (pname,ctx,lg)) lgs in
          go g l new_logs buf $ k ()
        inner (Switch xs :>>= _) =
          return (g, (buf, SM_Complete l xs lgs), [])
        inner (Peek idx :>>= k) = do
          case bufferPeek idx buf of
            Nothing -> return (g, (buf, SM_Suspend lgs), [])
            Just r  -> go g l lgs buf $ k r
        inner (Shift idx :>>= k) =
            case bufferGetWithIndex idx buf of
              (Nothing, _)   -> return (g,(buf, SM_Suspend lgs),[])
              (Just r, buf') -> go g l lgs buf' $ k r
