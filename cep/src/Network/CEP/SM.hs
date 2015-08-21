{-# LANGUAGE GADTs      #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
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

data SM_Exe

data SM_In g l a where
    PushMsg :: Typeable m => m -> SM_In g l ()
    Execute :: Subscribers -> (Phase g l) -> SM_In g l SM_Exe

data SM_Out g l a where
    SM_Complete :: g -> l -> [PhaseHandle] -> SM_Out g l SM_Exe
    SM_Suspend  :: SM_Out g l SM_Exe
    SM_Stop     :: SM_Out g l SM_Exe
    SM_Unit     :: SM_Out g l ()

smLocalState :: SM_Out g l a -> Maybe l
smLocalState (SM_Complete _ l _) = Just l
smLocalState _                   = Nothing

-- | Notifies every subscriber that a message those are interested in has
--   arrived.
notifySubscribers :: Serializable a => Subscribers -> a -> Process ()
notifySubscribers subs a = do
    self <- getSelfPid
    for_ (MM.lookup (fingerprint a) subs) $ \pid ->
      usend pid (Published a self)

-- | Phase Mealy finite state machine.
newtype SM g l =
    SM { unSM :: forall a. g -> SM_In g l a
              -> Process (g, [(Buffer,Buffer, SM_Out g l a, SM g l)]) }

newSM :: Buffer -> Maybe SMLogs -> l -> SM g l
newSM buf logs l = SM $ mainSM buf logs l

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

-- | Execute a 'Phase' state machine. If it's 'DirectCall' 'Phase', it's runned
--   directly. If it's 'ContCall' one, we make sure we can satisfy its
--   dependency. Otherwise, we 'Suspend' that phase.
mainSM :: forall g l a . Buffer
       -> Maybe SMLogs
       -> l
       -> g
       -> SM_In g l a
       -> Process (g,[(Buffer, Buffer, SM_Out g l a, SM g l)])
mainSM buf logs l g (PushMsg msg) =
    let new_buf = bufferInsert msg buf in
    return (g, [(buf, new_buf, SM_Unit, SM $ mainSM new_buf logs l)])
mainSM buf logs l g (Execute subs ph) =
    case _phCall ph of
      DirectCall action -> do
        (g',results) <- runPhaseM (_phName ph) subs logs g l buf action
        return (g', map nextState results)
      ContCall tpe k -> do
        res <- extractMsg tpe g l buf
        case res of
          Just (Extraction new_buf b) -> do
            (g', results) <- runPhaseM (_phName ph) subs logs g l new_buf (k b)
            results' <- mapM (nextStateNotify b) results
            return (g', results')
          Nothing -> do
            return (g, [(buf, buf, SM_Suspend, SM $ mainSM buf logs l)])
  where
    nextState (b,SM_Stop)    = (b,buf, SM_Stop, SM $ mainSM buf logs l)
    nextState (b,SM_Suspend) = (b,buf, SM_Suspend, SM $ mainSM buf logs l)
    nextState (b,s)          = (b,b, s, SM $ mainSM b logs (fromMaybe l $ smLocalState s))
    nextStateNotify :: Serializable b => b -> (Buffer, SM_Out g l SM_Exe) -> Process (Buffer,Buffer, SM_Out g l SM_Exe, SM g l)
    nextStateNotify b s@(_,SM_Complete{}) = do
      notifySubscribers subs b
      return (nextState s)
    nextStateNotify _ s = return $ nextState s

-- | 'Phase' state machine execution main loop. Runs until its stack is empty
--   except if get a 'Suspend' or 'Stop' instruction.
--   This execution is run goes not switch between forked threads. First parent
--   thread is executed to a safe point, and then child is run.
runPhaseM :: forall g l . String            -- ^ Process name.
          -> Subscribers       -- ^ List of events subscribers.
          -> Maybe SMLogs      -- ^ Logs?.
          -> g                 -- ^ Global state.
          -> l                 -- ^ Local state
          -> Buffer            -- ^ Buffer
          -> PhaseM g l ()
          -> Process (g, [(Buffer, SM_Out g l SM_Exe)])
runPhaseM pname subs plogs pg pl pb action = do
    (g,t@(_,out), phases) <- go pg pl plogs pb action
    let g' = case out of
                SM_Complete{} -> g
                _ -> pg
    fmap (t:) <$> consume g' phases
  where
    consume :: g -> [(Buffer, l, PhaseM g l ())] -> Process (g, [(Buffer, SM_Out g l SM_Exe)])
    consume g []     = return (g, [])
    consume g ((b,l,p):ps) = do
      (g',t@(_,out), phases) <- go g l plogs b p
      case out of
        SM_Complete{} -> fmap (t:) <$> consume g' (ps++phases)
        _             -> fmap (t:) <$> consume g  (ps++phases)

    go :: g -> l -> Maybe SMLogs -> Buffer -> PhaseM g l ()
            -> Process (g, (Buffer, SM_Out g l SM_Exe), [(Buffer,l, PhaseM g l ())])
    go g l lgs buf a = viewT a >>= inner
      where
        inner (Return _) = return (g, (buf, SM_Complete g l []), [])
        inner (Continue ph :>>= _)  = return (g, (buf, SM_Complete g l [ph]), [])
        inner (Save s :>>= k)       = go s l lgs buf $ k ()
        inner (Load :>>= k)         = go g l lgs buf $ k g
        inner (Get Global :>>= k)   = go g l lgs buf $ k g
        inner (Get Local  :>>= k)   = go g l lgs buf $ k l
        inner (Put Global s :>>= k) = go s l lgs buf $ k ()
        inner (Put Local  s :>>= k) = go g s lgs buf $ k ()
        inner (Stop :>>= _)         = return (g, (buf, SM_Stop), [])
        inner (Fork typ naction :>>= k) =
          let buf' = case typ of
                      NoBuffer -> emptyFifoBuffer
                      CopyBuffer -> buf
          in do (g', (b', out), sm) <- go g l lgs buf (k ())
                return (g', (b', out), (buf',l,naction):sm)
        inner (Lift m :>>= k) = do
          a' <- m
          go g l lgs buf (k a')
        inner (Suspend :>>= _) =
          return (g, (buf, SM_Suspend),[])
        inner (Publish e :>>= k) = do
          notifySubscribers subs e
          go g l lgs buf (k ())
        inner (PhaseLog ctx lg :>>= k) =
          let new_logs = fmap (S.|> (pname,ctx,lg)) lgs in
          go g l new_logs buf $ k ()
        inner (Switch xs :>>= _) =
          return (g, (buf, SM_Complete g l xs), [])
        inner (Peek idx :>>= k) = do
          case bufferPeek idx buf of
            Nothing -> return (g, (buf, SM_Suspend), [])
            Just r  -> go g l lgs buf $ k r
        inner (Shift idx :>>= k) =
            case bufferGetWithIndex idx buf of
              (Nothing, _)   -> return (g,(buf, SM_Suspend),[])
              (Just r, buf') -> go g l lgs buf' $ k r
