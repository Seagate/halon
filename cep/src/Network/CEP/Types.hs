{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
--
module Network.CEP.Types where

import Data.ByteString
import Data.Typeable
import GHC.Generics

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Monad.State.Strict
import Data.Binary
import Data.MultiMap
import Data.Time
import FRP.Netwire

data Sub a = Sub deriving (Generic, Typeable)

instance Binary a => Binary (Sub a)

data Msg a
    = SubRequest Subscribe
    | Other a

newtype CEP a = CEP (StateT Bookkeeping Process a)
                  deriving (Functor, Applicative, Monad)

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

instance Binary a => Binary (Published a)

asSub :: a -> Sub a
asSub _ = Sub

dstate :: Ctx s -> s
dstate (Ctx (Timed _ s)) = s

liftProcess :: Process a -> CEP a
liftProcess m = CEP $ lift m

runCEP :: CEP a -> Bookkeeping -> Process (a, Bookkeeping)
runCEP (CEP m) s = runStateT m s

userMsg :: a -> Msg a
userMsg = Other
