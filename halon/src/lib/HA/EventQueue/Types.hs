module HA.EventQueue.Types
    ( EventId(..)
    , HAEvent(..)
    ) where

import Control.Distributed.Process (ProcessId)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Data.Function (on)
import Data.Word (Word64)


-- | Globally unique event identifier.
data EventId = EventId
    { eventNodeId  :: !ProcessId
    , eventCounter :: {-# UNPACK #-} !Word64
    } deriving (Eq, Ord, Generic, Typeable)

instance Binary EventId

-- | An HA event. Generated by satellites.
data HAEvent a = HAEvent
    { eventId      :: {-# UNPACK #-} !EventId
    , eventPayload :: a
    , eventHops    :: [ProcessId]
    } deriving (Generic, Typeable)

instance Binary a => Binary (HAEvent a)

instance Eq (HAEvent a) where
    (==) = (==) `on` eventId

instance Ord (HAEvent a) where
    compare = compare `on` eventId
