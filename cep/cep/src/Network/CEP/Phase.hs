{-# LANGUAGE GADTs      #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -Wall -Werror #-}
-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
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
import           Control.Monad.Operational (viewT, ProgramViewT((:>>=), Return))
import           Control.Exception (fromException, throwIO)
import qualified Control.Monad.Catch as Catch
import           Control.Monad (unless)
import           Control.Monad.Trans
import qualified Control.Monad.Trans.State.Strict as State
import           Data.Sequence (Seq((:<|)), (<|), (><), empty)
import qualified Data.Map as M
import           Data.Foldable (traverse_, toList)
import           Control.Lens ((^.), (.=), zoom, use, assign, _1, _2)

import           Network.CEP.Buffer
import qualified Network.CEP.Log as Log
import           Network.CEP.Types hiding (Seq)

-- | 'SM_Complete': The phase has finished processing, yielding a new
-- set of SMs to run.
--
-- 'SM_Suspend': The phase has stopped temporarily, and should be
-- invoked again.
--
-- 'SM_Stop': The phase has stopped, and should not be executed again.
data PhaseOut l where
    SM_Complete :: l -> [Jump PhaseHandle] -> PhaseOut l
    SM_Suspend  :: PhaseOut l
    SM_Stop     :: PhaseOut l

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
extractMsg :: (Application app, Serializable a, Serializable b)
           => PhaseType app l a b
           -> l
           -> Buffer
           -> State.StateT (GlobalState app) Process (Maybe (Extraction b))
extractMsg typ l buf =
    case typ of
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
                          }
                in return $ Just ext
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
                  }
        in Just ext
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
                  }
        in Just ext
    go _ _ _ = Nothing

-- | Execute a single 'Phase'
--
--   If it's 'DirectCall' 'Phase', it's run
--   directly. If it's 'ContCall' one, we make sure we can satisfy its
--   dependency. Otherwise, we 'Suspend' that phase.
--
--   Call is evaluated until a safe point that is either final 'return'
--   or 'suspend' or 'commit'.
runPhase :: (Application app, g ~ GlobalState app)
         => String -- ^ Rule name
         -> Subscribers   -- ^ Subscribers.
         -> Maybe (SMLogger app l) -- ^ Current logger.
         -> SMId          -- ^ State machine id.
         -> l             -- ^ Local state.
         -> Buffer        -- ^ Current buffer.
         -> Phase app l     -- ^ Phase handle to interpret.
         -> State.StateT (EngineState g) Process [(SMId, (Buffer, PhaseOut l))]
runPhase rn subs logs idm l buf ph =
    case _phCall ph of
      DirectCall action -> runPhaseM rn pname subs logs idm l Nothing buf action
      ContCall tpe k -> do
        res <- zoom engineStateGlobal $ extractMsg tpe l buf
        case res of
          Just (Extraction new_buf b idx) -> do
            result <- runPhaseM rn pname subs logs idm l (Just idx) new_buf (k b)
            for_ (snd <$> result) $ \(_,out) ->
              case out of
                SM_Complete{} -> lift $ notifySubscribers subs b
                _             -> return ()
            return result
          Nothing -> return [(idm, (buf, SM_Suspend))]
  where
    pname = _phName ph

-- | 'Phase' state machine execution main loop. Runs until its stack is empty
--   except if get a 'Suspend' or 'Stop' instruction.
--   This execution is run goes not switch between forked threads. First parent
--   thread is executed to a safe point, and then child is run.
runPhaseM :: forall app g l. (Application app, g ~ GlobalState app)
          => String -- ^ Rule name
          -> String  -- ^ Process name.
          -> Subscribers         -- ^ List of events subscribers.
          -> Maybe (SMLogger app l) -- ^ Logs.
          -> SMId                -- ^ Machine index
          -> l                   -- ^ Local state
          -> Maybe Index         -- ^ Current index.
          -> Buffer              -- ^ Buffer
          -> PhaseM app l ()
          -> State.StateT (EngineState g) Process [(SMId, (Buffer, PhaseOut l))]
