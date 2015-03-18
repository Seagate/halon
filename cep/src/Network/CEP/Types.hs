{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeOperators              #-}
-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
--
module Network.CEP.Types where

import           Prelude hiding ((.))
import           Data.ByteString
import           Data.Dynamic
import qualified Data.MultiMap as M
import           GHC.Generics

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Monad.State.Strict
import Control.Wire
import Data.Binary
import Data.MultiMap

data Sub a = Sub deriving (Generic, Typeable)

instance Binary a => Binary (Sub a)

data Handled = forall a. Typeable a => Handled a

data Msg
    = SubRequest Subscribe
    | Other Dynamic

data RuleState s =
    RuleState
    { cepMatches    :: ![Match Msg]
    , cepRules      :: !(ComplexEvent s Dynamic Handled)
    , cepFinalizers :: (s -> Process s)
    , cepSpes       :: forall a. Typeable a => a -> s -> Process s
    }

newtype RuleM s a = RuleM (State (RuleState s) a)
    deriving (Functor, Applicative, Monad, MonadState (RuleState s))

newtype CEP s a = CEP (StateT (Bookkeeping s) Process a)
                  deriving (Functor, Applicative, Monad, MonadIO)

instance MonadState s (CEP s) where
    get = CEP $ gets _state

    put s = CEP $ modify $ \b -> b { _state = s }

type ComplexEvent s a b = Wire (Timed NominalDiffTime ()) () (CEP s) a b

data Bookkeeping s =
    Bookkeeping
    { _subscribers :: !(MultiMap Fingerprint ProcessId)
    , _state       :: !s
    }

data Subscribe =
    Subscribe
    { _subType :: !ByteString
    , _subPid  :: !ProcessId
    } deriving (Show, Typeable, Generic)

instance Binary Subscribe

data Published a =
    Published
    { pubValue :: !a
    , pubPid   :: !ProcessId
    } deriving (Show, Typeable, Generic)

instance Binary a => Binary (Published a)

asSub :: a -> Sub a
asSub _ = Sub

publish :: Serializable a => a -> CEP s ()
publish a = CEP $ do
    subs <- gets _subscribers
    self <- lift getSelfPid
    let sub = asSub a
        key = fingerprint sub

    lift $ forM_ (M.lookup key subs) $ \pid ->
      send pid (Published a self)

liftProcess :: Process a -> CEP s a
liftProcess m = CEP $ lift m

runCEP :: CEP s a -> Bookkeeping s -> Process (a, Bookkeeping s)
runCEP (CEP m) s = runStateT m s

getUsrState :: CEP s s
getUsrState = CEP $ gets _state

setUsrState :: s -> CEP s ()
setUsrState s = CEP $ modify (\b -> b { _state = s})

initRuleState :: RuleState s
initRuleState = RuleState
                { cepMatches    = []
                , cepRules      = mkEmpty
                , cepFinalizers = return
                , cepSpes       = \_ s -> return s
                }

runRuleM :: RuleM s a -> RuleState s
runRuleM (RuleM m) = execState m initRuleState

addRule :: Match Msg
        -> ComplexEvent s Dynamic Handled
        -> RuleState s
        -> RuleState s
addRule m r s =
    s { cepMatches = cepMatches s ++ [m]
      , cepRules   = cepRules s <|> r
      }

addFinalizer :: (s -> Process s) -> RuleState s -> RuleState s
addFinalizer p s = s { cepFinalizers = cepFinalizers s >=> p }

addSpecialized :: Typeable a
               => (a -> s -> Process s)
               -> RuleState s
               -> RuleState s
addSpecialized k rs = rs { cepSpes = composeSpe (cepSpes rs) k }

composeSpe :: Typeable b
           => (forall a. Typeable a => a -> s -> Process s)
           -> (b -> s -> Process s)
           -> (forall a. Typeable a => a -> s -> Process s)
composeSpe pk k r s = do
    s' <- pk r s
    case cast r of
      Just b -> k b s'
      _      -> return s'

dynEvent :: Serializable a => ComplexEvent s Dynamic a
dynEvent = mkGen_ $ \dyn ->
    case fromDynamic dyn of
      Just a -> Right a <$ publish a
      _      -> return $ Left ()

addRuleFinalizer :: (s -> Process s) -> RuleM s ()
addRuleFinalizer = modify . addFinalizer

define :: forall a b s. (Serializable a, Typeable b)
       => ComplexEvent s a b
       -> (b -> CEP s ())
       -> RuleM s ()
define w k = do
    let m       = match $ \(x :: a) -> return $ Other $ toDyn x
        rule    = observe . w . dynEvent
        observe = mkGen_ $ \b -> do
          k b
          return $ Right $ Handled b

    modify $ addRule m rule

finishedBy :: Typeable a => (a -> s -> Process s) -> RuleM s ()
finishedBy = modify . addSpecialized
