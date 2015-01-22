-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--

module Network.CEP
       ( module Network.CEP.Types
       , decoded
       , listen
       , listenMessage
       , publish
       , repeatedly
       , repeatedlyOnMessage
       , runProcessor
       , simpleSubscribe
       , subscribe
       ) where

import Prelude hiding ((.), id)
import Data.Monoid

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Monad.State hiding (state)
import           Control.Wire.Core
import qualified Data.MultiMap as M
import           FRP.Netwire

import Network.CEP.Types

simpleSubscribe :: Serializable a => ProcessId -> Sub a -> Process ()
simpleSubscribe pid sub = do
    self <- getSelfPid
    let key  = fingerprint sub
        fgBs = encodeFingerprint key
    send pid (Subscribe fgBs self)

subscribe :: Serializable a => ProcessId -> Sub a -> CEP ()
subscribe pid sub = liftProcess $ simpleSubscribe pid sub

publish :: Serializable a => a -> CEP ()
publish a = CEP $ do
    subs <- gets _subscribers
    self <- lift getSelfPid
    let sub = asSub a
        key = fingerprint sub

    lift $ forM_ (M.lookup key subs) $ \pid ->
      send pid (Published a self)

repeatedly :: Monoid s => (s -> a -> CEP s) -> ComplexEvent s a s
repeatedly k = go
  where
    go = mkGen $ \t a -> do
        s' <- k (dstate t) a
        return (Right s', go)

repeatedlyOnMessage :: (Monoid s, Serializable a)
                    => (s -> a -> CEP s)
                    -> ComplexEvent s Message s
repeatedlyOnMessage k = repeatedly k . decoded

listen :: (a -> CEP b) -> ComplexEvent s a ()
listen k = mkGen_ $ \a -> do
    _ <- k a
    return (Right ())

listenMessage :: Serializable a => (a -> CEP b) -> ComplexEvent s Message ()
listenMessage k = listen k . decoded

awaitMessage :: [Match (Msg i)] -> Process (Msg i)
awaitMessage ms = receiveWait xs
  where
    xs = match (return . SubRequest) : ms

runProcessor :: ComplexEvent s i s
             -> [Match (Msg i)]
             -> s
             -> Process b
runProcessor startWire ms start =
    go emptyBookkeeping clockSession start startWire
  where
    emptyBookkeeping = Bookkeeping M.empty
    go book session state wire = do
        cepMsg <- awaitMessage ms
        case cepMsg of
          SubRequest sub ->
            let key     = decodeFingerprint $ _subType sub
                value   = _subPid sub
                newMap  = M.insert key value (_subscribers book)
                newBook = book { _subscribers = newMap } in
            go newBook session state wire
          Other msg -> do
            (step, nextSession) <- stepSession session
            let action = stepWire wire (Ctx $ step state) (Right msg)
            ((res, newWire), newBook) <- runCEP action book
            case res of
              Right newState -> go newBook nextSession newState newWire
              Left _         -> go newBook nextSession state newWire

decoded :: Serializable a => ComplexEvent s Message a
decoded = mkGen_ $ \msg -> do
    mA <- unwrapMessage msg
    case mA of
      Just a -> Right a <$ publish a
      _      -> return $ Left mempty