runPhaseM rname pname subs logger idx pl mindex pb ph0 = do
    g <- use engineStateGlobal
    for_ logger $ \lf -> lift $ (sml_logger lf)
                                (Log.Event (Log.Location rname (getSMId idx) pname) Log.PhaseEntry) g
    consume $ (idx, pb, pl, ph0) <| empty
  where
    consume ((idm, b, l, ph) :<| phs) = do
      (out, phs', _) <- reverseOn (\x -> case x^._1._2 of
                                           SM_Complete{} -> True
                                           _             -> False)
                                  (go idm l b ph)
      ((idm, out) :) <$> consume (phs >< phs')
    consume _ = return []

    logJump :: Jump PhaseHandle -> Log.Jump
    logJump (NormalJump a) = Log.NormalJump $ _phHandle a
    logJump (OnTimeJump t a) = Log.TimeoutJump (toInt t) (_phHandle a)
      where
        toInt (Relative x) = x
        toInt (Absolute _) = (-1) -- XXX Fix this

    logForkType :: ForkType -> Log.ForkType
    logForkType NoBuffer = Log.NoBuffer
    logForkType CopyBuffer = Log.CopyBuffer
    logForkType CopyNewerBuffer = Log.CopyNewerBuffer

    reverseOn :: (a -> Bool)
              -> State.StateT (EngineState g) Process a
              -> State.StateT (EngineState g) Process a
    reverseOn p f = do
      old <- use engineStateGlobal
      x <- f
      unless (p x) (engineStateGlobal .= old)
      return x

    go :: SMId -> l -> Buffer -> PhaseM app l a
       -> State.StateT (EngineState g) Process
          ((Buffer, PhaseOut l), Seq (SMId, Buffer, l, PhaseM app l ()), Maybe a)
    go ids l buf a = lift (viewT a) >>= inner where
      loc :: Log.Location
      loc = Log.Location rname (getSMId ids) pname

      logIt evt = do
        g <- use engineStateGlobal
        for_ logger $ \lf -> lift $ (sml_logger lf) (Log.Event loc evt) g

      inner :: ProgramViewT (PhaseInstr app l) Process a
            -> State.StateT (EngineState g) Process
               ((Buffer, PhaseOut l), Seq (SMId, Buffer, l, PhaseM app l ()), Maybe a)
      inner (Return t) = return ((buf, SM_Complete l []), empty, Just t)
      inner (Catch f h :>>= next) = do
        ef <- Catch.try $ go ids l buf f
        case ef of
          Right ((buf', out), phs, mr) -> case (out, mr) of
            -- XXX: pass sm in continuation passing style
            (SM_Complete l' [], Just r) -> do
                (z, phs', t) <- go ids l' buf' $ next r
                return (z, phs >< phs', t)
            _ -> return ((buf, out), phs, Nothing)
          Left se -> case fromException se of
            -- Rethrow exception if type does not match
            Nothing -> liftIO $ throwIO se
            Just e  -> do
              -- Run exception handler
              ((buf', out), phs, mr) <- go ids l buf (h e)
              case (out, mr) of
                -- If handler completes and have result, then continue
                (SM_Complete l' _, Just r) -> do
                   (z, phs', s) <- go ids l' buf' (next r)
                   return (z, phs >< phs', s)
                -- Otherwise return current suspention
                _ -> return ((buf', out), phs, Nothing)
      inner (Continue ph :>>= _) = do
        logIt $ Log.Continue (Log.ContinueInfo (logJump ph))
        return ((buf, SM_Complete l [ph]), empty, Nothing)
      inner (Get Global :>>= k)   = go ids l buf . k =<< use engineStateGlobal
      inner (Get Local  :>>= k)   = go ids l buf $ k l
      inner (Put Global s :>>= k) = assign engineStateGlobal s >> (go ids l buf $ k ())
      inner (Put Local s :>>= k) = do
        for_ (logger >>= sml_state_logger) $ \se -> do
          logIt . Log.StateLog $ Log.StateLogInfo (se s)
        go ids s buf $ k ()
      inner (Stop :>>= _) = do
        logIt Log.Stop
        return ((buf, SM_Stop), empty, Nothing)
      inner (Fork typ naction :>>= k) =
        let buf' = case typ of
                    NoBuffer -> emptyFifoBuffer
                    CopyBuffer -> buf
                    CopyNewerBuffer -> maybe buf (`bufferDrop` buf) mindex
        in do
          ((b', out), phs, s) <- go ids l buf (k ())
          smId@(SMId i) <- nextSmId
          logIt $ Log.Fork $ Log.ForkInfo (logForkType typ) i
          return ((b', out), (smId, buf', l, naction) <| phs, s)
      inner (Lift m :>>= k) = do
        a' <- lift m
        go ids l buf (k a')
      inner (Suspend :>>= _) = do
        logIt Log.Suspend
        return ((buf, SM_Suspend), empty, Nothing)
      inner (Publish e :>>= k) = do
        lift $ notifySubscribers subs e
        go ids l buf (k ())
      inner (AppLog evt :>>= k) = do
        logIt $ Log.ApplicationLog $ Log.ApplicationLogInfo evt
        go ids l buf $ k ()
      inner (Switch xs :>>= _) = do
        logIt $ Log.Switch $ Log.SwitchInfo . toList $ (logJump <$> xs)
        return ((buf, SM_Complete l xs), empty, Nothing)
      inner (Peek idd :>>= k) = do
        case bufferPeek idd buf of
          Nothing -> return ((buf, SM_Suspend), empty, Nothing)
          Just r  -> go ids l buf $ k r
      inner (Shift idd :>>= k) =
          case bufferGetWithIndex idd buf of
            Nothing   -> return ((buf, SM_Suspend), empty, Nothing)
            Just (r, z, buf') -> go ids l buf' $ k (r,z)
