{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeOperators              #-}
-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
--
module Network.CEP.Types where

import Prelude hiding ((.))
import Data.ByteString
import Data.Dynamic
import GHC.Generics

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Monad.State.Strict
import Control.Wire
import Data.Binary
import Data.MultiMap

data Sub a = Sub deriving (Generic, Typeable)

instance Binary a => Binary (Sub a)

data Msg
    = SubRequest Subscribe
    | Other Input

data RuleState s =
    RuleState
    { cepMatches :: [Match Dynamic]
    , cepRules   :: ComplexEvent s Dynamic s
    }

newtype RuleM s a = RuleM (State (RuleState s) a)
    deriving (Functor, Applicative, Monad, MonadState (RuleState s))

newtype CEP a = CEP (StateT Bookkeeping Process a)
                  deriving (Functor, Applicative, Monad, MonadIO)

newtype Ctx s = Ctx (Timed NominalDiffTime s)
              deriving (Monoid, HasTime NominalDiffTime)

type ComplexEvent s a b = Wire (Ctx s) () CEP a b

data Bookkeeping =
    Bookkeeping { _subscribers :: !(MultiMap Fingerprint ProcessId) }

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

infixr 6 .+.

data a .+. b = Ask

infixr 6 .++.

data a .++. b = AskAppend

data Nil

data Only a = Only

data Input = forall b.
    Input { inputFingerprint :: Fingerprint
          , inputMsg         :: b
          }

matchInput :: forall a. Serializable a => a -> Match Msg
matchInput _ = match go
  where
    go (x :: a) = do
        let input =
              Input { inputFingerprint = fingerprint (undefined :: a)
                    , inputMsg         = x
                    }

        return $ Other input

class TypeMatch a where
    typematch :: a -> [Match Msg]

instance TypeMatch Nil where
    typematch _ = []

instance (Serializable a, TypeMatch b) => TypeMatch (a .+. b) where
    typematch _ = matchInput (undefined :: a) : typematch (undefined :: b)

instance (TypeMatch a, TypeMatch b) => TypeMatch (a .++. b) where
    typematch _ = typematch (undefined :: a) ++ typematch (undefined :: b)

instance Serializable a => TypeMatch (Only a) where
    typematch _ = [ matchInput (undefined :: a) ]

instance Binary a => Binary (Published a)

asSub :: a -> Sub a
asSub _ = Sub

dstate :: Ctx s -> s
dstate (Ctx (Timed _ s)) = s

liftProcess :: Process a -> CEP a
liftProcess m = CEP $ lift m

runCEP :: CEP a -> Bookkeeping -> Process (a, Bookkeeping)
runCEP (CEP m) s = runStateT m s

initRuleState :: RuleState s
initRuleState = RuleState
                { cepMatches = []
                , cepRules   = mkEmpty
                }

runRuleM :: RuleM s a -> RuleState s
runRuleM (RuleM m) = execState m initRuleState

addRule :: Match Dynamic
        -> ComplexEvent s Dynamic s
        -> RuleState s
        -> RuleState s
addRule m r s =
    s { cepMatches = cepMatches s ++ [m]
      , cepRules   = cepRules s <|> r
      }

dynEvent :: Typeable a => ComplexEvent s Dynamic a
dynEvent = mkPure_ $ \dyn ->
    case fromDynamic dyn of
      Just a -> Right a
      _      -> Left ()

define :: forall a b s. (Monoid s, Serializable a)
       => ComplexEvent s a b
       -> (b -> StateT s Process ())
       -> RuleM s ()
define w k = do
    let m       = match $ \(x :: a) -> return $ toDyn x
        rule    = observe . w . dynEvent
        observe = mkGen $ \s b -> do
          s' <- liftProcess $ execStateT (k b) (dstate s)
          return (Right s', observe)

    modify $ addRule m rule
